-- Fork-channel selection is offline and must never trust GitHub list order,
-- inherited tags, null sentinels, or an unrelated ZIP attachment.
-- Run: lua tests/unit/test_release_channel.lua
local script = debug.getinfo(1, "S").source:match("@?(.*)")
local unit_dir = script:match("(.+)/[^/]+$") or "."
local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
package.path = table.concat({ plugin_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path }, ";")
require("mock_koreader")
local TestRunner = require("test_runner"):new()
local Channel = require("koassistant_release_channel")
local Constants = require("koassistant_constants").GITHUB
local Updater = require("koassistant_update_checker")
local json = require("json")
local digest = string.rep("a", 64)

local function release(version, prerelease)
    local tag = Constants.TAG_PREFIX .. version
    return {
        tag_name = tag,
        draft = false,
        prerelease = prerelease or false,
        html_url = Constants.URL .. "/releases/tag/" .. tag,
        body = "Fork release notes",
        assets = { {
            name = Constants.ASSET_NAME,
            state = "uploaded",
            browser_download_url = Constants.URL .. "/releases/download/" .. tag .. "/" .. Constants.ASSET_NAME,
            size = 123456,
            digest = "sha256:" .. digest,
        } },
    }
end

local function select(releases, prereleases)
    return Channel.selectLatestRelease(releases, prereleases, Updater.compareVersions)
end

TestRunner:test("channel: only the public fork is configured", function()
    TestRunner:assertEqual(Constants.REPO_OWNER, "waverlylua")
    TestRunner:assertEqual(Constants.URL, "https://github.com/waverlylua/koassistant.koplugin")
    TestRunner:assertEqual(Constants.API_URL,
        "https://api.github.com/repos/waverlylua/koassistant.koplugin/releases?per_page=30")
    TestRunner:assertEqual(Constants.ASSET_NAME, "koassistant.koplugin.zip")
end)

TestRunner:test("versions: fork version advances RC5 and tags normalize", function()
    local meta = dofile(plugin_dir .. "/_meta.lua")
    TestRunner:assertEqual(meta.version, "0.23.1")
    TestRunner:assertEqual(Updater.compareVersions("0.23.0-queue.3-rc5", meta.version), -1)
    local version, prerelease = Channel.parseTag("waverly-v0.23.1")
    TestRunner:assertEqual(version, "0.23.1")
    TestRunner:assertFalse(prerelease)
    version, prerelease = Channel.parseTag("waverly-v0.23.2-rc.11")
    TestRunner:assertEqual(version, "0.23.2-rc.11")
    TestRunner:assertTrue(prerelease)
end)

TestRunner:test("versions: reject upstream, ambiguous and invalid fork tags", function()
    for _idx, tag in ipairs({ "v0.23.1", "0.23.1", "v99.0.0", "0.23.0-queue.3-rc5",
            "waverly-0.23.1", "Waverly-v0.23.1", "waverly-v0.23", "waverly-v0.23.01",
            "waverly-v0.23.1-", "waverly-v0.23.1-rc..1", "waverly-v0.23.1-01",
            "waverly-v0.23.1-rc.01", "waverly-v0.23.1-rc.", "waverly-v0.23.1-.rc",
            "waverly-v0.23.1+build.1", "waverly-v0.23.1/extra", "waverly-v0.23.1\n",
            "waverly-v9007199254740992.0.0", "waverly-v0.23.1-9007199254740992", "" }) do
        TestRunner:assertEqual(Channel.parseTag(tag), nil, tag)
    end
    for _idx, tag in ipairs({ false, 123, {}, function() end }) do
        TestRunner:assertEqual(Channel.parseTag(tag), nil)
    end
    TestRunner:assertEqual(Channel.parseTag(nil), nil)
end)

TestRunner:test("selection: greatest usable version wins in unsorted API response", function()
    local selected = select({ release("0.23.2"), release("0.23.11"), release("0.23.9") })
    TestRunner:assertEqual(selected.latest_version, "0.23.11")
    TestRunner:assertEqual(selected.zip_size, 123456)
    TestRunner:assertEqual(selected.zip_sha256, digest)
    TestRunner:assertEqual(selected.release_notes, "Fork release notes")
    TestRunner:assertEqual(selected.tag_name, "waverly-v0.23.11")
end)

