-- Multimodal request conversion for supported vision providers. OpenAI and
-- OpenAI Subscription share a saved-message shape; the Responses request
-- builder adapts it to input_text/input_image when it goes on the wire.
local Vision = {}
function Vision.supported(provider, model)
    model = tostring(model or ""):lower()
    if provider == "openai" or provider == "openai_codex" then
        return model:match("^gpt%-4o") ~= nil or model:match("^gpt%-4%.1") ~= nil
            or model:match("^gpt%-5") ~= nil or model:match("^gpt%-6") ~= nil
    elseif provider == "anthropic" then
        return model:match("^claude%-3") ~= nil or model:match("^claude%-sonnet%-4") ~= nil
            or model:match("^claude%-opus%-4") ~= nil or model:match("^claude%-haiku%-4") ~= nil
    elseif provider == "gemini" then
        return model:match("^gemini%-1%.5") ~= nil or model:match("^gemini%-2") ~= nil
            or model:match("^gemini%-3") ~= nil
    end
    return false
end

function Vision.unsupportedMessage(provider, model)
    return "The selected model (" .. tostring(provider or "unknown provider") .. " / " .. tostring(model or "unknown model")
        .. ") is not supported for image questions. Choose an image-capable OpenAI or OpenAI Subscription (GPT-4o/4.1/5/6), Anthropic (Claude 3/4), or Gemini (1.5/2/3) model in KOAssistant settings. No image was sent."
end

function Vision.message(provider, text, image)
    assert(type(image.data) == "string" and #image.data > 0, "Missing source image")
    local mime = image.mime_type or "image/png"
    if provider == "anthropic" then
        return { role = "user", content = {
            { type = "image", source = { type = "base64", media_type = mime, data = image.data } },
            { type = "text", text = text },
        }}
    elseif provider == "gemini" then
        return { role = "user", content = text, parts = {
            { inline_data = { mime_type = mime, data = image.data } }, { text = text },
        }}
    elseif provider == "openai" or provider == "openai_codex" then
        return { role = "user", content = {
            { type = "text", text = text },
            { type = "image_url", image_url = { url = "data:" .. mime .. ";base64," .. image.data, detail = "high" } },
        }}
    end
    error("Image questions require a supported vision provider")
end
return Vision
