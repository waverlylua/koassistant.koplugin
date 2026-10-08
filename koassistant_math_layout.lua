-- Strict, bounded LaTeX subset parser and two-dimensional mathematical layout.
-- No device, network, subprocess, filesystem or third-party typesetting engine.
-- Dimensions are pixels. A box has width w, ascent h and descent d; every child
-- position is relative to its parent's baseline. Unsupported syntax fails the
-- whole expression instead of silently changing its mathematical meaning.
local Lex = require("koassistant_math")
local M = {}
local UTF8 = "[\1-\127\194-\244][\128-\191]*"
local function fail(reason) error(reason, 0) end
local function tokenize(s)
    if #s > 12000 then fail("expression is too long") end
    local out, p = {}, 1
    while p <= #s do
        local ch = s:sub(p,p)
        if ch == "\\" then
            local name = s:match("^%a+", p+1) or s:sub(p+1,p+1)
            if name == "" then fail("unfinished command") end
            out[#out+1] = { t = "cmd", v = name }; p = p + #name + 1
        elseif ch:match("%s") then
            local ws = s:match("^%s+",p)
            out[#out+1] = { t = "ws", v = " " }; p = p + #ws
        else
            local value = s:match("^"..UTF8,p) or ch
            out[#out+1] = { t = ch, v = value }; p = p + #value
        end
        if #out > 4000 then fail("expression has too many tokens") end
    end
    return out
end
local P = {}; P.__index = P
function P:peek() return self.tokens[self.i] end
function P:next() local t=self:peek(); self.i=self.i+1; return t end
function P:ws() while self:peek() and self:peek().t == "ws" do self:next() end end
function P:rawGroup()
    self:ws(); if not self:peek() or self:next().t ~= "{" then fail("expected a braced argument") end
    local out, depth = {}, 1
    while self:peek() do
        local t = self:next()
        if t.t == "{" then depth=depth+1 end
        if t.t == "}" then depth=depth-1; if depth==0 then return table.concat(out) end end
        out[#out+1] = t.t=="cmd" and ("\\"..t.v) or t.v
    end
    fail("unclosed argument")
end
local function text(s, style, class) return { kind="text", text=s, style=style, class=class } end
local operators = { sum=true, prod=true, coprod=true, bigcup=true, bigcap=true, bigoplus=true,
    bigotimes=true, bigvee=true, bigwedge=true }
local integrals = { int=true, iint=true, iiint=true, oint=true }
local limit_functions = { lim=true, liminf=true, limsup=true, max=true, min=true, sup=true, inf=true }
local environments = { matrix=true, pmatrix=true, bmatrix=true, Bmatrix=true, vmatrix=true,
    Vmatrix=true, smallmatrix=true, cases=true, aligned=true, align=true, ["align*"]=true,
    gathered=true, gather=true, ["gather*"]=true, split=true, equation=true, ["equation*"]=true,
    array=true }
local styles = { text="roman", textrm="roman", textnormal="roman", mbox="roman", mathrm="roman",
    operatorname="roman", mathit="italic", textit="italic", mathbf="bold", textbf="bold",
    boldsymbol="bolditalic", bm="bolditalic", mathsf="roman", mathtt="mono" }
local accents = { vec=true, hat=true, widehat=true, bar=true, overline=true, underline=true,
    dot=true, ddot=true, tilde=true, widetilde=true }
-- Explicit delimiter sizes are independent atoms in TeX: \bigl( and \bigr)
-- need not form a paired group, and scripts attach to the delimiter itself.
local delimiter_sizes = {}
for prefix, scale in pairs({big=1.2, Big=1.8, bigg=2.4, Bigg=3}) do
    for _, suffix in ipairs({"", "l", "r", "m"}) do delimiter_sizes[prefix..suffix]=scale end
end
local delimiters = { ["("]=true, [")"]=true, ["["]=true, ["]"]=true, ["{"]=true, ["}"]=true,
    ["|"]=true, ["‖"]=true, ["⟨"]=true, ["⟩"]=true, ["⌊"]=true, ["⌋"]=true,
    ["⌈"]=true, ["⌉"]=true, ["/"]=true, ["\\"]=true }
local padded_symbols = {}
for value in ("= + < > − ≤ ≥ ≈ ≠ → ∈ × · ± ≺ ≻ ⪯ ⪰ ≼ ≽ ⊀ ⊁ ⋠ ⋡ ⊂ ⊃ ⊆ ⊇ ≡ ∼ ≃ ≅ ∝ ⊥ ∥ ∣ ∤"):gmatch("%S+") do
    padded_symbols[value]=true
end
function P:arg(style)
    self.depth=self.depth+1
    if self.depth>48 then fail("expression nesting is too deep") end
    self:ws()
    if not self:peek() then fail("missing argument") end
    local node
    if self:peek().t=="{" then
        self:next(); node=self:sequence(style, "}")
        if not self:peek() or self:next().t~="}" then fail("unclosed group") end
    else
        node=self:atom(style)
    end
    self.depth=self.depth-1
    return node
end
function P:delimiter()
    self:ws(); local t=self:next()
    if not t then fail("missing delimiter") end
    local value=t.t=="cmd" and Lex.symbols[t.v] or t.v
    if value=="." then return "" end
    if value=="<" then value="⟨" elseif value==">" then value="⟩" end
    if not delimiters[value] then fail("unsupported delimiter") end
    return value
end
function P:environment(name, style)
    if not environments[name] then fail("unsupported environment: "..name) end
    local columns
    if name=="array" then
        columns=self:rawGroup()
        if not columns:match("^[lcr]+$") then fail("unsupported array column specification") end
    end
    local rows, row = {}, {}
    while true do
        row[#row+1]=self:sequence(style, "environment")
        if #row>24 then fail("matrix is too large") end
        local t=self:peek()
        if not t then fail("unclosed environment: "..name) end
        if t.t=="&" then self:next()
        elseif t.t=="cmd" and (t.v=="\\" or t.v=="cr" or t.v=="newline") then
            self:next(); rows[#rows+1]=row; row={}
            self:ws()
            if self:peek() and self:peek().t=="[" then fail("custom row spacing is not supported") end
        elseif t.t=="cmd" and t.v=="end" then
            self:next(); if self:rawGroup()~=name then fail("mismatched environment") end
            if #row>1 or #row[1].children>0 then rows[#rows+1]=row end
            if #rows>80 then fail("matrix is too large") end
            break
        else fail("invalid environment separator") end
        if #rows > 80 or #row > 24 then fail("matrix is too large") end
    end
    return { kind="grid", rows=rows, env=name, columns=columns }
end
function P:command(name, style)
    if name=="frac" or name=="dfrac" or name=="tfrac" or name=="cfrac" or name=="binom" or name=="dbinom" or name=="tbinom" then
        return { kind="fraction", top=self:arg(style), bottom=self:arg(style), binomial=name:find("binom",1,true)~=nil }
    elseif name=="sqrt" then
        self:ws(); local index
        if self:peek() and self:peek().t=="[" then
            self:next(); index=self:sequence(style,"]")
            if not self:peek() or self:next().t~="]" then fail("unclosed root index") end
        end
        return { kind="root", body=self:arg(style), index=index }
    elseif name=="left" then
        local left=self:delimiter(); local body=self:sequence(style,"right")
        local t=self:next(); if not t or t.t~="cmd" or t.v~="right" then fail("unclosed left/right delimiter") end
        return { kind="fence", left=left, right=self:delimiter(), body=body }
    elseif delimiter_sizes[name] then
        return {kind="delimiter",delimiter=self:delimiter(),scale=delimiter_sizes[name],
            class=name:sub(-1)=="m" and "relation" or nil}
    elseif name=="begin" then return self:environment(self:rawGroup(),style)
    elseif name=="pmod" then
        return {kind="row",children={{kind="space",em=.35}, {kind="fence",left="(",right=")",
            body={kind="row",children={text("mod", "roman", "function"),self:arg(style)}}}}}
    elseif name=="bmod" or name=="mod" then
        return {kind="row",children={{kind="space",em=.2},text("mod", "roman", "function"),{kind="space",em=.1}}}
    elseif styles[name] then
        self:ws()
        if name=="operatorname" and self:peek() and self:peek().t=="*" then
            self:next()
            return {kind="scripts",base=self:arg("roman"),limits=true}
        end
        return self:arg(styles[name])
    elseif name=="mathbb" or name=="mathcal" then
        local source=self:rawGroup(); local map=name=="mathbb" and Lex.blackboard or Lex.calligraphic
        local out={}
        for c in source:gmatch(UTF8) do
            if not map[c] then fail("unsupported "..name.." letter: "..c) end
            out[#out+1]=map[c]
        end
        return text(table.concat(out),"roman")
    elseif accents[name] then return { kind="accent", accent=name, body=self:arg(style) }
    elseif name=="overset" or name=="stackrel" or name=="underset" then
        local label=self:arg(style); local base=self:arg(style)
        return { kind="scripts", base=base, sup=name~="underset" and label or nil,
            sub=name=="underset" and label or nil, limits=true }
    elseif name=="label" then self:rawGroup(); return { kind="space", em=0 }
    elseif name=="tag" then
        return { kind="fence", left="(",right=")", body=self:arg("roman") }
    elseif name=="displaystyle" or name=="textstyle" or name=="scriptstyle" or name=="scriptscriptstyle"
        or name=="notag" or name=="nonumber" then return { kind="space", em=0 }
    elseif name=="," or name==":" or name==";" or name==" " or name=="quad" or name=="qquad"
        or name=="enspace" or name=="thinspace" or name=="!" then
        return {kind="space",em=({[","]=.17,[":"]=.22,[";"]=.28,[" "]=.3,quad=1,qquad=2,
            enspace=.5,thinspace=.17,["!"]=-.12})[name]}
    elseif Lex.functions[name] then
        return {kind="text",text=name,style="roman",class="function",operator=limit_functions[name]}
    elseif Lex.symbols[name] then
        local symbol=Lex.symbols[name]
        return {kind="text",text=symbol,style=style or "roman",operator=operators[name],integral=integrals[name],
            class=(operators[name] or integrals[name]) and "operator" or nil}
    end
    fail("unsupported command: \\"..name)
end
function P:atom(style)
    self.depth=self.depth+1
    if self.depth>48 then fail("expression nesting is too deep") end
    local t=self:next(); local result
    if not t then fail("missing expression") end
    if t.t=="cmd" then result=self:command(t.v,style)
    elseif t.t=="{" then
        result=self:sequence(style,"}")
        if not self:peek() or self:next().t~="}" then fail("unclosed group") end
    elseif t.t=="}" or t.t=="^" or t.t=="_" or t.t=="&" then fail("unexpected "..t.v)
    elseif t.t=="%" then fail("TeX comments are not supported")
    elseif t.t=="ws" then result={kind="space",em=style and .28 or 0}
    else result=text(t.v=="-" and "−" or t.v,style or (t.v:match("^%a$") and "italic" or "roman")) end
    self.depth=self.depth-1
    return result
end
function P:sequence(style, stop)
    local children={}
    while self:peek() do
        local t=self:peek()
        if (stop=="}" or stop=="]") and t.t==stop then break end
        if stop=="right" and t.t=="cmd" and t.v=="right" then break end
        if stop=="environment" and (t.t=="&" or t.t=="cmd" and (t.v=="\\" or t.v=="cr" or t.v=="newline" or t.v=="end")) then break end
        if t.t=="^" or t.t=="_" or t.t=="'" then
            self:next()
            while children[#children] and children[#children].kind=="space" do table.remove(children) end
            local base=table.remove(children); if not base then fail("script has no base") end
            if base.kind~="scripts" then base={kind="scripts",base=base} end
            local slot=t.t=="_" and "sub" or "sup"
            if base[slot] then fail("duplicate script") end
            if t.t=="'" then
                local primes={"′"}; while self:peek() and self:peek().t=="'" do self:next(); primes[#primes+1]="′" end
                base[slot]=text(table.concat(primes),"roman")
            else base[slot]=self:arg(style) end
            children[#children+1]=base
        elseif t.t=="cmd" and (t.v=="limits" or t.v=="nolimits") then
            self:next()
            while children[#children] and children[#children].kind=="space" do table.remove(children) end
            local base=table.remove(children)
            if not base then fail("limits has no operator") end
            if base.kind~="scripts" then base={kind="scripts",base=base} end
            base.limits=t.v=="limits"; children[#children+1]=base
        else children[#children+1]=self:atom(style) end
    end
    return {kind="row",children=children}
end
function M.parse(source)
    if type(source)~="string" then return nil,"math source must be text" end
    local ok,result=pcall(function()
        local parser=setmetatable({tokens=tokenize(source),i=1,depth=0},P)
        local node=parser:sequence(); if parser:peek() then fail("unconsumed expression") end
        return node
    end)
    if ok then return result end
    return nil,tostring(result)
end

-- Layout primitives. A supplied measure(text,size,style) returns actual glyph
-- advance, top and bottom; tests can inject deterministic metrics.
local function box(w,h,d) return {w=w or 0,h=h or 0,d=d or 0,items={}} end
local function place(parent, child, x, y)
    parent.items[#parent.items+1]={box=child,x=x,y=y}
    parent.h=math.max(parent.h,child.h-y); parent.d=math.max(parent.d,child.d+y)
end
local function rule(parent,x1,y1,x2,y2,weight)
    parent.items[#parent.items+1]={line={x1,y1,x2,y2,weight}}
    parent.h=math.max(parent.h,-math.min(y1,y2)+weight/2)
    parent.d=math.max(parent.d,math.max(y1,y2)+weight/2)
end
local function glyph(str,size,style,measure)
    local w,h,d=measure(str,size,style)
    local b=box(w,h,d); b.text=str; b.size=size; b.style=style; return b
end
local function fence(body,left,right,size)
    local gap=size*.16; local dw=size*.38; local top=-body.h-size*.08; local bottom=body.d+size*.08
    local weight=math.max(1,size*.045)
    local b=box(body.w+(left~="" and dw+gap or 0)+(right~="" and dw+gap or 0),-top,bottom)
    local function delimiter(ch,x)
        if ch=="" then return end
        local middle=(top+bottom)/2
        if ch=="[" or ch=="]" or ch=="⌊" or ch=="⌋" or ch=="⌈" or ch=="⌉" then
            local left_side=ch=="[" or ch=="⌊" or ch=="⌈"
            local outer=left_side and x or x+dw; local inner=left_side and x+dw*.7 or x+dw*.3
            rule(b,outer,top,outer,bottom,weight)
            if ch~="⌊" and ch~="⌋" then rule(b,outer,top,inner,top,weight) end
            if ch~="⌈" and ch~="⌉" then rule(b,outer,bottom,inner,bottom,weight) end
        elseif ch=="/" or ch=="\\" then
            local slash=ch=="/"
            rule(b,x+(slash and dw or 0),top,x+(slash and 0 or dw),bottom,weight)
        elseif ch=="|" or ch=="‖" then
            rule(b,x+dw*.45,top,x+dw*.45,bottom,weight)
            if ch=="‖" then rule(b,x+dw*.8,top,x+dw*.8,bottom,weight) end
        elseif ch=="⟨" or ch=="⟩" then
            local outside=ch=="⟨" and x or x+dw; local inside=ch=="⟨" and x+dw or x
            rule(b,inside,top,outside,middle,weight); rule(b,outside,middle,inside,bottom,weight)
        else
            -- Smooth parentheses / braces approximated by short line segments.
            -- No font-stretching: every fence covers the actual measured rows.
            local mirrored=ch==")" or ch=="}"
            local points={}
            if ch=="{" or ch=="}" then
                points={{1,0},{.52,.03},{.4,.10},{.4,.35},{.3,.44},{0,.5},{.3,.56},{.4,.65},{.4,.90},{.52,.97},{1,1}}
            else
                points={{.92,0},{.55,.07},{.28,.19},{.08,.35},{0,.5},{.08,.65},{.28,.81},{.55,.93},{.92,1}}
            end
            for i=2,#points do
                local a,c=points[i-1],points[i]
                rule(b,x+(mirrored and 1-a[1] or a[1])*dw,top+a[2]*(bottom-top),
                    x+(mirrored and 1-c[1] or c[1])*dw,top+c[2]*(bottom-top),weight)
            end
        end
    end
    delimiter(left,0); local offset=left~="" and dw+gap or 0
    place(b,body,offset,0); delimiter(right,offset+body.w+gap)
    return b
end
local layout
layout=function(node,size,display,measure)
    local kind=node.kind
    if kind=="text" then
        local factor=node.class=="operator" and display and 1.55 or 1
        local b=glyph(node.text,size*factor,node.style,measure)
        if node.operator or node.integral then
            local out=box(b.w+size*.16); place(out,b,size*.08,(b.h-b.d)/2-size*.24)
            return out
        end
        if node.class=="function" then b.w=b.w+size*.13 end
        return b
    elseif kind=="space" then return box(node.em*size)
    elseif kind=="row" then
        local b=box()
        local left,right=0,0
        for _,child in ipairs(node.children) do
            local c=layout(child,size,display,measure)
            local padding=0
            if child.kind=="text" and padded_symbols[child.text] or child.class=="relation" then padding=size*.15 end
            local x=b.w+padding
            place(b,c,x,0)
            if child.kind~="space" then left=math.min(left,x);right=math.max(right,x+c.w) end
            b.w=b.w+c.w+2*padding
        end
        if left<0 then
            for _,item in ipairs(b.items) do item.x=item.x-left end
        end
        b.w=math.max(b.w,right)-left
        return b
    elseif kind=="fraction" then
        local scale=display and .9 or .8
        local num=layout(node.top,size*scale,false,measure); local den=layout(node.bottom,size*scale,false,measure)
        local gap=size*.19; local axis=-size*.24; local b=box(math.max(num.w,den.w)+size*.3)
        place(b,num,(b.w-num.w)/2,axis-gap-num.d)
        place(b,den,(b.w-den.w)/2,axis+gap+den.h)
        if node.binomial then return fence(b,"(",")",size) end
        rule(b,0,axis,b.w,axis,math.max(1,size*.045)); return b
    elseif kind=="scripts" then
        local base=layout(node.base,size,display,measure)
        local sup=node.sup and layout(node.sup,size*.68,false,measure)
        local sub=node.sub and layout(node.sub,size*.68,false,measure)
        local limits=node.limits
        if limits==nil then limits=display and node.base.operator end
        local b
        if limits then
            b=box(math.max(base.w,sup and sup.w or 0,sub and sub.w or 0))
            place(b,base,(b.w-base.w)/2,0)
            if sup then place(b,sup,(b.w-sup.w)/2,-base.h-size*.15-sup.d) end
            if sub then place(b,sub,(b.w-sub.w)/2,base.d+size*.15+sub.h) end
        else
            b=box(base.w+math.max(sup and sup.w or 0,sub and sub.w or 0)+size*.07); place(b,base,0,0)
            local sy=sup and -math.max(base.h*.65,sup.d+size*.45) or 0
            local dy=sub and math.max(base.d+sub.h*.45,size*.3) or 0
            if sub and sup and dy-sub.h-(sy+sup.d)<size*.16 then dy=sy+sup.d+size*.16+sub.h end
            if sup then place(b,sup,base.w+size*.04,sy) end
            if sub then place(b,sub,base.w+size*.04,dy) end
        end
        return b
    elseif kind=="root" then
        local body=layout(node.body,size,display,measure); local index=node.index and layout(node.index,size*.55,false,measure)
        local rw=size*.65; local lead=index and math.max(0,index.w-rw*.45) or 0
        local b=box(body.w+rw+lead+size*.12); local top=-body.h-size*.16; local bottom=math.max(body.d,size*.1)
        place(b,body,rw+lead,0)
        local points={{lead, -.03*size},{lead+rw*.18,-.12*size},{lead+rw*.44,bottom},{lead+rw*.82,top},{b.w,top}}
        for i=2,#points do local a,c=points[i-1],points[i];rule(b,a[1],a[2],c[1],c[2],math.max(1,size*.05)) end
        if index then place(b,index,0,-size*.4-index.d) end
        return b
    elseif kind=="delimiter" then
        if node.delimiter=="" then return box() end
        -- Fixed height centred on the same math axis as fractions/matrices.
        -- Reuse drawn fences so sizes do not depend on a font's tall glyphs.
        local half=size*node.scale/2
        return fence(box(0,half+size*.24-size*.08,half-size*.24-size*.08),node.delimiter,"",size)
    elseif kind=="fence" then return fence(layout(node.body,size,display,measure),node.left,node.right,size)
    elseif kind=="grid" then
        local rows,widths,total={}, {}, 0
        for r,row in ipairs(node.rows) do
            rows[r]={h=0,d=0,cells={}}
            for c,cell in ipairs(row) do
                local value=layout(cell,size,node.env~="smallmatrix" and display,measure)
                rows[r].cells[c]=value; widths[c]=math.max(widths[c] or 0,value.w)
                rows[r].h=math.max(rows[r].h,value.h,size*.65); rows[r].d=math.max(rows[r].d,value.d,size*.15)
            end
            total=total+rows[r].h+rows[r].d+(r>1 and size*.5 or 0)
        end
        local alignment=node.env:find("align",1,true) or node.env=="split"
        local gap=alignment and size*.25 or size*.8; local width=0
        for _,w in ipairs(widths) do width=width+w+gap end
        local b=box(math.max(0,width-gap)); local y=-total/2-size*.24
        for _,row in ipairs(rows) do
            y=y+row.h; local x=0
            for c,cell in ipairs(row.cells) do
                local mode=node.columns and node.columns:sub(c,c) or (alignment and (c%2==1 and "r" or "l") or node.env=="cases" and "l" or "c")
                local offset=mode=="r" and widths[c]-cell.w or mode=="c" and (widths[c]-cell.w)/2 or 0
                place(b,cell,x+offset,y); x=x+widths[c]+gap
            end
            y=y+row.d+size*.5
        end
        local grid_delimiters={pmatrix={"(",")"},bmatrix={"[","]"},Bmatrix={"{","}"},vmatrix={"|","|"},Vmatrix={"‖","‖"},cases={"{",""}}
        local sides=grid_delimiters[node.env]
        return sides and fence(b,sides[1],sides[2],size) or b
    elseif kind=="accent" then
        local body=layout(node.body,size,display,measure); local b=box(body.w);place(b,body,0,0)
        local y=-body.h-size*.16; local weight=math.max(1,size*.045)
        if node.accent=="underline" then y=body.d+size*.12;rule(b,0,y,b.w,y,weight)
        elseif node.accent=="dot" or node.accent=="ddot" then
            rule(b,b.w*.5,y,b.w*.5,y,weight*1.8)
            if node.accent=="ddot" then b.items[#b.items]=nil;rule(b,b.w*.35,y,b.w*.35,y,weight*1.8);rule(b,b.w*.65,y,b.w*.65,y,weight*1.8) end
        elseif node.accent=="hat" or node.accent=="widehat" then
            rule(b,0,y,b.w/2,y-size*.16,weight);rule(b,b.w/2,y-size*.16,b.w,y,weight)
        elseif node.accent=="tilde" or node.accent=="widetilde" then
            local prev
            for i=0,16 do local p={b.w*i/16,y-math.sin(i/16*math.pi*2)*size*.07}; if prev then rule(b,prev[1],prev[2],p[1],p[2],weight) end;prev=p end
        else
            rule(b,0,y,b.w,y,weight)
            if node.accent=="vec" then rule(b,b.w-size*.22,y-size*.12,b.w,y,weight);rule(b,b.w-size*.22,y+size*.12,b.w,y,weight) end
        end
        return b
    end
    fail("unsupported layout node")
end
-- Break only between top-level mathematical clauses/terms. Fractions, matrix
-- cells, scripts, braced groups and text labels remain indivisible. Even plain
-- or explicitly sized parentheses (which are independent parser atoms) must
-- stay paired on one line. A continuation retains its leading operator.
local relations = {}
for value in ("= < > ≤ ≥ ≈ ≠ → ∈ ≺ ≻ ⪯ ⪰ ≼ ≽ ⊀ ⊁ ⋠ ⋡ ⊂ ⊃ ⊆ ⊇ ≡ ∼ ≃ ≅ ∝ ⊥ ∥ ∣ ∤"):gmatch("%S+") do
    relations[value]=true
end
local closing={ ["("]=")", ["["]="]", ["{"]="}", ["⟨"]="⟩", ["⌊"]="⌋", ["⌈"]="⌉" }
local is_close={ [")"]=true, ["]"]=true, ["}"]=true, ["⟩"]=true, ["⌋"]=true, ["⌉"]=true }
local before_unary={ ["+"]=true, ["−"]=true, ["±"]=true, ["×"]=true, ["·"]=true,
    ["÷"]=true, ["/"]=true, ["*"]=true, [","]=true, [";"]=true }
local function wrapRow(ast,original,size,max_width)
    if ast.kind~="row" then return nil end
    local children=ast.children
    local breaks, stack, previous, previous_node={}, {}, nil, nil
    for i,child in ipairs(children) do
        local base=child.kind=="scripts" and child.base or child
        local symbol=base.kind=="text" and base.text or base.kind=="delimiter" and base.delimiter
        if closing[symbol] then stack[#stack+1]=closing[symbol]
        elseif is_close[symbol] then
            if stack[#stack]~=symbol then return nil end
            stack[#stack]=nil
        elseif symbol=="|" or symbol=="‖" then
            if stack[#stack]==symbol then stack[#stack]=nil else stack[#stack+1]=symbol end
        elseif #stack==0 and child.kind=="text" then
            local following=i+1
            while children[following] and children[following].kind=="space" do following=following+1 end
            local after=children[following]
            local numeric_comma=symbol=="," and previous and previous:match("^%d$")
                and after and after.kind=="text" and after.text:match("^%d$")
            if (symbol=="," and not numeric_comma) or symbol==";" then
                breaks[#breaks+1]={at=i+1,priority=1}
            elseif previous and (relations[symbol] or (symbol=="+" or symbol=="−" or symbol=="±")
                and not relations[previous] and not before_unary[previous]
                and not previous_node.operator and not previous_node.integral and previous_node.class~="function") then
                breaks[#breaks+1]={at=i,priority=relations[symbol] and 2 or 3}
            end
        end
        if child.kind~="space" then previous=symbol or "atom";previous_node=base end
        -- Keep adversarial answers from turning layout into an expensive search.
        if #breaks>128 then return nil end
    end
    if #stack>0 or #breaks==0 then return nil end
    breaks[#breaks+1]={at=#children+1,priority=0}
    local function slice(first,last)
        while first<=last and children[first].kind=="space" do first=first+1 end
        while last>=first and children[last].kind=="space" do last=last-1 end
        local b=box();local left,right=0,0
        for i=first,last do
            local child=children[i];local c=original.items[i].box
            local padding=(child.kind=="text" and padded_symbols[child.text] or child.class=="relation") and size*.15 or 0
            local x=b.w+padding
            place(b,c,x,0)
            if child.kind~="space" then left=math.min(left,x);right=math.max(right,x+c.w) end
            b.w=b.w+c.w+2*padding
        end
        if left<0 then for _,item in ipairs(b.items) do item.x=item.x-left end end
        b.w=math.max(b.w,right)-left
        return b
    end
    local rows,first,next_break={},1,1
    while first<=#children do
        local best,index
        for j=next_break,#breaks do
            local candidate=breaks[j]
            if candidate.at>first then
                local line=slice(first,candidate.at-1)
                if line.w>max_width then break end
                -- Prefer a complete clause to breaking an equation halfway.
                -- At equal priority, fill as much of the line as possible.
                if not best or candidate.priority<=breaks[index].priority then best,index=line,j end
            end
        end
        if not best then return nil end
        rows[#rows+1]=best
        first=breaks[index].at;next_break=index+1
    end
    if #rows<2 then return nil end
    local b=box();local y=0
    for i,row in ipairs(rows) do
        if i>1 then y=y+rows[i-1].d+size*.55+row.h end
        place(b,row,0,y);b.w=math.max(b.w,row.w)
    end
    b.line_count=#rows
    return b
end
function M.layout(ast,size,display,measure,max_width)
    local result=layout(ast,size,display,measure)
    if display and max_width and result.w>max_width then
        result=wrapRow(ast,result,size,max_width) or result
    end
    if result.w>12000 or result.h+result.d>16000 then return nil,"expression is too large to display" end
    return result
end
return M
