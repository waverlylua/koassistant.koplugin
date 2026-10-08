-- Offline 2-D math renderer. Uses KOReader's bundled FreeType fonts, BlitBuffer
-- and liblodepng; no TeX executable, browser, network or equation temp files.
local Math = require("koassistant_math")
local Layout = require("koassistant_math_layout")
local M = {}
local cache, order, bytes = {}, {}, 0
local function escape(source)
    return (source:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;")
        :gsub("_","&#95;"):gsub("%*","&#42;"):gsub("%[","&#91;"):gsub("%]","&#93;")
        :gsub("\\","&#92;"):gsub("%$","&#36;"))
end
local function fallback(source,reason,display)
    local label="Math source ("..escape(reason).."): "
    -- This is deliberately source, not a plausible but incomplete formula.
    -- Original stored text, Text mode and Copy are never transformed.
    local body=escape(source):gsub("\n","<br/>")
    return '<span class="koa-math-fallback">'..label..'<code>'..body..'</code></span>'
end
local function dependencies()
    local ffi=require("ffi")
    require("ffi/lodepng_h"); require("ffi/posix_h")
    return ffi,require("ffi/blitbuffer"),require("ui/font"),require("ui/rendertext"),
        require("device").screen,ffi.loadlib("lodepng")
end
local function encodePNG(ffi,png,buffer,width,height)
    local state=ffi.new("LodePNGState[1]"); png.lodepng_state_init(state)
    state[0].info_raw.colortype=png.LCT_GREY; state[0].info_raw.bitdepth=8
    state[0].info_png.color.colortype=png.LCT_GREY; state[0].info_png.color.bitdepth=8
    local output=ffi.new("unsigned char*[1]");local length=ffi.new("size_t[1]")
    local err=png.lodepng_encode(output,length,ffi.cast("const unsigned char*",buffer.data),width,height,state)
    png.lodepng_state_cleanup(state)
    if err~=0 then if output[0]~=nil then ffi.C.free(output[0]) end;error("PNG encoding failed: "..tostring(err)) end
    local data=ffi.string(output[0],length[0]);ffi.C.free(output[0]);return data
end
local function rasterize(ast,display,size,max_width,max_height)
    local ffi,BB,Font,RenderText,Screen,png=dependencies()
    local dpi=Screen:scaleBySize(100)/100
    local scale=2 -- supersampling keeps fraction bars/fences smooth on e-ink
    local fontnames={roman="NotoSerif-Regular.ttf",italic="NotoSerif-Italic.ttf",
        bold="NotoSerif-Bold.ttf",bolditalic="NotoSerif-BoldItalic.ttf",mono="DroidSansMono.ttf"}
    local function face(sz,style)
        -- TeX stops reducing script glyphs at its smallest style. Keep deeply
        -- nested input legible too; large resulting boxes fall back explicitly.
        return assert(Font:getFace(fontnames[style] or fontnames.roman,math.max(sz,size*scale*.5)/dpi))
    end
    local function measure(str,sz,style)
        local f=face(sz,style);local metric=RenderText:sizeUtf8Text(0,nil,f,str,true)
        return metric.x,metric.y_top,metric.y_bottom
    end
    local padding=4*scale
    local content_width=max_width*scale-padding*2
    local value,err=Layout.layout(ast,size*scale,display,measure,content_width)
    if not value then return nil,err end
    -- Reflow display math at safe top-level breaks before reducing its size.
    -- At most a small reduction; never silently make a wide derivation tiny.
    if value.w>content_width then
        local ratio=math.max(.85,content_width/math.max(1,value.w))
        value,err=Layout.layout(ast,size*scale*ratio,display,measure,content_width)
        if not value then return nil,err end
        if value.w>content_width then return nil,"expression is too wide; use Text mode or split it into aligned lines" end
    end
    local width=math.max(1,math.ceil(value.w+padding*2))
    local height=math.max(1,math.ceil(value.h+value.d+padding*2))
    if width>max_width*scale or height>max_height*scale or width*height>4000000 then
        return nil,"expression is too tall or large for this view; use Text mode"
    end
    local buffer=BB.new(width,height,BB.TYPE_BB8,nil,width,width)
    local ok,data=pcall(function()
        buffer:fill(BB.COLOR_WHITE)
        local function line(coords,ox,oy)
            local x1,y1,x2,y2,weight=unpack(coords)
            x1=x1+ox;y1=y1+oy;x2=x2+ox;y2=y2+oy
            local steps=math.max(1,math.ceil(math.max(math.abs(x2-x1),math.abs(y2-y1))))
            local thick=math.max(1,math.floor(weight+.5))
            for i=0,steps do
                buffer:paintRect(math.floor(x1+(x2-x1)*i/steps-thick/2+.5),
                    math.floor(y1+(y2-y1)*i/steps-thick/2+.5),thick,thick,BB.COLOR_BLACK)
            end
        end
        local function draw(b,x,y)
            if b.text then RenderText:renderUtf8Text(buffer,math.floor(x+.5),math.floor(y+.5),face(b.size,b.style),b.text,true) end
            for _,item in ipairs(b.items) do
                if item.box then draw(item.box,x+item.x,y+item.y) else line(item.line,x,y) end
            end
        end
        draw(value,padding,padding+value.h)
        return encodePNG(ffi,png,buffer,width,height)
    end)
    buffer:free()
    if not ok then return nil,"local renderer unavailable" end
    return {png=data,width=math.ceil(width/scale),height=math.ceil(height/scale),ascent=(value.h+padding)/scale,descent=(value.d+padding)/scale}
end
-- Public for native pixel-level tests. Errors are values and never lose source.
function M.renderFormula(source,display,options)
    options=options or {};local size=options.font_size or 20
    local ast,err=Layout.parse(source)
    if not ast then return nil,err end
    local ok,result,reason=pcall(rasterize,ast,display,size,options.max_width or 540,options.max_height or 600)
    if not ok then return nil,"local math rendering is unavailable" end
    return result,reason
end
function M.render(text,options)
    options=options or {}
    local rendered_count=0
    return Math.render(text,function(source,display)
        rendered_count=rendered_count+1
        if rendered_count>160 then return fallback(source,"too many formulas in one answer",display) end
        local key=table.concat({options.font_size or 20,options.max_width or 540,options.max_height or 600,display and 1 or 0,source},"|")
        if cache[key] then return cache[key] end
        local result,reason=M.renderFormula(source,display,options)
        if not result then return fallback(source,reason or "unsupported notation",display) end
        local encoded=require("mime").b64(result.png)
        local html=string.format('<img class="koa-math-image" src="data:image/png;base64,%s" width="%d" height="%d" alt="Typeset formula" style="vertical-align: middle;"/>',encoded,result.width,result.height)
        -- Bound session memory. Nothing is written to disk or sent off-device.
        while #order>=64 or bytes+#html>4*1024*1024 do
            if #order==0 then break end
            local old=table.remove(order,1);bytes=bytes-#cache[old];cache[old]=nil
        end
        cache[key]=html;order[#order+1]=key;bytes=bytes+#html
        return html
    end)
end
return M
