-- Real reader/queue/HTTP/answer widget integration with synthetic method calls.
local U=require('ui/uimanager')
local json=require('json')
local root=os.getenv('RICH_E2E_ROOT')
local function log(event,fields)
 fields=fields or {};fields.event=event;local f=assert(io.open(root..'/events.jsonl','a'));f:write(json.encode(fields),'\n');f:close()
end
local function check(v,label,detail) log(v and 'PASS' or 'FAIL',{check=label,detail=detail});assert(v,label) end
local function later(s,fn) U:scheduleIn(s,function() local ok,e=xpcall(fn,debug.traceback);if not ok then log('ERROR',{error=tostring(e)});U:quit(1) end end) end
local function shot(name) require('device').screen:shot(root..'/'..name..'.png') end
local function read(path) local f=assert(io.open(path,'rb'));local t=f:read('*a');f:close();return t end
later(1,function()
 local ui=require('apps/reader/readerui').instance
 check(ui and ui.koassistant,'real reader and plugin loaded')
 local p=ui.koassistant;p:ensureInitialized()
 for i=#U._window_stack,1,-1 do local w=U._window_stack[i].widget;if w.text=='Book info cache database updated.' then U:close(w) end end
 local R=require('koassistant_question_runtime');local Q=require('koassistant_question_ui');local P=require('koassistant_question_payload');local q=R.get(p)
 local source=read(root..'/rich-math-fixture.txt')
 if os.getenv('RICH_E2E_PHASE')=='recover' then
  check(#q.jobs==1 and q.jobs[1].answer==source,'rich TeX answer survives real app restart byte-for-byte')
  Q.showAnswer(p,q.jobs[1]);later(.3,function()shot('reloaded-rich-answer');log('DONE');U:quit(0)end);return
 end
 local plan={delay_seconds=1,status=200,answer_text=source};local f=assert(io.open(root..'/plan.json','w'));f:write(json.encode(plan));f:close()
 ui.paging:onGotoPage(3)
 local s=P.prepare(p,assert(P.capture(ui,{text='RICH_MATH_ORIGIN_PAGE_3',pos0={page=3},pos1={page=3}})),{id='queued_custom',text='Rich math fixture',prompt='Show rich equations for this selection.'})
 s.config.base_url='http://127.0.0.1:8767/v1/chat/completions';s.config.provider_settings={openai={base_url=s.config.base_url}}
 local j=assert(q:enqueue(s));ui.paging:onGotoPage(5)
 local function poll()
  if j.state=='running' or j.state=='queued' then later(.1,poll);return end
  check(j.state=='completed','rich fixture completed via real local HTTP',{error=j.error})
  check(j.answer==source,'stored raw TeX exactly equals local HTTP response')
  check(ui:getCurrentPage()==5 and j.document.page==3,'reading page and question origin stay independent')
  check(ui.gestures.gestures.tap_top_left_corner.refresh_content==true,'existing corner assignment is untouched by plugin initialization')
  ui.gestures.gestures.tap_top_left_corner={koassistant_question_inbox=true}
  ui.gestures:setupGesture('tap_top_left_corner')
  ui.gestures:gestureAction('tap_top_left_corner',{ges='tap',pos={x=3,y=3}})
  local inbox=U._window_stack[#U._window_stack].widget
  check(inbox.title=='AI answer inbox','configured dispatcher action opens actual inbox',{title=inbox.title})
  U:close(inbox);check(ui:getCurrentPage()==5,'closing dispatched inbox preserves reading page')
  Q.showAnswer(p,j)
  local viewer=U._window_stack[#U._window_stack].widget
  local sw=viewer.scroll_text_w
  check(sw and sw.htmlbox_widget,'actual answer uses HTML renderer')
  local html=sw.html_body or ''
  check(html:find('data:image/png;base64,',1,true),'rich answer HTML contains rendered PNG math')
  check(html:find('unsupportedSemanticCommand',1,true),'unsupported math source remains identifiable')
  local hf=assert(io.open(root..'/answer.html','w'));hf:write(html);hf:close()
  local pages=sw.htmlbox_widget.page_count;log('PAGES',{count=pages})
  local n=1
  local function nextpage()
   shot('answer-page-'..n)
   if n<pages then n=n+1;sw:onScrollDown();later(.2,nextpage);return end
   check(viewer.text==source and j.answer==source,'rendering does not mutate answer source')
   local copybutton
   for _,row in ipairs(viewer.buttons_table) do for _,button in ipairs(row) do if button.text=='Copy answer' then copybutton=button end end end
   check(copybutton~=nil,'actual Copy answer button is present')
   copybutton.callback()
   check(require('device').input.getClipboardText()==source,'Copy answer clipboard contains exact raw TeX')
   local top=U._window_stack[#U._window_stack].widget;if top~=viewer then U:close(top) end
   viewer:toggleMarkdown();later(.2,function()
    check(not viewer.render_markdown and viewer.text==source,'Text toggle preserves raw original TeX')
    shot('answer-raw-text')
    viewer:toggleMarkdown();later(.2,function()
     check(viewer.render_markdown and viewer.text==source,'Math toggle recreates view without source mutation')
     viewer:onClose();check(ui:getCurrentPage()==5,'closing rich answer restores unchanged source reader position')
     local inline_source='Inline baseline: text before $x_i^2+\\frac{1}{2}$ and text after.\n\nA shorter equation $E=mc^2$ stays within this sentence.\n\nMalformed source must stay visible: $$\\frac{1}{$$'
     local inline=require('koassistant_chatgptviewer'):new{title='Inline and fallback fixture',text=inline_source,configuration={features={render_markdown=true,render_math=true}},add_default_buttons=false}
     U:show(inline);later(.2,function()shot('answer-inline-baseline');check(inline.text==inline_source,'inline and malformed rendering preserve exact source');inline:onClose();log('DONE');U:quit(0)end)
    end)
   end)
  end
  later(.3,nextpage)
 end
 later(.2,poll)
end)
