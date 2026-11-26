#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Isolated public Swift HTTP client against a finite synthetic SSE peer."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import unittest
import urllib.request
import urllib.error

TOOLS = {'toolsListChanged': True}
BOTH = dict(TOOLS, promptsListChanged=True)
URIS = {'resourceSubscriptions': ['file:///one', 'file:///two']}
TASKS = {'taskIds': ['t1', 't2']}
KEY = 'io.modelcontextprotocol/subscriptionId'
FOREIGN = 'foreign-subscription'
# The observed callback labels and typed outcomes are independently asserted
# in the Swift overlay; the process checker requires every case exactly once.
CASES = {
    'valid-subset': (BOTH, 'complete', 'ack,tools'),
    'callback-error': (TOOLS, 'callbackError', 'ack'),
    'before-ack': (TOOLS, 'invalidResponse', ''),
    'foreign-ack': (TOOLS, 'invalidResponse', ''),
    'duplicate-ack': (TOOLS, 'invalidResponse', 'ack'),
    'expanded-ack': (TOOLS, 'invalidResponse', ''),
    'foreign-event': (TOOLS, 'invalidResponse', 'ack'),
    'unacknowledged-event': (BOTH, 'invalidResponse', 'ack'),
    'foreign-terminal': (TOOLS, 'invalidResponse', 'ack'),
    'resource-uri': (URIS, 'invalidResponse', 'ack'),
    'extension-valid': (TASKS, 'complete', 'ack,extension'),
    'extension-foreign': (TASKS, 'invalidResponse', 'ack'),
    'no-ack': (TOOLS, 'invalidResponse', ''),
    'after-terminal': (TOOLS, 'invalidResponse', 'ack'),
}


def need(ok, message):
    if not ok:
        raise RuntimeError(message)


def frames(case, ident):
    def event(method, sid=ident, **params):
        return {'jsonrpc':'2.0','method':method,'params':{'_meta':{KEY:sid},**params}}
    def ack(filter=TOOLS, sid=ident):
        return event('notifications/subscriptions/acknowledged',sid,notifications=filter)
    def close(sid=ident):
        return {'jsonrpc':'2.0','id':ident,'result':{'resultType':'complete','_meta':{KEY:sid}}}
    tool=event('notifications/tools/list_changed')
    task=lambda sid: event('notifications/tasks',sid,taskId='t1',status='completed')
    return {
        'valid-subset':[ack(),tool,close()],
        'callback-error':[ack(),tool,close()],
        'before-ack':[tool,ack(),close()],
        'foreign-ack':[ack(sid=FOREIGN),close()],
        'duplicate-ack':[ack(),ack(),close()],
        'expanded-ack':[ack(BOTH),close()],
        'foreign-event':[ack(),event('notifications/tools/list_changed',FOREIGN),close()],
        'unacknowledged-event':[ack(),event('notifications/prompts/list_changed'),close()],
        'foreign-terminal':[ack(),close(FOREIGN)],
        'resource-uri':[ack({'resourceSubscriptions':['file:///one']}),event('notifications/resources/updated',uri='file:///two'),close()],
        'extension-valid':[ack({'taskIds':['t1']}),task(ident),close()],
        'extension-foreign':[ack({'taskIds':['t1']}),task(FOREIGN),close()],
        'no-ack':[close()],
        'after-terminal':[ack(),close(),tool],
    }[case]


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self,*args):
        pass
    def do_POST(self):
        self.connection.settimeout(10)
        self.close_connection=True
        try:
            case=self.path.removeprefix('/mcp/')
            need(self.path == '/mcp/'+case and case in CASES,'unexpected route')
            length=int(self.headers.get('Content-Length','0'))
            need(0 < length <= 65536,'unexpected body size')
            body=self.rfile.read(length)
            need(len(body)==length,'short request')
            req=json.loads(body)
            ident=req.get('id')
            need(type(ident) is int,'expected actual numeric request ID')
            need(req.get('jsonrpc')=='2.0' and req.get('method')=='subscriptions/listen','wrong request')
            need(self.headers.get('Mcp-Method')=='subscriptions/listen' and
                 self.headers.get('MCP-Protocol-Version')=='2026-07-28','wrong HTTP MCP metadata')
            need('text/event-stream' in self.headers.get('Accept',''),'SSE not accepted')
            params=req.get('params',{})
            need(params.get('_meta',{}).get('io.modelcontextprotocol/protocolVersion')=='2026-07-28','wrong body protocol')
            need(params.get('notifications')==CASES[case][0],'unexpected requested filter')
            offered=frames(case,ident)
            with self.server.lock:
                need(case not in self.server.requests,'duplicate request')
                self.server.requests[case]={'id':ident,'requested':params['notifications'],'offeredFrames':offered}
            payload=b''.join(b'data: '+json.dumps(frame,separators=(',',':')).encode()+b'\n\n' for frame in offered)
            self.send_response(200)
            self.send_header('Content-Type','text/event-stream')
            self.send_header('Content-Length',str(len(payload)))
            self.send_header('Connection','close')
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
        except Exception as exc:
            with self.server.lock:
                self.server.errors.append(str(exc))
            # No retry or fallback success on a malformed request.
            self.close_connection=True


class Peer(ThreadingHTTPServer):
    daemon_threads=False
    block_on_close=True
    def __init__(self):
        self.lock=threading.Lock()
        self.requests={}
        self.errors=[]
        super().__init__(('127.0.0.1',0),Handler)
        self.thread=threading.Thread(target=self.serve_forever,kwargs={'poll_interval':0.05})
    @property
    def url(self):
        return f'http://127.0.0.1:{self.server_port}/mcp'
    def __enter__(self):
        self.thread.start()
        return self
    def __exit__(self,*_):
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=5)
        need(not self.thread.is_alive(),'peer supervisor did not join')


