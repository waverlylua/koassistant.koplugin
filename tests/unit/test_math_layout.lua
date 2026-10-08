-- Pure-Lua contracts for strict parsing, genuine two-dimensional math layout,
-- and source-safe renderer/document integration. No KOReader, FFI, fonts, PNG
-- encoder, network, filesystem fixture, or screenshot dependency is needed.
-- Run from the plugin root: lua tests/unit/test_math_layout.lua
-- Native raster output is tested separately by the device/E2E harness.

package.path = package.path .. ";./?.lua;./?/init.lua"

local Layout = require("koassistant_math_layout")
local T = { passed = 0, failed = 0 }
local EPSILON = 0.000001

function T:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print("  ✓ " .. name)
    else
        self.failed = self.failed + 1
        print("  ✗ " .. name .. ": " .. tostring(err))
    end
end

local function eq(actual, expected, why)
    assert(actual == expected, (why or "value mismatch") .. ": expected " .. tostring(expected)
        .. ", got " .. tostring(actual))
end
local function near(actual, expected, why)
    assert(math.abs(actual - expected) < EPSILON, (why or "geometry mismatch")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function has(value, needle, why)
    assert(type(value) == "string" and value:find(needle, 1, true),
        (why or "missing expected text") .. ": " .. needle .. " in " .. tostring(value))
end
local function lacks(value, needle, why)
    assert(not value:find(needle, 1, true), (why or "unexpected text") .. ": " .. needle)
end
local function less(a, b, why)
    assert(a < b, (why or "expected strict separation") .. ": " .. a .. " must be < " .. b)
end
local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Every Unicode code point has a predictable advance. This makes position
-- assertions independent of the fonts installed on the host running tests.
local function measure(str, size, style)
    assert(type(str) == "string" and finite(size) and size > 0, "invalid glyph measurement")
    assert(style == "roman" or style == "italic" or style == "bold"
        or style == "bolditalic" or style == "mono", "unknown glyph style: " .. tostring(style))
    local count = 0
    for _ in str:gmatch("[\1-\127\194-\244][\128-\191]*") do count = count + 1 end
    return count * size * 0.6, size * 0.8, size * 0.2
end
local function parsed(source)
    local ast, err = Layout.parse(source)
    assert(ast, "expected supported source to parse: " .. source .. "; error: " .. tostring(err))
    eq(err, nil, "successful parse must not return an error")
    eq(ast.kind, "row", "expression root")
    return ast
end
local function rejected(source, reason)
    local ok, ast, err = pcall(Layout.parse, source)
    assert(ok, "parse must return an error value, not raise: " .. tostring(ast))
    eq(ast, nil, "unsupported/malformed source must reject the WHOLE expression: " .. source:sub(1, 120))
    assert(type(err) == "string" and #err > 0, "rejection needs an actionable reason")
    if reason then has(err, reason, "wrong rejection reason") end
    return err
end
local function laidOut(source, size, display)
    local value, err = Layout.layout(parsed(source), size or 20, display ~= false, measure)
    assert(value, "layout unexpectedly rejected " .. source .. ": " .. tostring(err))
    return value
end
local function onlyChild(value)
    eq(#value.items, 1, "expected one expression child")
    assert(value.items[1].box, "expected a child box")
    return value.items[1].box
end
local function boxes(value)
    local result = {}
    for _, item in ipairs(value.items) do
        if item.box then result[#result + 1] = item end
    end
    return result
end
local function lines(value)
    local result = {}
    for _, item in ipairs(value.items) do
        if item.line then result[#result + 1] = item.line end
    end
    return result
end
local function flatten(value, x, y, result)
    result = result or { glyphs = {}, lines = {} }
    x, y = x or 0, y or 0
    if value.text then
        result.glyphs[#result.glyphs + 1] = {
            text = value.text, x = x, y = y, w = value.w, h = value.h, d = value.d,
            size = value.size, style = value.style,
        }
    end
    for _, item in ipairs(value.items) do
        if item.box then
            flatten(item.box, x + item.x, y + item.y, result)
        else
            local line = item.line
            result.lines[#result.lines + 1] = {
                line[1] + x, line[2] + y, line[3] + x, line[4] + y, line[5],
            }
        end
    end
    return result
end
local function glyph(value, text)
    local found
    for _, item in ipairs(flatten(value).glyphs) do
        if item.text == text then
            assert(not found, "test fixture requires a unique glyph: " .. text)
            found = item
        end
    end
    assert(found, "layout lost glyph: " .. text)
    return found
end
local function glyphText(value)
    local result = {}
    for _, item in ipairs(flatten(value).glyphs) do result[#result + 1] = item.text end
    return table.concat(result)
end
local function checkBoxBounds(value)
    assert(finite(value.w) and finite(value.h) and finite(value.d), "box dimensions must be finite")
    assert(value.w >= 0 and value.h >= 0 and value.d >= 0, "fixture box dimensions must be nonnegative")
    for _, item in ipairs(value.items) do
        if item.box then
            assert(finite(item.x) and finite(item.y), "child baseline must be finite")
            assert(item.box.h - item.y <= value.h + EPSILON, "parent clips child ascent")
            assert(item.box.d + item.y <= value.d + EPSILON, "parent clips child descent")
            checkBoxBounds(item.box)
        else
            local line = item.line
            eq(#line, 5, "a drawn rule requires endpoints and weight")
            for _, coordinate in ipairs(line) do assert(finite(coordinate), "rule coordinate must be finite") end
            assert(line[5] > 0, "rule must have positive thickness")
            assert(-math.min(line[2], line[4]) + line[5] / 2 <= value.h + EPSILON,
                "parent clips rule ascent/thickness")
            assert(math.max(line[2], line[4]) + line[5] / 2 <= value.d + EPSILON,
                "parent clips rule descent/thickness")
        end
    end
end

T:test("fractions have centered numerator and denominator separated by a rule", function()
    local fraction = onlyChild(laidOut([[\frac{abc}{d}]]))
    local children, rules = boxes(fraction), lines(fraction)
    eq(#children, 2, "fraction child count"); eq(#rules, 1, "fraction must have a bar")
    local numerator, denominator, bar = children[1], children[2], rules[1]
    near(bar[2], bar[4], "fraction bar must be horizontal")
    near(bar[1], 0, "bar starts at fraction edge"); near(bar[3], fraction.w, "bar covers full fraction width")
    near(numerator.x + numerator.box.w / 2, fraction.w / 2, "numerator centering")
    near(denominator.x + denominator.box.w / 2, fraction.w / 2, "denominator centering")
    less(numerator.y + numerator.box.d, bar[2] - bar[5] / 2, "numerator must sit above the rule")
    less(bar[2] + bar[5] / 2, denominator.y - denominator.box.h, "denominator must sit below the rule")
end)

T:test("nested fractions retain three distinct bars and four vertical levels", function()
    local value = laidOut([[\frac{1+\frac{a}{b}}{\frac{c}{d}}]])
    local fraction, all = onlyChild(value), flatten(value)
    eq(#all.lines, 3, "nested fractions cannot flatten to slash-separated text")
    local children, bar = boxes(fraction), lines(fraction)[1]
    less(children[1].y + children[1].box.d, bar[2], "entire nested numerator above outer bar")
    less(bar[2], children[2].y - children[2].box.h, "entire nested denominator below outer bar")
    less(glyph(value, "a").y, glyph(value, "b").y, "nested numerator order")
    less(glyph(value, "b").y, glyph(value, "c").y, "outer fraction separation")
    less(glyph(value, "c").y, glyph(value, "d").y, "nested denominator order")
    for i = 1, #all.lines do
        for j = i + 1, #all.lines do
            assert(math.abs(all.lines[i][2] - all.lines[j][2]) > EPSILON, "nested fraction bars collapsed")
        end
    end
    eq(glyphText(value), "1+abcd", "fraction must retain every mathematical token")
    checkBoxBounds(value)
end)

T:test("inline fractions remain two-dimensional and smaller than display fractions", function()
    local display = laidOut([[\frac{x}{y}]], 20, true)
    local inline = laidOut([[\frac{x}{y}]], 20, false)
    eq(#flatten(inline).lines, 1, "inline fraction bar")
    less(glyph(inline, "x").y, glyph(inline, "y").y, "inline numerator/denominator must be stacked")
    less(inline.h + inline.d, display.h + display.d, "display fraction needs more vertical space")
end)

T:test("binomial stacks its entries inside fences without drawing a fraction bar", function()
    local value = laidOut([[\binom{n}{k}]])
    less(glyph(value, "n").y, glyph(value, "k").y, "binomial order")
    local stacked = boxes(onlyChild(value))[1].box
    eq(#boxes(stacked), 2, "binomial has two stacked entries")
    eq(#lines(stacked), 0, "binomial must not have a division bar")
    assert(#flatten(value).lines > 4, "binomial needs enclosing fences")
    checkBoxBounds(value)
end)

T:test("radical overbar covers the entire tall radicand", function()
    local value = laidOut([[\sqrt{\frac{a+b}{c}}]])
    local root = onlyChild(value)
    local body, rules = boxes(root)[1], lines(root)
    eq(#rules, 4, "radical must be a drawn hook and overbar")
    local overbar = rules[#rules]
    near(overbar[2], overbar[4], "radical overbar horizontal")
    assert(overbar[1] <= body.x, "radical overbar must begin before radicand")
    assert(overbar[3] >= body.x + body.box.w, "radical overbar must cover radicand width")
    less(overbar[2], body.y - body.box.h, "radical must clear tall numerator")
    local maximum_y = -math.huge
    for _, rule in ipairs(rules) do maximum_y = math.max(maximum_y, rule[2], rule[4]) end
    assert(maximum_y >= body.y + body.box.d, "radical hook must reach bottom of radicand")
    checkBoxBounds(value)
end)

T:test("indexed roots put a small index at upper left without overlapping the body", function()
    local value = laidOut([[\sqrt[123]{x}]])
    local root = onlyChild(value)
    local body, index = boxes(root)[1], boxes(root)[2]
    assert(index, "indexed root lost its degree")
    less(index.y + index.box.d, body.y, "root index above baseline")
    assert(index.x + index.box.w <= body.x, "root index must not overlap radicand")
    less(glyph(value, "1").size, glyph(value, "x").size, "root index uses script size")
    eq(glyphText(value), "x123", "indexed root must retain degree and radicand")
    checkBoxBounds(value)
end)

T:test("2x2 matrices place all four cells in genuine rows and common columns", function()
    local value = laidOut([[\begin{matrix}a&bb\\ccc&d\end{matrix}]])
    local cells = boxes(onlyChild(value))
    eq(#cells, 4, "2x2 matrix cell count")
    near(cells[1].y, cells[2].y, "first-row baselines")
    near(cells[3].y, cells[4].y, "second-row baselines")
    less(cells[1].y + cells[1].box.d, cells[3].y - cells[3].box.h, "matrix rows need vertical clearance")
    near(cells[1].x + cells[1].box.w / 2, cells[3].x + cells[3].box.w / 2, "column one centers")
    near(cells[2].x + cells[2].box.w / 2, cells[4].x + cells[4].box.w / 2, "column two centers")
    less(cells[3].x + cells[3].box.w, cells[4].x, "matrix column clearance")
    eq(glyphText(value), "abbcccd", "matrix must not drop cells or add comma/semicolon substitutes")
    checkBoxBounds(value)
end)

T:test("matrix fences enclose both rows and scale with a fractional cell", function()
    for _, env in ipairs({"pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix"}) do
        local value = laidOut("\\begin{" .. env .. "}\\frac{a}{b}&c\\\\d&e\\end{" .. env .. "}")
        local fenced = onlyChild(value)
        local grid = boxes(fenced)[1]
        local rules = lines(fenced)
        assert(#rules >= 2, env .. " missing fences")
        local min_y, max_y = math.huge, -math.huge
        for _, rule in ipairs(rules) do
            min_y = math.min(min_y, rule[2], rule[4]); max_y = math.max(max_y, rule[2], rule[4])
        end
        less(min_y, grid.y - grid.box.h, env .. " fence must clear highest cell")
        less(grid.y + grid.box.d, max_y, env .. " fence must cover lowest row")
        eq(glyphText(value), "abcde", env .. " content preservation")
        checkBoxBounds(value)
    end
end)

T:test("cases have a full-height left brace, no right brace, and left-aligned conditions", function()
    local value = laidOut([[\begin{cases}x&\text{if }x>0\\-x&\text{otherwise}\end{cases}]])
    local fenced = onlyChild(value)
    local grid = boxes(fenced)[1]
    local cells, rules = boxes(grid.box), lines(fenced)
    eq(#cells, 4, "cases row and condition count")
    assert(#rules >= 4, "cases brace must be drawn, not a single undersized glyph")
    for _, rule in ipairs(rules) do
        assert(math.max(rule[1], rule[3]) < grid.x, "cases must have only a left brace")
    end
    near(cells[1].x, cells[3].x, "case expressions left aligned")
    near(cells[2].x, cells[4].x, "case conditions left aligned")
    less(cells[1].y, cells[3].y, "case rows must stack")
    checkBoxBounds(value)
end)

T:test("aligned equations share right-aligned left sides and left-aligned relation columns", function()
    local value = laidOut([[\begin{aligned}a&=b\\cccc&=d\end{aligned}]])
    local cells = boxes(onlyChild(value))
    eq(#cells, 4, "aligned cell count")
    near(cells[1].x + cells[1].box.w, cells[3].x + cells[3].box.w, "left sides must end at a shared column")
    near(cells[2].x, cells[4].x, "relation columns must start together")
    near(cells[1].y, cells[2].y, "equation one baseline")
    near(cells[3].y, cells[4].y, "equation two baseline")
    less(cells[1].y, cells[3].y, "aligned equations need distinct lines")
    local equal_signs = {}
    for _, item in ipairs(flatten(value).glyphs) do
        if item.text == "=" then equal_signs[#equal_signs + 1] = item end
    end
    eq(#equal_signs, 2, "both equality signs retained")
    near(equal_signs[1].x, equal_signs[2].x, "actual equality glyphs must align")
    checkBoxBounds(value)
end)

T:test("arrays honor explicit left, center, and right column specifications", function()
    local value = laidOut([[\begin{array}{lcr}a&b&c\\ddd&eee&fff\end{array}]])
    local cells = boxes(onlyChild(value))
    eq(#cells, 6, "array cell count")
    near(cells[1].x, cells[4].x, "array left column")
    near(cells[2].x + cells[2].box.w / 2, cells[5].x + cells[5].box.w / 2, "array centered column")
    near(cells[3].x + cells[3].box.w, cells[6].x + cells[6].box.w, "array right column")
end)

T:test("display sums stack centered limits above and below the operator", function()
    local value = laidOut([[\sum_{i=1}^{n}x_i]])
    local scripted = value.items[1].box
    local children = boxes(scripted)
    eq(#children, 3, "sum operator and both limits")
    local base, upper, lower = children[1], children[2], children[3]
    near(base.x + base.box.w / 2, upper.x + upper.box.w / 2, "upper limit centered over sum")
    near(base.x + base.box.w / 2, lower.x + lower.box.w / 2, "lower limit centered under sum")
    less(upper.y + upper.box.d, base.y - base.box.h, "sum upper limit clears operator")
    less(base.y + base.box.d, lower.y - lower.box.h, "sum lower limit clears operator")
    less(glyph(value, "n").size, glyph(value, "∑").size, "sum limit smaller than display operator")
    checkBoxBounds(value)
end)

T:test("inline sums use side scripts instead of display-style stacked limits", function()
    local scripted = onlyChild(laidOut([[\sum_{i=1}^{n}]], 20, false))
    local children = boxes(scripted)
    local base, upper, lower = children[1], children[2], children[3]
    assert(upper.x >= base.x + base.box.w, "inline sum superscript belongs to the right")
    assert(lower.x >= base.x + base.box.w, "inline sum subscript belongs to the right")
    less(upper.y, base.y, "inline upper bound raised")
    less(base.y, lower.y, "inline lower bound lowered")
end)

T:test("integral bounds remain side scripts and clear one another", function()
    local value = laidOut([[\int_0^\infty e^{-x}\,dx]])
    local children = boxes(value.items[1].box)
    local base, upper, lower = children[1], children[2], children[3]
    assert(upper.x >= base.x + base.box.w, "integral upper bound must be beside the operator")
    assert(lower.x >= base.x + base.box.w, "integral lower bound must be beside the operator")
    less(upper.y, base.y, "integral upper bound raised")
    less(base.y, lower.y, "integral lower bound lowered")
    less(upper.y + upper.box.d, lower.y - lower.box.h, "integral bounds cannot overlap")
    eq(glyph(value, "∫").text, "∫", "integral retained")
    eq(glyph(value, "∞").text, "∞", "infinite bound retained")
    checkBoxBounds(value)
end)

T:test("explicit limits and nolimits override defaults", function()
    local sum = boxes(onlyChild(laidOut([[\sum\nolimits_0^n]])))
    assert(sum[2].x >= sum[1].box.w, "nolimits must put sum upper bound at the side")
    local integral = boxes(onlyChild(laidOut([[\int\limits_0^1]])))
    near(integral[1].x + integral[1].box.w / 2, integral[2].x + integral[2].box.w / 2,
        "limits must center integral upper bound")
    less(integral[2].y + integral[2].box.d, -integral[1].box.h, "explicit upper limit above integral")
end)

T:test("ordinary paired scripts are smaller, on the right, and do not collide", function()
    local value = laidOut([[x_{\frac{a}{b}}^{\frac{c}{d}}]])
    local children = boxes(onlyChild(value))
    local base, upper, lower = children[1], children[2], children[3]
    assert(upper.x >= base.box.w and lower.x >= base.box.w, "scripts follow their base")
    near(upper.x, lower.x, "script columns")
    less(upper.y + upper.box.d, lower.y - lower.box.h, "tall paired scripts need clearance")
    less(glyph(value, "a").size, glyph(value, "x").size, "script scaling")
    checkBoxBounds(value)
end)

T:test("fences scale to nested content while invisible delimiters remain invisible", function()
    local value = laidOut([[\left.\frac{x}{y}\right|_0^1]])
    local scripted = onlyChild(value)
    local fenced = boxes(scripted)[1].box
    eq(#lines(fenced), 1, "one evaluation bar and no invisible left fence")
    local bar, body = lines(fenced)[1], boxes(fenced)[1]
    near(body.x, 0, "invisible left delimiter takes no width")
    near(bar[1], bar[3], "evaluation bar vertical")
    less(bar[2], -body.box.h, "evaluation bar covers numerator")
    less(body.box.d, bar[4], "evaluation bar covers denominator")
    checkBoxBounds(value)
end)

T:test("Android Schur-complement answer preserves its matrix order, inverse, and pseudoinverse", function()
    local fixtures = {
        {[[M=\begin{bmatrix}A&B\\B^{T}&C\end{bmatrix}\succeq 0.]], "M=ABBTC⪰0."},
        {[[g(x)=f(x,y^\star)=x^T\bigl(A-BC^{-1}B^T\bigr)x.]], "g(x)=f(x,y⋆)=xTA−BC−1BTx."},
        {[[A-BC^\dagger B^T\succeq0.]], "A−BC†BT⪰0."},
        {[[C\succeq0,\quad \operatorname{range}(B^T)\subseteq\operatorname{range}(C), \quad A-BC^\dagger B^T\succeq0.]], "C⪰0,range(BT)⊆range(C),A−BC†BT⪰0."},
    }
    for _, fixture in ipairs(fixtures) do
        local value = laidOut(fixture[1])
        eq(glyphText(value), fixture[2], "actual answer must retain every mathematical token")
        checkBoxBounds(value)
    end
    local pseudo = laidOut([[C^\dagger]])
    less(glyph(pseudo,"†").y, glyph(pseudo,"C").y, "pseudoinverse dagger must be a superscript")
    less(glyph(pseudo,"†").size, glyph(pseudo,"C").size, "dagger must use script size")
end)

T:test("matrix-order relations stay distinct from scalar comparisons and receive spacing", function()
    local fixtures = {preceq="⪯",succeq="⪰",prec="≺",succ="≻",preccurlyeq="≼",succcurlyeq="≽",
        nprec="⊀",nsucc="⊁",npreceq="⋠",nsucceq="⋡"}
    for command, symbol in pairs(fixtures) do
        local value = laidOut("A\\"..command.." B")
        eq(glyphText(value), "A"..symbol.."B", "relation has its own mathematical meaning")
        local a, rel, b = glyph(value,"A"), glyph(value,symbol), glyph(value,"B")
        less(a.x+a.w, rel.x, "relation has space before")
        less(rel.x+rel.w, b.x, "relation has space after")
    end
    eq(glyphText(laidOut([[A^{\dagger\dagger}+B^\ddagger+C^\top]])), "A††+B‡+C⊤", "adjoint and transpose symbols")
end)

T:test("all four explicit delimiter sizes and l/r/m variants draw independent fixed-height fences", function()
    local previous = 0
    for _, prefix in ipairs({"big","Big","bigg","Bigg"}) do
        local expected
        for _, suffix in ipairs({"","l","r","m"}) do
            local value = laidOut("\\"..prefix..suffix.."(")
            local height = value.h+value.d
            assert(#flatten(value).lines>0, "sizing must draw the delimiter, not drop it")
            if expected then near(height,expected,"l/r/m variants preserve delimiter height") else expected=height end
            checkBoxBounds(value)
        end
        less(previous,expected,"each successive delimiter size grows")
        previous=expected
    end
    local value = laidOut([[\bigl(x\Bigr)^2]])
    eq(glyphText(value),"x2","unpaired/differently sized delimiters retain body and script")
    less(glyph(value,"2").y,glyph(value,"x").y,"script belongs above the closing delimiter")
    local empty = onlyChild(laidOut([[\big.]]))
    eq(empty.w,0,"invisible delimiter has no visible width")
    eq(#empty.items,0,"invisible delimiter cannot draw a dot")
end)

T:test("floor, ceiling, norm, angle and slash delimiters have honest drawn geometry", function()
    for _, command in ipairs({"lfloor","rfloor","lceil","rceil"}) do
        local value = laidOut("\\Bigl\\"..command)
        local rules = flatten(value).lines
        eq(#rules,2,"floor and ceiling must have exactly one horizontal cap")
        local vertical, cap = rules[1], rules[2]
        near(cap[2],cap[4],"cap is horizontal")
        near(cap[2],command:find("floor",1,true) and vertical[4] or vertical[2],"cap at correct end")
        checkBoxBounds(value)
    end
    for _, source in ipairs({[[\Bigl\lVert x\Bigr\rVert]], [[\bigl<x\bigr>]],
        [[\Bigl\lbrack x\Bigr\rbrack]], [[\Bigl\lparen x\Bigr\rparen]],
        [[\left\lfloor\frac{x}{y}\right\rfloor]], [[\left\lceil x\right\rceil]],
        [[\big/]], [[\Big\backslash]]}) do
        local value = laidOut(source)
        assert(#flatten(value).lines>0,"delimiter must remain visible")
        checkBoxBounds(value)
    end
end)

T:test("accents draw over or under full expression width without losing their bases", function()
    for _, name in ipairs({"vec", "hat", "widehat", "bar", "overline", "underline", "dot", "ddot", "tilde", "widetilde"}) do
        local value = laidOut("\\" .. name .. "{xy}")
        eq(glyphText(value), "xy", name .. " must retain its full base")
        local accented = onlyChild(value)
        assert(#lines(accented) > 0, name .. " requires a drawn accent")
        local body = boxes(accented)[1]
        for _, rule in ipairs(lines(accented)) do
            if name == "underline" then
                less(body.box.d, math.min(rule[2], rule[4]), "underline below the base")
            else
                less(math.max(rule[2], rule[4]), -body.box.h, name .. " above the base")
            end
        end
        checkBoxBounds(value)
    end
end)

T:test("Greek, escaped characters, upright text, bold and blackboard glyphs survive layout", function()
    local value = laidOut([[\alpha+\beta=\mathbb{R}\quad\mathbf{v}\text{ if }x\&y\%\_]])
    eq(glyphText(value), "α+β=ℝvifx&y%_", "supported source must retain all visible symbols")
    eq(glyph(value, "x").style, "italic", "ordinary Latin variable style")
    eq(glyph(value, "v").style, "bold", "bold style preserved")
    eq(glyph(value, "f").style, "roman", "text style preserved")
    eq(glyph(value, "ℝ").style, "roman", "blackboard glyph style")
    checkBoxBounds(value)
end)

T:test("styles are passed to the measurement callback and sizes scale linearly", function()
    local small = laidOut([[\mathbf{x}+\frac{a}{b}]], 16)
    local large = laidOut([[\mathbf{x}+\frac{a}{b}]], 32)
    near(large.w, small.w * 2, "horizontal scaling")
    near(glyph(large, "x").size, glyph(small, "x").size * 2, "glyph size scaling")
    eq(glyph(large, "x").style, "bold", "measurement style")
end)

T:test("modulo commands preserve modulo semantics and pmod parentheses", function()
    local pmod = laidOut([[a\equiv b\pmod{n}]])
    eq(glyphText(pmod), "a≡bmodn", "pmod must render mod, not literal command name pmod")
    local last = pmod.items[#pmod.items].box
    local fence_found = false
    for _, item in ipairs(boxes(last)) do
        if #lines(item.box) > 0 then fence_found = true end
    end
    assert(fence_found, "pmod must draw parentheses around mod n")
    eq(glyphText(laidOut([[a\bmod n]])), "amodn", "bmod visible operator")
    eq(glyphText(laidOut([[a\mod n]])), "amodn", "mod visible operator")
    eq(glyph(pmod, "mod").style, "roman", "modulo operator is upright")
    checkBoxBounds(pmod)
end)

T:test("starred operator names stack limits without adding a literal star", function()
    local value = laidOut([[\operatorname*{argmax}_{x}f(x)]])
    local scripted = value.items[1].box
    local children = boxes(scripted)
    eq(#children, 2, "operatorname* and its lower limit")
    local base, lower = children[1], children[2]
    eq(glyphText(base.box), "argmax", "star is syntax, not visible multiplication")
    near(base.x + base.box.w / 2, lower.x + lower.box.w / 2, "named operator limit centered")
    less(base.y + base.box.d, lower.y - lower.box.h, "named operator limit sits below the base")
    for _, item in ipairs(flatten(base.box).glyphs) do eq(item.style, "roman", "named operator upright") end
    checkBoxBounds(value)
end)

T:test("whitespace before limits cannot detach scripts from the operator", function()
    local value = laidOut([[\sum \limits_{i=1}^{n}]])
    local children = boxes(onlyChild(value))
    eq(#children, 3, "operator and both limits stay attached across whitespace")
    eq(glyphText(children[1].box), "∑", "sum remains the scripted base")
    eq(glyphText(children[2].box), "n", "sum upper limit")
    eq(glyphText(children[3].box), "i=1", "sum lower limit")
end)

T:test("leading and trailing negative spaces cannot place visible glyphs outside box bounds", function()
    for _, source in ipairs({[[\!\!\!x]], [[x\!\!\!]], [[a\!\!\!\!\!\!b]]}) do
        local value = laidOut(source)
        assert(value.w >= 0, "negative spaces cannot create a negative result width")
        for _, item in ipairs(flatten(value).glyphs) do
            assert(item.x >= -EPSILON, "leading negative space clips glyph left of result box")
            assert(item.x + item.w <= value.w + EPSILON, "trailing negative space clips glyph at right edge")
        end
    end
end)

-- Strictness: render an honest source fallback instead of accepting a prefix,
-- inventing a plausible flattened formula, or swallowing unknown constructs.
local bad_sources = {
    {[[\big]], "missing delimiter"},
    {[[\bigl x]], "unsupported delimiter"},
    {[[\Big\unknown]], "unsupported delimiter"},
    {[[A\succeq0+\unsupportedSemanticCommand{C^\dagger}]], "unsupported command"},
    {[[a+\unknown{x}+b]], "unsupported command"},
    {[[\frac{a}]], "missing argument"},
    {[[\frac{a}{b]], "unclosed group"},
    {[[a}b]], "unexpected"},
    {[[{a+b]], "unclosed group"},
    {[[x^]], "missing argument"},
    {[[^2+x]], "script has no base"},
    {[[x_1_2]], "duplicate script"},
    {[[x^1^2]], "duplicate script"},
    {[[\sqrt[3{x}]], "unclosed root index"},
    {[[\left(x+y]], "unclosed left/right delimiter"},
    {[[\right)]], "unsupported command"},
    {[[a&b]], "unexpected"},
    {[[a% hidden suffix]], "comments"},
    {[[\begin{matrix}a&b]], "unclosed environment"},
    {[[\begin{matrix}a\end{cases}]], "mismatched environment"},
    {[[\begin{unknown}a\end{unknown}]], "unsupported environment"},
    {[[\begin{matrix}a\\[3pt]b\end{matrix}]], "row spacing"},
    {[[\begin{array}{|c|}a\end{array}]], "column specification"},
    {[[\mathbb{unsupported}]], "unsupported mathbb"},
    {"x+\\", "unfinished command"},
}
for index, fixture in ipairs(bad_sources) do
    T:test("strict parser rejects malformed/unsupported source #" .. index, function()
        rejected(fixture[1], fixture[2])
    end)
end

T:test("parser rejects invalid input as an error value", function()
    for _, source in ipairs({false, 42, {}}) do
        local ok, ast, err = pcall(Layout.parse, source)
        assert(ok, "invalid input must not raise")
        eq(ast, nil, "invalid input must not produce an AST")
        assert(type(err) == "string" and #err > 0, "invalid input needs an error")
    end
    local ast, err = Layout.parse(nil)
    eq(ast, nil, "nil input rejected"); assert(type(err) == "string", "nil input error")
end)

T:test("parser enforces the source-byte bound before tokenization", function()
    assert(Layout.parse(string.rep(" ", 12000)), "source at byte bound should be accepted")
    rejected(string.rep(" ", 12001), "too long")
end)

T:test("parser enforces token count independently of byte length", function()
    local ast = parsed(string.rep("x", 4000))
    eq(#ast.children, 4000, "exact token limit should be accepted")
    rejected(string.rep("x", 4001), "too many tokens")
end)

T:test("parser accepts moderate nesting but rejects excessive ordinary groups", function()
    parsed(string.rep("{", 20) .. "x" .. string.rep("}", 20))
    rejected(string.rep("{", 60) .. "x" .. string.rep("}", 60), "nesting is too deep")
end)

T:test("fraction recursion cannot bypass the parser depth bound", function()
    local source = "x"
    for _ = 1, 60 do source = "\\frac{" .. source .. "}{y}" end
    rejected(source, "nesting is too deep")
end)

T:test("script argument recursion cannot bypass the parser depth bound", function()
    local source = "x"
    for _ = 1, 60 do source = "x^{" .. source .. "}" end
    rejected(source, "nesting is too deep")
end)

local function matrix(rows, columns, trailing)
    local cells, result = {}, {}
    for _ = 1, columns do cells[#cells + 1] = "x" end
    for _ = 1, rows do result[#result + 1] = table.concat(cells, "&") end
    return "\\begin{matrix}" .. table.concat(result, "\\\\")
        .. (trailing and "\\\\" or "") .. "\\end{matrix}"
end
T:test("matrix row limit includes the final row without a trailing separator", function()
    eq(#parsed(matrix(80, 1)).children[1].rows, 80, "80-row matrix accepted")
    rejected(matrix(81, 1), "matrix is too large")
end)
T:test("matrix column limit includes the final cell without a trailing separator", function()
    eq(#parsed(matrix(1, 24)).children[1].rows[1], 24, "24-column matrix accepted")
    rejected(matrix(1, 25), "matrix is too large")
end)
T:test("matrix size bounds apply equally with a trailing row separator", function()
    eq(#parsed(matrix(80, 1, true)).children[1].rows, 80, "trailing separator must not invent a row")
    rejected(matrix(81, 1, true), "matrix is too large")
end)

T:test("layout rejects excessively wide expressions as an error value", function()
    local value, err = Layout.layout(parsed(string.rep("x", 1001)), 20, true, measure)
    eq(value, nil, "oversized width must reject, not render clipped math")
    has(err, "too large", "width rejection explanation")
end)
T:test("layout rejects excessively tall expressions as an error value", function()
    local value, err = Layout.layout(parsed(matrix(80, 1)), 150, true, measure)
    eq(value, nil, "oversized height must reject, not render clipped math")
    has(err, "too large", "height rejection explanation")
end)

local schur_wide = [[M = \begin{bmatrix} A & B\\ B^T & D \end{bmatrix}, \quad \text{Schur complement of }A = D-B^T A^{-1}B.]]
local function reflow(source,width,size,display)
    local value,err=Layout.layout(parsed(source),size or 20,display~=false,measure,width)
    assert(value,err);return value
end
T:test("screenshot 1241 Schur formula reflows without losing or shrinking any terms", function()
    local natural=laidOut(schur_wide,36)
    for _,width in ipairs({720,560,460}) do
        local wrapped=reflow(schur_wide,width,36)
        assert(wrapped.line_count and wrapped.line_count>1,"wide answer must wrap")
        assert(wrapped.w<=width,"wrapped answer must fit the viewer")
        eq(glyphText(wrapped),glyphText(natural),"matrix, transpose, inverse and label all retained")
        local before,after=flatten(natural).glyphs,flatten(wrapped).glyphs
        for i,item in ipairs(after) do
            eq(item.size,before[i].size,"reflow does not shrink text")
            eq(item.style,before[i].style,"reflow preserves font style")
        end
        checkBoxBounds(wrapped)
    end
end)
T:test("wide display clauses prefer punctuation breaks before equation breaks", function()
    local value=reflow([[a=b,\quad c=d]],70)
    eq(value.line_count,2,"two complete equations")
    eq(glyphText(value.items[1].box),"a=b,","comma stays with preceding clause")
    eq(glyphText(value.items[2].box),"c=d","second equation stays intact")
    near(glyph(value,"a").y,glyph(value,"b").y,"first equation baseline")
    less(glyph(value,"b").y,glyph(value,"c").y,"second equation on next line")
end)
T:test("equation and sum continuations keep leading operators and every operand", function()
    for _,fixture in ipairs({{[[abcd=efgh]],68,"abcd","=efgh"},
        {[[abcd+efgh]],68,"abcd","+efgh"},{[[abcd-efgh]],68,"abcd","−efgh"}}) do
        local value=reflow(fixture[1],fixture[2])
        eq(value.line_count,2,"continuation line count")
        eq(glyphText(value.items[1].box),fixture[3],"first operand")
        eq(glyphText(value.items[2].box),fixture[4],"operator retained on continuation")
    end
end)
T:test("unary signs stay attached to their operand on continuation lines", function()
    local value=reflow([[abcd=-efgh]],86)
    eq(value.line_count,2,"equation wraps before equals")
    eq(glyphText(value.items[2].box),"=−efgh","unary sign is not a break point")
    for _,source in ipairs({[[abcd\cdot -efgh]], [[abcd/-efgh]], [[\sin -abcdefgh]],
        [[\sum_{i=1}^n -abcdefgh]], [[\int -abcdefgh]]}) do
        eq(reflow(source,60).line_count,nil,"unary sign after a product or prefix operator stays attached")
    end
end)
T:test("commas within numeric literals cannot become clause breaks", function()
    for _,source in ipairs({[[12,345,678]], [[12, 345, 678]]}) do
        local value=reflow(source,55)
        eq(value.line_count,nil,"numeric commas are indivisible")
        eq(glyphText(value),"12,345,678","numeric source remains complete")
    end
end)
T:test("automatic breaks do not split raw, scripted, sized or norm delimiters", function()
    for _,source in ipairs({[[(a+b+c+d)]], [[(a+b+c+d)^2]], [[\bigl(a+b+c+d\bigr)^2]],
        [[\left(a+b+c+d\right)]], [[|a+b+c+d|]], [[\Bigl\lVert a+b+c+d\Bigr\rVert]]}) do
        local value=reflow(source,55)
        eq(value.line_count,nil,"indivisible delimiters must use the honest width fallback")
        assert(value.w>55,"fixture must actually overflow")
        eq(glyphText(value),glyphText(laidOut(source)),"all bracketed content remains")
    end
end)
T:test("matrix cells, fractions, grouped math and text labels remain indivisible", function()
    for _,source in ipairs({[[\begin{bmatrix}a+b+c&d\\e&f\end{bmatrix}]], [[\frac{a+b+c+d}{e}]],
        [[{a+b+c+d}]], [[\text{a+b=c,d}]]}) do
        local value=reflow(source,45)
        eq(value.line_count,nil,"nested structure must not be split")
        assert(value.w>45,"fixture must overflow")
    end
end)
T:test("unbroken products do not become ambiguous separate lines", function()
    local value=reflow([[abcdefghijk]],50)
    eq(value.line_count,nil,"products have no safe automatic break")
    eq(glyphText(value),"abcdefghijk","all product factors stay visible")
end)
T:test("inline formulas and display formulas that fit keep their original geometry", function()
    for _,display in ipairs({true,false}) do
        local original=laidOut([[a+b=c]],20,display)
        local value=reflow([[a+b=c]],display and 300 or 40,20,display)
        eq(value.line_count,nil,"no unnecessary reflow")
        near(value.w,original.w,"original width")
        near(value.h,original.h,"original ascent")
        near(value.d,original.d,"original descent")
    end
end)
T:test("wrapped rows have clearance, bounded glyphs and stable layout on repeated widths", function()
    local source=[[\!a=b,\quad c=\frac{d}{e},\quad f=g\!]]
    local ast=parsed(source)
    local original=Layout.layout(ast,20,true,measure)
    for _,width in ipairs({75,110,75}) do
        local value=Layout.layout(ast,20,true,measure,width)
        assert(value.line_count,"fixture must wrap")
        for i,item in ipairs(value.items) do
            assert(item.box.w<=width,"row fits")
            if i>1 then
                local prev=value.items[i-1]
                less(prev.y+prev.box.d,item.y-item.box.h,"rows do not collide")
            end
        end
        for _,item in ipairs(flatten(value).glyphs) do
            assert(item.x>=-EPSILON and item.x+item.w<=value.w+EPSILON,"no glyph clipped")
        end
        eq(glyphText(value),glyphText(original),"stable source")
        checkBoxBounds(value)
    end
    near(Layout.layout(ast,20,true,measure).w,original.w,"reflow cannot mutate AST or earlier geometry")
end)
T:test("wrapping reuses measured boxes instead of measuring each candidate again", function()
    local calls=0
    local function counted(...) calls=calls+1;return measure(...) end
    local ast=parsed(schur_wide)
    Layout.layout(ast,20,true,counted);local count=calls;calls=0
    assert(Layout.layout(ast,20,true,counted,300).line_count,"fixture wraps")
    eq(calls,count,"candidate search must not repeat font measurement")
end)
T:test("unbalanced standalone delimiters and excessive break points fall back safely", function()
    for _,source in ipairs({[[(a+b+c]], [[a+b+c)]], string.rep("x+",130).."x"}) do
        eq(reflow(source,50).line_count,nil,"unsafe or excessive reflow must not occur")
    end
end)

-- Isolate module stubs and cache for every renderer contract. Preserve any
-- pre-existing modules so the repository's dofile-based test runner is safe.
local function withModules(replacements, fn)
    local previous = {}
    for name, replacement in pairs(replacements) do
        previous[name] = { loaded = package.loaded[name], preload = package.preload[name] }
        package.loaded[name] = nil
        package.preload[name] = replacement
    end
    local ok, err = pcall(fn)
    for name, saved in pairs(previous) do
        package.loaded[name], package.preload[name] = saved.loaded, saved.preload
    end
    if not ok then error(err, 0) end
end
local function withRenderer(fn)
    local previous = package.loaded.koassistant_math_renderer
    package.loaded.koassistant_math_renderer = nil
    local ok, err = pcall(function() fn(require("koassistant_math_renderer")) end)
    package.loaded.koassistant_math_renderer = previous
    if not ok then error(err, 0) end
end
local function decodeSource(html)
    local body = html:match("<code>(.-)</code>")
    assert(body, "source fallback must contain a code body: " .. html)
    body = body:gsub("<br/>", "\n")
    local entities = { amp = "&", lt = "<", gt = ">", quot = '"' }
    return (body:gsub("&([#%w]+);", function(entity)
        if entities[entity] then return entities[entity] end
        if entity:match("^#%d+$") then return string.char(tonumber(entity:sub(2))) end
        error("unexpected HTML entity in fallback: " .. entity)
    end))
end
local function successfulRenderer(fn)
    withModules({ mime = function() return { b64 = function(png)
        eq(png, "test PNG bytes", "renderer must encode returned PNG bytes")
        return "UE5H"
    end } end }, function()
        withRenderer(function(renderer)
            local calls = {}
            renderer.renderFormula = function(source, display, options)
                calls[#calls + 1] = { source = source, display = display, options = options }
                return { png = "test PNG bytes", width = 90, height = 40, ascent = 30, descent = 10 }
            end
            fn(renderer, calls)
        end)
    end)
end

T:test("renderer exposes strict parsing failures before loading native dependencies", function()
    withModules({ ["ffi/lodepng_h"] = function() error("native dependency must not be loaded") end }, function()
        withRenderer(function(renderer)
            for _, fixture in ipairs(bad_sources) do
                local image, err = renderer.renderFormula(fixture[1], true)
                eq(image, nil, "malformed formula must not rasterize")
                has(err, fixture[2], "strict parse reason must reach caller")
                lacks(err, "native dependency", "parser must fail before native setup")
            end
        end)
    end)
end)

T:test("every malformed/unknown formula has an exact, labeled source fallback", function()
    withRenderer(function(renderer)
        for _, fixture in ipairs(bad_sources) do
            local source = fixture[1]
            local output = renderer.render("\\[" .. source .. "\\]")
            has(output, "koa-math-fallback", "unsupported notation must be visibly labeled")
            has(output, "Math source (", "fallback explains that it is source")
            lacks(output, "koa-math-image", "unsupported notation must not pretend to be typeset")
            eq(decodeSource(output), source, "fallback must preserve every character of rejected expression")
        end
    end)
end)

T:test("source fallback escapes HTML and markdown without double-decoding literal entities", function()
    local source = '\\unknown{a_<b>*[c]&"d"\\$} &lt; </code><img src="bad">'
    withRenderer(function(renderer)
        local output = renderer.render("\\(" .. source .. "\\)")
        eq(decodeSource(output), source, "HTML-sensitive source round trip")
        lacks(output, '<img src="bad">', "source cannot inject HTML")
        local body = assert(output:match("<code>(.-)</code>"))
        for _, unsafe in ipairs({"_", "*", "[", "]", "\\", "$", "<", ">"}) do
            lacks(body, unsafe, "fallback must be safe for later markdown passes")
        end
    end)
end)

T:test("multiline fallback preserves indentation, repeated spaces and all lines", function()
    local source = "\n  \\unknown{x}  + y\n\t\\frac{a}{b}\n"
    withRenderer(function(renderer)
        local output = renderer.render("before $$" .. source .. "$$ after")
        eq(decodeSource(output), source, "fallback source whitespace must not be normalized")
        has(output, "before ", "prose before display math retained")
        has(output, " after", "prose after display math retained")
    end)
end)

T:test("renderer safely falls back with complete source when native dependencies are unavailable", function()
    withModules({ ["ffi/lodepng_h"] = function() error("unavailable in pure-Lua test") end }, function()
        withRenderer(function(renderer)
            local source = [[\frac{a+b}{\sqrt{c}}]]
            local image, reason = renderer.renderFormula(source, true)
            eq(image, nil, "missing native renderer must be recoverable")
            has(reason, "unavailable", "missing dependency explanation")
            local output = renderer.render("$$" .. source .. "$$")
            has(output, "koa-math-fallback", "unavailable renderer source fallback")
            eq(decodeSource(output), source, "native failure cannot lose source")
        end)
    end)
end)

T:test("renderer preserves exact source and display flags for every delimiter style", function()
    successfulRenderer(function(renderer, calls)
        local source = "A $x_i$ B \\( y^2 \\) C $$\\frac{a}{b}$$ D \\[\\sqrt{x}\\] E"
        local output = renderer.render(source, { font_size = 22, max_width = 480, max_height = 600 })
        eq(#calls, 4, "one render call per formula")
        local found = {}
        for _, call in ipairs(calls) do
            found[call.source] = call.display
            eq(call.options.font_size, 22, "font size passed through")
            eq(call.options.max_width, 480, "maximum width passed through")
            eq(call.options.max_height, 600, "maximum height passed through")
        end
        eq(found.x_i, false, "dollar inline mode")
        eq(found[" y^2 "], false, "parenthesized inline mode and whitespace")
        eq(found[ [[\frac{a}{b}]] ], true, "double-dollar display mode")
        eq(found[ [[\sqrt{x}]] ], true, "bracketed display mode")
        has(output, 'src="data:image/png;base64,UE5H"', "PNG data URI")
        has(output, 'width="90" height="40"', "returned image dimensions")
        has(output, '<p class="koa-math">', "display formula paragraph")
        has(output, "A ", "leading prose retained"); has(output, " E", "trailing prose retained")
        eq(source, "A $x_i$ B \\( y^2 \\) C $$\\frac{a}{b}$$ D \\[\\sqrt{x}\\] E", "stored source unchanged")
    end)
end)

T:test("renderer passes an entire aligned display block through without flattening or splitting", function()
    successfulRenderer(function(renderer, calls)
        local source = [[\begin{aligned}a&=\frac{x}{y}\\b&=\sqrt{z}\end{aligned}]]
        local output = renderer.render("$$" .. source .. "$$")
        eq(#calls, 1, "aligned block must become one two-dimensional formula")
        eq(calls[1].source, source, "aligned source separators preserved")
        eq(calls[1].display, true, "aligned block display mode")
        local _, count = output:gsub("koa%-math%-image", "")
        eq(count, 1, "single image for the full aligned layout")
    end)
end)

T:test("renderer leaves code, currency prose, unmatched delimiters and no-math inputs untouched", function()
    successfulRenderer(function(renderer, calls)
        local documents = {
            "plain **bold** and _underline_", "Price $5 today; $10 tomorrow", "just $5$ here",
            "unfinished $$x+1", "unclosed \\(x^2", "`$x$` and ``\\(y\\)``",
            "before\n```latex\n$$\\frac{x}{y}$$\n```\nafter\n", "$ x $ spaced",
        }
        for _, source in ipairs(documents) do eq(renderer.render(source), source, "non-math identity") end
        eq(renderer.render(nil), nil, "nil document identity")
        eq(#calls, 0, "protected/non-math inputs cannot trigger formula rendering")
    end)
end)

T:test("renderer only transforms math outside code and preserves trailing newlines", function()
    successfulRenderer(function(renderer, calls)
        local source = "`$x$`\n```\n$$y$$\n```\n$z$\n"
        local output = renderer.render(source)
        eq(#calls, 1, "only unprotected formula rendered")
        eq(calls[1].source, "z", "correct unprotected formula")
        has(output, "`$x$`\n```\n$$y$$\n```\n", "all code remains literal")
        eq(output:sub(-1), "\n", "trailing newline preserved")
    end)
end)

T:test("successful render cache keys include source, mode, size and view bounds", function()
    successfulRenderer(function(renderer, calls)
        local first = renderer.render("$x$", { font_size = 20, max_width = 500, max_height = 600 })
        eq(renderer.render("$x$", { font_size = 20, max_width = 500, max_height = 600 }), first, "cache hit output")
        eq(#calls, 1, "identical render should reuse image")
        renderer.render("$y$", { font_size = 20, max_width = 500, max_height = 600 })
        renderer.render("$$x$$", { font_size = 20, max_width = 500, max_height = 600 })
        renderer.render("$x$", { font_size = 21, max_width = 500, max_height = 600 })
        renderer.render("$x$", { font_size = 20, max_width = 501, max_height = 600 })
        renderer.render("$x$", { font_size = 20, max_width = 500, max_height = 601 })
        eq(#calls, 6, "all material render options must invalidate the image key")
    end)
end)

T:test("renderer cache evicts old entries instead of growing without bound", function()
    successfulRenderer(function(renderer, calls)
        for i = 1, 65 do renderer.render("$x_{" .. i .. "}$") end
        eq(#calls, 65, "every distinct formula rendered once")
        renderer.render("$x_{65}$")
        eq(#calls, 65, "newest formula stays cached")
        renderer.render("$x_{1}$")
        eq(#calls, 66, "oldest formula must be evicted at the 64-entry cap")
    end)
end)

T:test("failed rendering is not cached, so later recovery can produce a real formula", function()
    withModules({ mime = function() return { b64 = function() return "UE5H" end } end }, function()
        withRenderer(function(renderer)
            local calls = 0
            renderer.renderFormula = function()
                calls = calls + 1
                if calls == 1 then return nil, "temporarily unavailable" end
                return { png = "png", width = 12, height = 20 }
            end
            local first = renderer.render("$x$")
            eq(decodeSource(first), "x", "failed render retains source")
            has(renderer.render("$x$"), "koa-math-image", "second attempt must recover")
            eq(calls, 2, "fallback must not poison successful-render cache")
        end)
    end)
end)

print(string.format("\n  Math layout results: %d passed, %d failed", T.passed, T.failed))
if arg and arg[0] and arg[0]:match("test_math_layout%.lua$") then
    os.exit(T.failed == 0 and 0 or 1)
end
return T.failed == 0
