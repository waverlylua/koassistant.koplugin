-- Authenticated TLS used only by the self-updater. Provider connections retain
-- their existing transport policy. LuaSec verifies chains but does not verify
-- DNS names, so both checks must complete before any HTTP request is sent.
local TLS = { CA_FILE = "data/ca-bundle.crt" }
local allowed_hosts = {
    ["api.github.com"] = true,
    ["github.com"] = true,
    ["release-assets.githubusercontent.com"] = true,
}

local function dnsNameMatches(pattern, hostname)
    if type(pattern) ~= "string" or type(hostname) ~= "string" then return false end
    pattern, hostname = pattern:lower(), hostname:lower()
    if pattern:find("[^a-z0-9.*%-]") or hostname:find("[^a-z0-9.%-]") then return false end
    if pattern == hostname then return true end
    -- A wildcard may cover exactly one leftmost label, never a whole suffix.
    local suffix = pattern:match("^%*%.([a-z0-9%-]+%.[a-z0-9.%-]+)$")
    if not suffix then return false end
    local first, rest = hostname:match("^([^.]+)%.(.+)$")
    return first ~= nil and rest == suffix
end

function TLS.verifyHostname(certificate, hostname)
    if not certificate or not allowed_hosts[hostname] then return false end
    local ok, extensions = pcall(function() return certificate:extensions() end)
    local san = ok and type(extensions) == "table" and extensions["2.5.29.17"]
    local names = type(san) == "table" and san.dNSName
    if type(names) ~= "table" then return false end
    -- Modern public certificates must identify their hosts in SAN. Deliberately
    -- do not fall back to legacy subject Common Names or IP address identities.
    for _, name in ipairs(names) do
        if dnsNameMatches(name, hostname) then return true end
    end
    return false
end

--- Connect to an updater host. A pre-resolved IPv4 address avoids macOS DNS
--- calls after fork; SNI and certificate identity still use the original host.
--- Returns a verified LuaSec socket, or nil plus a non-secret diagnostic.
function TLS.connect(resolved_ip, hostname, port, timeout)
    if not allowed_hosts[hostname] or tonumber(port) ~= 443 then
        return nil, "Unexpected update TLS destination"
    end
    timeout = timeout or 15
    local raw_sock, ssl_sock
    local ok, result = pcall(function()
        local socket, ssl = require("socket"), require("ssl")
        raw_sock = assert(socket.tcp())
        assert(raw_sock:settimeout(timeout))
        if resolved_ip then
            local ffi = require("ffi")
            require("ffi/posix_h")
            pcall(ffi.cdef, "int connect(int, const struct sockaddr *, unsigned int);")
            local addr = ffi.new("struct sockaddr_in")
            addr.sin_family = ffi.C.AF_INET
            addr.sin_port = ffi.C.htons(port)
            assert(ffi.C.inet_aton(resolved_ip, addr.sin_addr) == 1, "Invalid IPv4 address")
            local fd = ffi.C.socket(ffi.C.AF_INET, 1, 0)
            assert(fd >= 0, "Could not create update socket")
            if ffi.C.connect(fd, ffi.cast("const struct sockaddr *", addr), ffi.sizeof(addr)) ~= 0 then
                ffi.C.close(fd)
                error("Could not connect update socket")
            end
            raw_sock:setfd(fd)
        else
            assert(raw_sock:connect(hostname, port))
        end
        ssl_sock = assert(ssl.wrap(raw_sock, {
            mode = "client",
            protocol = "any",
            options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
            verify = "peer",
            cafile = TLS.CA_FILE,
        }))
        ssl_sock:sni(hostname) -- LuaSec returns no values on success
        assert(ssl_sock:settimeout(timeout))
        assert(ssl_sock:dohandshake())
        assert(ssl_sock:getpeerverification(), "Update certificate chain is untrusted")
        assert(TLS.verifyHostname(ssl_sock:getpeercertificate(), hostname), "Update certificate hostname mismatch")
        return ssl_sock
    end)
    if ok then return result end
    -- Neither exception text nor signed download URLs should reach logs/UI.
    if ssl_sock then pcall(function() ssl_sock:close() end)
    elseif raw_sock then pcall(function() raw_sock:close() end) end
    return nil, "Could not authenticate update server (certificate, hostname, or connection failed)"
end

--- A single HTTPS GET with LuaSocket's HTTP parser and a verified TLS socket.
--- Redirects are returned to the updater for explicit URL/host validation.
function TLS.request(options, timeout)
    if type(options) ~= "table" or type(options.url) ~= "string"
            or options.url:find("[%c%s]") or options.url:find("\\", 1, true)
            or options.url:find("#", 1, true) then
        return nil, "Unsafe update URL"
    end
    local hostname = options.url:match("^https://([a-z0-9.%-]+)/")
    if not allowed_hosts[hostname] or (options.method and options.method ~= "GET") then
        return nil, "Unexpected update request"
    end
    local headers = {}
    for key, value in pairs(options.headers or {}) do
        if type(key) ~= "string" or type(value) ~= "string" or key:find("[%c%s]")
                or value:find("[%c]") then return nil, "Unsafe update header" end
        local lower = key:lower()
        if lower ~= "accept" and lower ~= "user-agent" then return nil, "Unsupported update header" end
        headers[key] = value
    end
    local http = require("socket.http")
    if http.PROXY or options.proxy then return nil, "Update proxies are unsupported" end
    local function create()
        local conn = { timeout = timeout or 15 }
        function conn:settimeout() return 1 end -- retain the caller's bounded timeout
        function conn:connect(host, port)
            if host ~= hostname or tonumber(port) ~= 443 then return nil, "Unexpected update destination" end
            local err
            self.sock, err = TLS.connect(nil, hostname, 443, self.timeout)
            if not self.sock then return nil, err end
            return 1
        end
        function conn:close()
            if self.sock then return self.sock:close() end
            return 1
        end
        return setmetatable(conn, { __index = function(self, key)
            local sock = rawget(self, "sock")
            local method = sock and sock[key]
            if type(method) == "function" then
                return function(_, ...) return method(sock, ...) end
            end
        end })
    end
    -- Copy only supported fields: callers cannot replace host, scheme, port,
    -- socket factory, credentials, or the no-redirect policy through overrides.
    return http.request{
        url = options.url,
        method = "GET",
        headers = headers,
        sink = options.sink,
        create = create,
        redirect = false,
    }
end

return TLS
