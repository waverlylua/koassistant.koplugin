local script=debug.getinfo(1,"S").source:sub(2)
local root=script:match("^(.*)/tests/unit/") or "."
package.path=root.."/?.lua;"..root.."/tests/lib/?.lua;"..package.path
local T=require("test_runner"):new()
local Prompts=require("koassistant_question_prompts")
T:test("recent questions derive persistent custom wording newest first deduped and bounded",function()
    local jobs={}
    for i=1,9 do jobs[#jobs+1]={id=tostring(i),action_id="queued_custom",prompt="Question "..i,selected_text="PRIVATE SOURCE"} end
    jobs[#jobs+1]={id="10",action_id="queued_followup",prompt="Question 9"}
    jobs[#jobs+1]={id="11",action_id="queued_followup",saved_prompt_id="explain",prompt="registered wording"}
    local recent=Prompts.recent(jobs)
    T:assertEqual(#recent,5);T:assertEqual(recent[1].prompt,"Question 9");T:assertEqual(recent[1].job_id,"10")
    T:assertEqual(recent[2].prompt,"Question 8");T:assertEqual(recent[1].selected_text,nil)
end)
T:test("favorites reuse action service order and filter incompatible live extraction",function()
    local seen
    local plugin={action_service={getInputActionObjects=function(_self,context,path)
        seen={context,path};return {{id="z",prompt="Z"},{id="live",prompt="live",use_book_text=true},{id="a",prompt="A"}} end}}
    local favorites=Prompts.favorites(plugin,{document={file="/frozen.pdf"}})
    T:assertEqual(seen[1],"highlight");T:assertEqual(seen[2],"/frozen.pdf")
    T:assertEqual(#favorites,2);T:assertEqual(favorites[1].id,"z");T:assertEqual(favorites[2].id,"a")
end)
T:test("save uses existing registered store then adds highlight shortcut without a request",function()
    local actions,added={},{}
    local plugin={settings={readSetting=function() return actions end},action_service={
        addUserAction=function(_self,action) actions[#actions+1]=action end,
        addToInput=function(_self,context,id) added={context,id} end}}
    T:assertEqual(Prompts.save(plugin,"Explain notation","Explain each symbol"),"ui_1")
    T:assertEqual(actions[1].context,"highlight");T:assertEqual(actions[1].prompt,"Explain each symbol")
    T:assertEqual(added[1],"highlight");T:assertEqual(added[2],"ui_1")
    T:assertEqual(Prompts.save(plugin,"Explain notation","duplicate"),nil);T:assertEqual(#actions,1)
    T:assertEqual(Prompts.save(plugin," ","anything"),nil)
end)
return T:summary()
