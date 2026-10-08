-- Durable, reader-independent question jobs. Only explicit enqueue/retry can submit.
-- Runtime dependencies are injected so the state machine is testable without a GUI.
local Queue = {}
Queue.__index = Queue

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then error("Cyclic question snapshot") end
    seen[value] = true
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v, seen) end
    seen[value] = nil
    return out
end
Queue.copy = copy

function Queue:new(deps)
    local instance = setmetatable({ deps = deps, jobs = {}, next_id = 1, paused = false }, self)
    local data, err = deps.load()
    if err then instance.storage_error = err; instance.load_error = true; return instance end
    if data then
        if type(data) ~= "table" or data.version ~= 1 or type(data.jobs) ~= "table" then
            instance.load_error = true
            instance.storage_error = "Unsupported or damaged question inbox; its file was left untouched."
            return instance
        end
        local valid_states = { queued=true, running=true, completed=true, failed=true, cancelled=true, interrupted=true }
        local seen, maximum, count = {}, 0, 0
        for index, job in pairs(data.jobs) do
            count = count + 1
            if type(index) ~= "number" or index < 1 or index % 1 ~= 0
                    or type(job) ~= "table" or type(job.id) ~= "string" or not job.id:match("^%d+$")
                    or seen[job.id] or not valid_states[job.state]
                    or type(job.messages) ~= "table" or type(job.config) ~= "table"
                    or type(job.document) ~= "table" or type(job.attempts) ~= "number"
                    or job.attempts < 0 or job.attempts % 1 ~= 0 then
                instance.load_error = true
                instance.storage_error = "Damaged question inbox entry; its file was left untouched."
                return instance
            end
            seen[job.id] = true
            maximum = math.max(maximum, tonumber(job.id))
        end
        if count ~= #data.jobs or type(data.next_id) ~= "number" or data.next_id <= maximum
                or data.next_id % 1 ~= 0 then
            instance.load_error = true
            instance.storage_error = "Damaged question inbox index; its file was left untouched."
            return instance
        end
        instance.jobs = data.jobs
        instance.next_id = data.next_id or 1
        -- Never replay a pre-crash send, including one whose result was lost.
        -- Even queued jobs need explicit Retry after restart (no surprise charges).
        local changed = false
        for _, job in ipairs(instance.jobs) do
            if job.state == "running" or job.state == "queued" then
                job.state = "interrupted"
                job.error = "KOReader stopped before this job finished. Retry only if you want a new request; the previous request may already have been billed."
                changed = true
            end
        end
        if changed then instance:_save() end
    end
    return instance
end

function Queue:_save()
    local ok, err = self.deps.save({ version = 1, next_id = self.next_id, jobs = self.jobs })
    if not ok then
        self.storage_error = tostring(err or "Could not save question inbox")
        return nil, self.storage_error
    end
    self.storage_error = nil
    return true
end

function Queue:_changed()
    if self.deps.changed then self.deps.changed(self) end
end

function Queue:get(id, metadata_only)
    for _, job in ipairs(self.jobs) do
        if job.id == id then
            if self.deps.hydrate and not metadata_only then return self.deps.hydrate(job) end
            return job
        end
    end
end

function Queue:counts()
    local counts = { queued = 0, running = 0, unread = 0, failed = 0, interrupted = 0, cancelled = 0 }
    for _, job in ipairs(self.jobs) do
        if counts[job.state] then counts[job.state] = counts[job.state] + 1 end
        if job.state == "completed" and not job.read then counts.unread = counts.unread + 1 end
    end
    return counts
end

