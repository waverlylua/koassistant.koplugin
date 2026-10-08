local script = debug.getinfo(1, "S").source:sub(2)
local root = script:match("^(.*)/tests/unit/") or "."
package.path = root .. "/?.lua;" .. root .. "/tests/lib/?.lua;" .. package.path
local T = require("test_runner"):new()
local Payload = require("koassistant_question_payload")
local Vision = require("koassistant_question_vision")
local Queue = require("koassistant_question_queue")
local saved = {}
local function stub(name, value)
    saved[name] = { value = package.loaded[name] }
    package.loaded[name] = value
end
stub("koassistant_config_helper", { deepCopy = function(_self, data) return Queue.copy(data) end,
    getModelInfo = function(_self, config) return config.model or "default" end })

T:test("persisted configuration excludes credentials and unrelated private feature data", function()
    local config = { provider = "custom_local", model = "frozen", api_key = "SECRET", oauth = {access_token="SECRET"},
        system = {text="system"}, api_params={temperature=0.3}, features = {
            api_keys = {openai="SECRET"}, selection_data={text="other private selection"},
            custom_providers={{id="custom_local",base_url="http://localhost:1",api_key="SECRET",api_key_required=false}},
        }, provider_settings={custom_local={model="old",base_url="http://localhost:1",api_key="SECRET"}} }
    local frozen = Payload.config(config)
    T:assertEqual(frozen.api_key, nil); T:assertEqual(frozen.oauth, nil)
    T:assertEqual(frozen.features.api_keys, nil); T:assertEqual(frozen.features.selection_data, nil)
    T:assertEqual(frozen.custom_provider.api_key, nil)
    T:assertEqual(frozen.provider_settings.custom_local.api_key, nil)
    config.features.custom_providers[1].base_url = "http://wrong"
    config.model = "changed"
    T:assertEqual(frozen.custom_provider.base_url, "http://localhost:1")
    T:assertEqual(frozen.model, "frozen")
end)
T:test("selection-only action eligibility rejects live extraction and local actions", function()
    T:assertTrue(Payload.eligible{prompt="Explain"})
    T:assertFalse(Payload.eligible{prompt="Explain",requires={"book_text"}})
    T:assertFalse(Payload.eligible{prompt="Explain",local_handler="image_gen"})
    T:assertFalse(Payload.eligible{prompt="Explain",smart_retrieval=true})
end)
T:test("OpenAI image request carries image_url data URI and high detail", function()
    local msg = Vision.message("openai", "question", { data="UE5H", mime_type="image/png" })
    T:assertEqual(msg.content[1].text, "question")
    T:assertEqual(msg.content[2].image_url.url, "data:image/png;base64,UE5H")
    T:assertEqual(msg.content[2].image_url.detail, "high")
end)
T:test("Anthropic image request carries base64 source media type", function()
    local msg = Vision.message("anthropic", "question", { data="UE5H", mime_type="image/png" })
    T:assertEqual(msg.content[1].source.data, "UE5H")
    T:assertEqual(msg.content[1].source.media_type, "image/png")
    T:assertEqual(msg.content[2].text, "question")
end)
T:test("Gemini image request carries native inline_data parts", function()
    local msg = Vision.message("gemini", "question", { data="UE5H", mime_type="image/png" })
    T:assertEqual(msg.parts[1].inline_data.data, "UE5H")
    T:assertEqual(msg.parts[1].inline_data.mime_type, "image/png")
    T:assertEqual(msg.parts[2].text, "question")
end)
T:test("vision eligibility fails closed for text-only providers and unknown models", function()
    T:assertTrue(Vision.supported("openai", "gpt-4o-mini"))
    T:assertTrue(Vision.supported("openai", "gpt-6-sol"))
    T:assertTrue(Vision.supported("openai_codex", "gpt-5.6-terra"))
    T:assertTrue(Vision.supported("openai_codex", "gpt-5.4-mini"))
    T:assertFalse(Vision.supported("openai_codex", "gpt-3.5-turbo"))
    T:assertFalse(Vision.supported("openai_codex", "unknown"))
    T:assertTrue(Vision.supported("anthropic", "claude-sonnet-4-5"))
    T:assertTrue(Vision.supported("gemini", "gemini-2.5-pro"))
    T:assertFalse(Vision.supported("openai", "gpt-3.5-turbo"))
    T:assertFalse(Vision.supported("deepseek", "deepseek-chat"))
    T:assertFalse(Vision.supported("custom_foo", "unknown"))
end)
local seen_data
stub("koassistant_dialogs", {prepareQueuedConfig=function(_action, config) return config end})
stub("koassistant_doc_settings", {resolve=function() return {} end})
stub("koassistant_book_settings", {
    getMetadataOverride=function() return "Private alias", "" end,
    resolveBookInfoLevel=function() return "none" end,
    resolveDomain=function() return nil end,
})
stub("message_builder", {build=function(args) seen_data=args.data; return "built question" end})
stub("koassistant_book_tool_runner", {_liveSpoilerLine=function() return "Frozen no-spoilers instruction" end})
T:test("queued request honors per-book metadata override and Book info privacy", function()
    local plugin = {configuration={provider="openai",model="gpt-4o-mini",features={}},ui={}}
    function plugin:ensureInitialized() end
    function plugin:updateConfigFromSettings() end
    function plugin:_scrubContextFeatures() end
    local result = Payload.prepare(plugin, {selected_text="passage",document={file="/book.pdf",title="Secret title",authors="Author",page=4}}, {text="Explain",prompt="Explain"})
    T:assertEqual(seen_data._book_info_level, "none")
    T:assertEqual(seen_data.book_title, "Private alias")
    T:assertEqual(seen_data.book_author, "")
    T:assertEqual(result.document.title, "Secret title") -- provenance remains local
    T:assertEqual(result.messages[1].content, "built question")
    T:assertEqual(result.messages[2].content, "Frozen no-spoilers instruction")
end)
T:test("region snapshot stores one image payload and freezes vision request without web routes", function()
    local plugin = {configuration={provider="openai",model="gpt-4o-mini",features={enable_web_search=true}},ui={}}
    function plugin:ensureInitialized() end
    function plugin:updateConfigFromSettings() end
    function plugin:_scrubContextFeatures() end
    local result = Payload.prepare(plugin, {selected_text="",document={file="/book.pdf",title="Book"},
        image={data="UE5H",mime_type="image/png",width=120,height=80}}, {text="Explain",prompt="Explain"})
    T:assertEqual(result.image.data, nil)
    T:assertEqual(result.image.width, 120)
    T:assertEqual(result.messages[1].content[2].image_url.url, "data:image/png;base64,UE5H")
    T:assertEqual(result.config.enable_web_search, false)
    T:assertEqual(result.config.features.enable_web_search, false)
end)
for _, capture_kind in ipairs({"whole_page", "region"}) do
    T:test("subscription " .. capture_kind .. " snapshot retains image and freezes vision destination", function()
        local plugin = {configuration={provider="openai_codex",model="gpt-5.6-terra",features={enable_web_search=true}},ui={}}
        function plugin:ensureInitialized() end
        function plugin:updateConfigFromSettings() end
        function plugin:_scrubContextFeatures() end
        local captured = {selected_text="",document={file="/book.pdf",title="Book",page=7,capture_kind=capture_kind},
            image={data="UE5H",mime_type="image/png",width=120,height=80}}
        local result = Payload.prepare(plugin, captured, {text="Explain",prompt="Explain"})
        T:assertEqual(result.config.provider, "openai_codex")
        T:assertEqual(result.config.model, "gpt-5.6-terra")
        T:assertEqual(result.document.capture_kind, capture_kind)
        T:assertEqual(result.document.page, 7)
        T:assertEqual(result.image.data, nil)
        T:assertEqual(result.image.width, 120)
        T:assertEqual(result.messages[1].content[2].image_url.url, "data:image/png;base64,UE5H")
        T:assertEqual(result.messages[1].content[2].image_url.detail, "high")
        local scope = capture_kind == "whole_page" and "whole original document page" or "selected region"
        T:assertTrue(result.messages[1].content[1].text:find(scope, 1, true))
        T:assertEqual(result.messages[2].content, "Frozen no-spoilers instruction")
        T:assertEqual(result.config.enable_web_search, false)
        T:assertEqual(result.config.features.enable_web_search, false)
        captured.image.data = "CHANGED"
        captured.document.page = 9
        plugin.configuration.model = "changed"
        T:assertEqual(result.messages[1].content[2].image_url.url, "data:image/png;base64,UE5H")
        T:assertEqual(result.document.page, 7)
        T:assertEqual(result.config.model, "gpt-5.6-terra")
    end)
end
stub("koassistant_notebook", {getPageInfo=function() return {page=2,total_pages=6,chapter="footer chapter"} end})
stub("libs/libkoreader-lfs", {attributes=function() return {size=123,modification=456} end})
T:test("PDF selection origin uses selected page rather than continuous-view footer", function()
    local ui = {document={file="/book.pdf"},doc_props={title="Book"},toc={getTocTitleByPage=function(_self,p) return "Chapter "..p end}}
    local captured = Payload.capture(ui, {text="page 3 selection",pos0={page=3,x=12},pos1={page=4,x=40}})
    T:assertEqual(captured.document.page, 3)
    T:assertEqual(captured.document.end_page, 4)
    T:assertEqual(captured.document.chapter, "Chapter 3")
    T:assertEqual(captured.document.pos0.x, 12)
end)
for name, previous in pairs(saved) do package.loaded[name] = previous.value end
return T:summary()
