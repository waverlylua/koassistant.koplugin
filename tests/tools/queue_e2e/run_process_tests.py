#!/usr/bin/env python3
"""Real KOReader process + local HTTP integration, no unit mocks. Requires downloaded runtime."""
import pathlib,os,subprocess,json,time,signal,shutil,sys
R=pathlib.Path(__file__).resolve().parent; KR=pathlib.Path(os.getenv('KOREADER_RUNTIME',str(R/'lib/koreader'))); fixture=R/'fixtures/queue-math-fixture.pdf'
def prepare(name):
 home=R/name;home.mkdir(exist_ok=True);shutil.copy(fixture,home/'queue-math-fixture.pdf');(home/'patches').mkdir(exist_ok=True);(home/'settings').mkdir(exist_ok=True)
 shutil.copy(R/'integration_patch.lua',home/'patches/2-queue-e2e.lua')
 (home/'settings.reader.lua').write_text('return {language="en",color_rendering=true,has_seen_welcome=true,ges_hold_interval_ms=30}\n')
 (home/'settings/koassistant_settings.lua').write_text('return {provider="openai",model="gpt-4o-mini",setup_wizard_completed=true,features={auto_check_updates=false,enable_streaming=false}}\n')
 return home
def launch(home,phase):
 env={**os.environ,'KO_HOME':str(home),'SDL_VIDEODRIVER':'dummy','SDL_RENDER_DRIVER':'software','E2E_ROOT':str(R),'E2E_PHASE':phase,'EMULATE_READER_W':'600','EMULATE_READER_H':'800'}
 f=(R/f'logs/reader-{phase}.log').open('w')
 return subprocess.Popen([str(KR/'luajit'),'reader.lua',str(home/'queue-math-fixture.pdf')],cwd=KR,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
def events(phase):
 p=R/f'logs/process-{phase}.jsonl';return [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []
def receipts():
 p=R/'logs/provider-process.jsonl';return [json.loads(l) for l in p.read_text().splitlines() if json.loads(l).get('event')=='received'] if p.exists() else []
def runphase(home,phase,timeout=45):
 p=launch(home,phase)
 try: code=p.wait(timeout)
 except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);raise
 ev=events(phase);assert code==0 and any(x['event']=='DONE' for x in ev),(phase,code,ev[-3:]);return ev
if __name__=='__main__':
 for phase in ('flow','crash','recover','vision'):
  p=R/f'logs/process-{phase}.jsonl'
  if p.exists():p.rename(p.with_suffix('.jsonl.previous'))
 p=R/'logs/provider-process.jsonl'
 if p.exists():p.rename(p.with_suffix('.jsonl.previous'))
 server=subprocess.Popen([sys.executable,str(R/'mock_provider.py'),'--port','8766'],env={**os.environ,'MOCK_LOG':str(p),'MOCK_PLAN':str(R/'process-plan.json')},stdout=(R/'logs/mock-process.log').open('w'),stderr=subprocess.STDOUT,start_new_session=True)
 try:
  time.sleep(.2)
  stamp=str(int(time.time()));home=prepare('process-home-'+stamp);ev=runphase(home,'flow')
  rec=receipts();assert all(x['body'].get('model')=='gpt-4o-mini' for x in rec), 'wire model changed after enqueue';assert len(rec)==5,('flow expected exactly5 requests',len(rec));print('FLOW PASS',sum(x['event']=='PASS' for x in ev),'checks; exactly5 requests',flush=True)
  crashhome=prepare('crash-home-'+stamp);p=launch(crashhome,'crash')
  deadline=time.time()+15
  while time.time()<deadline and not any(x['event']=='CRASH_READY' for x in events('crash')):time.sleep(.1)
  assert any(x['event']=='CRASH_READY' for x in events('crash')),'crash never reached request boundary'
  before=len(receipts());os.killpg(p.pid,signal.SIGKILL);p.wait();assert before==6,('crash expected one new request',before)
  ev=runphase(crashhome,'recover');assert len(receipts())==before,'restart submitted duplicate request'
  print('RECOVERY PASS',sum(x['event']=='PASS' for x in ev),'checks; zero repeat requests',flush=True)
  vision_checks=0
  if (KR/'plugins/koassistant.koplugin/koassistant_question_region.lua').exists():
   config=KR/'plugins/koassistant.koplugin/configuration.lua';original=config.read_text();config.write_text(original.replace('127.0.0.1:8765','127.0.0.1:8766'))
   try:ve=runphase(prepare('vision-home-'+stamp),'vision')
   finally:config.write_text(original)
   wire=receipts()[-1]['body'];assert any(isinstance(m.get('content'),list) and any(p.get('type')=='image_url' for p in m['content']) for m in wire['messages']), 'image missing at actual HTTP boundary';assert len(receipts())==before+1,'vision expected exactly one request'
   vision_checks=sum(x['event']=='PASS' for x in ve);print('VISION PASS',vision_checks,'checks; actual PNG reached local HTTP',flush=True)
  summary={'result':'PASS','vision_assertions':vision_checks,'flow_assertions':sum(x['event']=='PASS' for x in events('flow')),'recovery_assertions':sum(x['event']=='PASS' for x in ev),'provider_requests':len(receipts()),'home':str(home),'recovery_home':str(crashhome),'runtime':'KOReader v2026.07.1 Linux SDL3 dummy','method':'Real app/process integration with synthetic method calls, not manual UI input'}
  (R/'logs/process-summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2))
 finally:os.killpg(server.pid,signal.SIGTERM);server.wait()