TestRunner:test("selection: drafts and inherited upstream releases are ignored", function()
    local draft, upstream = release("9.0.0"), release("99.0.0")
    draft.draft = true
    upstream.tag_name = "v99.0.0"
    TestRunner:assertEqual(select({ draft, upstream, release("0.23.1") }).latest_version, "0.23.1")
end)

TestRunner:test("selection: prerelease gate also checks tag, with correct SemVer order", function()
    local candidates = { release("0.23.2-rc.9", true), release("0.23.2-rc.11", true), release("0.23.1") }
    TestRunner:assertEqual(select(candidates, false).latest_version, "0.23.1")
    TestRunner:assertEqual(select(candidates, true).latest_version, "0.23.2-rc.11")
    candidates[2].prerelease = false -- a mistaken GitHub checkbox is still beta
    TestRunner:assertEqual(select(candidates, false).latest_version, "0.23.1")
    candidates[#candidates + 1] = release("0.23.2")
    TestRunner:assertEqual(select(candidates, true).latest_version, "0.23.2")
end)

TestRunner:test("selection: incomplete newer releases do not hide a usable update", function()
    local newer, other = release("0.24.0"), release("0.25.0")
    newer.assets = {}
    other.assets[1].digest = nil
    TestRunner:assertEqual(select({ newer, release("0.23.2"), other }).latest_version, "0.23.2")
end)

TestRunner:test("assets: exact named ZIP is selected after unrelated assets", function()
    local data = release("0.23.2")
    table.insert(data.assets, 1, { name = "source.zip", browser_download_url = "https://untrusted.invalid/source.zip" })
    local selected = select({ data })
    TestRunner:assertEqual(selected.zip_url, data.assets[2].browser_download_url)
    data.assets[2].digest = "sha256:" .. string.rep("A", 64)
    TestRunner:assertEqual(select({ data }).zip_sha256, digest)
end)

TestRunner:test("assets: duplicates and renamed/source ZIPs are rejected", function()
    local data = release("0.23.2")
    data.assets[2] = data.assets[1]
    TestRunner:assertEqual(Channel.validateAsset(data), nil)
    data = release("0.23.2")
    data.assets[1].name = "koassistant-source.zip"
    TestRunner:assertEqual(Channel.validateAsset(data), nil)
end)

TestRunner:test("assets: URL must match HTTPS host, repository, tag and filename exactly", function()
    for _idx, url in ipairs({ "http://github.com/waverlylua/koassistant.koplugin/releases/download/waverly-v0.23.2/koassistant.koplugin.zip",
            "https://github.com/zeeyado/koassistant.koplugin/releases/download/waverly-v0.23.2/koassistant.koplugin.zip",
            "https://github.com/waverlylua/koassistant.koplugin/releases/download/waverly-v0.23.1/koassistant.koplugin.zip",
            "https://github.com/waverlylua/koassistant.koplugin/archive/refs/tags/waverly-v0.23.2.zip",
            "https://github.com.evil.invalid/waverlylua/koassistant.koplugin/releases/download/waverly-v0.23.2/koassistant.koplugin.zip",
            release("0.23.2").assets[1].browser_download_url .. "?download=1",
            release("0.23.2").assets[1].browser_download_url .. "#fragment", "" }) do
        local data = release("0.23.2")
        data.assets[1].browser_download_url = url
        TestRunner:assertEqual(Channel.validateAsset(data), nil, url)
    end
end)

TestRunner:test("assets: uploaded state and bounded positive integer size are mandatory", function()
    for _idx, size in ipairs({ 0, -1, 1.5, "123456", false, {}, math.huge, 0/0, Constants.MAX_ASSET_BYTES + 1 }) do
        local data = release("0.23.2")
        data.assets[1].size = size
        TestRunner:assertEqual(Channel.validateAsset(data), nil, tostring(size))
    end
    local data = release("0.23.2")
    data.assets[1].size = nil
    TestRunner:assertEqual(Channel.validateAsset(data), nil)
    data = release("0.23.2")
    data.assets[1].state = "new"
    TestRunner:assertEqual(Channel.validateAsset(data), nil)
    data.assets[1].state = "uploaded"
    data.assets[1].size = Constants.MAX_ASSET_BYTES
    TestRunner:assertTrue(Channel.validateAsset(data))
end)

TestRunner:test("assets: malformed, absent and non-SHA256 digests are rejected", function()
    for _idx, hash in ipairs({ "", "sha256:", "sha256:" .. string.rep("a", 63),
            "sha256:" .. string.rep("a", 65), "sha256:" .. string.rep("g", 64),
            "sha512:" .. digest, false, {}, function() end }) do
        local data = release("0.23.2")
        data.assets[1].digest = hash
        TestRunner:assertEqual(Channel.validateAsset(data), nil)
    end
    local data = release("0.23.2")
    data.assets[1].digest = nil
    TestRunner:assertEqual(Channel.validateAsset(data), nil)
end)

TestRunner:test("selection: release link must remain on the fork's exact release", function()
    local data = release("0.23.2")
    data.html_url = "https://github.com/zeeyado/koassistant.koplugin/releases/tag/v0.23.2"
    TestRunner:assertEqual(select({ data }), nil)
end)

TestRunner:test("selection: malformed API values fail safely", function()
    for _idx, data in ipairs({ "releases", 123, false, function() end,
            { message = "API rate limit exceeded" }, { [2] = release("0.23.2") },
            { [1] = release("0.23.2"), extra = true }, { [0] = release("0.23.2") } }) do
        local selected, err = select(data)
        TestRunner:assertEqual(selected, nil)
        TestRunner:assertEqual(err, "Invalid release-list response")
    end
    TestRunner:assertEqual(select(nil), nil)
    TestRunner:assertEqual(select({}), nil)
    TestRunner:assertEqual(select({ false, 123, function() end, {}, "release" }), nil)
end)

TestRunner:test("selection: metadata must have Boolean flags, null notes are harmless", function()
    for _idx, field in ipairs({ "draft", "prerelease" }) do
        for _idx2, value in ipairs({ "false", 0, {}, function() end }) do
            local data = release("0.23.2")
            data[field] = value
            TestRunner:assertEqual(select({ data }), nil)
        end
        local data = release("0.23.2")
        data[field] = nil
        TestRunner:assertEqual(select({ data }), nil)
    end
    local data = release("0.23.2")
    data.body = function() end
    TestRunner:assertEqual(select({ data }).release_notes, "No release notes available.")
end)

TestRunner:test("assets: malformed arrays/null members do not crash", function()
    for _idx, value in ipairs({ false, 123, function() end, { message = "error" }, { false },
            { function() end }, { [2] = release("0.23.2").assets[1] } }) do
        local data = release("0.23.2")
        data.assets = value
        TestRunner:assertEqual(Channel.validateAsset(data), nil)
    end
end)

TestRunner:test("decode: valid empty/nonempty arrays are accepted", function()
    TestRunner:assertTrue(Channel.decodeResponse("[]", json.decode))
    TestRunner:assertTrue(Channel.decodeResponse(" \n [ ] \r\n", json.decode))
    local data = Channel.decodeResponse(json.encode({ release("0.23.2") }), json.decode)
    TestRunner:assertEqual(select(data).latest_version, "0.23.2")
end)

TestRunner:test("decode: errors, empty objects, null, scalars and truncated JSON fail", function()
    for _idx, body in ipairs({ "", " ", "{}", '{"message":"API rate limit exceeded"}',
            "null", "true", "123", '"string"', "[", "[] unexpected", "[] {}", '[{"tag_name":' }) do
        TestRunner:assertEqual(Channel.decodeResponse(body, json.decode), nil, body)
    end
    TestRunner:assertEqual(Channel.decodeResponse(nil, json.decode), nil)
    TestRunner:assertEqual(Channel.decodeResponse({}, json.decode), nil)
end)

TestRunner:test("decode: non-throwing parsers cannot turn errors/trailing text into success", function()
    TestRunner:assertEqual(Channel.decodeResponse("[", function() return nil, 2, "unterminated" end), nil)
    TestRunner:assertEqual(Channel.decodeResponse("[] junk", function() return {}, 3 end), nil)
    TestRunner:assertTrue(Channel.decodeResponse("[] \n", function() return {}, 3 end))
    TestRunner:assertEqual(Channel.decodeResponse("[]", function() return { message = "error" } end), nil)
end)

return TestRunner:summary()
