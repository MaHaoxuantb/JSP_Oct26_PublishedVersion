"""JSP-Oct26-GPU-Quick; ©2026 ThomasB. Isolated build, no deployment."""
import pathlib,subprocess,sys
here=pathlib.Path(__file__).resolve().parent;repo=here.parent.parent;out=pathlib.Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
subprocess.run(['clang++','-O3','-std=c++17','-c',str(here/'cpu.cpp'),'-o',str(out/'cpu.o')],check=True)
sources=[repo/'experiments/solver_bench/Sources/PuzzleRules'/f for f in ['Types.swift','Rules.swift']]
for f in ['ShapeOracle.swift','CoverSearch.swift']:
 p=out/f;p.write_text((repo/'experiments/solver_bench/Sources/ShapeDomain'/f).read_text().replace('import PuzzleRules\n',''));sources.append(p)
subprocess.run(['swiftc','-O','-module-cache-path',str(out/'modules'),*map(str,sources),str(here/'main.swift'),str(out/'cpu.o'),'-lc++','-o',str(out/'probe')],check=True)
