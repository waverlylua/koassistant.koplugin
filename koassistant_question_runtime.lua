-- Session singleton: never owned by the selection dialog or current book.
local Runtime = {}
local queue
local settings

function Runtime.get(plugin)
    if plugin then settings = plugin.settings end
    if queue then return queue end
    local store = require("koassistant_question_store"):new(
        require("datastorage"):getDataDir() .. "/ai-inbox")
    local UIManager = require("ui/uimanager")
    queue = require("koassistant_question_queue"):new{
        load = function() return store:load() end,
        save = function(data) return store:save(data) end,
        prompt = function(job) return store:prompt(job) end,
        hydrate = function(job) return store:hydrate(job) end,
        now = os.time,
        schedule = function(callback) UIManager:scheduleIn(0.1, callback) end,
        start = function(job, finish, register_cancel)
            local config = job.config
            config.features = config.features or {}
            config.features.enable_streaming = false
            config.features._suppress_loading_dialog = true
            config.features._background_request = true
            config.features._no_auto_retry = true
            -- Install cancellation BEFORE OAuth refresh or other async preparation.
            local cancelled, transport_cancel = false, nil
            register_cancel(function()
                cancelled = true
                if transport_cancel then transport_cancel() end
            end)
            config._is_cancelled = function() return cancelled end
            config._register_cancel = function(cancel)
                transport_cancel = cancel
                if cancelled then cancel() end
            end
            config.conversation_id = "queued_" .. job.id .. "_" .. job.attempts
            -- Credentials stay in the live settings. The query router separately
            -- honors config.custom_provider's frozen destination, without a settings
            -- proxy (OAuth may legitimately save refreshed authentication there).
            require("koassistant_gpt_query").query(job.messages, config,
                function(ok, content, err, reasoning, _web, usage)
                    finish(ok, content, err, reasoning, usage)
                end, settings)
        end,
        changed = function()
            -- No modal, notification, or answer popup: refresh only the footer.
            local ok, ReaderUI = pcall(require, "apps/reader/readerui")
            local ui = ok and ReaderUI.instance
            if ui and ui.view then
                if ui.view.footer_visible and ui.view.footer then
                    ui.view.footer:onUpdateFooter(true)
                else
                    local screen = require("device").screen
                    UIManager:setDirty(ui, "ui", require("ui/geometry"):new{
                        x = 0, y = screen:getHeight() - 40, w = screen:getWidth(), h = 40,
                    })
                end
            end
        end,
    }
    return queue
end

-- Read only: checking update safety must not initialize or resume the queue.
function Runtime.isBusy()
    if not queue then return false end
    local counts = queue:counts()
    return counts.queued > 0 or counts.running > 0 or queue.storage_error ~= nil
end

function Runtime.badge()
    if not queue then return "" end
    local counts = queue:counts()
    local parts = {}
    local _ = require("koassistant_gettext")
    if counts.unread > 0 then parts[#parts + 1] = counts.unread .. " " .. _("ready") end
    local active = counts.queued + counts.running
    if active > 0 then parts[#parts + 1] = active .. " " .. _("pending") end
    local attention = counts.failed + counts.interrupted
    if attention > 0 then parts[#parts + 1] = attention .. " " .. _("need attention") end
    return #parts > 0 and "AI: " .. table.concat(parts, " · ") or ""
end

function Runtime.installFooter(ui)
    local view = ui and ui.view
    if not view or not view.registerViewModule or (view.view_modules and view.view_modules.koassistant_question_badge) then return end
    local footer = view.footer
    -- Append at render time rather than change the reader's selected footer mode.
    -- The footer's own layout fits this text inside its existing area, so the badge
    -- never covers a book line. Restore its generator even if rendering fails.
    if footer and footer._updateFooterText then
        local original_update = footer._updateFooterText
        footer._updateFooterText = function(self, ...)
            local original_generator = self.genFooterText
            self.genFooterText = function(instance)
                local text, merge = original_generator(instance)
                local summary = not Runtime.suppress_badge and Runtime.badge() or ""
                if summary ~= "" then text = (text and text ~= "" and text .. " | " or "") .. summary end
                return text, merge
            end
            local ok, result = pcall(original_update, self, ...)
            self.genFooterText = original_generator
            if not ok then error(result) end
            return result
        end
        if footer.updateFooterText == original_update then footer.updateFooterText = footer._updateFooterText end
    end
    -- Hidden-footer fallback. This paint-only widget never consumes page taps.
    local Widget = require("ui/widget/widget")
    local badge = Widget:extend{}
    function badge:paintTo(bb, x, y)
        if self.view.footer_visible then return end
        local text = not Runtime.suppress_badge and Runtime.badge() or ""
        if text == "" then return end
        local widget = require("ui/widget/textwidget"):new{
            text = text, face = require("ui/font"):getFace("cfont", 14),
        }
        local size = widget:getSize()
        local screen = require("device").screen
        local left = x + screen:getWidth() - size.w - 8
        local top = y + screen:getHeight() - size.h - 8
        bb:paintRect(left - 3, top - 2, size.w + 6, size.h + 4, require("ffi/blitbuffer").COLOR_WHITE)
        widget:paintTo(bb, left, top)
        widget:free()
    end
    view:registerViewModule("koassistant_question_badge", badge:new{})
    if footer then footer:onUpdateFooter(true) end
end

return Runtime