function Queue:enqueue(snapshot)
    if _G.KOAssistantUpdatePending then return nil, "KOAssistant is updating. Please restart KOReader before adding questions." end
    if self.storage_error then return nil, self.storage_error end
    if type(snapshot) ~= "table" or type(snapshot.messages) ~= "table"
            or not snapshot.config or not snapshot.document then return nil, "Incomplete question snapshot" end
    local job = copy(snapshot)
    job.id = tostring(self.next_id)
    self.next_id = self.next_id + 1
    job.created_at, job.updated_at = self.deps.now(), self.deps.now()
    job.state, job.attempts = "queued", 0
    self.jobs[#self.jobs + 1] = job
    local ok, err = self:_save()
    if not ok then
        table.remove(self.jobs)
        return nil, err
    end
    self:_changed()
    self:_schedule()
    return job
end

function Queue:_schedule()
    if self.scheduled or self.active or self.paused or self.storage_error then return end
    self.scheduled = true
    self.deps.schedule(function()
        self.scheduled = false
        self:_pump()
    end)
end

function Queue:_pump()
    if _G.KOAssistantUpdatePending then return end
    if self.active or self.paused or self.storage_error then return end
    local job
    for _, candidate in ipairs(self.jobs) do
        if candidate.state == "queued" then job = candidate; break end
    end
    if not job then return end
    if self.deps.hydrate then
        local loaded, err = self.deps.hydrate(job)
        if not loaded then
            job.state, job.error = "failed", err
            self:_save(); self:_changed(); self:_schedule()
            return
        end
    end
    job.state = "running"
    job.attempts = job.attempts + 1
    job.updated_at = self.deps.now()
    -- Commit send intent BEFORE invoking any code that can touch the network.
    if not self:_save() then
        job.state = "interrupted"
        job.error = "Could not save send intent; no request was started."
        self:_changed()
        return
    end
    local attempt = job.attempts
    self.active = job.id
    self:_changed()
    local function finish(ok, answer, err, reasoning, usage)
        -- Cancellation, suspend, or an old attempt must never revive a job.
        if job.state ~= "running" or job.attempts ~= attempt then return end
        self.active, self.cancel_active = nil, nil
        job.updated_at = self.deps.now()
        job.state = ok and type(answer) == "string" and answer ~= "" and "completed" or "failed"
        job.answer = job.state == "completed" and answer or nil
        job.error = job.state == "failed" and tostring(err or "The provider returned an empty answer.") or nil
        job.reasoning, job.usage, job.read = reasoning, usage, false
        self:_save()
        self:_changed()
        self:_schedule()
    end
    local ok, err = pcall(self.deps.start, copy(job), finish, function(cancel)
        if job.state == "running" and job.attempts == attempt then self.cancel_active = cancel end
    end)
    if not ok then finish(false, nil, tostring(err)) end
end

function Queue:cancel(id, interrupted)
    local job = self:get(id, true)
    if not job or (job.state ~= "queued" and job.state ~= "running") then return false end
    local cancel = self.active == id and self.cancel_active or nil
    -- Invalidate before cancelling: the transport may synchronously call finish.
    job.state = interrupted and "interrupted" or "cancelled"
    job.error = interrupted and "Device suspended. Retry explicitly; the provider may already have processed and billed this request."
        or "Cancelled locally. A request already sent may still be processed and billed by the provider."
    job.updated_at = self.deps.now()
    if self.active == id then self.active, self.cancel_active = nil, nil end
    local ok, err = self:_save()
    if cancel then pcall(cancel) end
    self:_changed()
    self:_schedule()
    return ok, err
end

function Queue:retry(id)
    if _G.KOAssistantUpdatePending then return false, "KOAssistant is updating. Please restart KOReader before retrying questions." end
    if self.storage_error then return nil, self.storage_error end
    local job, load_err = self:get(id)
    if not job and load_err then return nil, load_err end
    if not job or (job.state ~= "failed" and job.state ~= "interrupted" and job.state ~= "cancelled") then
        return nil, "This question cannot be retried in its current state."
    end
    local previous = copy(job)
    job.state, job.error = "queued", nil
    job.updated_at = self.deps.now()
    local ok, err = self:_save()
    if not ok then
        for k in pairs(job) do job[k] = nil end
        for k, v in pairs(previous) do job[k] = v end
        return nil, err
    end
    self:_changed()
    self:_schedule()
    return true
end

function Queue:remove(id)
    if self.storage_error then return nil, self.storage_error end
    for index, job in ipairs(self.jobs) do
        if job.id == id then
            if job.state == "queued" or job.state == "running" then
                return nil, "Cancel this request before removing it."
            end
            table.remove(self.jobs, index)
            local ok, err = self:_save()
            if not ok then table.insert(self.jobs, index, job); return nil, err end
            self:_changed()
            return true
        end
    end
    return nil, "Question no longer exists."
end

-- Local-only recovery: persist retained answers before allowing another send.
function Queue:retrySave()
    if self.load_error then return nil, self.storage_error end
    local ok, err = self:_save()
    self:_changed()
    if ok then self:_schedule() end
    return ok, err
end

function Queue:markRead(id)
    local job = self:get(id, true)
    if job and job.state == "completed" and not job.read then
        job.read = true
        local ok, err = self:_save()
        if not ok then job.read = false end
        self:_changed()
        return ok, err
    end
    return true
end

function Queue:suspend()
    self.paused = true
    if self.active then self:cancel(self.active, true) end
end

function Queue:resume()
    self.paused = false
    -- Only never-started jobs from THIS session continue. Interrupted ones stay put.
    self:_schedule()
end

return Queue
