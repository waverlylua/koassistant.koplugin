-- Queue integration regressions across the real runtime, query router and OAuth
-- refresh path. No network, credentials, files, subprocesses or UI are touched.
local script = debug.getinfo(1, "S").source:sub(2)
local root = script:match("^(.*)/tests/unit/") or "."
package.path = root .. "/?.lua;" .. root .. "/tests/lib/?.lua;" .. package.path
require("mock_koreader")

local T = require("test_runner"):new()
local Queue = require("koassistant_question_queue")
local OAuth = require("koassistant_openai_codex_oauth")
local Codex = require("koassistant_api.openai_codex")
local Custom = require("koassistant_api.custom_openai")
local JSON = require("json")
local Base = require("koassistant_api.base")
local original_codex_query, original_custom_query = Codex.query, Custom.query
local original_resolve, original_fetch, original_write = Base.resolveForSubprocess, Base.fetchInSubprocess, Base.writeAllToFD
local replaced, originally_missing = {}, {}
local function replace(name, value)
    if replaced[name] == nil and not originally_missing[name] then
        replaced[name] = package.loaded[name]
        originally_missing[name] = package.loaded[name] == nil
    end
    package.loaded[name] = value
end

local function harness(use_codex_wire)
    local h = { callbacks = {}, refreshes = {}, dispatches = {}, flushes = 0 }
    h.settings = { data = { features = {
        custom_providers = {{ id = "custom_test", name = "Live provider", base_url = "https://live.example/v1" }},
        api_keys = { custom_test = "unit-test-key-never-sent" },
        openai_codex_oauth = {
            access_token = "expired-test-access", refresh_token = "test-refresh", expires_at = 1,
            chatgpt_account_id = "test-account",
        },
    } } }
    function h.settings:readSetting(key, default) return self.data[key] or default end
    function h.settings:saveSetting(key, value) self.data[key] = value; return self end
    function h.settings:flush() h.flushes = h.flushes + 1 end
    replace("ui/uimanager", {
        scheduleIn = function(_, _delay, fn) h.callbacks[#h.callbacks + 1] = fn end,
        setDirty = function() end,
    })
    replace("ui/network/manager", { runWhenConnected = function() error("Queued requests must not prompt for Wi-Fi") end })
    replace("apps/reader/readerui", {})
    replace("apikeys", {})
    replace("koassistant_question_store", { new = function()
        return {
            load = function() return nil end,
            hydrate = function(_, job) return job end,
            save = function(_, data) h.saved = Queue.copy(data); return true end,
        }
    end })
    replace("koassistant_question_runtime", nil)
    h.queue = require("koassistant_question_runtime").get({ settings = h.settings })
    OAuth._setAsyncRunnerForTests(function(request, callback)
        h.refreshes[#h.refreshes + 1] = { request = request, callback = callback }
        return #h.refreshes
    end)
    local function providerQuery(_, messages, config)
        h.dispatches[#h.dispatches + 1] = { messages = messages, config = config }
        if use_codex_wire then
            -- Exercise the actual request builder, SSE-only collected transport
            -- and response parser. Only DNS/HTTP/pipe writes are replaced; there
            -- are no network calls, real tokens or OS subprocesses in this test.
            local result = original_codex_query(Codex, messages, config)
            T:assertTrue(result._non_streaming)
            result._background_fn(1, 2)
            local ok, answer = result._response_parser(JSON.decode(h.pipe))
            T:assertTrue(ok)
            return answer
        end
        return "Answer from mocked provider"
    end
    Codex.query, Custom.query = providerQuery, providerQuery
    if use_codex_wire then
        h.requests = {}
        Base.resolveForSubprocess = function() return "203.0.113.10" end
        Base.fetchInSubprocess = function(url, opts)
            h.requests[#h.requests + 1] = { url = url, headers = opts.headers, body = JSON.decode(opts.body) }
            return 200, "data: " .. JSON.encode({type="response.completed",response={
                status="completed",output={{type="message",role="assistant",content={{type="output_text",text="Image answer"}}}},
            }}) .. "\n\n"
        end
        Base.writeAllToFD = function(_fd, value) h.pipe = value end
    end
    function h:tick()
        local callbacks = self.callbacks; self.callbacks = {}
        for _, callback in ipairs(callbacks) do callback() end
    end
    function h:resolve(index)
        self.refreshes[index].callback({ status_code = 200, body = JSON.encode({
            access_token = "refreshed-test-access-" .. index,
            refresh_token = "rotated-test-refresh-" .. index,
            chatgpt_account_id = "test-account", expires_in = 3600,
        }) })
    end
    return h
end

local function snapshot(provider, capture_kind)
    local result = { label = "Test question", prompt = "Explain", selected_text = "Original selection",
        messages = {{ role = "user", content = "Original selection" }},
        config = { provider = provider or "openai_codex", model = "gpt-5.4", features = {} },
        document = { file = "/test.epub", page = 2, pos0 = "xp-start", pos1 = "xp-end" },
    }
    if capture_kind then
        result.document = { file="/original.pdf", page=7, capture_kind=capture_kind }
        result.image = { mime_type="image/png", width=120, height=80 }
        result.messages = {require("koassistant_question_vision").message("openai_codex", "Explain the original image", {data="UE5H"})}
    end
    return result
end

for _, capture_kind in ipairs({"whole_page", "region"}) do
    T:test("queued subscription " .. capture_kind .. " reaches Responses after async OAuth without retargeting", function()
        local h = harness(true)
        local source = snapshot(nil, capture_kind)
        h.queue:enqueue(source); h:tick()
        T:assertEqual(h.queue:get("1").state, "running")
        T:assertEqual(#h.refreshes, 1)
        T:assertEqual(#h.requests, 0)
        -- Reading another page and changing defaults during refresh must not
        -- change the already-copied document or image request.
        source.document.page = 99
        source.messages[1].content[2].image_url.url = "data:image/png;base64,CHANGED"
        h.settings.data.features.provider = "deepseek"
        h:resolve(1)
        T:assertEqual(#h.requests, 1)
        local request = h.requests[1]
        T:assertEqual(request.url, "https://chatgpt.com/backend-api/codex/responses")
        T:assertEqual(request.headers["Authorization"], "Bearer refreshed-test-access-1")
        T:assertEqual(request.headers["ChatGPT-Account-ID"], "test-account")
        T:assertEqual(request.body.model, "gpt-5.4")
        T:assertEqual(request.body.stream, true)
        T:assertEqual(request.body.max_output_tokens, nil)
        T:assertEqual(request.body.input[1].content[1].type, "input_text")
        T:assertEqual(request.body.input[1].content[2].type, "input_image")
        T:assertEqual(request.body.input[1].content[2].image_url, "data:image/png;base64,UE5H")
        T:assertEqual(request.body.input[1].content[2].detail, "high")
        T:assertEqual(h.dispatches[1].config.features.enable_streaming, false)
        T:assertTrue(h.dispatches[1].config.features._background_request)
        T:assertTrue(h.dispatches[1].config.features._suppress_loading_dialog)
        T:assertTrue(h.dispatches[1].config.features._no_auto_retry)
        T:assertEqual(h.queue:get("1").state, "completed")
        T:assertEqual(h.queue:get("1").answer, "Image answer")
        T:assertEqual(h.queue:get("1").document.page, 7)
        T:assertEqual(h.saved.jobs[1].config.api_key, nil)
        T:assertEqual(h.saved.jobs[1].config.oauth, nil)
    end)
end

T:test("subscription image cancelled during OAuth is not sent; explicit retry sends once", function()
    local h = harness(true)
    h.queue:enqueue(snapshot(nil, "whole_page")); h:tick()
    h.queue:cancel("1"); h:resolve(1); h:tick()
    T:assertEqual(#h.requests, 0)
    T:assertEqual(h.queue:get("1").state, "cancelled")
    h.queue:retry("1"); h:tick()
    T:assertEqual(#h.requests, 1)
    T:assertEqual(h.queue:get("1").state, "completed")
    T:assertEqual(h.queue:get("1").attempts, 2)
    T:assertEqual(h.requests[1].body.input[1].content[2].image_url, "data:image/png;base64,UE5H")
end)

T:test("OAuth refresh preserves live custom-provider settings", function()
    local h = harness()
    h.queue:enqueue(snapshot()); h:tick()
    T:assertEqual(#h.refreshes, 1)
    T:assertEqual(#h.dispatches, 0)
    h:resolve(1)
    T:assertEqual(#h.dispatches, 1)
    T:assertEqual(h.queue:get("1").state, "completed")
    T:assertEqual(#h.settings.data.features.custom_providers, 1)
    T:assertEqual(h.settings.data.features.custom_providers[1].base_url, "https://live.example/v1")
    T:assertEqual(h.settings.data.features.openai_codex_oauth.refresh_token, "rotated-test-refresh-1")
    T:assertEqual(h.flushes, 1)
end)

T:test("cancel during OAuth refresh prevents a late paid submission", function()
    local h = harness()
    h.queue:enqueue(snapshot()); h:tick()
    T:assertEqual(#h.refreshes, 1)
    h.queue:cancel("1")
    h:resolve(1); h:tick()
    T:assertEqual(#h.dispatches, 0)
    T:assertEqual(h.queue:get("1").state, "cancelled")
    T:assertEqual(h.saved.jobs[1].state, "cancelled")
    -- A completed refresh can safely save its rotated token, even though the
    -- abandoned question must never be submitted.
    T:assertEqual(h.settings.data.features.openai_codex_oauth.refresh_token, "rotated-test-refresh-1")
end)

T:test("suspend during OAuth refresh cannot submit when refresh completes", function()
    local h = harness()
    h.queue:enqueue(snapshot()); h:tick(); h.queue:suspend()
    h:resolve(1); h.queue:resume(); h:tick()
    T:assertEqual(#h.dispatches, 0)
    T:assertEqual(h.queue:get("1").state, "interrupted")
end)

T:test("cancel and retry share one refresh and only the new attempt submits", function()
    local h = harness()
    h.queue:enqueue(snapshot()); h:tick(); h.queue:cancel("1")
    h.queue:retry("1"); h:tick()
    T:assertEqual(#h.refreshes, 1)
    h:resolve(1)
    T:assertEqual(#h.dispatches, 1)
    T:assertEqual(h.queue:get("1").state, "completed")
    T:assertEqual(h.saved.jobs[1].attempts, 2)
    T:assertEqual(h.saved.jobs[1].answer, "Answer from mocked provider")
    h:resolve(1)
    T:assertEqual(#h.dispatches, 1, "duplicate refresh completion must not dispatch twice")
    T:assertEqual(h.flushes, 1)
end)

T:test("cancelling one auth subscriber leaves other subscribers waiting", function()
    local h = harness()
    local cancel_first, first_calls, second_calls = nil, 0, 0
    local pid = OAuth.resolveAccessTokenAsync(h.settings, function() first_calls = first_calls + 1 end,
        function(cancel) cancel_first = cancel end)
    local joined_pid = OAuth.resolveAccessTokenAsync(h.settings, function(auth)
        T:assertTrue(auth ~= nil)
        second_calls = second_calls + 1
    end)
    T:assertEqual(pid, joined_pid)
    T:assertEqual(#h.refreshes, 1)
    cancel_first(); h:resolve(1)
    T:assertEqual(first_calls, 0)
    T:assertEqual(second_calls, 1)
    T:assertEqual(h.flushes, 1)
end)

T:test("synchronous refresh failure completes once and clears the in-flight entry", function()
    local h = harness()
    local starts, results = 0, {}
    OAuth._setAsyncRunnerForTests(function(_request, callback)
        starts = starts + 1
        callback(nil, "mock startup failure")
        return nil
    end)
    local function done(auth, err)
        results[#results + 1] = { auth = auth, error = err }
    end
    OAuth.resolveAccessTokenAsync(h.settings, done)
    T:assertEqual(#results, 1)
    T:assertEqual(results[1].auth, nil)
    T:assertEqual(results[1].error, "mock startup failure")
    OAuth.resolveAccessTokenAsync(h.settings, done)
    T:assertEqual(starts, 2)
    T:assertEqual(#results, 2)
    T:assertEqual(results[2].error, "mock startup failure")
end)

T:test("matching token strings on different settings objects do not share refreshes", function()
    local h = harness()
    local other_settings = Queue.copy(h.settings)
    local callbacks = 0
    OAuth.resolveAccessTokenAsync(h.settings, function() callbacks = callbacks + 1 end)
    OAuth.resolveAccessTokenAsync(other_settings, function() callbacks = callbacks + 1 end)
    T:assertEqual(#h.refreshes, 2)
    h:resolve(1); h:resolve(2)
    T:assertEqual(callbacks, 2)
    T:assertEqual(h.settings.data.features.openai_codex_oauth.refresh_token, "rotated-test-refresh-1")
    T:assertEqual(other_settings.data.features.openai_codex_oauth.refresh_token, "rotated-test-refresh-2")
end)

T:test("a missing refresh token fails once without starting a subprocess", function()
    local h = harness()
    h.settings.data.features.openai_codex_oauth.refresh_token = nil
    local callbacks, callback_error = 0
    OAuth.resolveAccessTokenAsync(h.settings, function(_auth, err)
        callbacks = callbacks + 1; callback_error = err
    end)
    T:assertEqual(callbacks, 1)
    T:assertTrue(callback_error ~= nil)
    T:assertEqual(#h.refreshes, 0)
end)

T:test("completed refresh is not reused by a later expired token", function()
    local h = harness()
    local callbacks = 0
    OAuth.resolveAccessTokenAsync(h.settings, function() callbacks = callbacks + 1 end)
    h:resolve(1)
    h.settings.data.features.openai_codex_oauth.expires_at = 1
    OAuth.resolveAccessTokenAsync(h.settings, function() callbacks = callbacks + 1 end)
    T:assertEqual(#h.refreshes, 2)
    T:assertTrue(h.refreshes[2].request.body:find("rotated%-test%-refresh%-1") ~= nil)
    h:resolve(2)
    T:assertEqual(callbacks, 2)
end)

T:test("late refresh cannot restore an account disconnected while it ran", function()
    local h = harness()
    local callback_auth, callback_error
    OAuth.resolveAccessTokenAsync(h.settings, function(auth, err) callback_auth, callback_error = auth, err end)
    h.settings.data.features.openai_codex_oauth = nil
    h:resolve(1)
    T:assertEqual(callback_auth, nil)
    T:assertTrue(callback_error ~= nil)
    T:assertEqual(h.settings.data.features.openai_codex_oauth, nil)
    T:assertEqual(h.flushes, 0)
end)

T:test("frozen custom destination uses current key without rewriting settings", function()
    local h = harness()
    local job = snapshot("custom_test")
    job.config.custom_provider = {
        id = "custom_test", name = "Frozen provider", base_url = "https://frozen.example/v1",
        api_key_required = true,
    }
    h.queue:enqueue(job)
    h.settings.data.features.api_keys.custom_test = "new-test-key-never-sent"
    h:tick()
    T:assertEqual(#h.dispatches, 1)
    T:assertEqual(h.dispatches[1].config.base_url, "https://frozen.example/v1")
    T:assertEqual(h.dispatches[1].config.api_key, "new-test-key-never-sent")
    T:assertEqual(h.settings.data.features.custom_providers[1].base_url, "https://live.example/v1")
    T:assertEqual(h.flushes, 0)
    T:assertEqual(h.saved.jobs[1].config.api_key, nil)
    T:assertEqual(h.saved.jobs[1].config.oauth, nil)
end)

OAuth._setAsyncRunnerForTests(nil)
Codex.query, Custom.query = original_codex_query, original_custom_query
Base.resolveForSubprocess, Base.fetchInSubprocess, Base.writeAllToFD = original_resolve, original_fetch, original_write
for name, value in pairs(replaced) do package.loaded[name] = value end
for name in pairs(originally_missing) do if originally_missing[name] then package.loaded[name] = nil end end
return T:summary()
