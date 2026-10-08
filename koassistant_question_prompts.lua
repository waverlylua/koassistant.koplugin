-- The queue shares KOAssistant's registered action store and highlight shortcut
-- ordering. Recent custom wording is derived from the existing durable inbox.
local Prompts = {}
local Payload = require("koassistant_question_payload")

function Prompts.favorites(plugin, captured)
    local out = {}
    for _, action in ipairs(plugin.action_service:getInputActionObjects("highlight", captured.document.file)) do
        if Payload.eligible(action) then out[#out + 1] = action end
    end
    return out
end

function Prompts.recent(jobs, maximum, load_prompt)
    local out, seen = {}, {}
    for i = #jobs, 1, -1 do
        local job = jobs[i]
        if load_prompt and (job.action_id == "queued_custom" or job.action_id == "queued_followup") then
            local prompt = load_prompt(job)
            if prompt then job = {action_id=job.action_id, saved_prompt_id=job.saved_prompt_id, id=job.id, prompt=prompt} end
        end
        if (job.action_id == "queued_custom" or (job.action_id == "queued_followup" and not job.saved_prompt_id))
                and type(job.prompt) == "string" and job.prompt:match("%S") then
            local key = job.prompt:gsub("%s+", " "):match("^%s*(.-)%s*$")
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = { prompt = job.prompt, job_id = job.id }
                if #out >= (maximum or 5) then break end
            end
        end
    end
    return out
end

function Prompts.save(plugin, name, prompt)
    if type(name) ~= "string" or not name:match("%S") then return nil, "Name the saved prompt first." end
    if type(prompt) ~= "string" or not prompt:match("%S") then return nil, "Write the prompt before saving it." end
    name = name:match("^%s*(.-)%s*$")
    if #name > 160 then return nil, "Use a shorter prompt name (160 bytes maximum)." end
    local existing = plugin.settings:readSetting("custom_actions") or {}
    for _, action in ipairs(existing) do
        if action.text == name then return nil, "A custom prompt already has that name. Choose another name or edit it in Manage shortcuts." end
    end
    local index = #existing + 1
    plugin.action_service:addUserAction{ text = name, prompt = prompt, context = "highlight" }
    local id = "ui_" .. index
    plugin.action_service:addToInput("highlight", id)
    return id
end

return Prompts
