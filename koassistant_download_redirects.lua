-- GitHub release downloads redirect to a signed asset URL. Resolve every hop
-- explicitly in the parent process (including DNS on macOS), never through a
-- library's unrestricted implicit redirect handler.
local GitHub = require("koassistant_constants").GITHUB
local Channel = require("koassistant_release_channel")
local Redirects = { MAX_HOPS = 5, MAX_URL_BYTES = 8192 }

function Redirects.isRedirect(code)
    return code == 301 or code == 302 or code == 303 or code == 307 or code == 308
end

function Redirects.isAllowedURL(url)
    if type(url) ~= "string" or #url > Redirects.MAX_URL_BYTES
            or url:find("[%c%s]") or url:find("\\", 1, true) or url:find("#", 1, true) then
        return false
    end
    local host, path = url:match("^https://([^/]+)(/.*)$")
    if host == "release-assets.githubusercontent.com" then
        return path:sub(1, #"/github-production-release-asset/") == "/github-production-release-asset/"
    end
    if host ~= "github.com" then return false end
    local prefix = "/" .. GitHub.REPO_OWNER .. "/" .. GitHub.REPO_NAME .. "/releases/download/"
    if path:sub(1, #prefix) ~= prefix then return false end
    local tag, filename = path:sub(#prefix + 1):match("^([^/]+)/([^/]+)$")
    return Channel.parseTag(tag) ~= nil and filename == GitHub.ASSET_NAME
end

function Redirects.nextURL(location, state)
    if not Redirects.isAllowedURL(location) then return nil, "Unsafe download redirect" end
    if state.hops >= Redirects.MAX_HOPS then return nil, "Too many download redirects" end
    if state.seen[location] then return nil, "Download redirect loop" end
    state.hops = state.hops + 1
    state.seen[location] = true
    return location
end

return Redirects
