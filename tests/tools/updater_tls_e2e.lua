-- Native LuaSec loopback exercise. The test reroutes only TCP connect to a
-- temporary loopback listener; TLS still validates the original GitHub name.
require("setupkoenv")
local root, ca_file, hostname, port, expected, mode = unpack(arg)
package.path = root .. "/?.lua;" .. package.path
local socket = require("socket")
local original_tcp = socket.tcp
socket.tcp = function()
    local raw = assert(original_tcp())
    return setmetatable({
        connect = function() return raw:connect("127.0.0.1", tonumber(port)) end,
    }, { __index = function(_, key)
        return function(_, ...) return raw[key](raw, ...) end
    end })
end
local TLS = require("koassistant_update_tls")
TLS.CA_FILE = ca_file
local success, err
if mode == "raw" or mode == "resolved" then
    local sock
    sock, err = TLS.connect(mode == "resolved" and "127.0.0.1" or nil, hostname, 443, 3)
    success = sock ~= nil
    if sock then
        assert(sock:send("GET / HTTP/1.1\r\nHost: " .. hostname .. "\r\nConnection: close\r\n\r\n"))
        assert(sock:receive("*l"):find("200", 1, true))
        sock:close()
    end
else
    local body = {}
    local result, code = TLS.request({
        url = "https://" .. hostname .. "/fixture",
        headers = { ["User-Agent"] = "KOAssistant TLS test" },
        sink = require("ltn12").sink.table(body),
    }, 3)
    success, err = result ~= nil, code
    if success then
        assert(code == 200, tostring(code))
        assert(table.concat(body) == "verified", "wrong body")
    end
end
assert(success == (expected == "success"), tostring(err))
print("PASS " .. mode .. " " .. hostname .. " " .. expected)
