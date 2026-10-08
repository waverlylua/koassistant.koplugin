-- Run with KOReader's LuaJIT from its runtime directory after setupkoenv.
local root = assert(os.getenv('KOASSISTANT_SOURCE'))
package.path = root .. '/?.lua;' .. root .. '/tests/lib/?.lua;' .. package.path
local T = require('test_runner'):new()
local Store = require('koassistant_question_store')
local Queue = require('koassistant_question_queue')
local lfs = require('libs/libkoreader-lfs')
local json = require('json')
local base = os.tmpname(); os.remove(base); assert(lfs.mkdir(base))
local function read(p) local f=assert(io.open(p,'rb'));local s=f:read('*a');f:close();return s end
local function write(p,s) local f=assert(io.open(p,'wb'));f:write(s);f:close() end
local function job(id,doc)
 return {id=id,state='completed',attempts=1,document={id=doc,file='/fixture.pdf',title='Fixture'},config={system='system context'},
 prompt='Explain $x^2$',selected_text='source **text**',answer='answer $2x$',messages={{role='user',content={{type='text',text='source **text**'},{type='image_url',image_url={url='data:image/png;base64,aW1hZ2U='}}}}}}
end
local s=Store:new(base..'/ai-inbox');local a,b=job('1','aa'),job('2','bb');local data={version=1,next_id=3,jobs={a,b}}
T:test('per-document manifests and separate Markdown and binary image files',function()
 assert(s:save(data));local m=json.decode(read(base..'/ai-inbox/aa/document.json'))
 T:assertEqual(read(base..'/ai-inbox/aa/'..m.jobs[1].files.prompt),a.prompt)
 T:assertEqual(read(base..'/ai-inbox/aa/question-1/source.png'),'image')
 T:assertFalse(read(base..'/ai-inbox/aa/document.json'):find('aW1hZ2U=',1,true))
 T:assertFalse(lfs.attributes(base..'/ai-inbox/index.json'))
end)
T:test('restart reads metadata only and round trips exact request/config',function()
 s=Store:new(base..'/ai-inbox');data=assert(s:load());a=data.jobs[1];b=data.jobs[2]
 T:assertEqual(a.answer,nil);T:assertEqual(#a.messages,0);T:assertEqual(a.prompt_preview,'Explain $x^2$')
 assert(s:hydrate(a));T:assertEqual(a.answer,'answer $2x$');T:assertEqual(a.config.system,'system context')
 T:assertEqual(a.messages[1].content[2].image_url.url,'data:image/png;base64,aW1hZ2U=')
end)
T:test('metadata changes preserve unhydrated payloads and unrelated manifest',function()
 local before=read(base..'/ai-inbox/aa/document.json');b.read=true;assert(s:save(data))
 T:assertEqual(read(base..'/ai-inbox/aa/document.json'),before)
 assert(s:hydrate(b));T:assertEqual(b.answer,'answer $2x$')
end)
T:test('failed manifest replacement leaves committed payload intact and is retryable',function()
 a.answer='changed answer';local rename=os.rename
 os.rename=function(from,to) if to:match('/aa/document.json$') then return nil,'injected failure' end;return rename(from,to) end
 local ok=s:save(data);os.rename=rename;T:assertFalse(ok)
 local old=Store:new(base..'/ai-inbox');local d=assert(old:load());assert(old:hydrate(d.jobs[1]));T:assertEqual(d.jobs[1].answer,'answer $2x$')
 assert(s:save(data));local new=Store:new(base..'/ai-inbox');d=assert(new:load());assert(new:hydrate(d.jobs[1]));T:assertEqual(d.jobs[1].answer,'changed answer')
end)
T:test('remove commits manifest then cleans payload and preserves ID high water',function()
 data.jobs={b};assert(s:save(data));T:assertFalse(lfs.attributes(base..'/ai-inbox/aa/question-1'))
 data.jobs={};assert(s:save(data));local d=assert(Store:new(base..'/ai-inbox'):load());T:assertEqual(d.next_id,3);T:assertEqual(#d.jobs,0)
end)
T:test('legacy file is neither read nor modified',function()
 local p=base..'/koassistant_question_inbox.json';write(p,'old test inbox deliberately invalid');assert(Store:new(base..'/new-ai-inbox'):save({jobs={},next_id=1}));T:assertEqual(read(p),'old test inbox deliberately invalid')
end)
T:test('symlink payload and path traversal are rejected',function()
 T:assertFalse(pcall(function() s:_path('aa','../outside') end))
 assert(lfs.link(base..'/koassistant_question_inbox.json',base..'/ai-inbox/aa/link',true))
 T:assertFalse(pcall(function() s:_path('aa','link') end))
end)
T:test('corrupt manifest is reported without replacement',function()
 local p=base..'/ai-inbox/aa/document.json';write(p,'broken');local loaded,err=Store:new(base..'/ai-inbox'):load();T:assertEqual(loaded,nil);T:assertTrue(err);T:assertEqual(read(p),'broken')
end)

local function fresh(name)
    return Store:new(base .. '/' .. name)
end
local function with_patch(target, key, replacement, callback)
    local original = target[key]
    target[key] = replacement(original)
    local ok, err = pcall(callback)
    target[key] = original
    assert(ok, err)
end
local function queue_for(store)
    local h = { pending = {}, starts = {} }
    h.queue = Queue:new{
        load = function() return store:load() end,
        save = function(d) return store:save(d) end,
        hydrate = function(j) return store:hydrate(j) end,
        now = os.time,
        schedule = function(fn) h.pending[#h.pending + 1] = fn end,
        start = function(j, finish) h.starts[#h.starts + 1] = {job=j, finish=finish} end,
    }
    function h:tick()
        local pending = self.pending; self.pending = {}
        for _, fn in ipairs(pending) do fn() end
    end
    return h
end
T:test('startup does not open Markdown or image payloads', function()
    local store = fresh('metadata-only')
    assert(store:save({jobs={job('1','aa')}, next_id=2}))
    local opened = 0
    with_patch(io, 'open', function(original)
        return function(path, mode)
            if path:find(store.path,1,true) then
                T:assertTrue(path:match('/document%.json$') ~= nil)
                opened = opened + 1
            end
            return original(path,mode)
        end
    end, function() assert(fresh('metadata-only'):load()) end)
    T:assertEqual(opened, 1)
end)
T:test('retry syncs a payload whose rename succeeded before directory sync failed', function()
    local store = fresh('asset-sync'); local d={jobs={job('1','aa')},next_id=2}
    local syncs = 0
    with_patch(require('ffi/util'), 'fsyncDirectory', function(original)
        return function(path)
            if path:match('/question%-1/question%.md$') then
                syncs = syncs + 1
                if syncs == 1 then return nil, 'injected payload directory sync failure' end
            end
            return original(path)
        end
    end, function()
        T:assertFalse(store:save(d))
        T:assertFalse(lfs.attributes(store.path..'/aa/document.json'))
        assert(store:save(d))
    end)
    T:assertEqual(syncs,2)
    local reloaded = fresh('asset-sync'); local jobs=assert(reloaded:load()).jobs
    assert(reloaded:hydrate(jobs[1]));T:assertEqual(jobs[1].prompt,d.jobs[1].prompt)
end)
T:test('retry syncs a directory whose creation succeeded before sync failed', function()
    local store=fresh('mkdir-sync');local syncs=0
    with_patch(require('ffi/util'), 'fsyncDirectory', function(original)
        return function(path)
            if path==store.path then
                syncs=syncs+1
                if syncs==1 then return nil,'injected mkdir sync failure' end
            end
            return original(path)
        end
    end,function()
        T:assertFalse(store:save({jobs={},next_id=1}))
        assert(store:save({jobs={},next_id=1}))
    end)
    T:assertEqual(syncs,2)
end)
T:test('failed first manifest sync reconciles failed enqueue without a ghost job or send', function()
    local store=fresh('first-manifest-sync');local h=queue_for(store);local failed=false
    with_patch(require('ffi/util'), 'fsyncDirectory', function(original)
        return function(path)
            if not failed and path:match('/document%.json$') then
                failed=true;return nil,'injected manifest directory sync failure'
            end
            return original(path)
        end
    end,function()
        T:assertEqual(h.queue:enqueue(job('1','aa')),nil)
        T:assertEqual(#h.queue.jobs,0)
        h:tick();T:assertEqual(#h.starts,0)
        assert(h.queue:retrySave())
    end)
    local d=assert(fresh('first-manifest-sync'):load())
    T:assertEqual(#d.jobs,0);T:assertEqual(d.next_id,2)
    local nextjob=assert(h.queue:enqueue(job('2','aa')))
    T:assertEqual(nextjob.id,'2');h:tick();T:assertEqual(#h.starts,1)
end)
T:test('restart interrupts saved running and queued records without hydration or resend', function()
    local store=fresh('restart');local h=queue_for(store)
    assert(h.queue:enqueue(job('1','aa')));assert(h.queue:enqueue(job('2','bb')));h:tick()
    T:assertEqual(#h.starts,1)
    local restarted=queue_for(fresh('restart'));restarted:tick()
    T:assertEqual(#restarted.starts,0)
    for _,j in ipairs(restarted.queue.jobs) do
        T:assertEqual(j.state,'interrupted');T:assertEqual(#j.messages,0)
    end
    assert(restarted.queue:retry('2'));restarted:tick()
    T:assertEqual(#restarted.starts,1)
    T:assertEqual(restarted.starts[1].job.messages[1].content[2].image_url.url,'data:image/png;base64,aW1hZ2U=')
end)
T:test('failed result save retains answer and retry saving never resends it', function()
    local store=fresh('result-sync');local h=queue_for(store)
    assert(h.queue:enqueue(job('1','aa')));h:tick()
    with_patch(os,'rename',function(original)
        return function(from,to)
            if to:match('/document%.json$') then return nil,'injected result failure' end
            return original(from,to)
        end
    end,function() h.starts[1].finish(true,'Retained $x^2$ answer') end)
    T:assertTrue(h.queue.storage_error);T:assertEqual(h.queue:get('1').answer,'Retained $x^2$ answer')
    h:tick();assert(h.queue:retrySave());h:tick();T:assertEqual(#h.starts,1)
    local restarted=queue_for(fresh('result-sync'));restarted:tick()
    T:assertEqual(restarted.queue:get('1').answer,'Retained $x^2$ answer');T:assertEqual(#restarted.starts,0)
end)
T:test('follow-up request remains exact after parent removal and process restart', function()
    local store=fresh('followup');local parent=job('1','aa')
    parent.config.provider='openai';parent.config.model='gpt-4o'
    local child=assert(require('koassistant_question_followup').prepare(parent,'Why?'))
    child.id='2';child.state='completed';child.attempts=1;child.answer='Because.'
    assert(store:save({jobs={parent,child},next_id=3}))
    assert(store:save({jobs={child},next_id=3}))
    local reload=fresh('followup');local d=assert(reload:load());T:assertEqual(#d.jobs,1)
    assert(reload:hydrate(d.jobs[1]))
    T:assertEqual(d.jobs[1].messages[2].content,parent.answer)
    T:assertEqual(d.jobs[1].messages[1].content[2].image_url.url,parent.messages[1].content[2].image_url.url)
    T:assertFalse(lfs.attributes(store.path..'/aa/question-1'))
end)
T:test('missing payload blocks retry but metadata read and confirmed removal still work', function()
    local store=fresh('missing');local j=job('1','aa');j.state='failed'
    assert(store:save({jobs={j},next_id=2}));assert(os.remove(store.path..'/aa/question-1/source.png'))
    local h=queue_for(fresh('missing'))
    local ok,err=h.queue:retry('1');T:assertEqual(ok,nil);T:assertTrue(err:find('Could not open saved question',1,true))
    T:assertTrue(h.queue:get('1',true));assert(h.queue:remove('1'));h:tick();T:assertEqual(#h.starts,0)
end)
T:test('malformed arrays, IDs and payload descriptors fail closed without overwriting files', function()
    local mutations={
        function(m) m.jobs={hidden=m.jobs[1]} end,
        function(m) m.jobs={m.jobs[1],json.null,m.jobs[1]} end,
        function(m) m.next_id=1 end,
        function(m) m.next_id=1.5 end,
        function(m) m.jobs[1].files.state='question-1/question.md' end,
        function(m) m.jobs[1].files.answer='question-2/answer.md' end,
        function(m) m.jobs[1].request[1].content[1].text.inbox_file='../outside' end,
        function(m) m.jobs[1].request[1].content[2].image_url.url.encoding='unknown' end,
    }
    for i,mutate in ipairs(mutations) do
        local store=fresh('invalid-'..i);assert(store:save({jobs={job('1','aa')},next_id=2}))
        local path=store.path..'/aa/document.json';local m=json.decode(read(path));mutate(m)
        local bytes=json.encode(m);write(path,bytes)
        local h=queue_for(fresh('invalid-'..i))
        T:assertTrue(h.queue.load_error);T:assertEqual(h.queue:retrySave(),nil)
        T:assertEqual(read(path),bytes);h:tick();T:assertEqual(#h.starts,0)
    end
end)

T:test('hydrated metadata changes reuse payloads without file reads or syncs', function()
    local store=fresh('payload-reuse');local j=job('1','aa');local d={jobs={j},next_id=2}
    assert(store:save(d));j.read=true
    with_patch(io,'open',function(original)
        return function(path,mode)
            T:assertFalse(path:find('/question-1/',1,true))
            return original(path,mode)
        end
    end,function() assert(store:save(d)) end)
    j.answer='A changed answer'
    assert(store:save(d))
    local reload=fresh('payload-reuse');local saved=assert(reload:load()).jobs[1]
    assert(reload:hydrate(saved));T:assertEqual(saved.answer,j.answer)
end)
T:test('preview limits preserve complete UTF-8 code points at mixed-script boundaries', function()
    local store=fresh('utf8');local j=job('1','aa')
    j.prompt=string.rep('x',191)..'文📚';j.selected_text=string.rep('y',95)..'📚文'
    assert(store:save({jobs={j},next_id=2}))
    local d=assert(fresh('utf8'):load());T:assertEqual(d.jobs[1].prompt_preview,string.rep('x',191))
    T:assertEqual(d.jobs[1].source_preview,string.rep('y',95))
    local m=read(store.path..'/aa/document.json')
    T:assertFalse(m:find(string.char(0xe6)..'"',1,true))
end)
os.exit(T:summary() and 0 or 1)
