local script = debug.getinfo(1, "S").source:sub(2)
local root = script:match("^(.*)/tests/unit/") or "."
package.path = root .. "/?.lua;" .. root .. "/tests/lib/?.lua;" .. package.path
local T = require("test_runner"):new()
local Queue = require("koassistant_question_queue")
local Followup = require("koassistant_question_followup")
local function original(image)
    return { id="1", state="completed", answer="Original answer α", selected_text="Frozen excerpt",
        label="Explain", prompt="Explain source", action_id="explain", attempts=1,
        document={file="/first.pdf",page=3,captured_at=100,capture_kind="whole_page"},
        config={provider="openai",model="gpt-4o-mini",features={}},
        image=image and {width=1273,height=1800,mime_type="image/png"} or nil,
        messages={image and require("koassistant_question_vision").message("openai","original question",{data="UE5H"})
            or {role="user",content="Original source and original question"},
            {role="user",content="Frozen spoiler boundary",is_context=true}},
    }
end
local function harness(data)
    local h = {stored=data,starts={},scheduled={},now=1000}
    h.deps={load=function() return h.stored and Queue.copy(h.stored) end,
        save=function(value) h.stored=Queue.copy(value);return true end,
        now=function() h.now=h.now+1;return h.now end,
        schedule=function(fn) h.scheduled[#h.scheduled+1]=fn end,
        start=function(job,finish,cancel) h.starts[#h.starts+1]={job=job,finish=finish};cancel(function() end) end}
    h.q=Queue:new(h.deps)
    function h:tick() local todo=self.scheduled;self.scheduled={};for _,fn in ipairs(todo) do fn() end end
    return h
end
T:test("follow-up is a new immutable snapshot with original source and prior answer", function()
    local p=original();local s=assert(Followup.prepare(p,"Explain the second step"))
    T:assertEqual(s.parent_id,"1");T:assertEqual(s.root_id,"1")
    T:assertEqual(s.messages[1].content,p.messages[1].content)
    T:assertEqual(s.messages[3].role,"assistant");T:assertEqual(s.messages[3].content,"Original answer α")
    T:assertTrue(s.messages[4].content:find("Explain the second step",1,true))
    p.document.page=99;p.answer="changed";p.messages[1].content="changed";p.config.model="changed"
    T:assertEqual(s.document.page,3);T:assertEqual(s.document.captured_at,100)
    T:assertEqual(s.config.model,"gpt-4o-mini");T:assertEqual(s.messages[3].content,"Original answer α")
end)
T:test("image source is carried exactly once and vision support fails closed", function()
    local p=original(true);local s=assert(Followup.prepare(p,"Explain the integral"))
    T:assertEqual(s.messages[1].content[2].image_url.url,"data:image/png;base64,UE5H")
    T:assertEqual(s.image.data,nil)
    p.config.model="gpt-3.5-turbo"
    local bad,err=Followup.prepare(p,"Explain")
    T:assertEqual(bad,nil);T:assertTrue(err:find("image-capable",1,true))
end)
T:test("subscription image follow-up keeps its original provider model and one frozen image", function()
    local p=original(true)
    p.config.provider="openai_codex";p.config.model="gpt-5.6-terra"
    local s=assert(Followup.prepare(p,"Explain the symbol"))
    T:assertEqual(s.config.provider,"openai_codex")
    T:assertEqual(s.config.model,"gpt-5.6-terra")
    T:assertEqual(s.messages[1].content[2].image_url.url,"data:image/png;base64,UE5H")
    T:assertEqual(#s.messages,4)
    T:assertEqual(s.messages[3].content,"Original answer α")
    T:assertEqual(s.config.enable_web_search,false)
    T:assertEqual(s.config.features.enable_web_search,false)
    p.messages[1].content[2].image_url.url="changed"
    T:assertEqual(s.messages[1].content[2].image_url.url,"data:image/png;base64,UE5H")
end)
T:test("repeated follow-ups keep root source and latest parent linkage", function()
    local p=original();local a=assert(Followup.prepare(p,"Question two"));a.id="2";a.state="completed";a.answer="Answer two"
    local b=assert(Followup.prepare(a,"Question three"))
    T:assertEqual(b.parent_id,"2");T:assertEqual(b.root_id,"1")
    T:assertEqual(#b.messages,6);T:assertEqual(b.messages[3].content,p.answer)
    T:assertEqual(b.messages[5].content,"Answer two");T:assertEqual(b.followup.exchanges,2)
end)
T:test("long conversations retain source and recent complete exchanges within budget", function()
    local p=original()
    for i=2,20 do local child=assert(Followup.prepare(p,"Question "..i));child.id=tostring(i);child.state="completed";child.answer="Answer "..i;p=child end
    T:assertEqual(p.followup.exchanges,8)
    T:assertTrue(p.followup.omitted_exchanges>0)
    T:assertEqual(p.messages[1].content,"Original source and original question")
    T:assertTrue(p.followup.history_bytes<=Followup.MAX_HISTORY_BYTES)
    T:assertTrue(Followup.describe(p):find("shortened history",1,true))
end)
T:test("oversized UTF-8 prior answer is visibly clipped without changing saved answer", function()
    local p=original();p.answer=string.rep("数学",5000)
    local s=assert(Followup.prepare(p,"Explain"))
    T:assertTrue(s.followup.prior_answer_clipped)
    T:assertTrue(s.messages[3].content:find("excerpt ends here",1,true))
    T:assertEqual(#p.answer,30000)
    local before=s.messages[3].content:match("^(.-)\n%[")
    T:assertEqual(#before%3,0)
    T:assertTrue(s.followup.history_bytes<=Followup.MAX_HISTORY_BYTES)
end)
T:test("incomplete or blank follow-up does not produce a snapshot", function()
    local p=original();p.state="failed";T:assertEqual(Followup.prepare(p,"Explain"),nil)
    p.state="completed";T:assertEqual(Followup.prepare(p,"  "),nil)
    T:assertEqual(Followup.prepare(p,string.rep("x",4001)),nil)
end)
T:test("follow-up queue persists before dispatch and does not rerun original", function()
    local p=original();local h=harness{version=1,next_id=2,jobs={p}}
    local job=assert(h.q:enqueue(assert(Followup.prepare(h.q:get("1"),"More detail"))))
    T:assertEqual(job.id,"2");T:assertEqual(#h.starts,0)
    T:assertEqual(h.stored.jobs[2].parent_id,"1");h:tick()
    T:assertEqual(#h.starts,1);T:assertEqual(h.starts[1].job.id,"2")
    h.starts[1].finish(true,"New follow-up answer");h:tick()
    T:assertEqual(h.q:get("1").answer,"Original answer α")
    T:assertEqual(h.q:get("1").attempts,1);T:assertEqual(#h.starts,1)
end)
T:test("cancel retry and restart preserve follow-up source without surprise sends", function()
    local h=harness{version=1,next_id=2,jobs={original(true)}}
    local job=assert(h.q:enqueue(assert(Followup.prepare(h.q:get("1"),"Explain image"))))
    h.q:cancel(job.id);h:tick();T:assertEqual(#h.starts,0)
    assert(h.q:retry(job.id));h:tick();T:assertEqual(#h.starts,1)
    local restarted=harness(h.stored);restarted:tick()
    T:assertEqual(#restarted.starts,0);T:assertEqual(restarted.q:get("2").state,"interrupted")
    T:assertEqual(restarted.q:get("2").messages[1].content[2].image_url.url,"data:image/png;base64,UE5H")
    assert(restarted.q:retry("2"));restarted:tick();T:assertEqual(#restarted.starts,1)
    T:assertEqual(restarted.starts[1].job.parent_id,"1")
end)
T:test("removing original job does not orphan frozen child context", function()
    local h=harness{version=1,next_id=2,jobs={original()}}
    local child=assert(h.q:enqueue(assert(Followup.prepare(h.q:get("1"),"Explain"))))
    assert(h.q:remove("1"));h:tick()
    T:assertEqual(child.parent_id,"1");T:assertEqual(h.starts[1].job.messages[3].content,"Original answer α")
end)
return T:summary()
