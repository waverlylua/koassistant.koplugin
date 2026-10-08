-- Keep locally generated PNG payloads out of the Markdown parser. luamd scans
-- raw HTML attributes as Markdown too: an ordinary 75 KB math answer can take
-- several seconds to parse, on EVERY open despite cached formula PNGs. Short
-- text tokens preserve the surrounding inline/block structure, then the exact
-- image tags are restored for MuPDF after Markdown conversion.
local M = {}

function M.convert(text, converter, options)
    if type(text) ~= "string" or not text:find('class="koa-math-image"', 1, true) then
        return converter(text, options)
    end
    -- Never replace a coincidentally matching token in the original answer.
    local prefix = "KOAMATHIMAGEPLACEHOLDER"
    while text:find(prefix, 1, true) do prefix = prefix .. "X" end
    local images = {}
    local protected = text:gsub('<img class="koa%-math%-image" src="data:image/png;base64,[A-Za-z0-9+/=]+"[^>]*>', function(tag)
        images[#images + 1] = tag
        return prefix .. #images .. "END"
    end)
    local html, err = converter(protected, options)
    if type(html) == "string" and #images > 0 then
        html = html:gsub(prefix .. "(%d+)END", function(index)
            return images[tonumber(index)] or prefix .. index .. "END"
        end)
    end
    return html, err
end

return M
