-- Immutable request snapshots, with an explicit credential-free persistence schema.
local Payload = {}

local function plain(value)
    local kind = type(value)
    if kind == "string" or kind == "boolean" then return value end
    if kind == "number" and value == value and math.abs(value) ~= math.huge then return value end
    if kind ~= "table" then return nil end
    local out = {}
    for k, v in pairs(value) do
        if type(k) == "string" or type(k) == "number" then out[k] = plain(v) end
    end
    return out
end
Payload.plain = plain

-- Do not serialize the global features table: it can contain keys and unrelated
-- private attachments. Preserve only transport settings needed by this request.
local feature_keys = {
    "provider", "enable_web_search", "web_search_effort", "enable_prompt_caching",
    "anthropic_api_version", "gemini_safety", "qwen_region", "kimi_region", "zai_region",
    "ollama_endpoints", "ollama_context_size", "request_timeout", "connect_timeout",
}
function Payload.config(config)
    local snapshot = {}
    for _, key in ipairs({ "provider", "model", "base_url", "system", "api_params", "enable_web_search" }) do
        snapshot[key] = plain(config[key])
    end
    snapshot.features = {}
    for _, key in ipairs(feature_keys) do snapshot.features[key] = plain((config.features or {})[key]) end
    -- Only the selected provider's URL/model are needed from legacy configuration.
    local ps = config.provider_settings and config.provider_settings[config.provider]
    if ps then
        snapshot.provider_settings = { [config.provider] = { model = ps.model, base_url = ps.base_url } }
    end
    local providers = config.features and config.features.custom_providers or {}
    for _, provider in ipairs(providers) do
        if provider.id == config.provider then
            snapshot.custom_provider = {
                id = provider.id, name = provider.name, base_url = provider.base_url,
                api_key_required = provider.api_key_required, model = provider.model,
            }
            break
        end
    end
    -- Resolve the exact model now; changing global preferences cannot retarget jobs.
    snapshot.model = require("koassistant_config_helper"):getModelInfo(config)
    return snapshot
end

function Payload.capture(ui, selection)
    local document = ui and ui.document
    if not document then return nil, "Open a document before queuing a question." end
    local props = ui.doc_props or {}
    local info = require("koassistant_notebook").getPageInfo(ui)
    -- Continuous PDF views can show the next page while their footer still
    -- names the previous one. The selection's own positions are authoritative.
    local start_page = selection and type(selection.pos0) == "table" and selection.pos0.page
    local end_page = selection and type(selection.pos1) == "table" and selection.pos1.page
    if type(start_page) == "number" then
        info.page = start_page
        info.chapter = ui.toc and ui.toc:getTocTitleByPage(start_page) or info.chapter
    end
    local attrs = require("libs/libkoreader-lfs").attributes(document.file) or {}
    return {
        selected_text = selection and selection.text or "",
        document = {
            file = document.file, title = props.display_title or props.title or document.file:match("[^/]+$"),
            authors = props.authors, size = attrs.size, modified = attrs.modification,
            page = info.page, end_page = end_page, total_pages = info.total_pages, chapter = info.chapter,
            captured_at = os.time(), capture_kind = "text_selection",
            pos0 = plain(selection and selection.pos0), pos1 = plain(selection and selection.pos1),
        },
    }
end

function Payload.prepare(plugin, captured, action)
    plugin:ensureInitialized()
    plugin:updateConfigFromSettings()
    local copy = require("koassistant_config_helper"):deepCopy(plugin.configuration)
    plugin:_scrubContextFeatures(copy.features)
    -- This local-only path lets the ordinary config builder apply per-book
    -- language, behavior/background and other overrides. It is not serialized.
    copy.features.book_metadata = { file = captured.document.file }
    local BookSettings = require("koassistant_book_settings")
    local doc_settings = require("koassistant_doc_settings").resolve(captured.document.file, plugin.ui)
    local domain_context
    if not action.skip_domain then
        local domain_id = action.domain or BookSettings.resolveDomain(doc_settings, copy.features)
        if domain_id then
            local domain = require("domain_loader").getDomainById(domain_id, copy.features.custom_domains or {})
            domain_context = domain and domain.context
        end
    end
    local config = require("koassistant_dialogs").prepareQueuedConfig(action, copy, plugin, domain_context)
    local features = config.features or {}
    local ai_title, ai_author = BookSettings.getMetadataOverride(doc_settings)
    local book_title = ai_title ~= nil and ai_title or captured.document.title
    local book_author = ai_author ~= nil and ai_author or captured.document.authors
    local stats_allowed = features.enable_basic_stats ~= false
    if not stats_allowed then
        for _, provider in ipairs(features.trusted_providers or {}) do
            if provider == config.provider then stats_allowed = true; break end
        end
    end
    local message = require("message_builder").build{
        prompt = action, context = "highlight", using_new_format = true,
        data = {
            highlighted_text = captured.selected_text,
            book_title = book_title, book_author = book_author,
            book_metadata = { title = book_title, author = book_author },
            _book_info_level = BookSettings.resolveBookInfoLevel(doc_settings, features),
            page_number = stats_allowed and tostring(captured.document.page or "") or nil,
            translation_language = features.translation_language or features.translate_to or "English",
            dictionary_language = features.dictionary_language or "English",
            response_language = features.primary_language or "English",
        },
    }
    local result = plain(captured)
    result.label = action.text or action.name or "Question"
    result.prompt = action.prompt or action.template or result.label
    result.action_id = action.id
    result.config = Payload.config(config)
    result.messages = {{ role = "user", content = message }}
    if captured.image then
        local Vision = require("koassistant_question_vision")
        if not Vision.supported(result.config.provider, result.config.model) then
            error(Vision.unsupportedMessage(result.config.provider, result.config.model))
        end
        -- Native web/tool routes have different image envelopes. Region questions
        -- are intentionally a single vision call without tools or web search.
        result.config.enable_web_search = false
        result.config.features.enable_web_search = false
        local image_scope = captured.document.capture_kind == "whole_page" and "the whole original document page" or "a selected region of a document page"
        result.messages = { Vision.message(result.config.provider,
            "The attached image is " .. image_scope .. ". Read its text, diagrams and mathematical notation carefully.\n"
                .. message, captured.image) }
        result.image = { mime_type = captured.image.mime_type, width = captured.image.width, height = captured.image.height }
    end
    -- Freeze the ordinary request's spoiler/privacy nudge now, while the source
    -- reader is still current. The queued transport must never re-read later pages.
    local spoiler_line = require("koassistant_book_tool_runner")._liveSpoilerLine(config, plugin.ui)
    if spoiler_line then
        result.messages[#result.messages + 1] = { role = "user", content = spoiler_line, is_context = true }
    end
    return result
end

function Payload.eligible(action)
    -- Actions needing live document extraction/tool rounds are intentionally left
    -- in Chat/Action. A queued job must depend only on its frozen selection.
    if action.local_handler or action.hidden or action.tools or action.smart_retrieval then return false end
    if action.requires and next(action.requires) then return false end
    for _, flag in ipairs({ "use_book_text", "use_highlights", "use_annotations", "use_notebook", "use_page_text",
            "use_reading_stats", "use_reading_progress", "use_library", "use_advanced_stats", "source_selection" }) do
        if action[flag] then return false end
    end
    if not action.prompt and not action.template then return false end
    return true
end

return Payload
