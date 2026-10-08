-- Whole native document page capture. Deliberately bypasses the reader viewport,
-- crop, reflow, contrast and zoom: the snapshot always includes the original page.
local Page = { MAX_EDGE = 1800 }

function Page.capture(ui, deps)
    deps = deps or {}
    local document = ui and ui.document
    if not document or not document.info or not document.info.has_pages or not document._document then
        return nil, "Open a PDF/page-based document first."
    end
    local captured, err = (deps.capture or require("koassistant_question_payload").capture)(ui)
    if not captured then return nil, err end
    local number = captured.document.page
    if type(number) ~= "number" or number < 1 or number % 1 ~= 0 then
        return nil, "Could not identify the current document page."
    end
    local BB = deps.BB or require("ffi/blitbuffer")
    local DC = deps.DC or require("ffi/drawcontext")
    local page, buffer
    local ok, image, encode_err = pcall(function()
        page = document._document:openPage(number)
        local dc = DC.new()
        dc:setRotate(0); dc:setZoom(1); dc:setOffset(0, 0)
        dc:setGamma(1); dc:setSaturation(1); dc:setBackgroundCleanup(false)
        local width, height = page:getSize(dc)
        assert(type(width) == "number" and type(height) == "number"
            and width > 0 and height > 0 and width < math.huge and height < math.huge,
            "Could not read original page dimensions.")
        local zoom = Page.MAX_EDGE / math.max(width, height)
        dc:setZoom(zoom)
        local w = math.min(Page.MAX_EDGE, math.max(1, math.ceil(width * zoom)))
        local h = math.min(Page.MAX_EDGE, math.max(1, math.ceil(height * zoom)))
        buffer = BB.new(w, h, document.color_bb_type or BB.TYPE_BBRGB32)
        buffer:fill(BB.COLOR_WHITE)
        page:draw(dc, buffer, 0, 0, document.render_mode)
        captured.document.capture_kind = "whole_page"
        captured.document.native_width, captured.document.native_height = width, height
        captured.document.capture_zoom, captured.document.capture_rotation = zoom, 0
        captured.document.page, captured.document.end_page = number, number
        captured.document.captured_at = (deps.now or os.time)()
        captured.document.page_basis = "reader_current_page"
        captured.selected_text = ""
        return (deps.encode or require("koassistant_question_region").encode)(buffer)
    end)
    if page then pcall(page.close, page) end
    if buffer then pcall(buffer.free, buffer) end
    if not ok then return nil, tostring(image) end
    if not image then return nil, encode_err end
    captured.image = image
    return captured
end

function Page.show(plugin)
    local captured, err = Page.capture(plugin.ui)
    if not captured then
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{ text = tostring(err) })
        return
    end
    require("koassistant_question_ui").showChooser(plugin, captured)
end

return Page
