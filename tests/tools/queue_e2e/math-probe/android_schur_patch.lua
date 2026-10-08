-- Real KOReader answer viewer regression proof at Android screenshot dimensions.
-- Run with KO_HOME containing this startup patch and the synthetic PDF; set
-- KOREADER_PLUGIN to the checkout and SCHUR_OUTPUT to an output directory.
local source=assert(os.getenv('KOREADER_PLUGIN'))
package.path=source..'/?.lua;'..package.path
local root=assert(os.getenv('SCHUR_OUTPUT'))
os.remove(root..'/viewer-error.txt')
os.remove(root..'/viewer-results.json')
local U=require('ui/uimanager')
local json=require('json')
local clock=require('socket').gettime
local function read(path) local f=assert(io.open(path));local s=f:read('*a');f:close();return s end
local function write(name,value) local f=assert(io.open(root..'/'..name,'w'));f:write(value);f:close() end
local function later(fn) U:scheduleIn(.25,function()
 local ok,err=xpcall(fn,debug.traceback)
 if not ok then write('viewer-error.txt',err);U:quit(1) end
end) end
later(function()
 package.path=source..'/?.lua;'..package.path
 for _,name in ipairs({'koassistant_chatgptviewer','koassistant_math','koassistant_math_layout','koassistant_math_renderer'}) do package.loaded[name]=nil end
 local Viewer=require('koassistant_chatgptviewer')
 assert(debug.getinfo(Viewer.init,'S').source== '@'..source..'/koassistant_chatgptviewer.lua','probe must use source checkout viewer')
 local text=read(source..'/tests/tools/queue_e2e/math-probe/android-schur-fixture.txt')
 local scale=require('device').screen:scaleBySize(100)/100
 local opts={title='Schur-complement regression',text=text,add_default_buttons=false,
  configuration={features={render_markdown=true,render_math=true,markdown_font_size=32/scale}}}
 local start=clock();local viewer=Viewer:new(opts);local cold=clock()-start
 U:show(viewer)
 local scroll=assert(viewer.scroll_text_w);local html=assert(scroll.html_body)
 assert(html:find('unsupportedSemanticCommand',1,true),'unknown notation source must remain')
 write('answer.html',html)
 local _,fallbacks=html:gsub('class="koa%-math%-fallback"','')
 assert(fallbacks==1,'only the deliberately unsupported command should fall back, got '..fallbacks)
 local _,rendered=html:gsub('class="koa%-math%-image"','')
 assert(rendered==20,'all 20 known formula spans must typeset, got '..rendered)
 local page,pages=1,scroll.htmlbox_widget.page_count
 local function capture()
  require('device').screen:shot(root..'/answer-page-'..page..'.png')
  if page<pages then page=page+1;scroll:onScrollDown();later(capture);return end
  assert(viewer.text==text,'display must preserve raw source')
  viewer:onClose()
  start=clock();local warm=Viewer:new(opts);local repeat_time=clock()-start
  U:show(warm)
  write('viewer-results.json',json.encode({width=824,height=1648,font_size=32,pages=pages,
   rendered_formulas=rendered,cold_seconds=cold,reopen_seconds=repeat_time,source_preserved=warm.text==text}))
  later(function()require('device').screen:shot(root..'/answer-reopened.png');warm:onClose();U:quit(0)end)
 end
 later(capture)
end)
