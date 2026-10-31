"""JSP-Oct26-Search-Escape; ©2026 ThomasB. Isolated native products."""
import pathlib,subprocess,sys,os,json,re
here=pathlib.Path(__file__).resolve().parent;repo=here.parent.parent;scratch=pathlib.Path(sys.argv[1]).resolve()
env=dict(os.environ,SWIFTPM_MODULECACHE_OVERRIDE=str(scratch/'modules'),CLANG_MODULE_CACHE_PATH=str(scratch/'modules'))
# Authority lives outside SwiftPM: compile the harness with the authority directly.
subprocess.run(['swift','build','--build-system','native','--disable-sandbox','--package-path',str(here),'--scratch-path',str(scratch),'-c','release','--target','EscapePolicies'],env=env,check=True)
release=next(scratch.glob('*/release/Modules')).parent
objects=[str(p) for name in ['PuzzleRules','ShapeDomain','SolverCore','RepairPolicies','EscapePolicies'] for p in (release/(name+'.build')).glob('*.o')]
subprocess.run(['swiftc','-O','-parse-as-library','-module-cache-path',str(scratch/'modules'),'-I',str(release/'Modules'),'-I',str(repo/'experiments/solver_bench/Sources/CSQLite'),str(repo/'JaneStreetPuzzle_Oct26/SoftwareVersion.swift'),str(here/'Sources/EscapeWorker/Worker.swift'),*objects,'-lsqlite3','-o',str(release/'cpu8-worker')],check=True)
core=sorted(p for p in (repo/'JaneStreetPuzzle_Oct26').glob('*.swift') if p.name!='main.swift')
probe=release/'authority-preflight'
subprocess.run(['swiftc','-O','-D','PATHS_CPU_ONLY','-module-cache-path',str(scratch/'modules'),'-I',str(release/'Modules'),*map(str,core),str(repo/'experiments/repair_completion/ProductionAdapter/ProductionWorker.swift'),*map(str,(release/'PuzzleRules.build').glob('*.o')),'-o',str(probe)],check=True)
v=json.loads(subprocess.check_output([str(probe),'--preflight']));version=int(re.search(r'current\s*=\s*(\d+)',(repo/'JaneStreetPuzzle_Oct26/SoftwareVersion.swift').read_text()).group(1))
assert v['softwareVersion']==version==v['minimumPeerVersion'] and v['strictAcceptsCurrent'] and not v['strictAcceptsOlder'] and v['transitionalAcceptsLegacy'] and not v['transitionalAcceptsFuture']
(release/'authority-preflight.json').write_text(json.dumps(v));print(release/'cpu8-worker')
