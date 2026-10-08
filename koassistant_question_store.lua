-- One authoritative manifest per document. Payload files are immutable once
-- referenced; the manifest is the commit point. No global index or migration.
local Store = {}
Store.__index = Store
local copy = require("koassistant_question_queue").copy
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local function integer(value, minimum)
    return type(value) == "number" and value >= minimum and value <= 9007199254740991 and value % 1 == 0
end
local function array(value)
    if type(value) ~= "table" then return false end
    local count = 0
    for key in pairs(value) do
        if not integer(key, 1) then return false end
        count = count + 1
    end
    for i = 1, count do if value[i] == nil then return false end end
    return count == #value
end
local payload_names = {prompt="question.md", selected_text="source.md", answer="answer.md", reasoning="reasoning.md"}
local function preview(text, maximum)
    text = text or ""
    local last = math.min(#text, maximum)
    while last > 0 and last < #text and text:byte(last + 1) >= 128 and text:byte(last + 1) < 192 do
        last = last - 1
    end
    return text:sub(1, last)
end
local function payload(job)
    local value = { messages=copy(job.messages), config=copy(job.config) }
    for key in pairs(payload_names) do value[key] = job[key] end
    return value
end
local function hash(bytes) return require("ffi/sha2").md5(bytes) end
local function read(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local bytes = file:read("*a"); file:close()
    return bytes
end
local function atomic(path, bytes)
    local temporary = path .. ".tmp"
    if require("libs/libkoreader-lfs").symlinkattributes(temporary, "mode") == "link" then
        return nil, "Inbox temporary symlink rejected"
    end
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err end
    local wrote, write_err = file:write(bytes)
    local flushed, flush_err = file:flush()
    if not wrote or not flushed then file:close(); os.remove(temporary); return nil, write_err or flush_err end
    local synced, sync_err = require("ffi/util").fsyncOpenedFile(file, true)
    local closed, close_err = file:close()
    if not synced or not closed then return nil, sync_err or close_err end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then return nil, rename_err end
    local durable, durable_err = require("ffi/util").fsyncDirectory(path)
    if not durable then return nil, durable_err end
    return true
end
local function directory(path, synced)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.symlinkattributes(path, "mode") == "link" then error("Inbox symlinks are not supported") end
    local mode = lfs.attributes(path, "mode")
    if mode then
        assert(mode == "directory", "Inbox path is not a directory")
    else
        assert(lfs.mkdir(path))
    end
    -- Retry directory durability even if a previous mkdir succeeded before sync failed.
    if not synced[path] then
        assert(require("ffi/util").fsyncDirectory(path))
        assert(require("ffi/util").fsyncDirectory(path:match("^(.*)/[^/]+$") or "."))
        synced[path] = true
    end
end
function Store:new(path)
    return setmetatable({ path = path, records = {}, manifests = {}, pending = {}, dirty = {}, synced_directories = {}, synced_assets = {}, loaded = setmetatable({}, { __mode = "k" }) }, self)
end
function Store:_path(doc, relative)
    assert(type(doc) == "string" and doc:match("^[a-f0-9]+$"), "Invalid document ID")
    assert(type(relative) == "string" and relative ~= "" and not relative:find("[^%w%._/%-]")
        and relative:sub(1,1) ~= "/", "Invalid inbox file reference")
    local path = self.path .. "/" .. doc
    local lfs = require("libs/libkoreader-lfs")
    assert(lfs.symlinkattributes(self.path, "mode") ~= "link", "Inbox symlink rejected")
    assert(lfs.symlinkattributes(path, "mode") ~= "link", "Inbox symlink rejected")
    for part in relative:gmatch("[^/]+") do
        assert(part ~= "." and part ~= "..", "Unsafe inbox file reference")
        path = path .. "/" .. part
        assert(lfs.symlinkattributes(path, "mode") ~= "link", "Inbox symlink rejected")
    end
    return path
end
function Store:documentID(document)
    if document.id then
        assert(document.id:match("^[a-f0-9]+$"), "Invalid document ID")
        return document.id
    end
    local ok, fingerprint = pcall(function() return require("util").partialMD5(document.file) end)
    -- Captured test snapshots and unavailable sources still have deterministic IDs.
    document.identity_kind = ok and fingerprint and "koreader_partial_md5" or "path_fallback"
    return ok and fingerprint or hash(assert(document.file, "Missing document path"))
end
function Store:load()
    self.records, self.manifests, self.pending, self.dirty, self.loaded = {}, {}, {}, {}, setmetatable({}, { __mode = "k" })
    local ok, result = pcall(function()
        local lfs, json = require("libs/libkoreader-lfs"), require("json")
        local data = { version = 1, next_id = 1, jobs = {} }
        if not lfs.attributes(self.path) then return data end
        assert(lfs.symlinkattributes(self.path, "mode") ~= "link", "Inbox symlink rejected")
        for doc in lfs.dir(self.path) do
            if doc:match("^[a-f0-9]+$") then
                local path = self:_path(doc, "document.json")
                if lfs.attributes(path) then
                    local bytes = assert(read(path))
                    local manifest = json.decode(bytes)
                    assert(type(manifest) == "table" and manifest.version == 1 and manifest.id == doc
                        and array(manifest.jobs) and integer(manifest.next_id, 1)
                        and type(manifest.document) == "table", "Invalid document manifest")
                    self.manifests[doc] = manifest
                    data.next_id = math.max(data.next_id, manifest.next_id)
                    for _, record in ipairs(manifest.jobs) do
                        assert(type(record) == "table" and type(record.id) == "string" and record.id:match("^[1-9]%d*$") and integer(tonumber(record.id), 1)
                            and tonumber(record.id) < manifest.next_id and not self.records[record.id]
                            and type(record.files) == "table" and array(record.request) and #record.request > 0
                            and type(record.document) == "table" and type(record.config) == "table", "Invalid question record")
                        for key, reference in pairs(record.files) do
                            assert(payload_names[key], "Invalid question payload key")
                            self:_reference(doc, record.id, reference)
                        end
                        self:_validateEncoded(doc, record.id, record.request)
                        self:_validateEncoded(doc, record.id, record.config)
                        self.records[record.id] = { doc = doc, record = record }
                        local job = copy(record)
                        job.files, job.request = nil, nil
                        job.messages = {} -- loaded only for opening/retry/follow-up
                        job.document.id = doc
                        data.jobs[#data.jobs + 1] = job
                    end
                end
            end
        end
        table.sort(data.jobs, function(a,b) return tonumber(a.id) < tonumber(b.id) end)
        return data
    end)
    if not ok then return nil, "Could not read document inbox: " .. tostring(result) end
    return result
end
function Store:_reference(doc, id, reference)
    assert(type(reference) == "string" and reference:match("^question%-" .. id .. "/[%w%._%-]+$")
        and reference:sub(-4) ~= ".tmp", "Invalid question file reference")
    return self:_path(doc, reference)
end
function Store:_validateEncoded(doc, id, value)
    if type(value) ~= "table" then return end
    if value.inbox_file then
        self:_reference(doc, id, value.inbox_file)
        assert(value.encoding == nil or value.encoding == "base64" or value.encoding == "data_url", "Invalid payload encoding")
        assert(not value.encoding or (type(value.mime) == "string" and value.mime:match("^[%w%+%.%-]+/[%w%+%.%-]+$")), "Invalid payload MIME type")
        for key in pairs(value) do
            assert(key == "inbox_file" or key == "encoding" or key == "mime", "Invalid payload descriptor")
        end
    else
        for _, child in pairs(value) do self:_validateEncoded(doc, id, child) end
    end
end
function Store:_decode(doc, value)
    if type(value) ~= "table" then return value end
    if value.inbox_file then
        local bytes = assert(read(self:_path(doc, value.inbox_file)))
        if value.encoding == "base64" then return require("mime").b64(bytes) end
        if value.encoding == "data_url" then return "data:" .. value.mime .. ";base64," .. require("mime").b64(bytes) end
        return bytes
    end
    local out = {}; for k,v in pairs(value) do out[k] = self:_decode(doc,v) end
    return out
end
function Store:prompt(job)
    if job.prompt then return job.prompt end
    local entry = self.records[job.id]
    if not entry or not entry.record.files.prompt then return end
    local ok, value = pcall(function() return read(self:_path(entry.doc, entry.record.files.prompt)) end)
    if ok then return value end
end
function Store:hydrate(job)
    if self.loaded[job] or not self.records[job.id] then return job end
    local entry = self.records[job.id]
    local ok, content = pcall(function()
        local record = entry.record
        local values = { messages = self:_decode(entry.doc, record.request), config = self:_decode(entry.doc, record.config) }
        for key, reference in pairs(record.files) do values[key] = assert(read(self:_path(entry.doc, reference))) end
        return values
    end)
    if not ok then return nil, "Could not open saved question: " .. tostring(content) end
    for key,value in pairs(content) do job[key] = value end
    self.loaded[job] = payload(job)
    return job
end
function Store:_asset(doc, folder, name, bytes)
    local relative = folder .. "/" .. name
    local path = self:_path(doc, relative)
    local old = read(path)
    if old and old ~= bytes then
        local stem, extension = name:match("^(.*)(%.[^.]+)$")
        relative = folder .. "/" .. (stem or name) .. "-" .. hash(bytes) .. (extension or "")
        path = self:_path(doc, relative); old = read(path)
    end
    if old ~= bytes then
        assert(atomic(path, bytes))
    elseif not self.synced_assets[path] then
        -- The rename may have succeeded on an earlier attempt whose directory
        -- sync failed. A manifest must not commit until that sync succeeds.
        assert(require("ffi/util").fsyncDirectory(path))
    end
    self.synced_assets[path] = true
    return relative
end
function Store:_record(job, doc)
    local previous = self.records[job.id]
    local record = copy(job)
    record.messages, record.prompt, record.selected_text, record.answer, record.reasoning = nil,nil,nil,nil,nil
    record.prompt_preview = preview(job.prompt or job.prompt_preview, 192)
    record.source_preview = preview(job.selected_text or job.source_preview, 96)
    if previous and (not self.loaded[job] or equal(self.loaded[job], payload(job))) then
        record.request, record.files, record.config = copy(previous.record.request), copy(previous.record.files), copy(previous.record.config)
        return record
    end
    self.loaded[job] = true
    local folder = "question-" .. job.id
    directory(self:_path(doc, folder), self.synced_directories)
    record.files = {}
    for key, name in pairs(payload_names) do
        if job[key] ~= nil then record.files[key] = self:_asset(doc,folder,name,job[key]) end
    end
    local text_id, image_id = 0, 0
    local function encode(value, key, parent)
        if type(value) == "string" then
            local mime, payload = value:match("^data:([^;]+);base64,(.*)$")
            local encoding = mime and "data_url" or nil
            if not mime and key == "data" and parent and (parent.media_type or parent.mime_type) then
                mime, payload, encoding = parent.media_type or parent.mime_type, value, "base64"
            end
            if mime then
                image_id = image_id + 1
                local bytes = assert(require("mime").unb64(payload), "Invalid image data")
                local extension = ({["image/png"]="png", ["image/jpeg"]="jpg", ["image/webp"]="webp", ["image/gif"]="gif"})[mime] or "bin"
                local name = (image_id == 1 and "source" or ("source-" .. image_id)) .. "." .. extension
                return { inbox_file=self:_asset(doc,folder,name,bytes), encoding=encoding, mime=mime }
            end
            if key == "content" or key == "text" or key == "system" then
                text_id = text_id + 1
                return { inbox_file=self:_asset(doc,folder,"request-" .. text_id .. ".md",value) }
            end
            return value
        end
        if type(value) ~= "table" then return value end
        local keys = {}; for k in pairs(value) do keys[#keys+1] = k end
        table.sort(keys, function(a,b) if type(a) == type(b) then return a < b end; return type(a) < type(b) end)
        local out = {}; for _,k in ipairs(keys) do out[k] = encode(value[k],k,value) end
        return out
    end
    record.request = encode(job.messages)
    record.config = encode(job.config)
    return record
end
function Store:save(data)
    local ok, err = pcall(function()
        directory(self.path, self.synced_directories)
        local groups = {}
        -- Keep empty manifests as ID high-water marks; no separate global index.
        for doc, manifest in pairs(self.manifests) do
            groups[doc] = { version=1, id=doc, document=copy(manifest.document), next_id=manifest.next_id, jobs={} }
        end
        for doc, manifest in pairs(self.pending) do
            if not groups[doc] then
                groups[doc] = { version=1, id=doc, document=copy(manifest.document), next_id=manifest.next_id, jobs={} }
            else
                groups[doc].next_id = math.max(groups[doc].next_id, manifest.next_id)
            end
        end
        for _, job in ipairs(data.jobs) do
            local doc = self:documentID(job.document)
            job.document.id = doc
            directory(self.path .. "/" .. doc, self.synced_directories)
            local group = groups[doc] or { version=1, id=doc, document=copy(job.document), next_id=1, jobs={} }
            assert(not group.document.size or not job.document.size or group.document.size == job.document.size, "Document fingerprint size mismatch")
            groups[doc] = group
            group.next_id = math.max(group.next_id, tonumber(job.id)+1)
            group.jobs[#group.jobs+1] = self:_record(job,doc)
        end
        local json = require("json")
        for doc, manifest in pairs(groups) do
            local bytes = json.encode(manifest)
            if self.dirty[doc] or not self.manifests[doc] or not equal(self.manifests[doc], manifest) then
                -- Retain uncertain first writes as well: a failed enqueue is
                -- removed from memory, so a local retry must clear its manifest.
                self.dirty[doc], self.pending[doc] = true, manifest
                assert(atomic(self:_path(doc,"document.json"),bytes))
            end
        end
        -- Only mutate caches or reclaim payloads after every manifest write succeeds.
        -- Failed multi-document saves retain all old payloads for an explicit retry.
        for doc, manifest in pairs(groups) do
                local retained = {}
                for _,record in ipairs(manifest.jobs) do retained[record.id] = true end
                for _,record in ipairs((self.manifests[doc] or {}).jobs or {}) do
                    if not retained[record.id] then
                        self.records[record.id] = nil
                        -- Manifest removal commits first. Cleanup never follows links.
                        pcall(function()
                            local folder = self:_path(doc,"question-" .. record.id)
                            local lfs = require("libs/libkoreader-lfs")
                            for name in lfs.dir(folder) do
                                if name ~= "." and name ~= ".." then
                                    local path = self:_path(doc,"question-" .. record.id .. "/" .. name)
                                    if lfs.attributes(path,"mode") == "file" then os.remove(path) end
                                end
                            end
                            lfs.rmdir(folder)
                        end)
                    end
                end
            self.manifests[doc], self.dirty[doc], self.pending[doc] = manifest, nil, nil
            for _,record in ipairs(manifest.jobs) do self.records[record.id] = {doc=doc,record=record} end
        end
        for _, job in ipairs(data.jobs) do
            if self.loaded[job] then self.loaded[job] = payload(job) end
        end
    end)
    if not ok then return nil,tostring(err) end
    return true
end
return Store
