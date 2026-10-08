-- Exercise the real non-streaming poll/cleanup code with fault-injected syscalls.
-- No subprocess, network request, credential, or actual descriptor is used.
local script = debug.getinfo(1, "S").source:sub(2)
local root = script:match("^(.*)/tests/unit/") or "."
package.path = root .. "/?.lua;" .. root .. "/tests/lib/?.lua;" .. package.path
require("mock_koreader")
local T = require("test_runner"):new()
-- Keep provider/dependency caches bound to the ordinary mocks even if this test
-- is loaded first in a shared Lua state.
require("koassistant_gpt_query")

-- Tests share one Lua state in run_tests.lua; restore every replaced module.
local keys = { "ffi", "ffi/util", "ui/uimanager", "ui/widget/infomessage",
    "koassistant_gpt_query", "bit" }
local saved = {}
for _, key in ipairs(keys) do saved[key] = package.loaded[key] end
local h

package.loaded["ffi"] = {
    os = "Linux",
    new = function() return {} end,
    cast = function(_, value) return value end,
    string = function(value, count) return count and h.held:sub(1, count) or value end,
    errno = function() return h.errno or 11 end,
    C = {
        O_NONBLOCK = 2048,
        fcntl = function(fd, command, flags)
            T:assertEqual(fd, 7)
            h.fcntls[#h.fcntls + 1] = { command = command, flags = flags }
            if command == 3 then return h.get_result or 0 end
            return h.set_result or 0
        end,
        close = function(fd)
            T:assertEqual(fd, 7)
            h.closes = h.closes + 1
            return 0
        end,
        read = function(fd)
            T:assertEqual(fd, 7)
            h.reads = h.reads + 1
            local item = table.remove(h.input, 1)
            if type(item) == "string" then h.held = item; return #item end
            if type(item) == "table" then h.errno = item.errno; return -1 end
            return item or 0
        end,
        strerror = function() return "injected error" end,
    },
}
package.loaded["ffi/util"] = setmetatable({
    runInSubProcess = function()
        h.starts = h.starts + 1
        if h.fork_failed then return false, "injected fork failure" end
        return 1234, 7
    end,
    terminateSubProcess = function(pid)
        T:assertEqual(pid, 1234)
        h.kills = h.kills + 1
    end,
    isSubProcessDone = function(pid, wait)
        T:assertEqual(pid, 1234)
        T:assertTrue(not wait, "child collection must not wait")
        h.reaps = h.reaps + 1
        return h.done == true
    end,
    getNonBlockingReadSize = function() error("cleanup must not inspect a released pipe") end,
    readAllFromFD = function() error("cleanup must never drain a pipe") end,
}, { __index = saved["ffi/util"] })
package.loaded["bit"] = { bor = function(a, b) return a + b end }
package.loaded["ui/widget/infomessage"] = {}
package.loaded["ui/uimanager"] = {
    -- Match the native API: no scheduling handle is returned.
    scheduleIn = function(_, seconds, callback)
        h.tasks[#h.tasks + 1] = { seconds = seconds, callback = callback }
    end,
    unschedule = function(_, callback)
        h.unscheduled[#h.unscheduled + 1] = callback
        for i = #h.tasks, 1, -1 do
            if h.tasks[i].callback == callback then table.remove(h.tasks, i) end
        end
    end,
}
package.loaded["koassistant_gpt_query"] = nil
local Query = require("koassistant_gpt_query")
-- Use the actual private implementation without adding a public test-only API.
local run_background
for i = 1, 100 do
    local name, value = debug.getupvalue(Query.query, i)
    if not name then break end
    if name == "handleNonStreamingBackground" then run_background = value; break end
end
assert(run_background, "non-streaming query implementation not found")

local function start(options)
    h = { tasks = {}, fcntls = {}, unscheduled = {}, input = {}, results = {},
        reads = 0, closes = 0, starts = 0, kills = 0, reaps = 0 }
    for key, value in pairs(options or {}) do h[key] = value end
    function h:tick()
        local task = table.remove(self.tasks, 1)
        assert(task, "no scheduled task")
        task.callback()
        return task
    end
    run_background(function() error("no actual child may run") end, "test",
        function(ok, content, err)
            h.results[#h.results + 1] = { ok = ok, content = content, error = err,
                closes_at_callback = h.closes }
        end,
        function(parsed) return true, parsed.answer end,
        { features = { _suppress_loading_dialog = true, loading_message = "Test" },
            _register_cancel = function(cancel)
                h.cancel = cancel
                if h.cancel_immediately then cancel() end
            end,
        }, "test-model")
    return h
end

T:test("F_GETFL failure never reaches a UI-loop read", function()
    local p = start{ get_result = -1 }
    T:assertEqual(#p.fcntls, 1)
    T:assertEqual(p.reads, 0)
    T:assertEqual(p.kills, 1)
    T:assertEqual(p.closes, 1)
    T:assertEqual(#p.results, 1)
    T:assertFalse(p.results[1].ok)
    T:assertEqual(p.results[1].closes_at_callback, 1)
    p.done = true; p:tick()
    T:assertEqual(p.reads, 0)
    T:assertEqual(#p.tasks, 0)
end)

T:test("F_SETFL failure closes and terminates without polling", function()
    local p = start{ set_result = -1 }
    T:assertEqual(#p.fcntls, 2)
    T:assertEqual(p.fcntls[2].flags, 2048)
    T:assertEqual(p.reads, 0)
    T:assertEqual(p.kills, 1)
    T:assertEqual(p.closes, 1)
    T:assertFalse(p.results[1].ok)
    p.done = true; p:tick()
    T:assertEqual(p.reads, 0)
end)

T:test("EOF delivers answer and closes before a delayed child exits", function()
    local p = start{ input = { '{"answer":"ready"}', 0 } }
    p:tick()
    T:assertEqual(p.results[1].content, "ready")
    T:assertTrue(p.results[1].ok)
    T:assertEqual(p.results[1].closes_at_callback, 1)
    T:assertEqual(p.reaps, 0, "answer completion must not wait for waitpid")
    p:tick(); p:tick() -- Child remains alive; collection only reschedules.
    T:assertEqual(p.reads, 2)
    T:assertEqual(p.closes, 1)
    p.done = true; p:tick()
    T:assertEqual(#p.tasks, 0)
    T:assertEqual(p.closes, 1)
    p.cancel()
    T:assertEqual(#p.results, 1)
    T:assertEqual(p.kills, 0)
end)

T:test("cancel unschedules the callback and closes exactly once", function()
    local p = start()
    local stale_poll = p.tasks[1].callback
    p.cancel(); p.cancel()
    T:assertEqual(p.unscheduled[1], stale_poll)
    T:assertEqual(#p.tasks, 1, "only the child reaper remains")
    T:assertEqual(p.tasks[1].seconds, 1)
    T:assertEqual(p.kills, 1)
    T:assertEqual(p.closes, 1)
    T:assertEqual(#p.results, 1)
    stale_poll()
    T:assertEqual(p.reads, 0, "stale callbacks must not touch a closed/reused FD")
    p:tick(); p.done = true; p:tick()
    T:assertEqual(p.closes, 1)
    T:assertEqual(#p.tasks, 0)
end)

T:test("cancel after EAGAIN unschedules the same poll function", function()
    local p = start{ input = { { errno = 11 } } }
    local callback = p.tasks[1].callback
    p:tick()
    T:assertEqual(p.tasks[1].callback, callback)
    p.cancel()
    T:assertEqual(p.unscheduled[1], callback)
    T:assertEqual(#p.tasks, 1)
    T:assertEqual(p.tasks[1].seconds, 1)
    T:assertEqual(p.closes, 1)
end)

T:test("a real read error fails once and cleanup never reads again", function()
    local p = start{ input = { { errno = 5 } } }
    p:tick()
    T:assertFalse(p.results[1].ok)
    T:assertEqual(p.closes, 1)
    p.done = true; p:tick()
    T:assertEqual(p.reads, 1)
    T:assertEqual(#p.results, 1)
end)

T:test("a drained finished child still completes without EOF", function()
    local p = start{ input = { '{"answer":"ready"}', { errno = 11 } }, done = true }
    p:tick()
    T:assertTrue(p.results[1].ok)
    T:assertEqual(p.results[1].content, "ready")
    T:assertEqual(p.closes, 1)
    p:tick()
    T:assertEqual(#p.tasks, 0)
end)

T:test("interrupted read retries without losing the response", function()
    local p = start{ input = { { errno = 4 }, '{"answer":"ready"}', 0 } }
    p:tick()
    T:assertTrue(p.results[1].ok)
    T:assertEqual(p.results[1].content, "ready")
    T:assertEqual(p.reads, 3)
    T:assertEqual(p.closes, 1)
end)

T:test("synchronous cancellation during registration never forks", function()
    local p = start{ cancel_immediately = true }
    T:assertEqual(p.starts, 0)
    T:assertEqual(#p.fcntls, 0)
    T:assertEqual(p.reads, 0)
    T:assertEqual(p.closes, 0)
    T:assertEqual(#p.tasks, 0)
    T:assertEqual(#p.results, 1)
    T:assertFalse(p.results[1].ok)
end)

T:test("fork failure never treats its error string as a descriptor", function()
    local p = start{ fork_failed = true }
    T:assertEqual(p.starts, 1)
    T:assertEqual(#p.fcntls, 0)
    T:assertEqual(p.reads, 0)
    T:assertEqual(p.closes, 0)
    T:assertEqual(p.kills, 0)
    T:assertEqual(#p.tasks, 0)
    T:assertEqual(#p.results, 1)
    T:assertFalse(p.results[1].ok)
end)

for _, key in ipairs(keys) do package.loaded[key] = saved[key] end
return T:summary()
