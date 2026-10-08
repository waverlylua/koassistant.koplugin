require('setupkoenv')
package.path='plugins/koassistant.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(require('datastorage'):getDataDir()..'/settings.reader.lua')
local BB=require('ffi/blitbuffer')
local Region=require('koassistant_question_region')
local mime=require('mime')
local p=require('datastorage'):getSettingsDir()..'/koassistant_region.tmp.png'
local old=BB.new(32,32,BB.TYPE_BBRGB32);old:fill(BB.COLOR_BLACK);old:writePNG(p);old:free()
local f=assert(io.open(p,'rb'));local stale=f:read('*a');f:close()
assert(os.execute('chmod 444 '..p)==0)
local new=BB.new(32,32,BB.TYPE_BBRGB32);new:fill(BB.COLOR_WHITE)
local result,err=Region.encode(new);new:free()
os.execute('chmod 600 '..p..' 2>/dev/null');os.remove(p)
if result and result.data==mime.b64(stale) then error('FAIL: native writePNG silent failure reused stale prior image') end
print('PASS: stale prior image never transmitted',result and 'fresh PNG' or tostring(err))

local dir=require('datastorage'):getSettingsDir()
assert(os.execute('chmod 555 '..dir)==0)
local failed=BB.new(32,32,BB.TYPE_BBRGB32);failed:fill(BB.COLOR_WHITE)
local ok,rejected,reason=pcall(Region.encode,failed);failed:free()
os.execute('chmod 755 '..dir)
assert(ok and rejected==nil,'FAIL: native PNG write failure was not rejected')
print('PASS: native unwritable destination fails closed',reason)
