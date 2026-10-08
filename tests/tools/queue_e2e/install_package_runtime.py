#!/usr/bin/env python3
"""Install an authored plugin ZIP in isolated runtime without touching desktop UI instance."""
import pathlib,zipfile,sys,os
R=pathlib.Path(__file__).resolve().parent; source=R/'lib/koreader'; root=R/'package-runtime';root.mkdir(exist_ok=True)
for p in source.iterdir():
 if p.name=='plugins': continue
 target=root/p.name
 if not target.exists() and not target.is_symlink():target.symlink_to(p)
plugins=root/'plugins';plugins.mkdir(exist_ok=True)
for p in (source/'plugins').iterdir():
 if p.name=='koassistant.koplugin':continue
 target=plugins/p.name
 if not target.exists() and not target.is_symlink():target.symlink_to(p)
archive=pathlib.Path(sys.argv[1]);out=plugins/'koassistant.koplugin'
# Never delete prior test output; each archive gets a fresh install directory.
if out.exists():out.rename(plugins/('koassistant-prior-'+str(len(list(plugins.glob('koassistant-prior-*'))))))
out.mkdir()
with zipfile.ZipFile(archive) as z:
 names=z.namelist();prefix='koassistant.koplugin/' if any(n.startswith('koassistant.koplugin/') for n in names) else ''
 for n in names:
  if not n.startswith(prefix):continue
  rel=pathlib.PurePosixPath(n[len(prefix):])
  if not rel.parts:continue
  assert not rel.is_absolute() and '..' not in rel.parts, 'unsafe archive path'
  dest=out/rel
  if n.endswith('/'):dest.mkdir(parents=True,exist_ok=True);continue
  dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(z.read(n))
assert (out/'main.lua').is_file(),'archive plugin root not found'
(out/'configuration.lua').write_text("return {provider='openai',model='gpt-4o-mini',provider_settings={openai={base_url='http://127.0.0.1:8765/v1/chat/completions'}},features={enable_streaming=false,enable_web_search=false,auto_check_updates=false,render_markdown=true}}\n")
(out/'apikeys.lua').write_text("return {openai='local-mock-only-no-credential'}\n")
print(root)
