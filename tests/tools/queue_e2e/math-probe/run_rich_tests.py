#!/usr/bin/env python3
import pathlib,os,subprocess,signal,shutil,json,time
R=pathlib.Path(__file__).resolve().parent.parent;OUT=R/'math-probe';KR=pathlib.Path(os.getenv('KOREADER_RUNTIME',str(R/'package-runtime' if (R/'package-runtime').exists() else R/'lib/koreader')))
h=OUT/('home-'+str(int(time.time())));(h/'patches').mkdir(parents=True);(h/'settings').mkdir()
shutil.copy(OUT/'rich_math_patch.lua',h/'patches/2-rich-math-test.lua');shutil.copy(R/'fixtures/queue-math-fixture.pdf',h/'fixture.pdf')
(h/'settings.reader.lua').write_text('return {language="en",color_rendering=true,has_seen_welcome=true}')
(h/'settings/koassistant_settings.lua').write_text('return {provider="openai",model="gpt-4o-mini",setup_wizard_completed=true,features={auto_check_updates=false,enable_streaming=false}}')
(h/'settings/gestures.lua').write_text('return {gesture_fm={},gesture_reader={tap_top_left_corner={refresh_content=true}},custom_multiswipes={}}')
for n in ('events.jsonl','provider.jsonl'):
 p=OUT/n
 if p.exists():p.rename(p.with_suffix('.previous-'+str(int(time.time()))))
s=subprocess.Popen(['python',str(R/'mock_provider.py'),'--port','8767'],env={**os.environ,'MOCK_LOG':str(OUT/'provider.jsonl'),'MOCK_PLAN':str(OUT/'plan.json')},stdout=(OUT/'server.log').open('w'),stderr=subprocess.STDOUT,start_new_session=True)
try:
 time.sleep(.2)
 for phase in ('flow','recover'):
  with (OUT/('reader-'+phase+'.log')).open('w') as f:
   p=subprocess.run(['./luajit','reader.lua',str(h/'fixture.pdf')],cwd=KR,env={**os.environ,'KO_HOME':str(h),'SDL_VIDEODRIVER':'dummy','SDL_RENDER_DRIVER':'software','EMULATE_READER_W':'600','EMULATE_READER_H':'800','RICH_E2E_ROOT':str(OUT),'RICH_E2E_PHASE':phase},stdout=f,stderr=subprocess.STDOUT,timeout=60)
   print(phase,p.returncode,flush=True);assert p.returncode==0
 requests=[json.loads(l) for l in (OUT/'provider.jsonl').read_text().splitlines() if json.loads(l).get('event')=='received'];assert len(requests)==1,requests
 print('PASS exactly one provider request; restart did not resubmit')
finally:os.killpg(s.pid,signal.SIGTERM);s.wait()
