import json,os,subprocess,tempfile,time,unittest
from pathlib import Path
from benchqueue.storage import Store,atomic_json,digest
from benchqueue.controller import admit,freeze_jobs,conditions,validate_result,Controller
from benchqueue.validation import evaluate,validate_certificate,canonical_partition,puzzle_orbit_key
from benchqueue.server import snapshot,series

def config(root):return dict(id='test-only',sizes=[1],boards_per_size=1,seeds=[42],trial_seconds=1,workers=4,preparation_workers=1,preparation_seconds=1,preparation_slice_seconds=.2,infrastructure_retries=2,order_seed=42,shape_store=str(root/'shapes.sqlite'),tools=os.environ.get('BENCH_TOOLS',''),worker=os.environ.get('BENCH_WORKER',''))
def certificate():return dict(puzzle=dict(id='p',n=1,clues=[-1]),solutionCount=1,solutions=[[0]],answers=[1],exhausted=True,rules='symmetric-capitol-integer-paths-v1',generator='orbit-connected-subsets-v1',nodes=1)
class QueueTests(unittest.TestCase):
 def setUp(self):self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.store=Store(self.root);self.c=config(self.root);self.store.create(self.c)
 def tearDown(self):self.temp.cleanup()
 def test_gate_and_unknown_rejection(self):
  with self.assertRaises(ValueError):freeze_jobs(self.store)
  cert=certificate();cert['exhausted']=False
  with self.assertRaises(ValueError):admit(self.store,dict(n=1,slot=0),dict(qualified=[cert]))
  self.assertEqual(self.store.rows('jobs'),[]);self.assertEqual(self.store.rows('boards'),[])
 def test_cert_independence_and_density(self):
  self.assertEqual(validate_certificate(certificate())['independentlyValidatedSolutions'],1)
  bad=certificate();bad['answers']=[2]
  with self.assertRaises(ValueError):validate_certificate(bad)
  bad=certificate();bad['puzzle']['clues']=[0]
  with self.assertRaises(ValueError):validate_certificate(bad)
 def test_known_example(self):
  rows=['ABBCC','ABBDC','AADDC','CAAAC','CCCCC'];labels=[ord(c) for r in rows for c in r];clues=[12,-1,-1,-1,17,8,-1,6,3,-1,-1,-1,-1,-1,-1,-1,7,6,-1,10,25,-1,-1,-1,0]
  self.assertEqual(evaluate(labels,5,clues)['answer'],8045)
 def test_distinct_boards_and_all_conditions(self):
  self.assertTrue(admit(self.store,dict(n=1,slot=0),dict(qualified=[certificate()])))
  self.assertFalse(admit(self.store,dict(n=1,slot=1),dict(qualified=[certificate()])))
  self.assertEqual(len(self.store.rows('boards')),1)
  Path(self.c['shape_store']).write_bytes(b'cache');self.store.set('shape_sha256',digest(self.c['shape_store']));freeze_jobs(self.store)
  self.assertEqual(len(self.store.rows('jobs')),8);self.assertEqual(len({j['id'] for j in self.store.rows('jobs')}),8)
  freeze_jobs(self.store);self.assertEqual(len(self.store.rows('jobs')),8)
 def test_failed_attempt_retry_limit(self):
  admit(self.store,dict(n=1,slot=0),dict(qualified=[certificate()]));Path(self.c['shape_store']).write_bytes(b'cache');self.store.set('shape_sha256',digest(self.c['shape_store']));freeze_jobs(self.store)
  job=self.store.rows('jobs')[0];controller=Controller(self.root)
  for i in range(1,4):
   folder=self.root/f'attempt{i}';folder.mkdir();a=dict(id=f'a{i}',job_id=job['id'],seq=i,pid=0,nonce='x',started=time.time(),status='running',directory=str(folder))
   with self.store.connect() as db:db.execute('INSERT INTO attempts(id,job_id,seq,pid,nonce,started,status,directory) VALUES(:id,:job_id,:seq,:pid,:nonce,:started,:status,:directory)',a)
   controller.finish_attempt(a);j=self.store.rows('jobs','WHERE id=?',(job['id'],))[0];self.assertEqual(j['status'],'pending' if i<3 else 'failed')
 def test_api_no_invented_values(self):
  snap=snapshot(self.store);self.assertEqual(snap['boards'],[]);self.assertEqual(snap['jobs'],[]);self.assertEqual(snap['planned'],8);self.assertEqual(series(self.store,'missing')['samples'],[])
 @unittest.skipUnless(os.environ.get('BENCH_TOOLS'),'Swift executables not supplied')
 def test_real_tiny_campaign_all_eight_conditions(self):
  # Explicit miniature integration test, never mixed with the N=5…9 campaign.
  subprocess.run([self.c['tools'],'precache','--db',self.c['shape_store'],'--progress',str(self.root/'shape-progress.json'),'--manifest',str(self.root/'shapes.json')],check=True)
  self.store.set('shape_sha256',digest(self.c['shape_store']));admit(self.store,dict(n=1,slot=0),dict(qualified=[certificate()]));freeze_jobs(self.store)
  Controller(self.root).trials();jobs=self.store.rows('jobs');self.assertEqual(len(jobs),8);self.assertEqual({j['status'] for j in jobs},{'solved'});self.assertEqual(len(self.store.rows('attempts')),8)
  sample=series(self.store,jobs[0]['id']);self.assertGreaterEqual(len(sample['samples']),2)
  for job in jobs:self.assertTrue(json.loads(job['result'])['solved'])

