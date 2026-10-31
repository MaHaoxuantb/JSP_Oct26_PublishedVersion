"""JSP-Oct26-GPU-Multicore; ©2026 ThomasB. Fetch closed/append-only evidence."""
import json,pathlib,subprocess,sys,tarfile
p=json.load(open('/private/tmp/jsp-gpu-multicore-current.json'));out=pathlib.Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
script='''import pathlib,tarfile,sys
r=pathlib.Path(ROOT)
with tarfile.open(fileobj=sys.stdout.buffer,mode='w|gz') as t:
 for p in r.rglob('*'):
  if p.is_file() and 'source' not in p.relative_to(r).parts and 'bin' not in p.relative_to(r).parts and p.name!='run.lock':
   t.add(p,arcname=str(p.relative_to(r)))
'''.replace('ROOT',repr(p['root']))
archive=out/'JSP-Oct26-GPU-Multicore-Evidence.tar.gz'
with archive.open('wb') as f:subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','thomasb@192.168.4.173','/usr/bin/python3 -'],input=script.encode(),stdout=f,check=True)
with tarfile.open(archive) as t:
 for member in t.getmembers():
  target=(out/member.name).resolve()
  if target.is_relative_to(out.resolve()) and member.isfile():
   target.parent.mkdir(parents=True,exist_ok=True)
   with t.extractfile(member) as src,target.open('wb') as dest:dest.write(src.read())
print(json.load(open(out/'state.json'))['phase'])
