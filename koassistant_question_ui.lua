local _ = require("koassistant_gettext")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local Runtime = require("koassistant_question_runtime")
local Payload = require("koassistant_question_payload")
local UI = {}

local function short(text, maximum)
    text = tostring(text or ""):gsub("%s+", " ")
    local count, out = 0, {}
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > maximum then return table.concat(out) .. "…" end
        out[#out + 1] = char
    end
    return table.concat(out)
end

local function label(job)
    if job.action_id == "queued_custom" or job.action_id == "queued_followup" then return short(job.prompt or job.prompt_preview, 48) end
    return job.label or _("Question")
end

local function stateLabel(job)
    local labels = { queued = _("Waiting"), running = _("Thinking"), completed = _("Ready"),
        failed = _("Failed"), interrupted = _("Interrupted"), cancelled = _("Cancelled") }
    return labels[job.state] or job.state
end

local function location(job)
    local doc = job.document or {}
    if doc.visible_pages and #doc.visible_pages > 0 then
        return _("Pages") .. " " .. table.concat(doc.visible_pages, ", ")
    elseif doc.page then
        local page = (doc.capture_kind == "whole_page" and _("Whole page") or _("Page")) .. " " .. doc.page
        if doc.end_page and doc.end_page ~= doc.page then page = page .. "–" .. doc.end_page end
        return page
    end
    return _("Saved selection")
end


local function errorMessage(err)
    UIManager:show(InfoMessage:new{ text = tostring(err) })
end

function UI.enqueue(plugin, captured, action)
    if captured.image then
        plugin:updateConfigFromSettings()
        action = require("koassistant_question_queue").copy(action)
        if not action.provider then
            action.provider = plugin.configuration.provider
            action.model = action.model or require("koassistant_config_helper"):getModelInfo(plugin.configuration)
        end
        action.model_tier = nil
    end
    local ok, snapshot = pcall(Payload.prepare, plugin, captured, action)
    if not ok then errorMessage(snapshot); return end
    local job, err = Runtime.get(plugin):enqueue(snapshot)
    if not job then errorMessage(err); return end
    -- Confirmation is brief; all later updates live in the discreet inbox badge.
    UIManager:show(require("ui/widget/notification"):new{ text = _("Queued. Open AI inbox in KOAssistant"), timeout = 3 })
    return job
end

local function sourceSummary(captured)
    local kind = captured.image and (captured.document.capture_kind == "whole_page"
        and _("Original full-page image") or _("Captured region")) or short(captured.selected_text, 70)
    return location(captured) .. " · " .. kind
end

function UI.enqueueFollowup(plugin, parent, prompt, action)
    local Followup = require("koassistant_question_followup")
    local snapshot, err = Followup.prepare(parent, prompt, {
        label = action and (action.text or action.name), action_id = action and action.id,
    })
    if not snapshot then errorMessage(err); return end
    local job
    job, err = Runtime.get(plugin):enqueue(snapshot)
    if not job then errorMessage(err); return end
    UIManager:show(require("ui/widget/notification"):new{ text = _("Follow-up queued. Original saved."), timeout = 3 })
    return job
end

function UI.showSavePrompt(plugin, prompt, on_return)
    local dialog
    dialog = require("ui/widget/inputdialog"):new{
        title = _("Save as registered prompt"),
        description = _("Saves only this wording as a highlight shortcut. No question is sent."),
        input = "", input_hint = _("Prompt name, e.g. Explain notation"),
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog); on_return() end },
            { text = _("Save prompt"), callback = function()
                local ok, id, err = pcall(require("koassistant_question_prompts").save, plugin, dialog:getInputText(), prompt)
                if not ok or not id then errorMessage(ok and err or id); return end
                UIManager:close(dialog)
                UIManager:show(require("ui/widget/notification"):new{ text = _("Prompt saved. No request sent."), timeout = 2 })
                on_return()
            end },
        }},
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function UI.showCustom(plugin, captured, initial, parent)
    -- Check the custom-question destination before asking the reader to type.
    -- Shortcuts can override the global provider, so the chooser itself stays
    -- available and Payload.prepare validates each shortcut's resolved config.
    if captured.image and not parent then
        plugin:ensureInitialized()
        plugin:updateConfigFromSettings()
        local config = plugin.configuration
        local model = require("koassistant_config_helper"):getModelInfo(config)
        local Vision = require("koassistant_question_vision")
        if not Vision.supported(config.provider, model) then
            errorMessage(Vision.unsupportedMessage(config.provider, model))
            return
        end
    end
    local dialog
    local submitted = false
    local description = sourceSummary(captured)
    local preview
    if parent then
        preview = require("koassistant_question_followup").prepare(parent, initial or "Follow-up")
        description = _("Answer") .. " #" .. parent.id .. " · " .. description .. "\n"
            .. _("Original source + saved answer · same model")
            .. (preview and preview.followup.history_clipped and ("\n" .. _("Long history will be shortened; see Context details")) or "")
    end
    local function input()
        local prompt = dialog:getInputText()
        if not prompt or not prompt:match("%S") then
            UIManager:show(require("ui/widget/notification"):new{ text = _("Write a question first"), timeout = 2 })
            return
        end
        return prompt
    end
    dialog = require("ui/widget/inputdialog"):new{
        title = parent and (_("Follow-up to answer") .. " #" .. parent.id)
            or (captured.image and _("Ask about this image") or _("Queue a question")),
        description = description, input = initial or "",
        input_hint = parent and _("What should I explain further in the saved answer?") or _("Ask about this source…"),
        buttons = {
            {
              { text = _("Save as prompt…"), callback = function()
                  local prompt = input(); if not prompt then return end
                  UIManager:close(dialog)
                  UI.showSavePrompt(plugin, prompt, function() UI.showCustom(plugin, captured, prompt, parent) end)
              end },
              parent and { text = _("Context details"), callback = function()
                  errorMessage(require("koassistant_question_followup").describe(preview or {}))
              end } or nil,
            },
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                { text = parent and _("Queue follow-up") or _("Queue"), is_enter_default = true, callback = function()
                    if submitted then return end
                    local prompt = input(); if not prompt then return end
                    local job
                    if parent then job = UI.enqueueFollowup(plugin, parent, prompt)
                    else job = UI.enqueue(plugin, captured, { id = "queued_custom", text = short(prompt, 48), prompt = prompt }) end
                    if job then submitted = true; UIManager:close(dialog) end
                end },
            },
        },
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function UI.showRecent(plugin, captured, parent)
    local dialog
    local items = {}
    local queue = Runtime.get(plugin)
    for _, recent in ipairs(require("koassistant_question_prompts").recent(queue.jobs, nil, queue.deps.prompt)) do
        local prompt = recent.prompt
        items[#items + 1] = { text = short(prompt, 64), callback = function()
            UIManager:close(dialog); UI.showCustom(plugin, captured, prompt, parent)
        end }
    end
    if #items == 0 then items[1] = { text = _("No custom questions saved yet"), enabled = false } end
    items[#items + 1] = { text = _("Back to shortcuts"), callback = function()
        UIManager:close(dialog); UI.showChooser(plugin, captured, parent)
    end }
    dialog = Menu:new{ title = _("Recent question wording"), subtitle = sourceSummary(captured),
        item_table = items, is_popout = true }
    UIManager:show(dialog)