class ProcessRecoveryTests(unittest.TestCase):
 setUp=QueueTests.setUp
 tearDown=QueueTests.tearDown
 @unittest.skipUnless(os.environ.get('BENCH_PROCESS_TESTS'),'Process inspection requires an unsandboxed test run')
 def test_live_adoption_and_explicit_stop(self):
  from benchqueue.controller import owns
  admit(self.store,dict(n=1,slot=0),dict(qualified=[certificate()]));Path(self.c['shape_store']).write_bytes(b'cache');self.store.set('shape_sha256',digest(self.c['shape_store']));freeze_jobs(self.store)
  job=self.store.rows('jobs')[0];folder=self.root/'adoption';folder.mkdir();marker=str(folder/'input.json');Path(marker).write_text('{}')
  import sys
  process=subprocess.Popen([sys.executable,'-c','import time;time.sleep(20)',marker])
  a=dict(id='live',job_id=job['id'],seq=1,pid=process.pid,nonce='unique-test',started=time.time(),status='running',directory=str(folder))
  with self.store.connect() as db:db.execute('INSERT INTO attempts(id,job_id,seq,pid,nonce,started,status,directory) VALUES(:id,:job_id,:seq,:pid,:nonce,:started,:status,:directory)',a)
  try:
   controller=Controller(self.root);controller.recover();self.assertEqual(len(controller.processes),1);self.assertEqual(controller.processes[job['id']]['pid'],process.pid)
   (self.root/'STOP').touch();controller.trials();process.wait(timeout=5)
   self.assertEqual(self.store.rows('attempts')[0]['status'],'interrupted');self.assertEqual(self.store.rows('jobs','WHERE id=?',(job['id'],))[0]['status'],'pending')
  finally:
   if process.poll() is None:process.kill();process.wait()

class CurrentPuzzleAdmissionTests(unittest.TestCase):
 setUp=QueueTests.setUp
 tearDown=QueueTests.tearDown
 def prepare_saved(self):
  state=self.root/'state.json';atomic_json(state,dict(puzzle=dict(id='current',n=1,clues=[-1]),witness=[0],nodes=10,search=dict(solutions=[],counters=dict(nodes=3))))
  with self.store.connect() as db:db.execute('INSERT INTO prep(id,n,slot,status,state_path,progress_path) VALUES(?,?,?,?,?,?)',('n1-b1',1,0,'pending',str(state),str(self.root/'progress.json')))
  Path(self.c['shape_store']).write_bytes(b'cache');self.store.set('shape_sha256',digest(self.c['shape_store']))
  self.c['admission_policy']='validated_witness';self.store.set('config',self.c)
 def test_current_clues_admitted_without_false_unique_claim(self):
  from benchqueue.controller import freeze_current_puzzles
  self.prepare_saved();freeze_current_puzzles(self.store)
  boards=self.store.rows('boards');self.assertEqual(len(boards),1);self.assertIsNone(boards[0]['solution_count']);record=json.loads(boards[0]['certificate']);self.assertFalse(record['exhausted']);self.assertEqual(record['puzzle']['clues'],[-1]);self.assertEqual(record['solutions'],[[0]]);self.assertEqual(len(self.store.rows('jobs')),8)
  self.assertIn('Unknown (not certified)',(self.root/'report/REPORT.md').read_text())
  self.assertIsNone(snapshot(self.store)['boards'][0]['solution_count'])
  with self.assertRaises(ValueError):freeze_current_puzzles(self.store)
 def test_current_admission_requires_explicit_policy(self):
  from benchqueue.controller import freeze_current_puzzles
  self.prepare_saved();self.c.pop('admission_policy');self.store.set('config',self.c)
  with self.assertRaises(ValueError):freeze_current_puzzles(self.store)
  self.assertEqual(self.store.rows('boards'),[])
 def test_invalid_current_witness_does_not_open_queue(self):
  from benchqueue.controller import freeze_current_puzzles
  self.prepare_saved();state=json.loads((self.root/'state.json').read_text());state['puzzle']['clues']=[1];atomic_json(self.root/'state.json',state)
  with self.assertRaises(ValueError):freeze_current_puzzles(self.store)
  self.assertEqual(self.store.rows('boards'),[]);self.assertEqual(self.store.rows('jobs'),[])
 def test_waiver_does_not_fake_exact_count(self):
  from benchqueue.validation import validate_fixture
  record=certificate();record['exhausted']=False
  with self.assertRaises(ValueError):validate_fixture(record,True)

if __name__=='__main__':unittest.main()
