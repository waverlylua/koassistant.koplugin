-- Offline transport regression tests exercise the shipping download function,
-- including both raw-SSL macOS and LuaSec branches. No network calls occur.
local script = debug.getinfo(1, "S").source:match("@?(.*)")
local unit_dir = script:match("(.+)/[^/]+$") or "."
local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
package.path = table.concat({ plugin_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path }, ";")
require("mock_koreader")
local TestRunner = require("test_runner"):new()
local Redirects = require("koassistant_download_redirects")
local source = "https://github.com/waverlylua/koassistant.koplugin/releases/download/waverly-v0.23.2/koassistant.koplugin.zip"
local asset = "https://release-assets.githubusercontent.com/github-production-release-asset/123/asset?token=PRIVATE"

local function runDownload(platform, responses, initial)
    local names = { "ffi", "ffi/util", "ui/uimanager", "bit", "ssl.https", "ltn12",
        "koassistant_api.base", "koassistant_update_tls", "libs/libkoreader-lfs", "koassistant_update_checker" }
    local saved = {}
    for _idx, name in ipairs(names) do saved[name] = package.loaded[name] end
    local path = os.tmpname()
    os.remove(path)
    local result = { requests = {}, dns = {}, callback_count = 0 }
    local ok, err = pcall(function()
        local pipes, next_pid, tasks, time = {}, 0, {}, 0
        local in_child, resolved_url = false, nil
        package.loaded["ui/uimanager"] = {
            scheduleIn = function(self, delay, fn)
                local task = { at = time + delay, fn = fn }
                tasks[#tasks + 1] = task
                return task
            end,
            unschedule = function(self, task) task.cancelled = true end,
        }
        package.loaded.ffi = {
            os = platform, cast = function(kind, value) return value end,
            new = function() return {} end,
            string = function(buffer) return buffer.data end,
            C = {
                O_NONBLOCK = 2048, fcntl = function() return 0 end,
                close = function() end, _exit = function() end,
                read = function(fd, buffer, count)
                    local value = pipes[fd] or ""
                    buffer.data = value:sub(1, count)
                    pipes[fd] = value:sub(count + 1)
                    return #buffer.data
                end,
            },
        }
        package.loaded["ffi/util"] = {
            template = saved["ffi/util"].template,
            runInSubProcess = function(fn)
                next_pid = next_pid + 1
                local pid = next_pid
                pipes[pid] = ""
                in_child = true
                fn(pid, pid)
                in_child = false
                return pid, pid
            end,
            writeToFD = function(fd, data) pipes[fd] = (pipes[fd] or "") .. data end,
            readAllFromFD = function(fd)
                local data = pipes[fd]
                pipes[fd] = ""
                return data
            end,
            terminateSubProcess = function() end,
            isSubProcessDone = function() return true end,
        }
        package.loaded.bit = { bor = function(a, b) return b end }
        package.loaded["libs/libkoreader-lfs"] = {
            attributes = function(filename)
                local file = io.open(filename, "rb")
                if not file then return nil end
                local size = file:seek("end")
                file:close()
                return { size = size, mode = "file" }
            end,
        }
        package.loaded.ltn12 = { sink = { file = function(file)
            return function(chunk)
                if chunk then file:write(chunk) else file:close() end
                return 1
            end
        end } }
        package.loaded["ssl.https"] = { request = function(request)
            assert(in_child, "network runs in subprocess")
            assert(request.redirect == false, "implicit redirects must be disabled")
            result.requests[#result.requests + 1] = request.url
            local response = assert(responses[request.url], "unexpected request")
            if response.throw then error(response.throw) end
            request.sink(response.body or "redirect body")
            request.sink(nil)
            if response.failed then return nil, response.code end
            return 1, response.code, { location = response.location }
        end }
        package.loaded["koassistant_api.base"] = {
            resolveForSubprocess = function(url)
                assert(not in_child, "macOS DNS must run in the parent for every hop")
                resolved_url = url
                result.dns[#result.dns + 1] = url
                return "192.0.2.1"
            end,
            connectSSLInSubprocess = function(ip, host)
                assert(in_child, "TLS connects in the subprocess")
                assert(ip == "192.0.2.1", "parent-resolved address is used")
                assert(resolved_url:match("^https://([^/]+)") == host, "SNI host follows redirect")
                result.requests[#result.requests + 1] = resolved_url
                local response = assert(responses[resolved_url], "unexpected request")
                if response.throw then error(response.throw) end
                local lines = { "HTTP/1.1 " .. tostring(response.code or 500) .. " Status" }
                if response.location then lines[#lines + 1] = "Location: " .. response.location end
                lines[#lines + 1] = ""
                local index, body_sent = 0, false
                return {
                    send = function(self, request) return #request end,
                    receive = function(self, wanted)
                        if wanted == "*l" then
                            index = index + 1
                            return lines[index]
                        end
                        if not body_sent then
                            body_sent = true
                            return nil, "closed", response.body or "redirect body"
                        end
                        return nil, "closed"
                    end,
                    close = function() end,
                }
            end,
        }
        -- TLS authentication has separate native certificate tests; transport
        -- stubs here isolate redirect orchestration on both platform branches.
        package.loaded["koassistant_update_tls"] = {
            connect = package.loaded["koassistant_api.base"].connectSSLInSubprocess,
            request = package.loaded["ssl.https"].request,
        }
        package.loaded["koassistant_update_checker"] = nil
        local updater = require("koassistant_update_checker")
        updater._downloadFile(initial or source, path, function(success, message)
            result.callback_count = result.callback_count + 1
            result.success, result.error = success, message
        end)
        local steps = 0
        while #tasks > 0 do
            steps = steps + 1
            assert(steps < 100, "scheduler did not settle")
            table.sort(tasks, function(a, b) return a.at < b.at end)
            local task = table.remove(tasks, 1)
            time = task.at
            if not task.cancelled then task.fn() end
        end
        local file = io.open(path, "rb")
        if file then result.body = file:read("*a"); file:close() end
    end)
    os.remove(path)
    for _idx, name in ipairs(names) do package.loaded[name] = saved[name] end
    if not ok then error(err) end
    return result
end

TestRunner:test("redirect policy: exact HTTPS origins and fork asset endpoints only", function()
    TestRunner:assertTrue(Redirects.isAllowedURL(source))
    TestRunner:assertTrue(Redirects.isAllowedURL(asset))
    for _idx, url in ipairs({ source:gsub("https:", "http:"), source:gsub("waverlylua", "zeeyado"),
            source:gsub("github.com", "github.com.evil.invalid"), asset:gsub("https://", "https://evil@"),
            asset:gsub(".com/", ".com:443/", 1), asset .. "\r\nHeader: value", asset .. "#fragment",
            asset:gsub("github%-production%-release%-asset/", "other/"), "/relative.zip", "//github.com/path",
            "https://release-assets.githubusercontent.com/", "https://github.com/", false, {}, 123 }) do
        TestRunner:assertFalse(Redirects.isAllowedURL(url), tostring(url))
    end
end)

for _idx, platform in ipairs({ "Linux", "OSX" }) do
    TestRunner:test(platform .. ": follows hosted redirect and writes the final ZIP once", function()
        local result = runDownload(platform, {
            [source] = { code = 302, location = asset }, [asset] = { code = 200, body = "ZIP BYTES" },
        })
        TestRunner:assertTrue(result.success, result.error)
        TestRunner:assertEqual(result.body, "ZIP BYTES")
        TestRunner:assertEqual(#result.requests, 2)
        TestRunner:assertEqual(result.callback_count, 1)
        if platform == "OSX" then
            TestRunner:assertEqual(#result.dns, 2)
            TestRunner:assertEqual(result.dns[2], asset)
        end
    end)
    TestRunner:test(platform .. ": rejects unsafe redirect before another network request", function()
        local result = runDownload(platform, { [source] = { code = 302, location = "https://evil.invalid/file.zip" } })
        TestRunner:assertFalse(result.success)
        TestRunner:assertEqual(result.error, "Unsafe download redirect")
        TestRunner:assertEqual(#result.requests, 1)
        TestRunner:assertEqual(result.body, nil)
    end)
    TestRunner:test(platform .. ": rejects redirect loop and limits the whole chain to five hops", function()
        local result = runDownload(platform, { [source] = { code = 302, location = source } })
        TestRunner:assertEqual(result.error, "Download redirect loop")
        local responses = { [source] = { code = 302, location = asset .. "1" } }
        for i = 1, 6 do responses[asset .. i] = { code = 302, location = asset .. (i + 1) } end
        result = runDownload(platform, responses)
        TestRunner:assertEqual(result.error, "Too many download redirects")
        TestRunner:assertEqual(#result.requests, 6)
        TestRunner:assertEqual(result.callback_count, 1)
    end)
    TestRunner:test(platform .. ": rejects non-200 response and missing redirect location", function()
        for _idx2, code in ipairs({ 302, 403, 404, 500 }) do
            local result = runDownload(platform, { [source] = { code = code, body = "NOT A ZIP" } })
            TestRunner:assertFalse(result.success)
            TestRunner:assertEqual(result.body, nil)
        end
    end)
    TestRunner:test(platform .. ": exceptions never expose signed URLs", function()
        local result = runDownload(platform, {
            [source] = { code = 302, location = asset }, [asset] = { throw = asset },
        })
        TestRunner:assertFalse(result.success)
        TestRunner:assertFalse(result.error:find("PRIVATE", 1, true))
    end)
end

TestRunner:test("LuaSec: nil request status cannot be accepted as a successful download", function()
    local result = runDownload("Linux", { [source] = { failed = true, body = "PARTIAL" } })
    TestRunner:assertFalse(result.success)
    TestRunner:assertEqual(result.body, nil)
end)

TestRunner:test("transport: unsafe initial URL is rejected without spawning or networking", function()
    local result = runDownload("Linux", {}, "https://evil.invalid/file.zip")
    TestRunner:assertFalse(result.success)
    TestRunner:assertEqual(#result.requests, 0)
    TestRunner:assertEqual(result.callback_count, 1)
end)

return TestRunner:summary()
