local script = debug.getinfo(1, "S").source:sub(2)
local root = script:match("^(.*)/tests/unit/") or "."
package.path = root .. "/?.lua;" .. root .. "/tests/lib/?.lua;" .. package.path
local T=require("test_runner"):new()
local Page=require("koassistant_question_page")
local function harness()
    local h={closed=0,freed=0,draws={}}
    h.ui={view={state={page=3,zoom=8,rotation=90}},document={info={has_pages=true},render_mode=0,configurable={text_wrap=1},_document={}}}
    function h.ui.document._document:openPage(number)
        return {getSize=function() return 595.2756,841.8898 end,
            draw=function(_self,dc,bb,x,y) h.draws[#h.draws+1]={page=number,zoom=dc.zoom,rotate=dc.rotate,w=bb.w,h=bb.h,x=x,y=y} end,
            close=function() h.closed=h.closed+1 end}
    end
    h.deps={now=function() return 1234 end,capture=function(ui) return {document={page=ui.view.state.page,file="/book.pdf"},selected_text=""} end,
        BB={TYPE_BBRGB32=1,COLOR_WHITE=1,new=function(w,hh) return {w=w,h=hh,fill=function() end,free=function() h.freed=h.freed+1 end} end},
        DC={new=function() return {setZoom=function(self,v) self.zoom=v end,setRotate=function(self,v) self.rotate=v end,setOffset=function() end,setGamma=function() end,setSaturation=function() end,setBackgroundCleanup=function() end} end},
        encode=function(bb) return {data="PNG-"..bb.w.."-"..bb.h,width=bb.w,height=bb.h} end}
    return h
end
T:test("whole page is native original page independent of zoom rotation reflow and viewport",function()
    local h=harness();local a=assert(Page.capture(h.ui,h.deps))
    h.ui.view.state.zoom=20;h.ui.view.state.rotation=180
    local b=assert(Page.capture(h.ui,h.deps))
    T:assertEqual(a.image.data,b.image.data);T:assertEqual(h.draws[1].rotate,0)
    T:assertEqual(a.image.height,1800);T:assertTrue(a.image.width<=1800)
    T:assertEqual(a.document.capture_kind,"whole_page");T:assertEqual(a.document.page,3)
    T:assertEqual(a.document.captured_at,1234);T:assertEqual(a.document.end_page,3)
    T:assertEqual(h.closed,2);T:assertEqual(h.freed,2)
end)
T:test("page navigation cannot retarget a previously captured whole page",function()
    local h=harness();local a=assert(Page.capture(h.ui,h.deps));h.ui.view.state.page=5
    local b=assert(Page.capture(h.ui,h.deps))
    T:assertEqual(a.document.page,3);T:assertEqual(b.document.page,5)
    T:assertEqual(h.draws[1].page,3);T:assertEqual(h.draws[2].page,5)
end)
T:test("encode failure closes native page and frees buffer without snapshot",function()
    local h=harness();h.deps.encode=function() return nil,"encoding failed" end
    local a,err=Page.capture(h.ui,h.deps)
    T:assertEqual(a,nil);T:assertEqual(err,"encoding failed");T:assertEqual(h.closed,1);T:assertEqual(h.freed,1)
end)
T:test("render failure releases native resources and never falls back to viewport",function()
    local h=harness();h.ui.document._document.openPage=function() return {getSize=function() return 600,800 end,draw=function() error("broken page") end,close=function() h.closed=h.closed+1 end} end
    local a,err=Page.capture(h.ui,h.deps)
    T:assertEqual(a,nil);T:assertTrue(err:find("broken page",1,true));T:assertEqual(h.closed,1);T:assertEqual(h.freed,1)
end)
T:test("nonpaged document and unknown current page fail closed",function()
    local h=harness();h.ui.document.info.has_pages=false;T:assertEqual(Page.capture(h.ui,h.deps),nil)
    h.ui.document.info.has_pages=true;h.ui.view.state.page=nil;T:assertEqual(Page.capture(h.ui,h.deps),nil)
    T:assertEqual(#h.draws,0)
end)
return T:summary()
