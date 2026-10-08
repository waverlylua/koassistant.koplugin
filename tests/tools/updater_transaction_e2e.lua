-- Run via updater_transaction_e2e.sh. Each case gets a new Lua process and a
-- disposable install. Invoke the actual popup callbacks / performUpdate via
-- debug upvalues, not a copied implementation. UI/settings/network/download are
-- stubbed. Archive, checksum, copy/move, preservation and rollback stay real;
-- a few cases wrap exactly one filesystem operation to inject a failure.
local work, case_name, version = arg[1], arg[2], arg[3]
assert(work and case_name and version, "usage: updater_transaction_e2e.lua <work> <case> <version>")
local root = work .. "/" .. case_name
local plugins = root .. "/plugins"
local plugin = plugins .. "/koassistant.koplugin"
local staging = plugins .. "/koassistant.koplugin_staging"
local preserve = plugins .. "/koassistant.koplugin_userfiles"
local backup_base = plugins .. "/koassistant.koplugin.backup"

require("setupkoenv")
local lfs = require("libs/libkoreader-lfs")
local ffiutil = require("ffi/util")
local sha = require("ffi/sha2")
local real_execute, real_copy = ffiutil.execute, ffiutil.copyFile

local function read(path)
    local f = assert(io.open(path, "rb"), path)
    local bytes = f:read("*a")
    f:close()
    return bytes
end
local function write(path, bytes)
    local f = assert(io.open(path, "wb"), path)
    assert(f:write(bytes))
    assert(f:close())
end
local function mkdir(path)
    assert(lfs.mkdir(path) or lfs.attributes(path, "mode") == "directory", path)
end
local function snapshot(path, rel, out)
    rel, out = rel or "", out or {}
    local mode = lfs.attributes(path, "mode")
    assert(mode, "Missing snapshot path: " .. path)
    out[rel] = mode == "file" and ("file:" .. read(path)) or mode
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                snapshot(path .. "/" .. entry, rel == "" and entry or rel .. "/" .. entry, out)
            end
        end
    end
    return out
end
local function equal_tree(expected, path, label)
    local actual = snapshot(path)
    for key, bytes in pairs(expected) do
        assert(actual[key] == bytes, (label or path) .. " differs: " .. key)
    end
    for key in pairs(actual) do
        assert(expected[key] ~= nil, (label or path) .. " has unexpected entry: " .. key)
    end
end
local function upvalue(fn, name)
    for index = 1, 100 do
        local found, value = debug.getupvalue(fn, index)
        if not found then break end
        if found == name then return value, index end
    end
    error("Missing upvalue: " .. name)
end
local function replace(fn, name, value)
    local _, index = upvalue(fn, name)
    debug.setupvalue(fn, index, value)
end

local messages, visible, closed, restarts = {}, {}, {}, {}
local online = case_name ~= "offline"
local function widget(kind)
    return { new = function(_self, o)
        o = type(o) == "table" and o or { name = o }; o._kind = kind; return o
    end }
