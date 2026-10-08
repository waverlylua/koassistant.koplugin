-- Two-corner capture of the displayed PDF page. The backing image is frozen BEFORE
-- any selector/help UI is painted, so controls never leak into the provider image.
local Region = {}
local _ = require("koassistant_gettext")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local BB = require("ffi/blitbuffer")

function Region.crop(source, rect)
    local x = math.max(0, math.floor(rect.x))
    local y = math.max(0, math.floor(rect.y))
    local w = math.min(math.floor(rect.w), source:getWidth() - x)
    local h = math.min(math.floor(rect.h), source:getHeight() - y)
    assert(w >= 16 and h >= 16, "Select a larger region (at least 16 × 16 pixels).")
    -- blit into an independent tightly-owned buffer; viewport:copy can include
    -- source stride padding outside the requested crop on some BB formats.
    local result = BB.new(w, h, BB.TYPE_BBRGB32)
    result:blitFrom(source, 0, 0, x, y, w, h)
    return result, { x = x, y = y, w = w, h = h }
end

function Region.encode(buffer)
    local path = require("datastorage"):getSettingsDir() .. "/koassistant_region.tmp.png"
    -- KOReader's BB.writePNG ignores encoder failure returns. Never let an old
    -- crash-leftover file masquerade as this capture when the next write fails.
    local lfs = require("libs/libkoreader-lfs")
    if lfs.symlinkattributes(path) then
        local removed, remove_err = os.remove(path)
        if not removed then return nil, "Could not clear previous image capture: " .. tostring(remove_err) end
    end
    local ok, err = pcall(buffer.writePNG, buffer, path)
    if not ok then os.remove(path); return nil, tostring(err) end
    local file = io.open(path, "rb")
    if not file then return nil, "Could not read captured region" end
    local bytes = file:read("*a"); file:close(); os.remove(path)
    if not bytes or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil, "Image encoding failed; no region was queued." end
    if #bytes > 4 * 1024 * 1024 then return nil, "Region image is too large (4 MiB maximum). Select a smaller region." end
    return { data = require("mime").b64(bytes), mime_type = "image/png", width = buffer:getWidth(), height = buffer:getHeight() }
end

function Region.show(plugin)
    local ui = plugin.ui
    if not ui or not ui.document or not ui.document.info.has_pages then
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("Open a PDF/page-based document first.") })
        return
    end
    local captured, capture_err = require("koassistant_question_payload").capture(ui)
    if not captured then error(capture_err) end
    local width, height = Screen:getWidth(), Screen:getHeight()
    local frozen = BB.new(width, height, BB.TYPE_BBRGB32)
    frozen:fill(BB.COLOR_WHITE)
    -- Render only the reader's current view, never the open menu/other overlays.
    local runtime = require("koassistant_question_runtime")
    runtime.suppress_badge = true
    local footer_visible = ui.view.footer_visible
    ui.view.footer_visible = false
    local ok, err = pcall(ui.view.paintTo, ui.view, frozen, 0, 0)
    ui.view.footer_visible = footer_visible
    runtime.suppress_badge = nil
    if not ok then frozen:free(); error(err) end
    local InputContainer = require("ui/widget/container/inputcontainer")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    local Selector = InputContainer:extend{ modal = true, covers_fullscreen = true }
    function Selector:init()
        self.dimen = Geom:new{ x = 0, y = 0, w = width, h = height }
        self.ges_events = {
            Pick = { GestureRange:new{ ges = "tap", range = self.dimen } },
            Cancel = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
        self.key_events = { Cancel = {{ Device.input.group.Back }} }
        self.help = TextWidget:new{ text = _("Tap two opposite corners · Swipe/Back cancels"), face = Font:getFace("smallinfofont"), max_width = width - 10 }
    end
    function Selector:paintTo(bb, x, y)
        bb:blitFrom(frozen, x, y, 0, 0, width, height)
        local size = self.help:getSize()
        bb:paintRect(0, 0, width, size.h + 8, BB.COLOR_WHITE)
        self.help:paintTo(bb, 5, 4)
        if self.first then
            bb:paintRect(self.first.x - 6, self.first.y - 1, 12, 3, BB.COLOR_BLACK)
            bb:paintRect(self.first.x - 1, self.first.y - 6, 3, 12, BB.COLOR_BLACK)
        end
    end
    function Selector:onCancel()
        UIManager:close(self)
        return true
    end
    function Selector:onCloseWidget()
        if frozen then frozen:free(); frozen = nil end
        if self.help then self.help:free(); self.help = nil end
    end
    function Selector:onPick(_arg, ges)
        if not self.first then
            self.first = { x = ges.pos.x, y = ges.pos.y }
            UIManager:setDirty(self, "ui")
            return true
        end
        local rect = { x = math.min(self.first.x, ges.pos.x), y = math.min(self.first.y, ges.pos.y),
            w = math.abs(self.first.x - ges.pos.x), h = math.abs(self.first.y - ges.pos.y) }
        local crop_ok, cropped, bounds = pcall(Region.crop, frozen, rect)
        if not crop_ok then
            self.first = nil
            UIManager:show(require("ui/widget/infomessage"):new{ text = tostring(cropped), timeout = 2 })
            return true
        end
        local image, encode_err = Region.encode(cropped)
        cropped:free()
        if not image then
            UIManager:show(require("ui/widget/infomessage"):new{ text = encode_err }); return true
        end
        captured.image = image
        captured.document.capture_kind = "region"
        captured.document.region = bounds
        local first = ui.view:screenToPageTransform{ x = bounds.x, y = bounds.y }
        local last = ui.view:screenToPageTransform{ x = bounds.x + bounds.w - 1, y = bounds.y + bounds.h - 1 }
        if first and last and first.page and last.page then
            captured.document.page, captured.document.end_page = first.page, last.page
            captured.document.region_page_start, captured.document.region_page_end = first, last
        else
            -- If coordinates fall in a page gap, preserve an honest visible-page
            -- set instead of claiming the footer's single page as the whole image.
            captured.document.visible_pages = ui.view:getCurrentPageList()
            captured.document.page = nil
        end
        captured.document.screen_width, captured.document.screen_height = width, height
        captured.selected_text = ""
        UIManager:close(self)
        require("koassistant_question_ui").showChooser(plugin, captured)
        return true
    end
    UIManager:show(Selector:new{})
end
return Region
