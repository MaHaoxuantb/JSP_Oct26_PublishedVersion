"""JSP-Oct26-GPU-Multicore; ©2026 ThomasB. Isolated native build only."""
import pathlib,subprocess,sys
here=pathlib.Path(__file__).resolve().parent;root=here.parent.parent
out=pathlib.Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
release=pathlib.Path(sys.argv[2]);sources=sorted(p for p in (root/'JaneStreetPuzzle_Oct26').glob('*.swift') if p.name!='main.swift')
subprocess.run(['swiftc','-O','-module-cache-path',str(out/'modules'),'-I',str(release/'Modules'),*map(str,sources),str(here/'MulticoreWorker.swift'),*map(str,(release/'PuzzleRules.build').glob('*.o')),'-o',str(out/'multicore-worker')],check=True)
