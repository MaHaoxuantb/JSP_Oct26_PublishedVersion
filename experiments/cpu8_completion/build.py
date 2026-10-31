"""JSP-Oct26-CPU8-Completion; ©2026 ThomasB. Native scratch builds only."""
import pathlib,subprocess,sys,os
here=pathlib.Path(__file__).resolve().parent;repo=here.parent.parent;scratch=pathlib.Path(sys.argv[1]).resolve()
env=dict(os.environ,SWIFTPM_MODULECACHE_OVERRIDE=str(scratch/'modules'),CLANG_MODULE_CACHE_PATH=str(scratch/'modules'))
subprocess.run(['swift','build','--build-system','native','--disable-sandbox','--package-path',str(repo/'experiments/repair_completion'),'--scratch-path',str(scratch),'-c','release'],env=env,check=True)
release=next(scratch.glob('*/release/completion-worker')).parent
objects=[str(p) for name in ['PuzzleRules','ShapeDomain','SolverCore','RepairPolicies'] for p in (release/(name+'.build')).glob('*.o')]
subprocess.run(['swiftc','-O','-parse-as-library','-module-cache-path',str(scratch/'modules'),'-I',str(release/'Modules'),'-I',str(repo/'experiments/solver_bench/Sources/CSQLite'),str(repo/'JaneStreetPuzzle_Oct26/SoftwareVersion.swift'),str(here/'Sources/CPU8Worker/main.swift'),*objects,'-lsqlite3','-o',str(release/'cpu8-worker')],check=True)
print(release/'cpu8-worker')
# Compile the existing authority preflight against the same release sources.
core=sorted(p for p in (repo/'JaneStreetPuzzle_Oct26').glob('*.swift') if p.name!='main.swift')
probe=release/'authority-preflight'
subprocess.run(['swiftc','-O','-D','PATHS_CPU_ONLY','-module-cache-path',str(scratch/'modules'),'-I',str(release/'Modules'),*map(str,core),str(repo/'experiments/repair_completion/ProductionAdapter/ProductionWorker.swift'),*map(str,(release/'PuzzleRules.build').glob('*.o')),'-o',str(probe)],check=True)
raw=subprocess.check_output([str(probe),'--preflight'])
import json
import re
version=int(re.search(r'current\s*=\s*(\d+)',(repo/'JaneStreetPuzzle_Oct26/SoftwareVersion.swift').read_text()).group(1))
v=json.loads(raw);assert v['softwareVersion']==version and v['minimumPeerVersion']==version
assert v['strictAcceptsCurrent'] and not v['strictAcceptsOlder'] and v['transitionalAcceptsLegacy'] and not v['transitionalAcceptsFuture']
(release/'authority-preflight.json').write_bytes(raw)
