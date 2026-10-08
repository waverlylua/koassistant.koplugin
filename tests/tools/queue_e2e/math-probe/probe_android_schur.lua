-- Regression corpus transcribed from the user's Android screenshots 870/871.
-- Real native KOReader fonts/PNG renderer; no network or private document.
-- Run from KOReader with KOREADER_PLUGIN, SCHUR_OUTPUT and KO_HOME set.
require('setupkoenv')
package.path=assert(os.getenv('KOREADER_PLUGIN'))..'/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(require('datastorage'):getDataDir()..'/settings.reader.lua')
require('document/canvascontext'):init(require('device'))
local root=assert(os.getenv('SCHUR_OUTPUT'))
local json=require('json')
local clock=require('socket').gettime
local M=require('koassistant_math_renderer')
local cases={
 {id='block-matrix',tex=[[M=\begin{bmatrix}A&B\\B^{T}&C\end{bmatrix}\succeq 0.]]},
 {id='schur-quadratic',tex=[[g(x)=f(x,y^\star)=x^T\bigl(A-BC^{-1}B^T\bigr)x.]]},
 {id='pseudoinverse',tex=[[A-BC^\dagger B^T\succeq0.]]},
 {id='range-conditions',tex=[[C\succeq0,\quad \operatorname{range}(B^T)\subseteq\operatorname{range}(C), \quad A-BC^\dagger B^T\succeq0.]]},
 {id='sized-delimiters',tex=[[\bigl(x\bigr)\quad\Bigl[x\Bigr]\quad\biggl\lfloor x\biggr\rfloor\quad\Biggl\lVert x\Biggr\rVert]]},
 {id='order-relations',tex=[[A\preceq B\succeq C\prec D\succ E\quad F^{\dagger}\quad G^{\ddagger}]]},
 {id='order-variants',tex=[[A\preceq B\preccurlyeq C\quad D\succeq E\succcurlyeq F\quad G\npreceq H\nsucceq I]]},
 {id='unsupported',tex=[[A\succeq0+\unsupportedSemanticCommand{C^\dagger}]],fallback=true},
}
local options={font_size=32,max_width=752,max_height=1400}
local results={width=824,font_size=32,content_width=options.max_width,cases={}}
for _,case in ipairs(cases) do
 local t=clock();local rendered,err=M.renderFormula(case.tex,true,options);local cold=clock()-t
 t=clock();M.renderFormula(case.tex,true,options);local warm=clock()-t
 local source='$$'..case.tex..'$$'
 t=clock();local html=M.render(source,options);local document_cold=clock()-t
 t=clock();local cached=M.render(source,options);local document_warm=clock()-t
 assert(html==cached,'cache must preserve exact display')
 if case.fallback then assert(not rendered and err:find('unsupported command',1,true))
 elseif case.id=='range-conditions' and not rendered then
  assert(err:find('too wide',1,true),'long condition may need explicit source fallback at this width')
 else assert(rendered,case.id..': '..tostring(err)) end
 if rendered then
  local out=assert(io.open(root..'/'..case.id..'.png','wb'));out:write(rendered.png);out:close()
 end
 results.cases[#results.cases+1]={id=case.id,source=case.tex,rendered=rendered~=nil,error=err,
  width=rendered and rendered.width,height=rendered and rendered.height,
  cold_seconds=cold,warm_seconds=warm,document_cold_seconds=document_cold,document_cached_seconds=document_warm}
 print(case.id,rendered and (rendered.width..'x'..rendered.height) or err,cold,warm,document_warm)
end
local out=assert(io.open(root..'/results.json','w'));out:write(json.encode(results));out:close()
