-- Pure validation/selection for the experimental waverlylua update channel.
-- Never infer installable content from the first ZIP or the GitHub list order.
-- Tag namespace and exact asset URLs prevent inherited upstream releases, source
-- archives, and unrelated assets from replacing the installed fork.
local GitHub = require("koassistant_constants").GITHUB

local ReleaseChannel = {}

local function isArray(value)
    if type(value) ~= "table" then return false end
    local mt = getmetatable(value)
    if type(mt) == "table" and mt.__jsontype == "object" then return false end
    local count, last = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
        if key > last then last = key end
    end
    return count == last
end

local function canonicalNumber(value)
    -- The updater's numeric comparison runs on LuaJIT doubles: values must be
    -- represented exactly, and SemVer numeric identifiers cannot have zero pads.
    return value:match("^[0-9]+$") ~= nil
        and (#value == 1 or value:sub(1, 1) ~= "0")
        and #value <= 16 and tonumber(value) <= 9007199254740991
end

local function singleArrayRoot(body)
    if type(body) ~= "string" or not body:match("^%s*%[") then return false end
    -- LuaJSON's strict mode still accepts multiple root values. Locate the end
    -- of this root without treating brackets inside JSON strings as structure.
    local depth, quoted, escaped = 0, false, false
    for i = 1, #body do
        local char = body:sub(i, i)
        if quoted then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == '"' then
                quoted = false
            end
        elseif char == '"' then
            quoted = true
        elseif char == "[" or char == "{" then
            depth = depth + 1
        elseif char == "]" or char == "}" then
            depth = depth - 1
            if depth == 0 then return body:sub(i + 1):find("%S") == nil end
        end
    end
    return false
end

--- Fork tags use waverly-vX.Y.Z, optionally followed by a SemVer prerelease.
--- Build metadata is deliberately unsupported: it cannot advance precedence.
--- @return string|nil normalized installed version; boolean prerelease
function ReleaseChannel.parseTag(tag)
    if type(tag) ~= "string" or #tag > 200
            or tag:sub(1, #GitHub.TAG_PREFIX) ~= GitHub.TAG_PREFIX then
        return nil
    end
    local version = tag:sub(#GitHub.TAG_PREFIX + 1)
    local major, minor, patch, suffix = version:match("^([0-9]+)%.([0-9]+)%.([0-9]+)(.*)$")
    if not major or not canonicalNumber(major) or not canonicalNumber(minor)
            or not canonicalNumber(patch) then
        return nil
    end
    if suffix == "" then return version, false end
    if suffix:sub(1, 1) ~= "-" then return nil end
    local pre = suffix:sub(2)
    if pre == "" or pre:find("[^0-9A-Za-z%.%-]") or pre:find("..", 1, true)
            or pre:sub(1, 1) == "." or pre:sub(-1) == "." then
        return nil
    end
    for id in pre:gmatch("[^%.]+") do
        if id:match("^[0-9]+$") and not canonicalNumber(id) then return nil end
    end
    return version, true
end

--- Decode a GitHub release-list response, including non-throwing JSON decoders.
--- Checking the raw root also distinguishes [] from {} on decoders that erase
--- that distinction. Error objects/null/scalars never count as successful checks.
--- @return table|nil releases; string|nil diagnostic
function ReleaseChannel.decodeResponse(body, decode)
    -- KOReader's LuaJSON exposes a callable table, unlike dkjson/cjson. Prefer
    -- its strict decoder while continuing to support function-style decoders.
    if type(decode) == "table" and type(decode.getDecoder) == "function" then
        decode = decode.getDecoder(true)
    end
    if not singleArrayRoot(body) or type(decode) ~= "function" then
        return nil, "Invalid release-list response"
    end
    local ok, releases, position, err = pcall(decode, body)
    if not ok or err ~= nil or not isArray(releases) then
        return nil, "Invalid release-list response"
    end
    -- dkjson returns the next character position; strict decoders simply return
    -- the value. Neither form may leave non-whitespace after the JSON payload.
    if type(position) == "number" and body:sub(position):find("%S") then
        return nil, "Trailing data in release-list response"
    end
    return releases
end

--- Find the one installable asset and normalize the fields required by download.
--- SHA-256 is mandatory for this fork channel; fail closed while an upload is
--- incomplete or its digest is not yet available from GitHub.
function ReleaseChannel.validateAsset(release)
    if type(release) ~= "table" or not ReleaseChannel.parseTag(release.tag_name)
            or not isArray(release.assets) then
        return nil, "Invalid release assets"
    end
    local asset
    for _idx, candidate in ipairs(release.assets) do
        if type(candidate) ~= "table" then return nil, "Invalid release asset" end
        if candidate.name == GitHub.ASSET_NAME then
            if asset then return nil, "Duplicate plugin assets" end
            asset = candidate
        end
    end
    if not asset then return nil, "Plugin ZIP is missing" end
    local expected_url = GitHub.URL .. "/releases/download/" .. release.tag_name
        .. "/" .. GitHub.ASSET_NAME
    if asset.state ~= "uploaded" or asset.browser_download_url ~= expected_url then
        return nil, "Plugin ZIP is not an uploaded fork asset"
    end
    if type(asset.size) ~= "number" or asset.size ~= asset.size or asset.size < 1
            or asset.size > GitHub.MAX_ASSET_BYTES or asset.size % 1 ~= 0 then
        return nil, "Invalid plugin ZIP size"
    end
    local digest = type(asset.digest) == "string" and asset.digest:match("^sha256:(%x+)$")
    if not digest or #digest ~= 64 then return nil, "Plugin ZIP SHA-256 is missing or invalid" end
    return {
        zip_url = expected_url,
        zip_size = asset.size,
        zip_sha256 = digest:lower(),
    }
end

--- Select the highest usable fork release, regardless of API order. Incomplete
--- newer releases are skipped so an older complete upgrade can still be offered.
--- compare_versions is the update checker's existing SemVer comparator.
--- @return table|nil normalized update info; string|nil response/selection error
function ReleaseChannel.selectLatestRelease(releases, include_prereleases, compare_versions)
    if not isArray(releases) then return nil, "Invalid release-list response" end
    if type(compare_versions) ~= "function" then return nil, "Version comparator is missing" end
    local best
    for _idx, release in ipairs(releases) do
        if type(release) == "table" and release.draft == false
                and type(release.prerelease) == "boolean" then
            local version, tag_prerelease = ReleaseChannel.parseTag(release.tag_name)
            -- A mislabeled prerelease tag must not escape the user's beta gate.
            local prerelease = release.prerelease or tag_prerelease
            if version and (include_prereleases or not prerelease) then
                local page_url = GitHub.URL .. "/releases/tag/" .. release.tag_name
                local asset = ReleaseChannel.validateAsset(release)
                if asset and release.html_url == page_url
                        and (not best or compare_versions(version, best.latest_version) > 0) then
                    best = {
                        latest_version = version,
                        tag_name = release.tag_name,
                        download_url = page_url,
                        release_notes = type(release.body) == "string" and release.body
                            or "No release notes available.",
                        is_prerelease = prerelease,
                        zip_url = asset.zip_url,
                        zip_size = asset.zip_size,
                        zip_sha256 = asset.zip_sha256,
                    }
                end
            end
        end
    end
    if not best then return nil, "No usable fork releases found" end
    return best
end

return ReleaseChannel