end

function UI.showChooser(plugin, captured, parent, show_all)
    local dialog
    local submitted = false
    local items = {}
    local Prompts = require("koassistant_question_prompts")
    plugin:ensureInitialized()
    local function choose(action)
        if submitted then return end
        if parent then
            -- Shortcut wording is reused; parent config/source stay frozen.
            local message = require("message_builder").build{
                prompt = action, context = "highlight", using_new_format = true,
                data = { highlighted_text = "the preceding saved answer in this conversation, using its original document source" },
            }
            if UI.enqueueFollowup(plugin, parent, message, action) then submitted = true; UIManager:close(dialog) end
        elseif UI.enqueue(plugin, captured, action) then submitted = true; UIManager:close(dialog) end
    end
    items[#items + 1] = { text = show_all == "all" and _("Registered prompts · tap to queue") or _("Favorites / saved shortcuts · tap to queue"), enabled = false }
    local actions = show_all == "all" and plugin.action_service:getAllActions("highlight", false, true) or Prompts.favorites(plugin, captured)
    local count = 0
    for _, action in ipairs(actions) do
        if Payload.eligible(action) then
            local picked = action
            count = count + 1
            if show_all or count <= 3 then
                items[#items + 1] = { text = action.text or action.name or action.id, callback = function() choose(picked) end }
            end
        end
    end
    if count == 0 then items[#items + 1] = { text = _("No queue-compatible shortcuts yet"), enabled = false } end
    if not show_all and count > 3 then
        items[#items + 1] = { text = _("More saved shortcuts…"), callback = function()
            UIManager:close(dialog); UI.showChooser(plugin, captured, parent, "favorites")
        end }
    end
    items[#items + 1] = { text = _("Recent questions · reuse wording…"), callback = function()
        UIManager:close(dialog); UI.showRecent(plugin, captured, parent)
    end }
    items[#items + 1] = { text = _("Write a question…"), callback = function()
        UIManager:close(dialog); UI.showCustom(plugin, captured, nil, parent)
    end }
    items[#items + 1] = { text = show_all and _("Back to saved shortcuts") or _("All registered prompts…"), callback = function()
        UIManager:close(dialog); UI.showChooser(plugin, captured, parent, not show_all and "all" or nil)
    end }
    items[#items + 1] = { text = _("Manage shortcuts…"), callback = function()
        UIManager:close(dialog)
        require("koassistant_ui/prompts_manager"):new(plugin):showInputActionsManager("highlight", function()
            UIManager:nextTick(function() UI.showChooser(plugin, captured, parent) end)
        end)
    end }
    local subtitle = sourceSummary(captured)
    if parent then
        local preview = require("koassistant_question_followup").prepare(parent, "Follow-up")
        subtitle = _("Answer") .. " #" .. parent.id .. " · " .. subtitle .. "\n" .. _("Same saved model; shortcut wording only")
            .. (preview and preview.followup.history_clipped and (" · " .. _("history shortened")) or "")
    end
    dialog = Menu:new{
        title = parent and _("Queue a follow-up") or _("Queue question"),
        subtitle = subtitle, item_table = items, is_popout = true,
        title_bar_left_icon = "info", onLeftButtonTap = function()
            errorMessage(parent and require("koassistant_question_followup").describe(require("koassistant_question_followup").prepare(parent, "Follow-up") or {})
                or _("Choose a shortcut to queue once. Recent questions open an editor with this source. Saved shortcuts share KOAssistant’s highlight action order. Actions requiring live book extraction are unavailable here."))
        end,
    }
    UIManager:show(dialog)
end


local function source(job)
    local doc = job.document or {}
    return location(job) .. " · " .. (doc.title or doc.file or "")
end

function UI.showAnswer(plugin, job)
    local queue = Runtime.get(plugin)
    local loaded, err = queue:get(job.id)
    if not loaded then errorMessage(err or _("Question no longer exists.")); return end
    job = loaded
    queue:markRead(job.id)
    local viewer
    local features = plugin.settings:readSetting("features") or {}
    viewer = require("koassistant_chatgptviewer"):new{
        saved_answer_view = true,
        settings_callback = function(key, value)
            local feature = key:match("^features%.(.+)$")
            if feature ~= "markdown_font_size" and feature ~= "text_align" and feature ~= "chat_window_size" then return end
            local saved = plugin.settings:readSetting("features") or {}
            saved[feature] = value
            plugin.settings:saveSetting("features", saved)
            plugin.settings:flush()
        end,
        title = short(label(job), 48) .. "\n" .. short(source(job), 64),
        title_multilines = true,
        text = job.answer,
        configuration = { features = { render_markdown = true, render_math = true,
            auto_save_all_chats = false, auto_save_chats = false,
            markdown_font_size = features.markdown_font_size, text_align = features.text_align } },
        add_default_buttons = false,
        buttons_table = {
          {{ text = _("Ask a follow-up…"), callback = function()
              viewer:onClose(); UI.showChooser(plugin, job, job)
          end }},
          {
            { text = _("Copy answer"), callback = function()
                require("device").input.setClipboardText(job.answer)
                UIManager:show(require("ui/widget/notification"):new{ text = _("Answer copied"), timeout = 2 })
            end },
            { text = _("Text / Math"), callback = function() viewer:toggleMarkdown() end },
          },
          {
            { text = _("Back to inbox"), callback = function() viewer:onClose(); UI.showInbox(plugin) end },
            { text = _("Close"), callback = function() viewer:onClose() end },
          },
        },
    }
    UIManager:show(viewer)
end

function UI.showJob(plugin, id)
    local queue = Runtime.get(plugin)
    local job, err = queue:get(id, true)
    if not job then errorMessage(err or _("Question no longer exists.")); return end
    local dialog
    local buttons = {}
    if job.state == "completed" then
        buttons[#buttons + 1] = {{ text = _("Read answer"), callback = function()
            UIManager:close(dialog); UI.showAnswer(plugin, job)
        end }}
    end
    if job.state == "queued" or job.state == "running" then
        buttons[#buttons + 1] = {{ text = _("Cancel request"), callback = function()
            local ok, err = queue:cancel(id)
            UIManager:close(dialog)
            if not ok and err then errorMessage(err) end
            UI.showInbox(plugin)
        end }}
    elseif job.state ~= "completed" then
        buttons[#buttons + 1] = {{ text = _("Retry explicitly…"), callback = function()
            UIManager:close(dialog)
            UIManager:show(require("ui/widget/confirmbox"):new{
                text = _("Submit this question again? A previous attempt may already have been processed and billed. Retrying starts a new request."),
                ok_text = _("Retry"), ok_callback = function()
                    local ok, err = queue:retry(id)
                    if not ok then errorMessage(err) end
                    UI.showInbox(plugin)
                end,
            })
        end }}
    end
    buttons[#buttons + 1] = {{ text = _("View saved question"), callback = function()
        local loaded, err = queue:get(id)
        if not loaded then errorMessage(err); return end
        job = loaded
        UIManager:close(dialog)
        UIManager:show(require("ui/widget/textviewer"):new{
            title = source(job),
            text = (job.label or "Question") .. "\n\n" .. (job.prompt or "") .. "\n\n" .. (job.selected_text or "")
                .. (job.parent_id and ("\n\nFollow-up to answer #" .. job.parent_id .. "\n" .. require("koassistant_question_followup").describe(job)) or "")
                .. (job.document.captured_at and ("\n\nSource captured: " .. os.date("%Y-%m-%d %H:%M:%S", job.document.captured_at)) or ""),
        })
    end }}
    if job.state ~= "queued" and job.state ~= "running" then
        buttons[#buttons + 1] = {{ text = _("Remove from inbox…"), callback = function()
            UIManager:close(dialog)
            UIManager:show(require("ui/widget/confirmbox"):new{
                text = _("Remove this inbox entry, its answer and its image copy? Existing follow-ups keep their own saved source and history."),
                ok_text = _("Remove"), ok_callback = function()
                    local ok, err = queue:remove(id)
                    UI.showInbox(plugin)
                    if not ok then errorMessage(err) end
                end,
            })
        end }}
    end
    buttons[#buttons + 1] = {
        { text = _("Back to inbox"), callback = function() UIManager:close(dialog); UI.showInbox(plugin) end },
        { text = _("Close"), callback = function() UIManager:close(dialog) end },
    }
    dialog = ButtonDialog:new{
        title = source(job) .. "\n" .. label(job) .. " · " .. stateLabel(job) .. "\n"
            .. tostring(job.config.provider) .. " / " .. tostring(job.config.model)
            .. (job.error and "\n\n" .. job.error or ""),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function UI.showInbox(plugin)
    local queue = Runtime.get(plugin)
    if queue.load_error then errorMessage(queue.storage_error); return end
    local dialog
    local items = {{ text = _("Refresh inbox"), callback = function()
        UIManager:close(dialog); UI.showInbox(plugin)
    end }}
    if queue.storage_error then
        items[#items + 1] = { text = _("Save failed · answers below are still readable"), callback = function()
            errorMessage(queue.storage_error)
        end }
        items[#items + 1] = { text = _("Retry saving inbox (no new request)"), callback = function()
            local ok, err = queue:retrySave()
            UIManager:close(dialog)
            UI.showInbox(plugin)
            if not ok then errorMessage(err) end
        end }
    end
    for i = #queue.jobs, 1, -1 do
        local job = queue.jobs[i]
        local id = job.id
        items[#items + 1] = {
            text = short(label(job), 26) .. "\n" .. location(job) .. " · "
                .. (job.parent_id and (_("Follow-up to") .. " #" .. job.parent_id)
                    or job.image and (_("Image") .. " #" .. job.id)
                    or short(job.selected_text or job.source_preview, 24)) .. " · " .. short(job.document.title, 18),
            mandatory = stateLabel(job),
            bold = job.state == "completed" and not job.read,
            callback = function()
                UIManager:close(dialog)
                if job.state == "completed" then UI.showAnswer(plugin, job) else UI.showJob(plugin, id) end
            end,
            hold_callback = function() UIManager:close(dialog); UI.showJob(plugin, id) end,
        }
    end
    if #queue.jobs == 0 then items[#items + 1] = { text = _("Select text → Queue question\nOr queue a PDF region / whole page from the KOAssistant menu"), enabled = false } end
    dialog = Menu:new{ title = _("AI answer inbox"), subtitle = Runtime.badge(), item_table = items, is_popout = true,
        items_max_lines = 2, items_font_size = 20, title_bar_left_icon = "info",
        onLeftButtonTap = function() errorMessage(_("Tap a ready answer to read it. Hold any question for details, retry or removal. Close returns to reading.")) end }
    UIManager:show(dialog)
end

return UI
