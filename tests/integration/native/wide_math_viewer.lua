-- Actual native answer-window regression, offline synthetic transcription of
-- screenshot 1241. Same environment as wide_math.lua, plus reader dimensions.
io.stdout:setvbuf('no')
require('setupkoenv')
package.path=assert(os.getenv('KOREADER_PLUGIN'))..'/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(require('datastorage'):getDataDir()..'/settings.reader.lua')
require('document/canvascontext'):init(require('device'))
local Viewer=require('koassistant_chatgptviewer')
local U=require('ui/uimanager')
local Screen=require('device').screen
local clock=require('socket').gettime
local root=assert(os.getenv('MATH_OUTPUT'))
local text=[=[A Schur complement arises when a matrix is divided into blocks and you want to “eliminate” one group of variables while keeping track of its effect on the rest.

Start with a block matrix

$$M=\begin{bmatrix}A&B\\C&D\end{bmatrix},$$

where $A$ is square and invertible. The **Schur complement of $A$ in $M$** is

$$D-CA^{-1}B.$$

There is a symmetric version especially common in convex optimization:

$$M = \begin{bmatrix} A & B\\ B^T & D \end{bmatrix}, \quad \text{Schur complement of }A = D-B^T A^{-1}B.$$

The phrase “of $A$” matters: if instead $D$ is invertible, one can eliminate $D$, obtaining

$$A-BD^{-1}C.$$
]=]
local results={}
for attempt=1,3 do
    local start=clock()
    local viewer=Viewer:new{title='Schur complement · local regression fixture',saved_answer_view=true,
        text=text,add_default_buttons=false,configuration={features={render_markdown=true,render_math=true,
        markdown_font_size=36/(Screen:scaleBySize(100)/100)}}}
    local elapsed=clock()-start
    assert(elapsed<2,'native answer opening must not stall')
    U:show(viewer);U:forceRePaint()
    local scroll=viewer.scroll_text_w
    local html=assert(scroll.html_body)
    assert(not html:find('koa-math-fallback',1,true),'every screenshot formula must typeset in the actual viewer')
    local _,images=html:gsub('class="koa%-math%-image"','')
    assert(images==10,'every formula span must remain in the answer')
    local pages=scroll.htmlbox_widget.page_count
    for page=1,pages do
        if attempt==1 then Screen:shot(root..'/wide-answer-page-'..page..'.png') end
        if page<pages then scroll:onScrollDown();U:forceRePaint() end
    end
    for _=1,2 do
        viewer:toggleMarkdown();U:forceRePaint()
        assert(viewer.text==text,'Text/Math toggle must retain original answer')
    end
    assert(not viewer.scroll_text_w.html_body:find('koa-math-fallback',1,true),'restored Math view must still render')
    if attempt==1 then
        local file=assert(io.open(root..'/wide-answer.html','w'));file:write(html);file:close()
        Screen:shot(root..'/wide-answer-restored.png')
    end
    results[#results+1]={attempt=attempt,open_seconds=elapsed,pages=pages,formulas=images,source_preserved=viewer.text==text}
    viewer:onClose();U:forceRePaint()
    print('OPEN',attempt,elapsed,pages,images)
end
local file=assert(io.open(root..'/wide-viewer-results.json','w'))
file:write(require('json').encode(results));file:close()
print('Native wide-math viewer checks passed')
