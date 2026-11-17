"""Offline API tests. No Windows command, device action or AD change is executed."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
import uuid
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bridge', ROOT / 'WindowsBridge/bridge.py')
bridge = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = bridge
spec.loader.exec_module(bridge)
TOKEN = 'a' * 43
OTHER = 'b' * 43

def config():
    return {'allowedHosts':['bridge.test'],'directoryServer':'dc.test','operators':[
        {'id':'alice','tokenSHA256':hashlib.sha256(TOKEN.encode()).hexdigest(),'targets':['PC001.test'],'actions':sorted(bridge.ACTIONS)},
        {'id':'bob','tokenSHA256':hashlib.sha256(OTHER.encode()).hexdigest(),'targets':['PC002.test'],'actions':['Inventory']}]}

class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.database = Path(self.temp.name)/'jobs.db'
        self.calls=[]
        def runner(req):
            self.calls.append((req.action, req.target, dict(req.payload)))
            return {'message':'completed'}
        self.app=bridge.create_app(config(),self.database,runner)
        self.client=TestClient(self.app,base_url='https://bridge.test')
        self.headers={'Authorization':'Bearer '+TOKEN}
    def tearDown(self):
        self.app.state.store.pool.shutdown(wait=True)
        self.temp.cleanup()
    def submit(self,action='Inventory',target='PC001.test',payload=None,confirmed=False,ident=None,headers=None):
        return self.client.post('/v1/jobs',json={'requestId':ident or str(uuid.uuid4()),'action':action,'target':target,'payload':payload or {},'confirmed':confirmed},headers=headers or self.headers)
    def complete(self,ident):
        for _ in range(100):
            r=self.client.get('/v1/jobs/'+ident,headers=self.headers).json()
            if r['state'] not in ('queued','running'):return r
            time.sleep(.01)
        self.fail('Mock job failed to complete')
    def test_auth_and_https(self):
        self.assertEqual(self.client.get('/v1/capabilities').status_code,401)
        self.assertEqual(self.client.get('/v1/capabilities',headers=self.headers).status_code,200)
        self.assertEqual(self.client.get('http://bridge.test/v1/capabilities',headers=self.headers).status_code,400)
        self.assertEqual(self.client.get('https://wrong.test/v1/capabilities',headers=self.headers).status_code,400)
    def test_target_and_action_authorization(self):
        self.assertEqual(self.submit(target='OTHER').status_code,403)
        self.assertEqual(self.submit(action='RunShell').status_code,403)
        self.assertEqual(self.submit(action='Restart',confirmed=True,headers={'Authorization':'Bearer '+OTHER}).status_code,403)
        self.assertEqual(self.calls,[])
    def test_confirmation_and_validation(self):
        self.assertEqual(self.submit(action='Restart').status_code,409)
        self.assertEqual(self.submit(payload={'Command':'whoami'}).status_code,422)
        self.assertEqual(self.submit(action='PopupMessage',confirmed=True,payload={'Title':'Hello','Message':'x'*2001,'Seconds':60}).status_code,422)
    def test_dedup_and_lookup(self):
        request=str(uuid.uuid4())
        a=self.submit(action='Restart',confirmed=True,ident=request)
        self.assertEqual(a.status_code,202)
        b=self.submit(action='Restart',confirmed=True,ident=request)
        self.assertEqual(a.json(),b.json())
        self.assertEqual(self.complete(a.json()['id'])['state'],'succeeded')
        self.assertEqual(len(self.calls),1)
        self.assertEqual(self.client.get('/v1/requests/'+request,headers=self.headers).json(),a.json())
        self.assertEqual(self.submit(ident=request).status_code,409)
    def test_jobs_are_owner_scoped(self):
        ident=self.submit().json()['id']
        self.assertEqual(self.client.get('/v1/jobs/'+ident,headers={'Authorization':'Bearer '+OTHER}).status_code,404)
    def test_directory_pins_server_and_no_password_persistence(self):
        payload={'ObjectGUID':str(uuid.uuid4()),'DistinguishedName':'CN=Tester,DC=test','SamAccountName':'tester','Password':'do-not-store-SECRET','ChangeAtLogon':True}
        r=self.submit(action='DirectoryResetPassword',target='attacker.test',payload=payload,confirmed=True)
        self.assertEqual(r.status_code,202)
        self.assertEqual(self.complete(r.json()['id'])['target'],'dc.test')
        self.assertEqual(self.calls[0][1],'dc.test')
        self.assertNotIn(b'do-not-store-SECRET',self.database.read_bytes())
    def test_validation_never_echoes_password(self):
        data={'requestId':'not-a-uuid','action':'DirectoryResetPassword','payload':{'Password':'do-not-echo-SECRET'}}
        r=self.client.post('/v1/jobs',json=data,headers=self.headers)
        self.assertEqual(r.status_code,422)
        self.assertNotIn('do-not-echo-SECRET',r.text)
    def test_write_failure_is_unknown_and_never_retried(self):
        def broken(req): raise RuntimeError('secret-input-must-not-escape')
        request=bridge.JobRequest(requestId=uuid.uuid4(),action='Restart',target='PC001.test',confirmed=True)
        ident=self.app.state.store.submit('alice',request,broken)
        r=self.complete(ident)
        self.assertEqual(r['state'],'unknown')
        self.assertNotIn('secret-input',json.dumps(r))
        again=self.app.state.store.submit('alice',request,broken)
        self.assertEqual(ident,again)

    def test_payload_size_limit(self):
        r=self.client.post('/v1/jobs',content='x'*17000,headers={**self.headers,'Content-Type':'application/json'})
        self.assertEqual(r.status_code,413)
    def test_restart_marks_unfinished_unknown(self):
        with sqlite3.connect(self.database) as db:
            db.execute("INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?,?)",('test-id','alice',str(uuid.uuid4()),'Restart','PC001.test','running',time.time(),None,None))
        store=bridge.Store(self.database)
        self.assertEqual(store.record('test-id','alice')['state'],'unknown')
        store.pool.shutdown()
    def test_expired_results_not_returned(self):
        ident=self.submit().json()['id'];self.complete(ident)
        with sqlite3.connect(self.database) as db:db.execute('UPDATE jobs SET created=? WHERE id=?',(time.time()-1900,ident))
        r=self.client.get('/v1/jobs/'+ident,headers=self.headers).json()
        self.assertEqual(r['state'],'expired');self.assertIsNone(r['result'])

if __name__=='__main__':unittest.main()
