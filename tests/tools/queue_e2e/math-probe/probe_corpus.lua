require('setupkoenv')
package.path=(os.getenv('KOREADER_PLUGIN') or 'plugins/koassistant.koplugin')..'/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(require('datastorage'):getDataDir()..'/settings.reader.lua')
require('document/canvascontext'):init(require('device'))
local root=assert(os.getenv('RICH_E2E_ROOT'),'set RICH_E2E_ROOT to the math-probe directory')
local f=assert(io.open(root..'/corpus.json'));local corpus=require('json').decode(f:read('*a'));f:close()
local M=require('koassistant_math_renderer');local output={}
for _,case in ipairs(corpus) do
 local t=require('socket').gettime();local rendered,err=M.renderFormula(case.tex,case.display,{font_size=22,max_width=540,max_height=600})
 local elapsed=require('socket').gettime()-t
 if rendered then local out=assert(io.open(root..'/formula-'..case.id..'.png','wb'));out:write(rendered.png);out:close() end
 output[#output+1]={id=case.id,rendered=rendered~=nil,error=err,width=rendered and rendered.width,height=rendered and rendered.height,elapsed=elapsed}
 print(case.id,rendered and (rendered.width..'x'..rendered.height) or ('FALLBACK '..tostring(err)),elapsed)
end
local out=assert(io.open(root..'/corpus-result.json','w'));out:write(require('json').encode(output));out:close()
