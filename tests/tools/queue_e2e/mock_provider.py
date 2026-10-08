#!/usr/bin/env python3
"""Local-only delayed OpenAI-compatible fixture. Never contacts a paid provider."""
import http.server,json,time,pathlib,threading,argparse,os
ROOT=pathlib.Path(__file__).resolve().parent
LOG=pathlib.Path(os.getenv('MOCK_LOG',str(ROOT/'logs/provider.jsonl'))); PLAN=pathlib.Path(os.getenv('MOCK_PLAN',str(ROOT/'provider_plan.json'))); LOCK=threading.Lock(); count=0

def log(data):
 with LOCK:
  with LOG.open('a') as f: f.write(json.dumps({'time':time.time(),**data},ensure_ascii=False)+'\n')
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  body=json.dumps({'ok':True,'requests':count}).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def do_POST(self):
  global count
  raw=self.rfile.read(int(self.headers.get('content-length',0)));body=json.loads(raw)
  with LOCK: count+=1; rid=count
  plan=json.loads(PLAN.read_text()) if PLAN.exists() else {}
  delay=plan.get('delay_seconds',20); status=plan.get('status',200)
  log({'event':'received','id':rid,'path':self.path,'body':body,'delay_seconds':delay,'planned_status':status})
  time.sleep(delay)
  messages=body.get('messages',body.get('input',[]))
  def message_text(m):
   content=m.get('content','')
   return content if isinstance(content,str) else '\n'.join(p.get('text','') for p in content if p.get('type')=='text')
  text='\n'.join(message_text(m) for m in messages if m.get('role')=='user')
  answer=f'### Local fixture answer {rid}\n\nRequest {rid} stayed linked to its captured question.\n\n'+text[-600:]+'\n\nThe derivative of $x^2 + nx + 1$ is $2x+n$.\n\n$$\\frac{d}{dx}(x^2+nx+1)=2x+n$$\n\nNo external AI service was contacted.'
  if plan.get('answer_mode')=='clean_math':
   answer=('### Local test response\n\n'
           'For $f(x)=x^2+4x+1$, differentiate each term.\n\n'
           'The power rule gives $x^2 \\mapsto 2x$. The linear term gives $4x \\mapsto 4$, and the constant gives $1 \\mapsto 0$.\n\n'
           '$$f\'(x)=2x+4$$\n\n'
           'A canned local response for testing the queue and math display. No external AI service was contacted.')
  if isinstance(plan.get('answer_text'),str): answer=plan['answer_text']
  data={'id':f'mock-{rid}','object':'chat.completion','created':int(time.time()),'model':body.get('model','test-model'),'choices':[{'index':0,'message':{'role':'assistant','content':answer},'finish_reason':'stop'}],'usage':{'prompt_tokens':20,'completion_tokens':40,'total_tokens':60}} if status==200 else {'error':{'message':f'Intentional E2E HTTP {status}','type':'test_failure','code':'test_failure'}}
  raw=json.dumps(data).encode()
  try:
   self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw);log({'event':'responded','id':rid,'status':status})
  except (BrokenPipeError,ConnectionResetError):log({'event':'client_disconnected','id':rid,'status':status})
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=8765);a=p.parse_args();LOG.parent.mkdir(exist_ok=True);log({'event':'server_started'});http.server.ThreadingHTTPServer(('127.0.0.1',a.port),Handler).serve_forever()
