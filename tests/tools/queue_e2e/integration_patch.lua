-- Test-only KOReader late patch. Real UIManager, ReaderUI, PDF engine, plugin,
-- subprocess transport, durable storage and localhost HTTP; synthetic method calls.
local U = require('ui/uimanager')
local json = require('json')
local root = os.getenv('E2E_ROOT')
local phase = os.getenv('E2E_PHASE') or 'flow'
local function log(event, fields)
 fields=fields or {}; fields.event=event;fields.time=os.time();fields.phase=phase
 local f=assert(io.open(root..'/logs/process-'..phase..'.jsonl','a'));f:write(json.encode(fields),'\n');f:close()
end
local function check(value, label, fields)
 log(value and 'PASS' or 'FAIL',{check=label,detail=fields});if not value then error(label) end
end
local function later(s,fn) U:scheduleIn(s,function() local ok,err=xpcall(fn,debug.traceback);if not ok then log('ERROR',{error=tostring(err)});U:quit(1) end end) end
local function plan(delay,status)
 local f=assert(io.open(root..'/process-plan.json','w'));f:write(json.encode{delay_seconds=delay,status=status});f:close()
end
later(1,function()
 local ui=require('apps/reader/readerui').instance
 check(ui and ui.document and ui.koassistant,'real PDF reader and plugin loaded')
 for i=#U._window_stack,1,-1 do local w=U._window_stack[i].widget;if w.text=='Book info cache database updated.' then U:close(w) end end
 local plugin=ui.koassistant
 plugin.settings:saveSetting('setup_wizard_completed',true)
 local features=plugin.settings:readSetting('features') or {};features.auto_check_updates=false;plugin.settings:saveSetting('features',features)
 local R=require('koassistant_question_runtime');local P=require('koassistant_question_payload');local q=R.get(plugin)
 local function snapshot(page,token)
  ui.paging:onGotoPage(page)
  local selected={text='ORIGIN_TOKEN_PAGE_'..page..' '..token,pos0={page=page,x=10,y=10},pos1={page=page,x=100,y=20}}
  local c=assert(P.capture(ui,selected))
  local s=P.prepare(plugin,c,{id='e2e_custom',text=token,prompt='Explain '..token..' and the selected formula.'})
  s.config.base_url='http://127.0.0.1:8766/v1/chat/completions'
  s.config.provider_settings={openai={base_url=s.config.base_url}}
  return s
 end
 if phase=='vision' then
  plan(1,200)
  ui.paging:onGotoPage(3)
  local Region=require('koassistant_question_region')
  local before=#q.jobs
  Region.show(plugin)
  local cancelled=U._window_stack[#U._window_stack].widget
  cancelled:onCancel()
  check(#q.jobs==before,'cancelling region selector creates no request')
  Region.show(plugin)
  local selector=U._window_stack[#U._window_stack].widget
  selector:onPick(nil,{pos={x=3,y=96}})
  selector:onPick(nil,{pos={x=520,y=200}})
  local chooser=U._window_stack[#U._window_stack].widget
  local selected
  for _,item in ipairs(chooser.item_table or {}) do if item.text=='Explain' then selected=item;break end end
  -- Compact picker shows ordered favorites first; enter the registered prompt
  -- catalog when Explain is not one of those first three shortcuts.
  if not selected then
   for _,item in ipairs(chooser.item_table or {}) do if item.text=='All registered prompts…' then item.callback();break end end
   chooser=U._window_stack[#U._window_stack].widget
   for _,item in ipairs(chooser.item_table or {}) do if item.text=='Explain' then selected=item;break end end
  end
  check(selected~=nil,'real region picker opens saved prompt menu')
  selected.callback()
  local job=q.jobs[#q.jobs]
  check(job and job.image and job.image.width==517 and job.image.height==104,'two-corner crop is correctly sized')
  check(job.document.page==3 and job.document.end_page==3,'region transform captures correct page')
  local parts=job.messages[1].content
  check(type(parts)=='table' and parts[2].type=='image_url','production vision payload has OpenAI image part')
  local b64=parts[2].image_url.url:match('^data:image/png;base64,(.+)$')
  check(b64~=nil,'vision image is embedded PNG without external upload')
  local imagefile=assert(io.open(root..'/screenshots/process-actual-vision-crop.png','wb'));local decoded=require('mime').unb64(b64);imagefile:write(decoded);imagefile:close()
  ui.paging:onGotoPage(5)
  later(3,function()
   check(job.state=='completed','actual cropped image traverses queued HTTP and completes',{error=job.error})
   check(ui:getCurrentPage()==5,'page navigation remains effective during image request')
   log('DONE');U:quit(0)
  end)
  return
 end
 if phase=='recover' then
  check(#q.jobs==2,'recovered both persisted jobs')
  check(q.jobs[1].state=='interrupted' and q.jobs[2].state=='interrupted','running and queued become interrupted')
  later(3,function()check(not q.active and q.jobs[1].attempts==1 and q.jobs[2].attempts==0,'restart sends neither pending nor running jobs automatically');log('DONE');U:quit(0)end)
  return
 end
 plan(phase=='crash' and 30 or 2,200)
 ui.paging:onGotoPage(4)
 local nextpage=assert(P.capture(ui,{text='next visible page',pos0={page=5},pos1={page=5}}))
 check(nextpage.document.page==5 and nextpage.document.end_page==5,'selection page wins over current footer page')
 local input_a=snapshot(1,'FIRST_JOB')
 local a=assert(q:enqueue(input_a))
 input_a.selected_text='MUTATED_AFTER_ENQUEUE';input_a.messages[1].content='MUTATED_AFTER_ENQUEUE'
 local b=assert(q:enqueue(snapshot(2,'SECOND_JOB')))
 ui.paging:onGotoPage(4)
 plugin.settings:saveSetting('model','changed-after-enqueue')
 if phase=='crash' then
  later(.4,function() check(a.state=='running' and b.state=='queued','crash fixture at running plus queued boundary');log('CRASH_READY') end)
  return
 end
 local baseline_windows=#U._window_stack;local baseline_names={}
 for i,w in ipairs(U._window_stack) do baseline_names[i]={name=w.widget.name,text=w.widget.text,title=w.widget.title} end
 log('BASELINE_WINDOWS',{windows=baseline_windows,names=baseline_names})
 local ticks=0;local started=require('socket').gettime()
 local function waitdone(callback)
  local function poll()
   ticks=ticks+1
   if a.state=='completed' and b.state=='completed' then callback();return end
   if require('socket').gettime()-started>25 then error('transport completion timeout: '..tostring(a.state)..' / '..tostring(a.error)..' ; '..tostring(b.state)..' / '..tostring(b.error)) end
   later(.05,poll)
  end
  later(.05,poll)
 end
 later(.5,function()
  check(a.state=='running' and b.state=='queued','sequential worker keeps second job queued')
  check(ui:getCurrentPage()==4,'real reader moved to page4 while request in flight')
  check(#U._window_stack==baseline_windows,'no blocking loading or answer window during request',{windows=#U._window_stack})
  require('device').screen:shot(root..'/screenshots/process-reading-inflight.png')
 end)
 waitdone(function()
  plugin.settings:saveSetting('model','gpt-4o-mini')
  check(a.config.model=='gpt-4o-mini' and b.config.model=='gpt-4o-mini','queued models do not change with global preference')
  check(a.selected_text:find('FIRST_JOB',1,true),'enqueue deep-copies request snapshot')
  check(ticks>30,'UIManager ticks continue during delayed real HTTP',{ticks=ticks})
  check(a.document.page==1 and b.document.page==2,'two answers retain distinct origin pages')
  check(a.answer:find('FIRST_JOB',1,true) and not a.answer:find('SECOND_JOB',1,true),'first response bound to first question')
  check(b.answer:find('SECOND_JOB',1,true) and not b.answer:find('FIRST_JOB',1,true),'second response bound to second question')
  check(#U._window_stack==baseline_windows and ui:getCurrentPage()==4,'completion does not open modal or change reader position')
  check(q:counts().unread==2,'both answers unread until opened')
  require('koassistant_question_ui').showAnswer(plugin,a)
  later(.2,function()
   require('device').screen:shot(root..'/screenshots/process-answer-formula.png')
   check(a.read and q:counts().unread==1,'opening answer clears only its unread count')
   for i=#U._window_stack,baseline_windows+1,-1 do U:close(U._window_stack[i].widget) end
   plan(3,200)
   local c=assert(q:enqueue(snapshot(3,'CANCEL_RUNNING')))
   local d=assert(q:enqueue(snapshot(5,'CANCEL_QUEUED')))
   assert(q:cancel(d.id))
   later(.4,function()
    check(c.state=='running' and d.state=='cancelled','queued cancellation prevents worker dispatch')
    assert(q:cancel(c.id))
    later(3.5,function()
     check(c.state=='cancelled' and not c.answer,'late canceled response cannot revive job')
     plan(.1,503)
     local e=assert(q:enqueue(snapshot(6,'FAIL_THEN_RETRY')))
     later(1.5,function()
      check(e.state=='failed' and e.attempts==1,'503 becomes failed with no automatic retry',{error=e.error})
      plan(.1,200);assert(q:retry(e.id))
      later(1.5,function()
       check(e.state=='completed' and e.attempts==2,'explicit retry makes one new successful attempt')
       require('koassistant_question_ui').showCustom(plugin,assert(P.capture(ui,{text='The derivative of x squared is 2x.'})))
       local prompt_dialog=U._window_stack[#U._window_stack].widget
       prompt_dialog:setInputText('Explain each step in this derivative.')
       U:setDirty(prompt_dialog,'ui')
       later(.2,function()
        require('device').screen:shot(root..'/screenshots/process-custom-prompt.png')
        U:close(prompt_dialog)
        require('koassistant_question_ui').showInbox(plugin)
        later(.2,function()require('device').screen:shot(root..'/screenshots/process-inbox.png');log('DONE');U:quit(0)end)
       end)
      end)
     end)
    end)
   end)
  end)
 end)
end)
