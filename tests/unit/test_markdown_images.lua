local script=debug.getinfo(1,"S").source:sub(2)
local root=script:match("^(.*)/tests/unit/") or "."
package.path=root.."/?.lua;"..root.."/tests/lib/?.lua;"..package.path
local T=require("test_runner"):new()
local M=require("koassistant_markdown_images")
local function tag(payload)
    return '<img class="koa-math-image" src="data:image/png;base64,'..payload..'" width="72" height="31" alt="Typeset formula" style="vertical-align: middle;"/>'
end
T:test("large PNG data never reaches Markdown conversion",function()
    local image=tag(("Ab01+/="):rep(12000))
    local source="Before "..image.." after"
    local options={test=true}
    local html=M.convert(source,function(input,opts)
        T:assertTrue(#input<100)
        T:assertTrue(not input:find("data:image",1,true))
        T:assertEqual(opts,options)
        return "<p>"..input.."</p>"
    end,options)
    T:assertEqual(html,"<p>"..source.."</p>")
end)
T:test("multiple inline and display image tags are restored byte-for-byte",function()
    local source="Before "..tag("Abc=").." after\n\n<div class=\"koa-math-display\">"..tag("DeF+").."</div>"
    T:assertEqual(M.convert(source,function(input)return input end),source)
end)
T:test("existing placeholder-looking text is never replaced",function()
    local source="KOAMATHIMAGEPLACEHOLDER1END KOAMATHIMAGEPLACEHOLDERX2END "..tag("Abc=")
    T:assertEqual(M.convert(source,function(input)return input end),source)
end)
T:test("ordinary content and options pass through untouched",function()
    local source="**Bold** and $raw$";local options={}
    T:assertEqual(M.convert(source,function(input,opts)
        T:assertEqual(input,source);T:assertEqual(opts,options);return "<b>Bold</b>"
    end,options),"<b>Bold</b>")
end)
T:test("other HTML and image sources stay under ordinary Markdown semantics",function()
    local source='<img src="picture.png"/><img class="koa-math-image" src="https://example.com/image.png"/>'
    T:assertEqual(M.convert(source,function(input)T:assertEqual(input,source);return input end),source)
end)
T:test("converter errors retain their original contract",function()
    local html,err=M.convert(tag("Abc="),function()return nil,"parse failed" end)
    T:assertEqual(html,nil);T:assertEqual(err,"parse failed")
end)
T:test("empty math image payload does not consume following source",function()
    local source=tag("").." after "..tag("QwE=")
    T:assertEqual(M.convert(source,function(input)return input end),source)
end)
return T:summary()
