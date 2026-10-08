local script=debug.getinfo(1,"S").source:sub(2)
local root=script:match("^(.*)/tests/unit/") or "."
package.path=root.."/?.lua;"..root.."/tests/lib/?.lua;"..package.path
local T=require("test_runner"):new()
local saved={}
local function stub(name,value) saved[name]={value=package.loaded[name]};package.loaded[name]=value end
local shown,closed,queued={}, {}, {}
local q={jobs={},deps={}}
function q:get(id) for _,job in ipairs(self.jobs) do if job.id==id then return job end end end
function q:enqueue(snapshot) queued[#queued+1]=snapshot;return snapshot end
function q:markRead() return true end
local class={new=function(_self,args)
    args.getInputText=function(self) return self.input end
    args.onShowKeyboard=function() end
    args.onClose=function(self) closed[#closed+1]=self end
    return args
end}
stub("koassistant_gettext",function(s) return s end)
stub("ui/uimanager",{show=function(_self,w) shown[#shown+1]=w end,close=function(_self,w) closed[#closed+1]=w end,nextTick=function(_self,fn) fn() end})
for _,name in ipairs{"menu","buttondialog","infomessage","notification","inputdialog"} do stub("ui/widget/"..name,class) end
stub("koassistant_chatgptviewer",class)
stub("koassistant_question_runtime",{get=function() return q end,badge=function() return "" end})
stub("koassistant_config_helper", {getModelInfo=function(_self, config) return config.model end})
local Payload=require("koassistant_question_payload")
local prepare=Payload.prepare
Payload.prepare=function(_plugin,captured,action) return {document=captured.document,messages={{role="user",content=action.prompt}},prompt=action.prompt} end
package.loaded["koassistant_question_ui"]=nil
local UI=require("koassistant_question_ui")
local function reset()
    shown,closed,queued={},{},{};q.jobs={}
    local custom={}
    local plugin={settings={readSetting=function(_self,key) if key=="custom_actions" then return custom end;return {} end},action_service={}}
    function plugin:ensureInitialized() end
    function plugin:updateConfigFromSettings() end
    function plugin.action_service:getInputActionObjects()
        local out={};for i=1,6 do out[#out+1]={id="p"..i,text="Prompt "..i,prompt="Ask "..i} end;return out
    end
    plugin.action_service.getAllActions=plugin.action_service.getInputActionObjects
    function plugin.action_service:addUserAction(action) custom[#custom+1]=action end
    function plugin.action_service:addToInput(context,id) self.added={context,id} end
    return plugin,{document={file="/current.pdf",page=9},selected_text="CURRENT SOURCE"},custom
end
local function item(dialog,text)
    for _,v in ipairs(dialog.item_table or {}) do if v.text==text then return v end end
    error("Missing item "..text)
end
local function button(dialog,text)
    for _,row in ipairs(dialog.buttons or dialog.buttons_table or {}) do for _,v in ipairs(row) do if v.text==text then return v end end end
    error("Missing button "..text)
end
T:test("compact picker keeps three ordered favorites and custom on first nine rows",function()
    local plugin,c=reset();UI.showChooser(plugin,c)
    local dialog=shown[#shown]
    T:assertEqual(#dialog.item_table,9)
    T:assertEqual(dialog.item_table[2].text,"Prompt 1")
    T:assertEqual(dialog.item_table[4].text,"Prompt 3")
    T:assertTrue(item(dialog,"More saved shortcuts…"));T:assertTrue(item(dialog,"Write a question…"))
    T:assertTrue(dialog.subtitle:find("CURRENT SOURCE",1,true));T:assertEqual(#queued,0)
end)
T:test("shortcut repeated callback submits exactly one new job",function()
    local plugin,c=reset();UI.showChooser(plugin,c)
    local chosen=item(shown[#shown],"Prompt 1")
    chosen.callback();chosen.callback();T:assertEqual(#queued,1)
    T:assertEqual(queued[1].document.page,9)
end)
T:test("recent wording opens editor on current source and does not resend old job",function()
    local plugin,c=reset();q.jobs={{id="10",action_id="queued_custom",prompt="Old wording",document={page=1}}}
    UI.showRecent(plugin,c);item(shown[#shown],"Old wording").callback()
    local editor=shown[#shown];T:assertEqual(editor.input,"Old wording")
    T:assertTrue(editor.description:find("Page 9",1,true));T:assertEqual(#queued,0)
    local send=button(editor,"Queue");send.callback();send.callback()
    T:assertEqual(#queued,1);T:assertEqual(queued[1].document.page,9)
end)
T:test("save-as-prompt returns typed editor and never queues",function()
    local plugin,c,custom=reset();UI.showCustom(plugin,c,"Explain each symbol")
    button(shown[#shown],"Save as prompt…").callback()
    local save=shown[#shown];save.input="My notation helper";button(save,"Save prompt").callback()
    T:assertEqual(#queued,0);T:assertEqual(#custom,1);T:assertEqual(custom[1].text,"My notation helper")
    T:assertEqual(shown[#shown].input,"Explain each symbol")
    T:assertEqual(plugin.action_service.added[1],"highlight")
end)
T:test("custom cancellation leaves queue unchanged",function()
    local plugin,c=reset();UI.showCustom(plugin,c,"Draft only");button(shown[#shown],"Cancel").callback()
    T:assertEqual(#queued,0)
end)
T:test("unsupported image model is explained before the question editor opens",function()
    local plugin,c=reset();c.image={data="UE5H"}
    plugin.configuration={provider="deepseek",model="deepseek-chat"}
    UI.showCustom(plugin,c)
    T:assertEqual(#shown,1)
    T:assertTrue(shown[1].text:find("deepseek / deepseek-chat",1,true))
    T:assertTrue(shown[1].text:find("OpenAI Subscription",1,true))
    T:assertEqual(shown[1].input,nil)
    T:assertEqual(#queued,0)
end)
T:test("subscription image question opens normally and cancellation sends nothing",function()
    local plugin,c=reset();c.image={data="UE5H"}
    plugin.configuration={provider="openai_codex",model="gpt-5.6-terra"}
    UI.showCustom(plugin,c,"Explain the equation")
    T:assertEqual(shown[#shown].title,"Ask about this image")
    T:assertEqual(shown[#shown].input,"Explain the equation")
    button(shown[#shown],"Cancel").callback()
    T:assertEqual(#queued,0)
end)
T:test("answer exposes separate full-width follow-up row without rerunning it",function()
    local plugin,c=reset();c.id="7";c.label="Explain";c.answer="Saved answer";c.prompt="Explain";c.config={}
    q.jobs={c}
    UI.showAnswer(plugin,c)
    local viewer=shown[#shown]
    T:assertEqual(#viewer.buttons_table,3);T:assertEqual(#viewer.buttons_table[1],1)
    T:assertEqual(viewer.buttons_table[1][1].text,"Ask a follow-up…")
    T:assertEqual(#queued,0)
end)
T:test("saved-answer font and alignment settings persist across reopen",function()
    local plugin,c=reset();c.id="7";c.answer="Saved answer";c.config={}
    local features={markdown_font_size=20,text_align="auto",provider_secret_setting="unchanged"}
    local flushes=0
    plugin.settings.readSetting=function(_self,key) if key=="features" then return features end end
    plugin.settings.saveSetting=function(_self,key,value) T:assertEqual(key,"features");features=value end
    plugin.settings.flush=function() flushes=flushes+1 end
    q.jobs={c}
    UI.showAnswer(plugin,c)
    local viewer=shown[#shown]
    T:assertTrue(viewer.saved_answer_view)
    viewer.settings_callback("features.markdown_font_size",30)
    viewer.settings_callback("features.text_align","left")
    viewer.settings_callback("provider","should not persist")
    q.jobs={c}
    UI.showAnswer(plugin,c)
    T:assertEqual(shown[#shown].configuration.features.markdown_font_size,30)
    T:assertEqual(shown[#shown].configuration.features.text_align,"left")
    T:assertEqual(features.provider_secret_setting,"unchanged")
    T:assertEqual(flushes,2);T:assertEqual(#queued,0)
end)
Payload.prepare=prepare
package.loaded["koassistant_question_ui"]=nil
for name,previous in pairs(saved) do package.loaded[name]=previous.value end
return T:summary()
