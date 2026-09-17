# 减面工具 (Decimator) v2
# 顶点聚类减面；保轮廓、保贴图 UV、自动柔化、自动补洞；分块执行（界面不卡、可取消）
require 'sketchup.rb'

module SUDecimate
  VERSION = '2.0.0'.freeze
  PREF_KEY = 'SUDecimate'.freeze

  DEFAULTS = {
    ratio: 0.50,
    protect_boundary: true,
    autosmooth: true,
    smooth_angle: 30.0,
    transfer_uv: true,
    fill_holes: true,
    recursive: true
  }.freeze

  # ================= 基础工具 =================
  def self.poly_area(pts)
    n = pts.size
    return 0.0 if n < 3
    ax = ay = az = 0.0
    (0...n).each do |i|
      p1 = pts[i]
      p2 = pts[(i + 1) % n]
      ax += (p1.y - p2.y) * (p1.z + p2.z)
      ay += (p1.z - p2.z) * (p1.x + p2.x)
      az += (p1.x - p2.x) * (p1.y + p2.y)
    end
    0.5 * Math.sqrt(ax * ax + ay * ay + az * az)
  end

  def self.scope_stats(ents)
    faces = ents.grep(Sketchup::Face)
    ec = Hash.new(0)
    faces.each { |f| f.edges.each { |e| ec[e] += 1 } }
    b = 0
    ec.each_value { |c| b += 1 if c == 1 }
    { faces: faces.size, boundary: b }
  end

  def self.collect_scopes(root_entities, recursive, visited = {})
    out = []
    root_entities.each do |e|
      case e
      when Sketchup::Group
        next if visited[e]
        visited[e] = true
        out << e.entities
        out.concat(SUDecimate.collect_scopes(e.entities, recursive, visited)) if recursive
      when Sketchup::ComponentInstance
        d = e.definition
        next if d.image? || visited[d]
        visited[d] = true
        out << d.entities
        out.concat(SUDecimate.collect_scopes(d.entities, recursive, visited)) if recursive
      end
    end
    out
  end

  def self.alive_count(faces, pinned, cell)
    seen = {}
    n = 0
    faces.each do |f|
      keys = []
      f.vertices.each do |v|
        p = v.position
        keys << (pinned[v] ? [-1, v.entityID, 0] : [(p.x / cell).floor, (p.y / cell).floor, (p.z / cell).floor])
      end
      next if keys.uniq.size < 3
      sig = keys.sort
      next if seen[sig]
      seen[sig] = true
      n += keys.uniq.size - 2      # 统一按三角化后的面数统计
    end
    n
  end

  def self.find_cell(faces, pinned, target_ratio, diag)
    sample = faces
    if faces.size > 12000
      step = (faces.size / 12000.0).ceil
      sample = []
      i = 0
      while i < faces.size
        sample << faces[i]
        i += step
      end
    end
    lo = diag * 0.0005
    hi = diag * 0.35
    12.times do
      mid = (lo + hi) / 2.0
      r = SUDecimate.alive_count(sample, pinned, mid).to_f / sample.size
      if r > target_ratio
        lo = mid
      else
        hi = mid
      end
    end
    2.times do                          # 用全量再精修两次，比例更准
      mid = (lo + hi) / 2.0
      r = SUDecimate.alive_count(faces, pinned, mid).to_f / [faces.size, 1].max
      if r > target_ratio
        lo = mid
      else
        hi = mid
      end
    end
    (lo + hi) / 2.0
  end

  # ================= 分块任务 =================
  class Job
    CHUNK_PREP  = 6000     # 顶点/边统计
    CHUNK_DATA  = 2500     # 生成新面数据
    CHUNK_ERASE = 4000     # 删除旧几何
    CHUNK_BUILD = 1200     # 建面
    CHUNK_STYLE = 500      # 赋材质/图层/UV
    CHUNK_EDGE  = 5000     # 柔化
    CHUNK_HOLE  = 1200     # 补洞
    MAX_HOLE_EDGES = 20_000

    attr_reader :progress, :result

    def initialize(targets, opts, callbacks = {})
      @model = Sketchup.active_model
      raw_scopes = opts[:scopes]
      @opts = DEFAULTS.merge(opts)
      @scopes = (raw_scopes || SUDecimate.collect_scopes(targets || [], @opts[:recursive])).select { |s| s.grep(Sketchup::Face).size >= 8 }
      @res = { scopes: 0, before_faces: 0, after_faces: 0, boundary_before: 0,
               boundary_after: 0, uv_faces: 0, filled: 0, skipped_holes: 0, seconds: 0 }
      @cb = callbacks
      @si = 0
      @phase = :prep
      @progress = 0.0
      @done_faces = 0
      @cancelled = false
      @timer = nil
    end

    def start
      if @scopes.empty?
        @result = { error: '选中的对象里没有足够的面可减（可能面数太少）' }
        @cb[:done]&.call(@result)
        return
      end
      @total_faces = @scopes.inject(0) { |s, e| s + e.grep(Sketchup::Face).size }
      @model.start_operation('减面 (Decimate)', false)
      @t0 = Time.now
      @timer = UI.start_timer(0.01, true) { tick }
      @cb[:started]&.call(@total_faces, @scopes.size)
    end

    def cancel
      @cancelled = true
    end

    def tick
      return if @paused
      begin
        4.times do
          r = advance
          break if r == :park
          return finish if r == :done
        end
      rescue StandardError => e
        @error = "减面出错并已回滚：#{e.class} #{e.message} @ #{e.backtrace.to_a.first}"
        @cancelled = true
        finish
      end
    end

    def advance
      return :done if @cancelled
      return :done if @si >= @scopes.size
      s = @scopes[@si]
      case @phase
      when :prep
        prep_scope(s)
        @phase = :data
      when :data
        return :park unless data_chunk
        @phase = :erase
      when :erase
        return :park unless erase_chunk(s)
        @phase = :build
      when :build
        return :park unless build_chunk(s)
        @phase = :style
      when :style
        return :park unless style_chunk
        @phase = :smooth
      when :smooth
        return :park unless smooth_chunk(s)
        @phase = :holes
      when :holes
        return :park unless hole_chunk(s)
        st = SUDecimate.scope_stats(s)
        @res[:scopes] += 1
        @res[:before_faces] += @prep[:faces].size
        @res[:after_faces] += st[:faces]
        @res[:boundary_before] += @prep[:boundary]
        @res[:boundary_after] += st[:boundary]
        @done_faces += @prep[:faces].size
        @si += 1
        @phase = :prep
        @progress = @total_faces > 0 ? (@done_faces.to_f / @total_faces) : 1.0
        @cb[:progress]&.call(@progress, @si, @scopes.size)
      end
      @si >= @scopes.size ? :done : :more
    end

    def prep_scope(s)
      @prep = { faces: s.grep(Sketchup::Face), boundary: 0, cell: 0.0 }
      faces = @prep[:faces]
      @vpos = {}
      @ec = Hash.new(0)
      faces.each do |f|
        f.vertices.each { |v| @vpos[v] = v.position unless @vpos.key?(v) }
        f.edges.each { |e| @ec[e] += 1 }
      end
      b = 0
      @ec.each_value { |c| b += 1 if c == 1 }
      @prep[:boundary] = b
      @pinned = {}
      if @opts[:protect_boundary]
        @ec.each { |e, c| e.vertices.each { |v| @pinned[v] = true } if c == 1 }
      end
      bb = Geom::BoundingBox.new
      @vpos.each_value { |p| bb.add(p) }
      diag = Math.sqrt(bb.width**2 + bb.height**2 + bb.depth**2)
      @prep[:cell] = diag > 0 ? SUDecimate.find_cell(faces, @pinned, @opts[:ratio], diag) : 0.0

      @key_of = {}
      @rep = {}
      cell = @prep[:cell]
      if cell > 0
        acc = {}
        @vpos.each do |v, p|
          k = @pinned[v] ? [-1, v.entityID, 0] : [(p.x / cell).floor, (p.y / cell).floor, (p.z / cell).floor]
          @key_of[v] = k
          a = (acc[k] ||= [0.0, 0.0, 0.0, 0])
          a[0] += p.x; a[1] += p.y; a[2] += p.z; a[3] += 1
        end
        acc.each { |k, a| @rep[k] = Geom::Point3d.new(a[0] / a[3], a[1] / a[3], a[2] / a[3]) }
        acc = nil
      end
      @data = []
      @seen = {}
      @fi = 0
      @erase_faces = faces
      @erase_edges = nil
      @ei = 0
      @ej = 0
      @bi = 0
      @sty = 0
      @created = []
      @edge_list = nil
      @gi = 0
      @hole_list = nil
      @hi = 0
      @hole_rounds = 0
      @tw = @opts[:transfer_uv] ? Sketchup.create_texture_writer : nil
    end

    def data_chunk
      faces = @prep[:faces]
      min_area = (@prep[:cell]**2) * 1e-5
      n = 0
      while @fi < faces.size && n < CHUNK_DATA
        f = faces[@fi]
        @fi += 1
        n += 1
        next unless f.valid?
        keys = []
        f.vertices.each { |v| keys << @key_of[v] }
        next if keys.include?(nil) || keys.uniq.size < 3
        sig = keys.sort
        next if @seen[sig]
        @seen[sig] = true
        pts = keys.map { |k| @rep[k] }
        next if SUDecimate.poly_area(pts) <= min_area
        uvs = nil
        mat = f.material
        if @tw && mat && mat.texture
          begin
            uvh = f.get_UVHelper(true, false, @tw)
            uvs = f.vertices.map { |v| uvh.get_front_UVQ(v.position) }
          rescue StandardError
            uvs = nil
          end
        end
        @data << [pts, mat, f.back_material, f.layer, uvs]
      end
      @fi >= faces.size
    end

    def erase_chunk(s)
      @erase_edges ||= s.grep(Sketchup::Edge)
      if @ei < @erase_faces.size                     # 批量删除，比逐个 erase! 快很多
        batch = (@erase_faces[@ei, 3000] || []).select(&:valid?)
        @ei += 3000
        s.erase_entities(batch) unless batch.empty?
        return false
      end
      if @ej < @erase_edges.size
        batch = (@erase_edges[@ej, 6000] || []).select(&:valid?)
        @ej += 6000
        s.erase_entities(batch) unless batch.empty?
      end
      @ej >= @erase_edges.size
    end

    def build_chunk(s)
      # 统一三角化后用 PolygonMesh + fill_from_mesh 建面（C 层批量，且三角形一定合法不会丢面）
      mesh = Geom::PolygonMesh.new
      pt_index = {}
      tri_seen = {}
      @records = []                     # 每个三角形: [点数组, UV数组, 所属data索引]
      @data.each_with_index do |d, _di|
        pts = d[0]
        uvs = d[4]
        next if pts.size < 3
        tris = []
        if pts.size == 3
          tris << [0, 1, 2]
        else
          (1...(pts.size - 1)).each { |k| tris << [0, k, k + 1] }
        end
        tris.each do |(a, b, c)|
          tp = [pts[a], pts[b], pts[c]]
          tu = uvs ? [uvs[a], uvs[b], uvs[c]] : nil
          next if SUDecimate.poly_area(tp) <= 0.0
          ids = tp.map do |p|
            k = [(p.x * 1e6).round, (p.y * 1e6).round, (p.z * 1e6).round]
            pt_index[k] ||= mesh.add_point(p)
          end
          next if ids.uniq.size < 3
          key = ids.sort
          next if tri_seen[key]
          tri_seen[key] = true
          mesh.add_polygon(ids[0], ids[1], ids[2])
          @records << [tp, tu, d]
        end
      end
      if mesh.count_polygons > 0
        begin
          s.fill_from_mesh(mesh)
        rescue StandardError
        end
      end
      @faces = s.grep(Sketchup::Face)
      @map = (@faces.size == @records.size) ? (0...@faces.size).to_a : nil
      if @map.nil?
        @by_centroid = {}
        @records.each_with_index do |rec, i|
          pts = rec[0]
          c = [(pts.inject(0.0) { |s2, p| s2 + p.x } / 3.0 * 1e4).round,
               (pts.inject(0.0) { |s2, p| s2 + p.y } / 3.0 * 1e4).round,
               (pts.inject(0.0) { |s2, p| s2 + p.z } / 3.0 * 1e4).round]
          @by_centroid[c] ||= i
        end
      end
      true
    end

    def style_chunk
      n = 0
      while @sty < @faces.size && n < CHUNK_STYLE
        face = @faces[@sty]
        ri = if @map
               @map[@sty]
             else
               c = [(face.bounds.center.x * 1e4).round, (face.bounds.center.y * 1e4).round, (face.bounds.center.z * 1e4).round]
               @by_centroid[c]
             end
        @sty += 1
        n += 1
        next unless ri && face.is_a?(Sketchup::Face) && face.valid?
        rec = @records[ri]
        next unless rec
        d = rec[2]
        begin
          face.material = d[1] if d[1]
          face.back_material = d[2] if d[2]
          face.layer = d[3] if d[3]
          if rec[1] && d[1] && d[1].texture
            pairs = []
            rec[0].each_with_index { |pt, j| pairs << pt; pairs << rec[1][j] }
            face.position_material(d[1], pairs, true)
            @res[:uv_faces] += 1
          end
        rescue StandardError
        end
      end
      @sty >= @faces.size
    end

    def smooth_chunk(s)
      return true unless @opts[:autosmooth]
      @edge_list ||= s.grep(Sketchup::Edge)
      thr = @opts[:smooth_angle] * Math::PI / 180.0
      n = 0
      while @gi < @edge_list.size && n < CHUNK_EDGE
        e = @edge_list[@gi]
        @gi += 1
        n += 1
        next unless e.valid?
        fs = e.faces
        next unless fs.size == 2
        begin
          e.smooth = e.soft = (fs[0].normal.angle_between(fs[1].normal) < thr)
        rescue StandardError
        end
      end
      @gi >= @edge_list.size
    end

    def hole_chunk(s)
      return true unless @opts[:fill_holes]
      if @hole_edges.nil?
        @hole_edges = s.grep(Sketchup::Edge).select { |e| e.faces.size == 1 }
        if @hole_edges.size > MAX_HOLE_EDGES
          @res[:skipped_holes] += 1
          return true
        end
        @hole_adj = Hash.new { |h, k| h[k] = [] }
        @hole_edges.each { |e| e.vertices.each { |v| @hole_adj[v] << e } }
        @hole_used = {}
        @hi = 0
      end
      n = 0
      while @hi < @hole_edges.size && n < CHUNK_HOLE
        e0 = @hole_edges[@hi]
        @hi += 1
        n += 1
        next if @hole_used[e0] || !e0.valid? || e0.faces.size != 1
        fill_loop(s, e0)
      end
      if @hi >= @hole_edges.size && @hole_rounds < 2
        @hole_rounds += 1
        @hole_edges = nil
        return false
      end
      true
    end

    def fill_loop(s, start)
      edges = []
      verts = []
      cur = start
      v = start.vertices[0]
      closed = false
      16.times do
        break if @hole_used[cur] || !cur.valid?
        @hole_used[cur] = true
        edges << cur
        verts << v
        v = cur.vertices[0].equal?(v) ? cur.vertices[1] : cur.vertices[0]
        cand = @hole_adj[v].reject { |e| @hole_used[e] || e.equal?(cur) }
        if cand.empty?                                   # 回到起点（起点那条边已被标记 used）
          closed = @hole_adj[v].any? { |e| e.equal?(start) }
          break
        end
        if cand.size > 1                                 # 有歧义（多条边界边相交），放弃这个洞
          closed = false
          break
        end
        cur = cand.first
        if cur.equal?(start)
          closed = true
          break
        end
      end
      return unless closed && edges.size >= 3 && edges.size <= 10 && verts.size == edges.size
      pts = verts.map(&:position)
      begin
        f = s.add_face(pts)
        if f.is_a?(Sketchup::Face)
          nb = edges.map { |e| e.valid? ? e.faces.find { |x| !x.equal?(f) } : nil }.compact.first
          begin
            f.reverse! if nb && f.normal.dot(nb.normal) < 0
          rescue StandardError
          end
          @res[:filled] += 1
        end
      rescue StandardError
      end
    end

    def finish
      UI.stop_timer(@timer) if @timer
      @timer = nil
      if @cancelled
        @model.abort_operation
        @result = { error: @error || '已取消（模型已还原）' }
      elsif @opts[:debug_abort]
        @model.abort_operation
        @res[:seconds] = (Time.now - @t0).round(1)
        @result = @res.merge(debug: '已回滚')
      else
        @model.commit_operation
        @res[:seconds] = (Time.now - @t0).round(1)
        @result = @res
      end
      @cb[:done]&.call(@result)
    end
  end

  # ================= 界面 =================
  SETUP_HTML = <<~HTML
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <style>
      body{font:13px -apple-system,"PingFang SC",sans-serif;margin:14px;color:#222}
      h3{margin:0 0 8px;font-size:15px}
      .row{margin:10px 0}
      input[type=range]{width:100%}
      .val{font-weight:600;color:#0a6}
      label{display:block;margin:6px 0}
      .hint{color:#888;font-size:12px;line-height:1.5;margin-top:8px}
      .btns{text-align:right;margin-top:14px}
      button{padding:7px 14px;border-radius:6px;border:1px solid #bbb;background:#f7f7f7}
      button.primary{background:#2b7de9;border-color:#2b7de9;color:#fff;font-weight:600}
      #info{background:#f6f8fa;border:1px solid #e3e6ea;border-radius:6px;padding:8px;font-size:12px;line-height:1.6}
    </style></head><body>
    <h3>减面工具</h3>
    <div id="info">__INFO__</div>
    <div class="row">保留面数比例：<span class="val" id="rv">50%</span>
      <input type="range" id="ratio" min="5" max="95" step="5" value="50"></div>
    <label><input type="checkbox" id="boundary" checked> 保护轮廓 / 开口边界（推荐）</label>
    <label><input type="checkbox" id="uv" checked> 传递贴图 UV</label>
    <label><input type="checkbox" id="smooth" checked> 自动柔化曲面（30°）</label>
    <label><input type="checkbox" id="fill" checked> 自动补小洞（防破面）</label>
    <label><input type="checkbox" id="recursive" checked> 递归处理子组 / 子组件</label>
    <div class="btns"><button onclick="sketchup.win_close()">取消</button>
      <button class="primary" onclick="go()">开始减面</button></div>
    <div class="hint">减面是近似优化，比例越低细节越少。执行后可一次 Cmd+Z 撤销。</div>
    <script>
      var r=document.getElementById('ratio');
      r.oninput=function(){document.getElementById('rv').textContent=r.value+'%';};
      function go(){
        sketchup.run(JSON.stringify({
          ratio:parseInt(r.value,10)/100,
          protect_boundary:document.getElementById('boundary').checked,
          transfer_uv:document.getElementById('uv').checked,
          autosmooth:document.getElementById('smooth').checked,
          fill_holes:document.getElementById('fill').checked,
          recursive:document.getElementById('recursive').checked}));
      }
    </script></body></html>
  HTML

  PROGRESS_HTML = <<~HTML
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <style>
      body{font:13px -apple-system,"PingFang SC",sans-serif;margin:14px;color:#222}
      #bar{height:10px;background:#e6e9ee;border-radius:5px;overflow:hidden;margin:10px 0}
      #fill{height:100%;width:0%;background:#2b7de9;transition:width .2s}
      .btns{text-align:right}
      button{padding:6px 14px;border-radius:6px;border:1px solid #bbb;background:#f7f7f7}
    </style></head><body>
    <h3 id="t">正在减面…</h3>
    <div id="bar"><div id="fill"></div></div>
    <div id="s" style="font-size:12px;color:#666">准备中</div>
    <div class="btns" style="margin-top:14px"><button onclick="sketchup.cancel()">取消</button></div>
    <script>
      sketchup.set=function(p,txt){document.getElementById('fill').style.width=(p*100).toFixed(0)+'%';
        document.getElementById('t').textContent='正在减面… '+(p*100).toFixed(0)+'%';
        if(txt)document.getElementById('s').textContent=txt;};
    </script></body></html>
  HTML

  def self.show_dialog
    model = Sketchup.active_model
    targets = model.selection.to_a.select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
    if targets.empty?
      UI.messagebox('请先选中要减面的【组】或【组件】（可多选），再点这个按钮。')
      return
    end
    scopes = collect_scopes(targets, true)
    faces = scopes.inject(0) { |s, e| s + e.grep(Sketchup::Face).size }
    info = "已选 #{targets.size} 个对象，共 #{scopes.size} 层几何，合计 #{faces} 个面。"
    @setup_dlg = UI::HtmlDialog.new(dialog_title: '减面工具', preferences_key: PREF_KEY,
                                    width: 390, height: 460, resizable: false,
                                    style: UI::HtmlDialog::STYLE_DIALOG)
    @setup_dlg.set_html(SETUP_HTML.sub('__INFO__', info))
    @setup_dlg.add_action_callback('run') { |_c, json|
      begin
        require 'json'
        opts = JSON.parse(json, symbolize_names: true)
      rescue StandardError
        opts = {}
      end
      @setup_dlg.close
      start_job(targets, opts)
    }
    @setup_dlg.add_action_callback('win_close') { |_c, _| @setup_dlg.close }
    @setup_dlg.set_on_closed { @setup_dlg = nil }
    @setup_dlg.show
  end

  def self.start_job(targets, opts)
    @job = Job.new(targets, opts,
                   started: lambda { |faces, n|
                     @progress_dlg = UI::HtmlDialog.new(dialog_title: '减面中', preferences_key: PREF_KEY + '_p',
                                                        width: 340, height: 190, resizable: false,
                                                        style: UI::HtmlDialog::STYLE_DIALOG)
                     @progress_dlg.set_html(PROGRESS_HTML)
                     @progress_dlg.add_action_callback('cancel') { |_c, _| @job&.cancel }
                     @progress_dlg.set_on_closed { @job&.cancel }
                     @progress_dlg.show
                     Sketchup.status_text = "减面中：共 #{faces} 个面 / #{n} 层"
                   },
                   progress: lambda { |p, i, n|
                     @progress_dlg&.execute_script("sketchup.set(#{p}, '#{i}/#{n} 层')")
                     Sketchup.status_text = "减面中… #{(p * 100).round}%"
                   },
                   done: lambda { |res|
                     @progress_dlg&.close
                     @progress_dlg = nil
                     Sketchup.status_text = ''
                     if res[:error]
                       UI.messagebox(res[:error])
                     else
                       pct = res[:before_faces] > 0 ? (100.0 * (res[:before_faces] - res[:after_faces]) / res[:before_faces]).round(1) : 0
                       msg = "减面完成 ✅\n\n" \
                             "处理层次：#{res[:scopes]} 层\n" \
                             "面数：#{res[:before_faces]} → #{res[:after_faces]}（减少 #{pct}%）\n" \
                             "边界边（破面指标）：#{res[:boundary_before]} → #{res[:boundary_after]}\n" \
                             "补洞：#{res[:filled]} 处；传递 UV 的面：#{res[:uv_faces]}\n" \
                             "耗时：#{res[:seconds]} 秒\n\n" \
                             "不满意可一次 Cmd+Z 撤销。"
                       UI.messagebox(msg)
                     end
                   })
    @job.start
  end

  # ================= 面数扫描（筛选重物） =================
  def self.def_faces(defn, cache, visiting = {})
    return cache[defn] if cache.key?(defn)
    return 0 if visiting[defn]
    visiting[defn] = true
    n = ents_faces(defn.entities, cache, visiting)
    visiting.delete(defn)
    cache[defn] = n
    n
  end

  def self.ents_faces(ents, cache, visiting = {})
    n = ents.grep(Sketchup::Face).size
    ents.grep(Sketchup::Group).each do |g|
      begin
        n += ents_faces(g.entities, cache, visiting)
      rescue StandardError
      end
    end
    ents.grep(Sketchup::ComponentInstance).each do |i|
      begin
        n += def_faces(i.definition, cache, visiting) unless i.definition.image?
      rescue StandardError
      end
    end
    n
  end

  SCAN_HTML = <<~HTML
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <style>
      body{font:12px -apple-system,"PingFang SC",sans-serif;margin:10px;color:#222}
      .bar{margin-bottom:8px;line-height:1.9}
      input[type=number]{width:80px}
      input[type=text]{width:120px}
      .wrap{max-height:430px;overflow:auto;border:1px solid #e3e6ea;border-radius:6px}
      table{border-collapse:collapse;width:100%}
      th,td{border-bottom:1px solid #eee;padding:4px 6px;text-align:left;white-space:nowrap}
      th{position:sticky;top:0;background:#fafbfc;z-index:1}
      tbody tr:hover{background:#eef4ff;cursor:pointer}
      tr.sel{background:#dbe9ff}
      .num{text-align:right}
      .foot{margin-top:8px}
      button{padding:5px 10px;border-radius:5px;border:1px solid #bbb;background:#f7f7f7}
    </style></head><body>
    <div class="bar">最小面数 <input id="min" type="number" value="0">
      名称 <input id="q" type="text" placeholder="搜索名称">
      <label><input type="checkbox" id="nested"> 含嵌套对象</label>
      <button onclick="rescan()">重新扫描</button>
      <span id="st" style="color:#888"></span></div>
    <div class="wrap"><table><thead><tr>
      <th>#</th><th>名称</th><th>类型</th><th class="num">单个面数</th>
      <th class="num">实例</th><th class="num">合计面数</th><th>图层</th>
    </tr></thead><tbody id="tb"></tbody></table></div>
    <div class="foot">显示 <b id="cnt">0</b> / 共 <b id="all">0</b> 项，合计 <b id="sum">0</b> 面
      <button onclick="sketchup.decimate_selected()">对当前选中项减面…</button>
      <span style="color:#888">（单击=选中，双击=选中并缩放到该对象）</span></div>
    <script>
      var rows=[], sel=-1;
      function fmt(n){ return n.toLocaleString(); }
      function render(){
        var minv = parseInt(document.getElementById('min').value||'0',10)||0;
        var q = document.getElementById('q').value.trim().toLowerCase();
        var tb = document.getElementById('tb'); tb.innerHTML='';
        var cnt=0, sum=0;
        rows.forEach(function(r){
          if (r[5] < minv) return;
          if (q && r[1].toLowerCase().indexOf(q) < 0) return;
          cnt++; sum += r[5];
          var tr = document.createElement('tr');
          if (sel === r[0]) tr.className='sel';
          tr.onclick = function(){ sel=r[0]; render(); sketchup.pick(r[0]); };
          tr.ondblclick = function(){ sel=r[0]; render(); sketchup.zoom(r[0]); };
          tr.innerHTML = '<td>'+cnt+'</td><td>'+r[1]+'</td><td>'+r[2]+'</td><td class="num">'+fmt(r[3])+
            '</td><td class="num">'+fmt(r[4])+'</td><td class="num">'+fmt(r[5])+'</td><td>'+r[6]+'</td>';
          tb.appendChild(tr);
        });
        document.getElementById('cnt').textContent = cnt;
        document.getElementById('sum').textContent = fmt(sum);
      }
      function rescan(){ sketchup.scan(JSON.stringify({nested: document.getElementById('nested').checked})); }
      function scan_data(d, t){
        rows = d;
        document.getElementById('all').textContent = d.length;
        document.getElementById('st').textContent = '扫描用时 ' + t + ' 秒';
        render();
      }
      document.getElementById('min').oninput = render;
      document.getElementById('q').oninput = render;
      document.getElementById('nested').onchange = rescan;
      sketchup.scan(JSON.stringify({nested:false}));
    </script></body></html>
  HTML

  def self.build_scan_rows(include_nested = false)
    m = Sketchup.active_model
    cache = {}
    visiting = {}
    rows = []
    top = m.entities.to_a
    groups = top.select { |e| e.is_a?(Sketchup::Group) }
    insts = top.select { |e| e.is_a?(Sketchup::ComponentInstance) && !e.definition.image? }

    by_def = {}
    insts.each { |i| (by_def[i.definition] ||= []) << i }
    by_def.each do |d, list|
      n = def_faces(d, cache, visiting)
      rows << { name: d.name, kind: '组件', faces: n, instances: d.count_instances,
                total: n * d.count_instances, layer: (list.first.layer ? list.first.layer.name : ''),
                targets: list }
    end
    groups.each do |g|
      n = ents_faces(g.entities, cache, visiting)
      rows << { name: (g.name.to_s.empty? ? '(未命名组)' : g.name), kind: '组', faces: n, instances: 1,
                total: n, layer: (g.layer ? g.layer.name : ''), targets: [g] }
    end

    if include_nested
      walk = lambda do |ents, root, depth|
        return if depth > 4
        ents.each do |e|
          if e.is_a?(Sketchup::Group)
            n = ents_faces(e.entities, cache, visiting)
            rows << { name: (e.name.to_s.empty? ? '(未命名组)' : e.name), kind: '组·嵌套', faces: n,
                      instances: 1, total: n, layer: (e.layer ? e.layer.name : ''), targets: [root] }
            walk.call(e.entities, root, depth + 1)
          elsif e.is_a?(Sketchup::ComponentInstance) && !e.definition.image?
            d = e.definition
            n = def_faces(d, cache, visiting)
            rows << { name: d.name, kind: '组件·嵌套', faces: n, instances: d.count_instances,
                      total: n * d.count_instances, layer: (e.layer ? e.layer.name : ''), targets: [root] }
            walk.call(d.entities, root, depth + 1)
          end
        end
      end
      top.each { |e| walk.call(e.entities, e, 1) if e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
    end
    rows.sort_by { |r| -r[:total] }
  end

  def self.do_scan(opts_json)
    require 'json'
    opts = begin
      JSON.parse(opts_json)
    rescue StandardError
      {}
    end
    t0 = Time.now
    Sketchup.status_text = '正在扫描面数…'
    @scan_rows = build_scan_rows(opts['nested'] ? true : false)
    Sketchup.status_text = ''
    data = []
    @scan_rows.each_with_index do |r, i|
      data << [i, r[:name].to_s, r[:kind], r[:faces], r[:instances], r[:total], r[:layer].to_s]
    end
    @scan_dlg&.execute_script("scan_data(#{data.to_json}, #{(Time.now - t0).round(1)})")
  end

  def self.scan_pick(idx, zoom = false)
    rows = @scan_rows || []
    r = rows[idx.to_i]
    return unless r
    m = Sketchup.active_model
    m.selection.clear
    list = (r[:targets] || []).select { |e| e.valid? }
    list.each { |e| m.selection.add(e) }
    if zoom && !list.empty?
      begin
        m.active_view.zoom(list)
      rescue StandardError
        begin
          m.active_view.zoom(list.first)
        rescue StandardError
        end
      end
    end
    Sketchup.status_text = "已选中 #{list.size} 个对象：#{r[:name]}｜合计 #{r[:total]} 面"
  end

  def self.show_scan_dialog
    @scan_dlg ||= UI::HtmlDialog.new(dialog_title: '面数扫描（筛选重物）',
                                     preferences_key: PREF_KEY + '_scan',
                                     width: 720, height: 620, resizable: true,
                                     style: UI::HtmlDialog::STYLE_DIALOG)
    @scan_dlg.set_html(SCAN_HTML)
    @scan_dlg.add_action_callback('scan') { |_c, json| do_scan(json) }
    @scan_dlg.add_action_callback('pick') { |_c, i| scan_pick(i, false) }
    @scan_dlg.add_action_callback('zoom') { |_c, i| scan_pick(i, true) }
    @scan_dlg.add_action_callback('decimate_selected') { |_c, _| show_dialog }
    @scan_dlg.set_on_closed { @scan_dlg = nil }
    @scan_dlg.show
  end

  def self.install_menu!
    return if @menu_installed
    @menu_installed = true
    menu = UI.menu('Extensions').add_submenu('减面工具')
    scan_cmd = UI::Command.new('面数扫描…') { SUDecimate.show_scan_dialog }
    scan_cmd.tooltip = '扫描模型里所有组/组件，按面数从多到少列出，点击行即可在模型中选中'
    scan_cmd.status_bar_text = '单击行=选中该对象，双击=选中并缩放到该对象'
    menu.add_item(scan_cmd)
    dec_cmd = UI::Command.new('减面…') { SUDecimate.show_dialog }
    dec_cmd.tooltip = '大模型减面（保轮廓 / 保贴图 / 防破面）'
    dec_cmd.status_bar_text = '选中组或组件后点击，可设置保留比例'
    menu.add_item(dec_cmd)
    menu.add_separator
    about = UI::Command.new('关于/使用说明') { SUDecimate.show_help }
    menu.add_item(about)
    file_loaded(__FILE__)
  end

  def self.show_help
    UI.messagebox(
      "减面工具 v#{VERSION}\n\n" \
      "① 面数扫描：列出模型里所有组/组件，按合计面数从多到少排列。\n" \
      "   单击某行 = 在模型里选中它；双击 = 选中并缩放过去。\n\n" \
      "② 减面：先选中要处理的组/组件（可多选），再打开「减面…」。\n" \
      "   保留比例 = 处理后剩余的面数百分比；比例越小减得越狠。\n" \
      "   勾选项默认全开：保轮廓、传贴图UV、自动柔化、自动补洞。\n\n" \
      "③ 执行过程中有进度条，可随时取消；完成后一次 Cmd+Z 即可整体撤销。\n\n" \
      "提示：同一组件被多处引用时，减面会影响它的所有实例。"
    )
  end

  SUDecimate.install_menu!
end
