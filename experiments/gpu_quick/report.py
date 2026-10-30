"""JSP-Oct26-GPU-Quick; ©2026 ThomasB. Publish actual short-probe evidence."""
from pathlib import Path
import json,shutil,hashlib,csv,statistics,datetime,zoneinfo,platform
here=Path(__file__).resolve().parent;repo=here.parent.parent
out=here/'results'/'20261030-quick';out.mkdir(parents=True,exist_ok=True)
files={}
for host in ['local','mini']:
 for run in ['final','repeat']:
  src=Path('/private/tmp/jsp-gpu-'+host+'-'+run+'.json');dest=out/('JSP-Oct26-GPU-Quick-'+host+'-'+run+'.json');shutil.copyfile(src,dest);files[(host,run)]=json.loads(src.read_text())
shutil.copyfile('/private/tmp/jsp-gpu-capture.json',out/'JSP-Oct26-GPU-Quick-Inputs.json')
allrows=[]
for (host,run),d in files.items():
 for row in d['rows']:allrows.append(dict(host=host,run=run,**{k:v for k,v in row.items() if not k.endswith('SamplesMS')}))
with (out/'JSP-Oct26-GPU-Quick-Timings.csv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=list(allrows[0]));w.writeheader();w.writerows(allrows)
manifest=dict(experiment='JSP-Oct26-GPU-Quick',copyright='©2026 ThomasB',author='ThomasB',created=datetime.datetime.now(zoneinfo.ZoneInfo('Asia/Tokyo')).isoformat(),software='Isolated probe; production software version 2 unchanged; no deployment',constraint='One dispatched threadgroup, 256 threads / 8 SIMD groups; no physical core affinity guarantee',build='native clang++ -O3 and swiftc -O on each host',sources={})
for p in list(here.glob('*.swift'))+list(here.glob('*.py'))+list(here.glob('*.cpp'))+list(here.glob('*.h'))+list(here.glob('*.metal'))+[repo/'experiments/solver_bench/Sources'/folder/name for folder,names in [('PuzzleRules',['Types.swift','Rules.swift']),('ShapeDomain',['ShapeOracle.swift','CoverSearch.swift'])] for name in names]:
 manifest['sources'][str(p.relative_to(repo))]=hashlib.sha256(p.read_bytes()).hexdigest()
manifest['data']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*') if p.is_file()}
(out/'JSP-Oct26-GPU-Quick-Manifest.json').write_text(json.dumps(manifest,indent=2))
def summarize(host,task,n,batch):
 a=[x for x in allrows if x['host']==host and x['task']==task and x['n']==n and x['batch']==batch]
 cpu=statistics.mean(x['cpuMS'] for x in a);gpu=statistics.mean(x['gpuMS'] for x in a)
 return cpu,gpu,cpu/gpu
summary=[]
for host,title in [('local','M4 Mac'),('mini','M2 Mini')]:
 for task,label,batch in [('shape-checks','Shape checks vs optimized CPU',1024),('shape-existing-Swift','Shape checks vs existing shared Swift',1024),('bound-paths-heap-certified','Bound paths vs heap CPU',1024),('cpu-BP-plus-bound-paths','CPU BP plus independent bound batch',256),('cpu-BP-plus-shapes','CPU BP plus independent shape batch',1024)]:
  cpu,gpu,ratio=summarize(host,task,11,batch);summary.append(f'| {title} | {label} | {batch} | {cpu:.3f} | {gpu:.3f} | {ratio:.2f}× |')
report='''# JSP-Oct26-GPU-Quick-Report

©2026 ThomasB

Author: ThomasB  
Date: 2026-10-30, Asia/Tokyo

## Finding

Under the one-active-threadgroup GPU proxy, optimized CPU shape checks beat this
GPU implementation clearly. GPU bound-path batches outperform the existing
scan-based CPU algorithm on larger boards, but a heap-based CPU control removes
most of that advantage. At N=11 and batch 1,024 the M2 GPU remains about 19% faster
than the heap CPU, while the M4 is roughly even to slower across the two runs.

CPU branch pruning overlapped with independent GPU work reduces elapsed time for
our controlled combined workload: about 8% on the M4 and 7% on the M2 for the
256-path overlap test. This is **not a fresh solver time-to-solution result**.
GPU results do not drive that replay's branch decisions. Actual integrated search
could lose the gain to batching delay, different search order or unused work.

The measured result revises the initial shape-offload priority: test CPU
allocation/bitset improvements and heap paths before investing in a GPU shape
producer. Restricted-GPU bounds remain a conditional candidate for large batches.

## N=11 measured elapsed time

Each entry averages the medians of two separate invocations on that host. A ratio
above 1 means the GPU or hybrid completed the specified workload faster. These
are milliseconds for the entire batch, not milliseconds per board. CPU and GPU
received identical captured/derived inputs. Hosts are compared only internally.

| Host | Workload | Batch | CPU ms | GPU/hybrid ms | CPU / GPU |
| --- | --- | ---: | ---: | ---: | ---: |
'''+ '\n'.join(summary)+'''

Small batch sizes, especially 1 and 32, generally lose to submission overhead.
All N=7,9,11 and batch 1,32,256,1024 timings, individual samples, and both CPU path
controls are retained in the accompanying JSON and CSV. Do not select only a
favorable board or compare a GPU implementation only against the weaker CPU
control.

## What was actually tested

- Shape connectivity, every nonidentity square-lattice symmetry and the exact
  common-single-fixed-cell capital rule. The GPU and optimized C++ CPU share the
  same shape routine; existing shared Swift `Rules.geometry` is an independent
  reference and a separately timed CPU control.
- Lower/upper-bound **distance subproblems**, derived using the improvement-mode
  size/source rules from saved fixed-exterior patches. The benchmark computes
  distances, not the whole bound-quality reduction or a full energy evaluator.
  GPU Bellman–Ford is compared with CPU scan and heap Dijkstra. GPU timings
  include a CPU shortest-path certificate checking sources, triangle inequalities
  and positive tight predecessors. CPU arithmetic and GPU arithmetic are exact
  bounded integers.
- Actual shared `CoverSearch`, including pruning and lazy shape generation, on a
  fixed source-derived patch of at most 20 cells and a cap of 32 nodes per sample.
  A fresh identical job is created for each sample. This CPU work overlaps an
  **independent** saved GPU shape or path batch. The serial control performs the
  same two jobs on the CPU. This is an overlap feasibility test, not an integrated
  asynchronous frontier or demand-driven shape producer.
- A GPU population-SA implementation was **not** built in this quick screen. It
  needs legal move generation, per-chain state, acceptance and exchanges with BP;
  timing energy kernels alone would not establish its benefit.

## Inputs and checks

Inputs were captured read-only from the paused Repair-Completion campaign. N=7
and N=9 use 96 recorded source partitions/patches each; N=11 uses 61. There are
658, 1,137 and 741 distinct source-derived/perturbed masks respectively. Perturbed
masks remove or add cells to exercise rejection; they are not claimed to be
recorded search proposals. Derived bound inputs select zero, half or all of the
source regions inside a recorded patch; they are not a trace of visited nodes.
Batches cycle the input lists when needed, so batch size is not a count of unique
shapes. Data preparation and independent reference construction are outside the
warm timing and must be included in a future complete solver comparison.

Each final invocation compared 3,939 shape outputs and 3,939 distance arrays
against shared Swift rules, with no disagreement. There are four retained final
invocations, two per Mac. The GPU path certificate also runs inside every timed
GPU path call. Shape reference comparisons run outside timing; a real solver
must independently verify any final proposed solution. Repeated timings use 15
samples per standalone optimized task, five for existing-Swift geometry and shape
overlap, and 16 alternating-order paired samples for path overlap. The small
shape-overlap gains are less reliable because those arms ran in separate blocks.
No confidence intervals or statistical solve-time claims are made.

## Budget and timing boundaries

Exactly one compute threadgroup of 256 threads is dispatched per command. Path
work uses eight independent 32-lane SIMD groups inside that group. No multiple
GPU groups or queues run concurrently. This is a conservative one-GPU-core
**proxy**, not proof of physical core affinity or reservation. CPU work is one
application thread; Metal/OS helper work and CPU migration are not physically
pinned. No full-device result is mislabeled as a one-core result.

GPU warm timings include copying inputs into reused shared buffers, command
encoding/submission, completion wait and result handling; paths include the CPU
certificate. CPU controls use prepared input arrays, allocated output arrays and
no submission cost. This is a warm-component comparison. Reusable-buffer creation,
shader compilation and construction of inputs are excluded from warm timings.
Each JSON separately records shader/pipeline initialization time; caches were
already warm for later invocations, so it is not a clean cold-start measurement.
The initial local prototype's shader setup was approximately 0.329 seconds.

Both hosts compile their own native scratch binaries, using their installed
Swift and Clang toolchains. Original sources are preserved. No installed worker,
core solver, software release version or live queue was changed. The earlier
scan-only prototype results were superseded by the stronger CPU controls and are
not pooled into the final results.

## Suggested next step

First measure the CPU bitset/shape representation and heap path control inside
the shared solver, with caching and actual call sizes. Production already has a
heap path implementation, so the scan-to-heap gain applies chiefly to the shared
experimental engine; it is not a new production optimization. Then, if real
search supplies enough independent bound work, implement a bounded asynchronous
frontier and compare it with the same batched CPU frontier. Preserve conservative
bounds and independent final validation. Run matched fresh solves only after that
component test wins. Do not launch another long GPU campaign from this replay.

The Repair-Completion campaign remains paused on both Macs. Reports, raw timing
samples, source/data hashes and captured inputs are stored beside this document.
'''
(out/'JSP-Oct26-GPU-Quick-Report.md').write_text(report)
print(out/'JSP-Oct26-GPU-Quick-Report.md')
