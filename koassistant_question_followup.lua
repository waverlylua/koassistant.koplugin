-- Pure, immutable follow-up snapshots. No reader access, no network and no
-- dependency on the ancestor remaining in the inbox after this job is saved.
local Followup = { MAX_HISTORY_BYTES = 24000, MAX_ANSWER_BYTES = 16000,
    MAX_QUESTION_BYTES = 4000, MAX_EXCHANGES = 8 }
local copy = require("koassistant_question_queue").copy

local function prefix(text, maximum)
    if #text <= maximum then return text, false end
    local last = maximum
    while last > 0 and text:byte(last + 1) >= 128 and text:byte(last + 1) < 192 do last = last - 1 end
    return text:sub(1, last) .. "\n[Earlier answer excerpt ends here; full answer remains in the inbox.]", true
end

function Followup.prepare(parent, question, options)
    options = options or {}
    if not parent or parent.state ~= "completed" or type(parent.answer) ~= "string" then
        return nil, "Open a completed answer before asking a follow-up."
    end
    if type(question) ~= "string" or not question:match("%S") then return nil, "Write a follow-up question first." end
    if #question > Followup.MAX_QUESTION_BYTES then return nil, "Keep the follow-up question within 4,000 bytes." end
    if parent.image and not require("koassistant_question_vision").supported(parent.config.provider, parent.config.model) then
        return nil, "The saved source image requires an image-capable model. This follow-up was not sent."
    end
    local source_count = parent.followup and parent.followup.source_message_count or #parent.messages
    if type(source_count) ~= "number" or source_count < 1 or source_count > #parent.messages then
        return nil, "The saved original source is incomplete."
    end
    local messages = {}
    for i = 1, source_count do messages[#messages + 1] = copy(parent.messages[i]) end
    local answer, clipped = prefix(parent.answer, Followup.MAX_ANSWER_BYTES)
    local latest = { role = "user", content = "Follow-up on the preceding saved answer. Use the original source above.\n\n" .. question }
    local exchanges = {{ {role="assistant", content=answer}, latest }}
    local bytes = #answer + #latest.content
    local omitted = parent.followup and parent.followup.omitted_exchanges or 0
    -- Walk backwards in complete assistant/user pairs, keeping recent history.
    local old = {}
    for i = source_count + 1, #parent.messages, 2 do
        local a, u = parent.messages[i], parent.messages[i + 1]
        if not a or not u or a.role ~= "assistant" or u.role ~= "user"
            or type(a.content) ~= "string" or type(u.content) ~= "string" then
            return nil, "The saved follow-up history is incomplete."
        end
        old[#old + 1] = { a, u }
    end
    local stopped = false
    for i = #old, 1, -1 do
        local size = #old[i][1].content + #old[i][2].content
        if not stopped and #exchanges < Followup.MAX_EXCHANGES and bytes + size <= Followup.MAX_HISTORY_BYTES then
            table.insert(exchanges, 1, copy(old[i])); bytes = bytes + size
        else
            stopped = true; omitted = omitted + 1
        end
    end
    for _, pair in ipairs(exchanges) do
        messages[#messages + 1] = pair[1]; messages[#messages + 1] = pair[2]
    end
    local snapshot = {
        selected_text = parent.selected_text, document = copy(parent.document), image = copy(parent.image),
        config = copy(parent.config), messages = messages, label = options.label or "Follow-up",
        prompt = question, action_id = "queued_followup", saved_prompt_id = options.action_id,
        parent_id = parent.id, root_id = parent.root_id or parent.id,
        followup = { source_message_count = source_count, parent_id = parent.id, root_id = parent.root_id or parent.id,
            exchanges = #exchanges, omitted_exchanges = omitted, prior_answer_clipped = clipped,
            history_bytes = bytes, max_history_bytes = Followup.MAX_HISTORY_BYTES,
            max_exchanges = Followup.MAX_EXCHANGES, history_clipped = clipped or omitted > 0
                or (parent.followup and parent.followup.history_clipped) or false },
    }
    -- This conversation is a single call over frozen source/history. Tool/web
    -- fetches could refresh or expand that source and are intentionally disabled.
    snapshot.config.enable_web_search = false
    snapshot.config.features = snapshot.config.features or {}
    snapshot.config.features.enable_web_search = false
    return snapshot
end

function Followup.describe(snapshot)
    local context = snapshot.followup
    local text = "Original source + saved answer; same model. Up to 8 recent exchanges / 24 KB of thread text (about 6,000 English tokens; image/source extra)."
    if context and context.history_clipped then
        text = text .. " This request uses shortened history"
            .. (context.omitted_exchanges > 0 and (" (" .. context.omitted_exchanges .. " older exchanges omitted)") or "")
            .. ". Full saved answers stay in the inbox."
    end
    return text
end

return Followup