end
local UIManager = {
    show = function(_self, w)
        visible[#visible + 1] = w
        if w.text then
            messages[#messages + 1] = w.text
            io.write("MSG ", tostring(w._kind), ": ", w.text:gsub("\n", " | "), "\n")
        end
    end,
    close = function(_self, w) closed[w] = true end,
    forceRePaint = function() end,
    setDirty = function() end,
    broadcastEvent = function() end,
    scheduleIn = function(_self, _delay, fn) fn() end,
    nextTick = function(_self, fn) fn() end,
    unschedule = function() end,
    askForRestart = function(_self, msg) restarts[#restarts + 1] = msg end,
}
local settings = { readSetting = function() end, saveSetting = function() end,
    flush = function() end, isTrue = function() return false end, has = function() return false end }
local stubs = {
    ["ui/uimanager"] = UIManager,
    ["ui/widget/infomessage"] = widget("info"),
    ["ui/widget/confirmbox"] = widget("confirm"),
    ["ui/widget/buttondialog"] = widget("buttons"),
    ["ui/widget/notification"] = widget("notification"),
    ["ui/event"] = widget("event"),
    ["ui/network/manager"] = { isOnline = function() return online end,
        runWhenOnline = function(_self, fn) fn() end, runWhenConnected = function(_self, fn) fn() end },
    ["device"] = { isAndroid = function() return false end, canOpenLink = function() return false end,
        screen = { getWidth = function() return 600 end, getHeight = function() return 800 end,
            scaleBySize = function(_self, n) return n end } },
    ["datastorage"] = { getSettingsDir = function() return root .. "/settings" end,
        getDataDir = function() return root .. "/data" end, getFullDataDir = function() return root .. "/data" end },
    ["luasettings"] = { open = function() return settings end },
}
for name, mod in pairs(stubs) do package.preload[name] = function() return mod end end
table.insert(package.loaders, 2, function(name)
    if name:match("^ui/") or name:match("^apps/") or name == "ffi/blitbuffer" then
        return function() return setmetatable({}, { __index = function() return widget(name) end }) end
    end
end)
_G.G_reader_settings = settings
package.path = plugin .. "/?.lua;" .. package.path

local Registry = require("koassistant_storage_registry")
local user_files, user_dirs = Registry.updateFiles(), Registry.updateDirs()
for _, filename in ipairs(user_files) do
    write(plugin .. "/" .. filename, "-- user-owned " .. filename .. "\nreturn { fixture = 'reader customization' }\n")
end
for _, dirname in ipairs(user_dirs) do
    mkdir(plugin .. "/" .. dirname)
    mkdir(plugin .. "/" .. dirname .. "/nested")
    write(plugin .. "/" .. dirname .. "/reader.md", "Reader content: café / 中文\n")
    write(plugin .. "/" .. dirname .. "/nested/empty.txt", "")
    write(plugin .. "/" .. dirname .. "/nested/binary.bin", "\0\255\1reader\0bytes\n")
end
write(plugin .. "/transaction_obsolete.lua", "return 'old release only'\n")
write(root .. "/settings/koassistant_settings.lua", "return { features = { fixture = true }, api_keys = { fixture = 'fake-test-key' } }\n")
write(root .. "/settings/settings.reader.lua", "return { fixture = 'global reader preferences' }\n")
mkdir(root .. "/data/ai-inbox")
mkdir(root .. "/data/ai-inbox/jobs")
write(root .. "/data/ai-inbox/index.lua", "return { version = 1, fixture = 'durable inbox' }\n")
write(root .. "/data/ai-inbox/jobs/1.json", '{"answer":"saved answer","fixture":true}\n')
write(root .. "/data/ai-inbox/jobs/1.bin", "\0saved question attachment\255")
if case_name == "linked_domains" then
    mkdir(root .. "/elsewhere")
    assert(real_execute("/bin/mv", plugin .. "/domains", root .. "/elsewhere/domains") == 0)
    assert(lfs.link(root .. "/elsewhere/domains", plugin .. "/domains", true))
end
if case_name == "git_worktree" then write(plugin .. "/.git", "gitdir: /unrelated/worktrees/plugin\n") end

local before = snapshot(plugin)
local external_settings, external_data = snapshot(root .. "/settings"), snapshot(root .. "/data")
local expected = snapshot(work .. "/release")
for _, list in ipairs({ user_files, user_dirs }) do
    for _, name in ipairs(list) do
        for path, bytes in pairs(before) do
            if path == name or path:sub(1, #name + 1) == name .. "/" then expected[path] = bytes end
        end
    end
end

local existing_backups = {}
if case_name == "backup_collisions" or case_name == "backup_full" then
    local count = case_name == "backup_full" and 1000 or 12
    for index = 1, count do
        local path = backup_base .. (index == 1 and "" or "_" .. index)
        if index % 2 == 0 then
            write(path, "Previous recovery copy " .. index .. "\n")
        else
            mkdir(path); write(path .. "/sentinel.txt", "Previous recovery copy " .. index .. "\n")
        end
        existing_backups[path] = snapshot(path)
    end
end

local UC = assert(loadfile(plugin .. "/koassistant_update_checker.lua"))()
local show_popup = upvalue(UC.showPendingUpdate, "showUpdatePopup")
local perform_update = upvalue(show_popup, "performUpdate")
-- Replace only the view renderer. The real popup still builds its buttons and
-- callbacks, including Later and Update Now; actual loadUI still runs.
upvalue(perform_update, "loadUI")()
replace(show_popup, "MarkdownViewer", widget("release-notes"))
replace(show_popup, "ensureMarkdownViewer", function() end)

local Runtime = require("koassistant_question_runtime")
local Queue = require("koassistant_question_queue")
local scheduled, starts, saves = {}, 0, 0
local queue = Queue:new{
    load = function() end,
    save = function() saves = saves + 1; return true end,
    now = function() return 1 end,
    schedule = function(fn) scheduled[#scheduled + 1] = fn end,
    start = function() starts = starts + 1 end,
}
replace(Runtime.get, "queue", queue)
assert(not Runtime.isBusy(), "Idle queue is busy")
local function job(state)
    return { id = "1", state = state, attempts = 0, document = {}, config = {}, messages = {} }
end
if case_name == "queued_guard" or case_name == "running_guard" then
    queue.jobs = { job(case_name == "queued_guard" and "queued" or "running") }
    assert(Runtime.isBusy(), "Queued/running work is not busy")
elseif case_name == "streaming_guard" then
    _G.KOAssistantStreaming = true
end

local archive_cases = { wrong_root = true, traversal = true, symlink = true, duplicate = true,
    missing_module = true, metadata_execution = true, garbage = true }
local zip = work .. "/" .. (archive_cases[case_name] and case_name or "good") .. ".zip"
local zip_bytes = read(zip)
local info = { zip_url = "https://fixture.invalid/update.zip", latest_version = version,
    current_version = "fixture-installed", release_notes = "Transaction integration fixture",
    download_url = "https://fixture.invalid/release", zip_size = #zip_bytes,
    zip_sha256 = sha.sha256(zip_bytes) }
if case_name == "bad_size" then info.zip_size = #zip_bytes + 1 end
if case_name == "bad_digest" then info.zip_sha256 = string.rep("0", 64) end
if case_name == "wrong_version" then info.latest_version = "999.0.0" end
if case_name == "no_url" then info.zip_url = nil end

local downloads, finish_download = 0, nil
local defer = case_name == "repeated_update" or case_name == "active_during_download"
    or case_name == "queue_pending_lock"
replace(perform_update, "downloadFile", function(_url, dest, callback)
    downloads = downloads + 1
    assert(_G.KOAssistantUpdatePending, "Update lock was not set before download")
    write(dest, zip_bytes)
    finish_download = callback
    if not defer then callback(case_name ~= "download_failure", "Injected download failure") end
end)

local injected = 0
ffiutil.copyFile = function(src, dst, ...)
    if src == plugin .. "/apikeys.lua" and dst == preserve .. "/apikeys.lua"
            and (case_name == "preserve_missing" or case_name == "preserve_same_size") then
        injected = injected + 1
        if case_name == "preserve_same_size" then write(dst, string.rep("X", #read(src))) end
        return nil -- a lying successful copy / full-disk-style failure
    end
    return real_copy(src, dst, ...)
end
ffiutil.execute = function(bin, src, dst, ...)
    if bin:match("/mv$") then
        if (case_name == "move_old_failure" and src == plugin)
                or ((case_name == "move_new_failure" or case_name == "rollback_failure") and src == staging)
                or (case_name == "rollback_failure" and src:sub(1, #backup_base) == backup_base and dst == plugin) then
            injected = injected + 1
            return 1
        end
        if case_name == "restore_same_size" and src == preserve .. "/apikeys.lua" then
            assert(dst == staging .. "/apikeys.lua", "User data restoration happened after swapping live code")
            local ret = real_execute(bin, src, dst, ...)
            if ret == 0 then write(dst, string.rep("Y", #read(dst))); injected = injected + 1 end
            return ret
        end
        -- The live install must still contain all original bytes when the final
        -- pre-swap check passes, and staging must already contain user files.
        if src == plugin then
            equal_tree(before, plugin, "live plugin before swap")
            for _, filename in ipairs(user_files) do
                assert(read(staging .. "/" .. filename) == read(plugin .. "/" .. filename),
                    "User file missing before atomic swap: " .. filename)
            end
        end
    end
    return real_execute(bin, src, dst, ...)
end

local function button(popup, text)
    for _, row in ipairs(popup.buttons_table) do
        for _, item in ipairs(row) do if item.text == text then return item.callback end end
    end
    error("Popup button missing: " .. text)
end
local function open_popup()
    show_popup(info)
    return visible[#visible]
end
local function contains_message(needle)
    for _, text in ipairs(messages) do if text:find(needle, 1, true) then return true end end
    return false
end
local function external_unchanged()
    equal_tree(external_settings, root .. "/settings", "settings outside plugin")
    equal_tree(external_data, root .. "/data", "ai-inbox outside plugin")
    for path, bytes in pairs(existing_backups) do equal_tree(bytes, path, "existing backup") end
end
local function no_temps()
    for _, path in ipairs({ staging, preserve, plugins .. "/koassistant.koplugin_update.zip" }) do
        assert(not lfs.symlinkattributes(path), "Temporary update entry remains: " .. path)
    end
end
local function no_extra_siblings()
    for entry in lfs.dir(plugins) do
        local path = plugins .. "/" .. entry
        assert(entry == "." or entry == ".." or entry == "koassistant.koplugin"
            or existing_backups[path] or entry:match("^koassistant%.koplugin%.backup"),
            "Unexpected file beside installed plugin: " .. entry)
    end
end

if case_name == "later_dismissal" then
    local popup = open_popup()
    button(popup, "Later")()
    assert(closed[popup], "Later did not close the popup")
    assert(downloads == 0 and not _G.KOAssistantUpdatePending, "Later started or locked an update")
    equal_tree(before, plugin, "Later dismissed install")
elseif case_name == "repeated_update" then
    local popup = open_popup()
    local update_now = button(popup, "Update Now")
    update_now(); update_now()
    assert(downloads == 1 and _G.KOAssistantUpdatePending, "Repeated Update Now started a second download")
    equal_tree(before, plugin, "install while download pending")
    finish_download(false, "Injected asynchronous download failure")
    assert(not _G.KOAssistantUpdatePending and #restarts == 0, "Download error retained lock or asked for restart")
    equal_tree(before, plugin, "install after download failure")
    no_temps()
    update_now()
    assert(downloads == 2 and _G.KOAssistantUpdatePending, "Retry was not allowed after download error")
    finish_download(true)
    assert(#restarts == 1 and _G.KOAssistantUpdatePending, "Retry did not install and retain restart lock")
    update_now()
    assert(downloads == 2 and #restarts == 1, "Repeated update after install was not blocked")
elseif case_name == "active_during_download" then
    perform_update(info)
    assert(downloads == 1)
    _G.KOAssistantStreaming = true
    finish_download(true)
elseif case_name == "queue_pending_lock" then
    perform_update(info)
    assert(_G.KOAssistantUpdatePending)
    local fresh, enqueue_err = queue:enqueue(job("queued"))
    assert(not fresh and enqueue_err and #queue.jobs == 0 and saves == 0,
        "enqueue wrote or scheduled work during update")
    queue.jobs = { job("failed") }
    local retried, retry_err = queue:retry("1")
    assert(not retried and retry_err and queue.jobs[1].state == "failed" and saves == 0,
        "retry changed work during update")
    queue.jobs[1].state = "queued"
    queue:_pump()
    assert(starts == 0 and saves == 0 and queue.jobs[1].state == "queued", "pump started work during update")
    queue.jobs = {}
    finish_download(false, "Injected download failure")
    assert(not _G.KOAssistantUpdatePending)
    assert(queue:enqueue(job("queued")), "enqueue remained blocked after failed update")
    assert(#scheduled == 1 and saves == 1)
    scheduled[1]()
    assert(starts == 1 and queue.jobs[1].state == "running", "queue did not recover after failed update")
else
    perform_update(info)
end

local succeeds = case_name == "success" or case_name == "linked_domains"
    or case_name == "backup_collisions" or case_name == "repeated_update" or case_name == "metadata_execution"
local guards = { queued_guard = true, running_guard = true, streaming_guard = true,
    git_worktree = true, offline = true, no_url = true, later_dismissal = true }
local failure_reason = {
    backup_full = "Too many previous update backups",
    download_failure = "Injected download failure",
    active_during_download = "AI questions became active during download",
    queue_pending_lock = "Injected download failure",
    bad_size = "incomplete",
    bad_digest = "damaged",
    garbage = "Failed to extract update archive",
    wrong_version = "Version mismatch",
    wrong_root = "Failed to extract update archive",
    traversal = "Failed to extract update archive",
    symlink = "Failed to extract update archive",
    duplicate = "Failed to extract update archive",
    missing_module = "Required plugin file missing: koassistant_release_channel.lua",
    preserve_missing = "Could not save a copy of your file apikeys.lua",
    preserve_same_size = "Could not save a copy of your file apikeys.lua",
    restore_same_size = "User file was not preserved: apikeys.lua",
    move_old_failure = "Failed to move current plugin to backup",
    move_new_failure = "Previous version restored",
    rollback_failure = "failed to restore previous version",
}
local guard_reason = {
    queued_guard = "finish or cancel queued and running AI questions",
    running_guard = "finish or cancel queued and running AI questions",
    streaming_guard = "finish or cancel queued and running AI questions",
    git_worktree = "disabled for git-based installs",
    offline = "No network connection",
    no_url = "No download URL available",
}
if succeeds then
    assert(#restarts == 1, "Expected exactly one restart prompt")
    assert(restarts[1]:find(version, 1, true), "Restart prompt omitted installed version")
    assert(_G.KOAssistantUpdatePending, "Successful update did not hold lock until restart")
    if case_name == "metadata_execution" then
        assert(not _G.KOA_TEST_UNTRUSTED_META_EXECUTED, "Downloaded metadata was executed during validation")
        expected["_meta.lua"] = "file:_G.KOA_TEST_UNTRUSTED_META_EXECUTED = true\n" .. read(work .. "/release/_meta.lua")
    end
    equal_tree(expected, plugin, "new plugin with user files")
    local retained = 0
    for entry in lfs.dir(plugins) do
        local path = plugins .. "/" .. entry
        if entry:match("^koassistant%.koplugin%.backup") and not existing_backups[path] then
            retained = retained + 1
            equal_tree(before, path, "retained complete old plugin")
            assert(restarts[1]:find(path, 1, true), "Restart prompt omitted retained backup path")
        end
    end
    assert(retained == 1, "Expected exactly one new retained backup, got " .. retained)
    local previous_downloads = downloads
    perform_update(info)
    assert(downloads == previous_downloads, "Second install started before restart")
    local added, err = queue:enqueue(job("queued"))
    assert(not added and err and starts == 0 and saves == 0,
        "Queue accepted a new question after successful update while restart was deferred")
elseif guards[case_name] then
    assert(downloads == 0 and #restarts == 0 and not _G.KOAssistantUpdatePending, "Guard allowed update side effects")
    equal_tree(before, plugin, "guarded install")
    if guard_reason[case_name] then
        assert(contains_message(guard_reason[case_name]), "Guard did not explain the specific refusal")
    end
else
    assert(#restarts == 0 and not _G.KOAssistantUpdatePending, "Failed update asked for restart or retained lock")
    assert(contains_message("Update failed:"), "Failure was not reported")
    assert(failure_reason[case_name] and contains_message(failure_reason[case_name]),
        "Failure did not report the expected cause: " .. tostring(failure_reason[case_name]))
    if case_name == "rollback_failure" then
        assert(not lfs.attributes(plugin), "Failed rollback unexpectedly restored live plugin")
        equal_tree(before, backup_base, "recoverable old plugin after failed rollback")
        assert(contains_message(backup_base), "Failed rollback omitted recovery path")
    else
        equal_tree(before, plugin, "old plugin after failure")
    end
end
if case_name:match("^preserve_") or case_name == "restore_same_size" or case_name:match("^move_")
        or case_name == "rollback_failure" then
    assert(injected > 0, "Requested filesystem fault was never reached")
end
if case_name == "linked_domains" then
    assert(read(root .. "/elsewhere/domains/reader.md") == "Reader content: café / 中文\n", "Symlink target lost user data")
end
assert(not lfs.attributes(plugins .. "/escaped.txt"), "Archive traversal escaped staging")
assert(not _G.KOA_TEST_UNTRUSTED_META_EXECUTED, "Untrusted metadata ran")
external_unchanged()
no_temps()
no_extra_siblings()
io.write("PASS ", case_name, " (plugin/settings/inbox bytes and transaction state checked)\n")
