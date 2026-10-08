-- Run from an official KOReader directory with a fresh KO_HOME, KOREADER_PLUGIN,
-- SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software, and optional
-- EMULATE_READER_W=824 EMULATE_READER_H=1648. No network or real account used.
-- Timings cover full native Markdown, math, MuPDF, show/scroll/toggle/close.
io.stdout:setvbuf('no')
print('START')
require('setupkoenv')
package.path=assert(os.getenv('KOREADER_PLUGIN'),'set KOREADER_PLUGIN to the plugin checkout')..'/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(require('datastorage'):getDataDir()..'/settings.reader.lua')
require('document/canvascontext'):init(require('device'))
print('ENV READY')
local gettime=require('socket').gettime
for _,pair in ipairs{{'koassistant_math_renderer','render'},{'ui/widget/htmlboxwidget','setContent'}}do
 local m=require(pair[1]);local key=pair[2];local original=m[key];m[key]=function(...)local s=gettime();local a,b=original(...);print('STAGE '..key,gettime()-s);return a,b end
end
local md=require('apps/filemanager/lib/md');package.loaded['apps/filemanager/lib/md']=function(...)local s=gettime();local a,b=md(...);print('STAGE MD',gettime()-s);return a,b end
local V=require('koassistant_chatgptviewer')
print('VIEWER LOADED')
local U=require('ui/uimanager');local Screen=require('device').screen
local gettime=require('socket').gettime
local function elapsed(label,start) local took=gettime()-start;print(label,string.format('%.4f seconds',took));assert(took<(tonumber(os.getenv('KOA_PERF_LIMIT_SECONDS')) or 2),label..' blocked the UI');return gettime() end
local source=[=[Write the quadratic in block form as

$$f(x,y)=\begin{bmatrix}x\\y\end{bmatrix}^{T}\begin{bmatrix}A&B\\B^{T}&C\end{bmatrix}\begin{bmatrix}x\\y\end{bmatrix}.$$

Here $A$ and $C$ are symmetric, and joint convexity of $f$ means precisely that its Hessian is positive semidefinite:

$$M=\begin{bmatrix}A&B\\B^{T}&C\end{bmatrix}\succeq 0.$$

For fixed $x$, the $y$-dependent part is

$$y^TCy+2x^TBy.$$

Setting its gradient to zero gives

$$2B^Tx+2Cy=0,\quad y^\star=-C^{-1}B^Tx.$$

Substitution yields

$$g(x)=f(x,y^\star)=x^T\bigl(A-BC^{-1}B^T\bigr)x.$$

Partial minimization preserves convexity:

$$g(x)=\inf_y f(x,y).$$

Hence

$$A-BC^\dagger B^T\succeq0.$$

]=]
for _,copies in ipairs{1,1}do
 local start=gettime()
 local v=V:new{title='Android screenshot formula timing '..copies,text=source:rep(copies),configuration={features={render_markdown=true,render_math=true,markdown_font_size=28}},add_default_buttons=false}
 start=elapsed('CREATE '..copies,start)
 U:show(v);U:forceRePaint();start=elapsed('SHOW '..copies,start)
 local sw=v.scroll_text_w;print('PAGES',sw.htmlbox_widget.page_count,'HTMLBYTES',#sw.html_body)
 for p=2,sw.htmlbox_widget.page_count do sw:onScrollDown();U:forceRePaint() end
 start=elapsed('SCROLL ALL '..copies,start)
 for i=1,2 do v:toggleMarkdown();U:forceRePaint() end
 start=elapsed('TOGGLE TWO '..copies,start)
 assert(v.text==source:rep(copies),'rendering changed original answer')
 v:onClose();U:forceRePaint();elapsed('CLOSE '..copies,start)
 collectgarbage('collect')
end

for i=1,2 do
 local start=gettime()
 local raw=("This is a plain English answer without mathematical notation.\n\n"):rep(30)
 local v=V:new{title="Plain English control",text=raw,configuration={features={render_markdown=true,render_math=true,markdown_font_size=28}},add_default_buttons=false}
 U:show(v);U:forceRePaint();elapsed("PLAIN CREATE "..i,start)
 assert(v.text==raw,"plain source changed")
 v:onClose();U:forceRePaint()
end
