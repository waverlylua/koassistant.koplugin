-- Offline unit coverage for the updater-only authenticated TLS transport.
local script = debug.getinfo(1, "S").source:match("@?(.*)")
local unit_dir = script:match("(.+)/[^/]+$") or "."
local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
package.path = table.concat({ plugin_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path }, ";")
local TestRunner = require("test_runner"):new()
local TLS = require("koassistant_update_tls")
local saved_socket, saved_ssl, saved_http = package.loaded.socket, package.loaded.ssl, package.loaded["socket.http"]
local function cert(names)
    return { extensions = function() return { ["2.5.29.17"] = { dNSName = names } } end }
end
TestRunner:test("TLS: exact SAN names and one-label wildcard", function()
    for _, host in ipairs({ "github.com", "api.github.com", "release-assets.githubusercontent.com" }) do
        TestRunner:assertTrue(TLS.verifyHostname(cert({ host:upper() }), host))
    end
    TestRunner:assertTrue(TLS.verifyHostname(cert({ "*.github.com" }), "api.github.com"))
    TestRunner:assertTrue(TLS.verifyHostname(cert({ "*.githubusercontent.com" }), "release-assets.githubusercontent.com"))
end)
TestRunner:test("TLS: reject mismatches, NUL, malformed or broad wildcards", function()
    for _, name in ipairs({ "attacker.com", "api.github.com.attacker.com", "api.github.com\0.attacker.com",
            "*", "*.com", "*.*.com", "a*.github.com", "*github.com", "api.github.com.", "github.com" }) do
        TestRunner:assertFalse(TLS.verifyHostname(cert({ name }), "api.github.com"), name)
    end
    TestRunner:assertFalse(TLS.verifyHostname(cert({ "*.github.com" }), "github.com"))
    TestRunner:assertFalse(TLS.verifyHostname(cert({ "*.com" }), "github.com"))
    TestRunner:assertFalse(TLS.verifyHostname(cert({ "*.github.com" }), "a.api.github.com"))
end)
TestRunner:test("TLS: require supported host and DNS SAN, never Common Name", function()
    TestRunner:assertFalse(TLS.verifyHostname(cert({ "example.com" }), "example.com"))
    TestRunner:assertFalse(TLS.verifyHostname({ extensions = function() return {} end,
        subject = function() return { { name = "commonName", value = "api.github.com" } } end }, "api.github.com"))
    TestRunner:assertFalse(TLS.verifyHostname(nil, "api.github.com"))
    TestRunner:assertFalse(TLS.verifyHostname({ extensions = function() error("unsupported") end }, "api.github.com"))
end)
local state
local function transport(failure)
    state = { sent = 0, closed = 0, verified = false }
    local function close() state.closed = state.closed + 1; return 1 end
    local raw = {
        settimeout = function() return 1 end,
        connect = function() if failure == "connect" then return nil, "failed" end return 1 end,
        close = close,
    }
    local secure = {
        settimeout = function() return 1 end,
        sni = function(_, host) state.sni = host end, -- native API has no return value
        dohandshake = function() if failure == "handshake" then return nil, "untrusted" end return true end,
        getpeerverification = function() if failure == "chain" then return false end return true end,
        getpeercertificate = function() return cert({ failure == "hostname" and "attacker.com" or "api.github.com" }) end,
        send = function(_, value) state.sent = state.sent + #value; return #value end,
        close = close,
    }
    package.loaded.socket = { tcp = function() return raw end }
    package.loaded.ssl = { wrap = function(_, params)
        state.params = params
        if failure == "wrap" then return nil, "missing CA" end
        return secure
    end }
end
TestRunner:test("TLS: chain, CA bundle, SNI and mandatory checks before returning socket", function()
    transport()
    local socket = assert(TLS.connect(nil, "api.github.com", 443, 8))
    TestRunner:assertEqual(state.params.verify, "peer")
    TestRunner:assertEqual(state.params.cafile, "data/ca-bundle.crt")
    TestRunner:assertEqual(state.sni, "api.github.com")
    TestRunner:assertEqual(state.sent, 0)
    socket:close()
end)
for _, failure in ipairs({ "connect", "wrap", "handshake", "chain", "hostname" }) do
    TestRunner:test("TLS: " .. failure .. " failure closes without request bytes", function()
        transport(failure)
        local sock, err = TLS.connect(nil, "api.github.com", 443, 8)
        TestRunner:assertEqual(sock, nil)
        TestRunner:assertTrue(type(err) == "string")
        TestRunner:assertEqual(state.sent, 0)
        TestRunner:assertEqual(state.closed, 1)
    end)
end
TestRunner:test("TLS: unexpected destination rejected before connection", function()
    transport()
    TestRunner:assertEqual(TLS.connect(nil, "attacker.com", 443, 8), nil)
    TestRunner:assertEqual(TLS.connect(nil, "api.github.com", 80, 8), nil)
    TestRunner:assertEqual(state.closed, 0)
end)
TestRunner:test("TLS: HTTP uses verified custom connection and disables redirects", function()
    transport()
    package.loaded["socket.http"] = { request = function(options)
        TestRunner:assertFalse(options.redirect)
        TestRunner:assertEqual(options.host, nil)
        local conn = options.create()
        TestRunner:assertTrue(conn:settimeout(60))
        TestRunner:assertTrue(conn:connect("api.github.com", 443))
        TestRunner:assertEqual(conn:send("GET / HTTP/1.1\r\n\r\n"), 18)
        conn:close()
        return 1, 302, { location = "https://attacker.com/" }
    end }
    local ok, status = TLS.request({ url = "https://api.github.com/releases", host = "attacker.com" }, 8)
    TestRunner:assertEqual(ok, 1)
    TestRunner:assertEqual(status, 302)
end)
TestRunner:test("TLS: failed custom connection closes without recursive lookup", function()
    transport("hostname")
    package.loaded["socket.http"] = { request = function(options)
        local conn = options.create()
        local ok, err = conn:connect("api.github.com", 443)
        TestRunner:assertEqual(ok, nil)
        TestRunner:assertTrue(conn:close())
        return nil, err
    end }
    TestRunner:assertEqual(TLS.request({ url = "https://api.github.com/a" }), nil)
    TestRunner:assertEqual(state.sent, 0)
end)
TestRunner:test("TLS: reject insecure URLs, userinfo, ports, proxies, and header overrides", function()
    local touched = false
    package.loaded["socket.http"] = { request = function() touched = true end }
    for _, url in ipairs({ "http://api.github.com/a", "https://attacker.com/a", "https://api.github.com:80/a",
            "https://api.github.com@attacker.com/a", "https://api.github.com/a\r\nInjected: true",
            "https://api.github.com/a#fragment", "https://api.github.com\\attacker.com/a" }) do
        TestRunner:assertEqual(TLS.request({ url = url }), nil)
    end
    for _, headers in ipairs({ { Host = "attacker.com" }, { Authorization = "secret" }, { ["User-Agent"] = "x\r\nInjected: true" } }) do
        TestRunner:assertEqual(TLS.request({ url = "https://api.github.com/a", headers = headers }), nil)
    end
    TestRunner:assertEqual(TLS.request({ url = "https://api.github.com/a", proxy = "http://example.com" }), nil)
    TestRunner:assertFalse(touched)
end)
package.loaded.socket, package.loaded.ssl, package.loaded["socket.http"] = saved_socket, saved_ssl, saved_http
return TestRunner:summary()