def audit(log, requests, errors):
    need(not errors,'peer request errors: '+str(errors))
    need(set(requests)==set(CASES),'missing or unexpected peer cases')
    for name,(filter,_,_) in CASES.items():
        row=requests[name]
        need(type(row['id']) is int and row['requested']==filter and row['offeredFrames']==frames(name,row['id']), 'peer receipt differs '+name)
    rows=re.findall(r'^A22A_HTTP case=([a-z-]+) verdict=([A-Za-z]+) callbacks=([a-z,]*)\s*$',log,re.M)
    expected={(name,verdict,callbacks) for name,(_,verdict,callbacks) in CASES.items()}
    need(len(rows)==len(expected) and set(rows)==expected,'missing, duplicate or incorrect Swift case receipt')
    need(sum(int(n) for n in re.findall(r'Test run with (\d+) tests? in \d+ suites? passed',log))==1,'expected one passing parameterized Swift test function')
    return len(rows)


def qualify(checkout,mode,out):
    need(mode in ('debug','release'),'invalid mode')
    source=Path(__file__).resolve().parents[1]/'Tools/Diagnostics/A22AHTTPAdmissionProbe.swift'
    overlay=checkout/'Tests/MCPHTTPClientTests/A22AHTTPAdmissionProbe.swift'
    need(not overlay.exists(),'overlay would overwrite existing file')
    out.mkdir(parents=True,exist_ok=False)
    original=source.read_bytes()
    (out/'overlay.sha256').write_text(hashlib.sha256(original).hexdigest()+'\n')
    (out/'overlay.swift').write_bytes(original)
    with Peer() as peer:
        rc=None
        try:
            overlay.write_bytes(original)
            env=dict(os.environ,MCP_A22A_PROBE_URL=peer.url)
            args=['swift','test','--force-resolved-versions','--jobs','2','-c',mode,'--filter','A22AHTTPAdmissionProbe']
            with (out/'swift.log').open('wb') as f:
                rc=subprocess.run(args,cwd=checkout,env=env,stdout=f,stderr=subprocess.STDOUT,check=False).returncode
            need(overlay.read_bytes()==original,'overlay bytes changed')
        finally:
            if overlay.exists(): overlay.unlink()
            (out/'process.json').write_text(json.dumps({'exit':rc,'mode':mode},indent=2)+'\n')
    (out/'peer.json').write_text(json.dumps({'requests':peer.requests,'errors':peer.errors,'joined':not peer.thread.is_alive()},indent=2,sort_keys=True)+'\n')
    need(rc==0,'Swift HTTP admission probe failed; inspect swift.log')
    count=audit((out/'swift.log').read_text(errors='replace'),peer.requests,peer.errors)
    (out/'decision.json').write_text(json.dumps({'outcome':'PASS_A22A_HTTP_ADMISSION','cases':count,'mode':mode,'peer_joined':True},indent=2)+'\n')
    print(f'PASS_A22A_HTTP_ADMISSION: {count}/{len(CASES)} cases; joined synthetic peer')


class Controls(unittest.TestCase):
    def fixture_log(self):
        return '\n'.join(f'A22A_HTTP case={n} verdict={v} callbacks={c}' for n,(_,v,c) in CASES.items())+'\nTest run with 1 test in 1 suite passed\n'
    def fixture_requests(self):
        return {n:{'id':7,'requested':f,'offeredFrames':frames(n,7)} for n,(f,_,_) in CASES.items()}
    def test_receipt(self):
        self.assertEqual(audit(self.fixture_log(),self.fixture_requests(),[]),14)
    def test_missing_case(self):
        with self.assertRaises(RuntimeError): audit(self.fixture_log().split('\n',1)[1],self.fixture_requests(),[])
    def test_wrong_callback(self):
        with self.assertRaises(RuntimeError): audit(self.fixture_log().replace('callbacks=ack,tools','callbacks=ack,prompts'),self.fixture_requests(),[])
    def test_duplicate_case(self):
        with self.assertRaises(RuntimeError): audit(self.fixture_log()+self.fixture_log(),self.fixture_requests(),[])
    def test_peer_error(self):
        with self.assertRaises(RuntimeError): audit(self.fixture_log(),self.fixture_requests(),['bad request'])
    def test_loopback(self):
        with Peer() as peer:
            for name,(filter,_,_) in CASES.items():
                body={'jsonrpc':'2.0','id':42,'method':'subscriptions/listen','params':{'_meta':{'io.modelcontextprotocol/protocolVersion':'2026-07-28'},'notifications':filter}}
                request=urllib.request.Request(peer.url+'/'+name,data=json.dumps(body).encode(),headers={'Content-Type':'application/json','Mcp-Method':'subscriptions/listen','MCP-Protocol-Version':'2026-07-28','Accept':'text/event-stream'})
                with urllib.request.urlopen(request,timeout=5) as response:
                    self.assertEqual(response.headers['Content-Type'],'text/event-stream')
                    actual=[json.loads(line[6:]) for line in response.read().splitlines() if line.startswith(b'data: ')]
                    self.assertEqual(actual,frames(name,42))
        self.assertEqual(audit(self.fixture_log(),peer.requests,peer.errors),14)


if __name__=='__main__':
    if sys.argv[1:]==['--selftest']:
        unittest.main(argv=[sys.argv[0]],verbosity=2)
    else:
        need(len(sys.argv)==4,'usage: probe CHECKOUT debug|release OUTPUT')
        qualify(Path(sys.argv[1]).resolve(),sys.argv[2],Path(sys.argv[3]).resolve())
