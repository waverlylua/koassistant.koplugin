-- Native offline regression for screenshot 1241. Run from official KOReader:
-- KO_HOME=<disposable profile> KOREADER_PLUGIN=<checkout> MATH_OUTPUT=<directory>
-- SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software ./luajit <this script>
require('setupkoenv')
package.path=assert(os.getenv('KOREADER_PLUGIN'))..'/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(require('datastorage'):getDataDir()..'/settings.reader.lua')
require('document/canvascontext'):init(require('device'))
local renderer=require('koassistant_math_renderer')
local clock=require('socket').gettime
local output=assert(os.getenv('MATH_OUTPUT'))
local source=[[M = \begin{bmatrix} A & B\\ B^T & D \end{bmatrix}, \quad \text{Schur complement of }A = D-B^T A^{-1}B.]]
local results={}
for _,width in ipairs({720,560,460}) do
    local options={font_size=36,max_width=width,max_height=1200}
    local started=clock()
    local result,reason=renderer.renderFormula(source,true,options)
    if os.getenv('EXPECT_WIDE_FALLBACK') then
        assert(not result and reason:find('too wide',1,true),'baseline must reproduce screenshot fallback')
    else
        assert(result,'wide screenshot formula must render: '..tostring(reason))
        assert(result.width<=width,'no horizontal clipping')
        local file=assert(io.open(output..'/wide-schur-'..width..'.png','wb'))
        file:write(result.png);file:close()
        local html=renderer.render('$$'..source..'$$',options)
        assert(html:find('koa-math-image',1,true) and not html:find('koa-math-fallback',1,true))
        assert(html==renderer.render('$$'..source..'$$',options),'cached reflow must be stable')
    end
    results[#results+1]={width=width,rendered=result~=nil,error=reason,
        image_width=result and result.width,image_height=result and result.height,seconds=clock()-started}
    print(width,result and (result.width..'x'..result.height) or reason)
end
if not os.getenv('EXPECT_WIDE_FALLBACK') then
    local atomic=string.rep('x',100)
    local result,reason=renderer.renderFormula(atomic,true,{font_size=36,max_width=460,max_height=1200})
    assert(not result and reason:find('too wide',1,true),'unbreakable products must retain source fallback')
    result,reason=renderer.renderFormula(source,false,{font_size=36,max_width=460,max_height=1200})
    assert(not result and reason:find('too wide',1,true),'inline math must not silently become display lines')
    result,reason=renderer.renderFormula(source,true,{font_size=36,max_width=460,max_height=40})
    assert(not result and reason:find('too tall',1,true),'wrapped math must still respect the height budget')
end
local file=assert(io.open(output..'/wide-math-results.json','w'))
file:write(require('json').encode(results));file:close()
print('Native wide-math checks passed')
