require('setupkoenv');package.path=(os.getenv('KOREADER_PLUGIN')or'plugins/koassistant.koplugin')..'/?.lua;'..package.path
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(require('datastorage'):getDataDir()..'/settings.reader.lua')
require('document/canvascontext'):init(require('device'))
local root=assert(os.getenv('RICH_E2E_ROOT'))
local r=assert(require('koassistant_math_renderer').renderFormula('x_i^2+\\frac{1}{2}',false,{font_size=22,max_width=540,max_height=600}))
local img=string.format('<img src="data:image/png;base64,%s" width="%d" height="%d" %%s/>',require('mime').b64(r.png),r.width,r.height)
print('dimensions',r.width,r.height,'ascent',r.ascent,'descent',r.descent)
local variants={{'middle',img:format('style="vertical-align:middle;"')},{'negative-px',img:format('style="vertical-align:-'..r.descent..'px;"')},{'negative-em',img:format('style="vertical-align:-0.5em;"')},{'baseline',img:format('style="vertical-align:baseline;"')},{'text-bottom',img:format('style="vertical-align:text-bottom;"')},{'bottom',img:format('style="vertical-align:bottom;"')},{'sub-wrapper','<sub>'..img:format('')..'</sub>'},{'span-sub','<span style="vertical-align:sub;">'..img:format('')..'</span>'},{'image-sub',img:format('style="vertical-align:sub;"')}}
local body='<html><head><style>body{font-size:22px;margin:12px;}p{margin:0 0 20px 0;}</style></head><body>'
for _,v in ipairs(variants)do body=body..'<p>'..v[1]..'<br/>Text before '..v[2]..' and after.</p>'end
body=body..'</body></html>'
local M=require('ffi/mupdf');local d=M.openDocumentFromText(body,'html');d:layoutDocument(600,1000,22)
for n=1,d:getPages()do local p=d:openPage(n);local b=p:draw_new(require('ffi/drawcontext').new(),600,1000,0,0);b:writePNG(root..'/baseline-probe-'..n..'.png');b:free();p:close()end
d:close()
