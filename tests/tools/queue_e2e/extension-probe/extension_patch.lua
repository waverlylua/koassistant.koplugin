local U=require('ui/uimanager');local json=require('json');local root=os.getenv('EXT_E2E_ROOT')
local function log(event,fields) fields=fields or {};fields.event=event;local f=assert(io.open(root..'/events.jsonl','a'));f:write(json.encode(fields),'\n');f:close() end
local function check(v,label,detail)log(v and 'PASS' or 'FAIL',{check=label,detail=detail});assert(v,label)end
local function later(s,fn)U:scheduleIn(s,function()local ok,e=xpcall(fn,debug.traceback);if not ok then log('ERROR',{error=tostring(e)});U:quit(1)end end)end
local function plan(text)local f=assert(io.open(root..'/plan.json','w'));f:write(json.encode{delay_seconds=.4,status=200,answer_text=text});f:close()end
local function imagewrite(name,img)local f=assert(io.open(root..'/'..name..'.png','wb'));f:write((require('mime').unb64(img.data)));f:close()end
local function waitjob(job,fn)local start=require('socket').gettime();local function poll()if job.state=='queued' or job.state=='running' then assert(require('socket').gettime()-start<15,'job timed out');later(.1,poll);return end;check(job.state=='completed','job '..job.id..' completed via real HTTP',{error=job.error});fn()end;later(.1,poll)end
later(1,function()
 local ui=require('apps/reader/readerui').instance;local p=ui.koassistant;p:ensureInitialized()
 local Q=require('koassistant_question_ui');local R=require('koassistant_question_runtime');local P=require('koassistant_question_payload');local Page=require('koassistant_question_page');local Prompts=require('koassistant_question_prompts');local q=R.get(p)
 for i=#U._window_stack,1,-1 do local w=U._window_stack[i].widget;if w.text=='Book info cache database updated.'then U:close(w)end end
 if os.getenv('EXT_E2E_PHASE')=='recover' then
  local c=q:get('3');check(c and c.state=='completed' and c.parent_id=='2' and c.root_id=='1','follow-up lineage survives restart after ancestor removal')
  check(c.document.page==3 and c.image and type(c.messages[1].content)=='table' and c.messages[1].content[2].image_url.url:match('^data:image/png;base64,') and #c.messages>=5,'follow-up retained full original source independently')
  local found;for _,a in ipairs(p.action_service:getAllActions('highlight',false,true)) do if a.text=='E2E saved notation prompt' then found=a end end
  check(found and found.prompt=='Explain all mathematical notation.','registered prompt survives actual reader restart')
  local favorites=Prompts.favorites(p,{document=c.document});local fav;for _,a in ipairs(favorites)do if a.text=='E2E saved notation prompt'then fav=true end end
  check(fav,'saved prompt still appears in shared favorites after restart')
  local recent=Prompts.recent(q.jobs);check(#recent==5 and recent[1].prompt=='  repeated   wording  ','bounded deduplicated recent wording persists from inbox')
  check(not q.active,'restart does not launch completed or cancelled follow-ups');log('DONE');U:quit(0);return
 end
 ui.paging:onGotoPage(3)
 local captured,err=Page.capture(ui);check(captured~=nil,'native original full PDF page captured',{error=err})
 check(captured.document.page==3 and captured.document.end_page==3 and captured.document.capture_kind=='whole_page','whole-page source metadata identifies original page')
 check(math.max(captured.image.width,captured.image.height)<=1800,'full-page raster stays within1800pxlongest-edge cap')
 imagewrite('original-full-page3',captured.image)
 ui.zooming:onZoom('in');ui.zooming:onZoom('in');ui.zooming:onZoom('in')
 local zoomed=assert(Page.capture(ui));check(zoomed.image.data==captured.image.data,'whole-page bytes independent of actual reader zoom')
 local jobcount=#q.jobs;local id=assert(Prompts.save(p,'E2E saved notation prompt','Explain all mathematical notation.'))
 check(#q.jobs==jobcount,'saving registered prompt queues no request')
 local dupe=Prompts.save(p,'E2E saved notation prompt','Should not overwrite');check(dupe==nil,'duplicate registered prompt name rejected without overwrite')
 local favorites=Prompts.favorites(p,captured);local matched;for _,a in ipairs(favorites)do if a.id==id and a.prompt=='Explain all mathematical notation.'then matched=true end end
 check(matched,'saved prompt registered in existing shared favorites')
 plan('ORIGINAL_ANSWER_ON_PAGE3: the derivative is $2x+3$.')
 local snapshot=P.prepare(p,captured,{id='queued_custom',text='Whole page test',prompt='Explain ORIGINAL_SOURCE_WHOLE_PAGE3.'})
 snapshot.config.base_url='http://127.0.0.1:8768/v1/chat/completions';snapshot.config.provider_settings={openai={base_url=snapshot.config.base_url}}
 local a=assert(q:enqueue(snapshot));ui.paging:onGotoPage(5)
 waitjob(a,function()
  local original=require('koassistant_question_queue').copy(a)
  plan('FIRST_FOLLOWUP_ANSWER: differentiate each term.')
  local b=assert(Q.enqueueFollowup(p,a,'FIRST_FOLLOWUP: why does the linear term give 3?'))
  check(b.parent_id==a.id and b.root_id==a.id and b.document.page==3,'follow-up lineage and original source retained while reader is on5')
  check(b.config.model==a.config.model and b.image.data==a.image.data,'follow-up freezes original model and source image')
  waitjob(b,function()
   check(a.answer==original.answer and a.attempts==1 and a.messages[1].content[1].text==original.messages[1].content[1].text,'original answer and request remain untouched by follow-up')
   check(b.messages[#b.messages-1].role=='assistant' and b.messages[#b.messages-1].content==a.answer,'follow-up includes exact preceding saved answer')
   assert(q:remove(a.id));check(q:get(a.id)==nil and b.image.data==original.image.data,'child remains self-contained after ancestor removed')
   plan('SECOND_FOLLOWUP_ANSWER: the original page stays the context.')
   local c=assert(Q.enqueueFollowup(p,b,'SECOND_FOLLOWUP: keep using the original formula.'))
   waitjob(c,function()
    check(c.parent_id==b.id and c.root_id==a.id and c.document.page==3,'second follow-up keeps root/source after root deletion')
    check(c.messages[#c.messages-1].content==b.answer and c.messages[#c.messages-3].content==original.answer,'second follow-up retains both prior answers in order')
    check(ui:getCurrentPage()==5,'full-page and follow-up work did not move reading position')
    q:suspend()
    local base=#q.jobs
    for i=#U._window_stack,1,-1 do local w=U._window_stack[i].widget;if w~=ui then U:close(w)end end
    Q.showChooser(p,captured,nil,'all');local menu=U._window_stack[#U._window_stack].widget
    local item;for _,x in ipairs(menu.item_table)do if x.text=='E2E saved notation prompt'then item=x end end
    check(item~=nil,'saved prompt is visible in actual registered chooser')
    item.callback();item.callback();check(#q.jobs==base+1,'repeated saved-prompt callback creates only one job');assert(q:cancel(q.jobs[#q.jobs].id))
    for i=#U._window_stack,1,-1 do local w=U._window_stack[i].widget;if w~=ui then U:close(w)end end
    Q.showCustom(p,captured,'Duplicate custom submit guard');local dialog=U._window_stack[#U._window_stack].widget
    local button;for _,row in ipairs(dialog.buttons)do for _,x in ipairs(row)do if x.text=='Queue'then button=x end end end
    check(button~=nil,'custom prompt actual Queue button available')
    local old=#q.jobs;button.callback();button.callback();check(#q.jobs==old+1,'repeated custom-submit callback creates only one job');assert(q:cancel(q.jobs[#q.jobs].id))
    for i=1,7 do local x=require('koassistant_question_queue').copy(snapshot);x.prompt='Recent '..i;local j=assert(q:enqueue(x));assert(q:cancel(j.id))end
    for _,t in ipairs({'repeated wording','  repeated   wording  '})do local x=require('koassistant_question_queue').copy(snapshot);x.prompt=t;local j=assert(q:enqueue(x));assert(q:cancel(j.id))end
    local recent=Prompts.recent(q.jobs);check(#recent==5 and recent[1].prompt=='  repeated   wording  ','recent custom wording deduplicates whitespace and caps at5')
    for i=2,#recent do check(recent[i].prompt~='repeated wording','recent entry'..i..' has no duplicate wording')end
    for i=#U._window_stack,1,-1 do local w=U._window_stack[i].widget;if w~=ui then U:close(w)end end
    local current=assert(P.capture(ui,{text='NEW_SOURCE_PAGE5',pos0={page=5},pos1={page=5}}))
    local before_recent=#q.jobs;Q.showRecent(p,current)
    local recentmenu=U._window_stack[#U._window_stack].widget
    recentmenu.item_table[1].callback()
    check(#q.jobs==before_recent,'choosing Recent only opens editable wording, sends no request')
    local editor=U._window_stack[#U._window_stack].widget
    check(editor:getInputText()==recent[1].prompt,'Recent editor preserves exact chosen wording')
    local submit;for _,row in ipairs(editor.buttons)do for _,x in ipairs(row)do if x.text=='Queue'then submit=x end end end
    submit.callback();local reused=q.jobs[#q.jobs]
    check(reused.document.page==5 and reused.selected_text=='NEW_SOURCE_PAGE5','Recent wording binds to newly captured source, not original job')
    assert(q:cancel(reused.id))
    log('DONE');U:quit(0)
   end)
  end)
 end)
end)
