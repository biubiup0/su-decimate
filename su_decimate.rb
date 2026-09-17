# 减面工具 —— 扩展加载器
require 'sketchup.rb'
require 'extensions.rb'

module SUDecimate
  PLUGIN_DIR = File.dirname(__FILE__)
end

unless file_loaded?(__FILE__)
  ex = SketchupExtension.new('减面工具 (Decimator)', File.join(__dir__, 'su_decimate', 'main.rb'))
  ex.version     = '2.0.0'
  ex.description = '大模型减面：面数扫描（按面数排序、点击选中）+ 顶点聚类减面（保轮廓 / 传递贴图 UV / 自动补洞不破面）'
  ex.creator     = 'biubiup0'
  ex.copyright   = '2026'
  Sketchup.register_extension(ex, true)
  file_loaded(__FILE__)
end
