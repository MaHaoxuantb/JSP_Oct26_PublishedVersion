"""JSP-Oct26-Search-Escape; ©2026 ThomasB. Exact symmetric-cover/distance prototype.
Exhaustive shapes on <=16 released cells; fixed exterior is explicit, not global proof.
"""
import argparse,collections,heapq,json,pathlib,sys,time
from ortools.sat.python import cp_model
REPO=pathlib.Path(__file__).resolve().parents[2];sys.path.insert(0,str(REPO/'experiments/solver_bench'))
from benchqueue.validation import evaluate
from clue_constraints import derive

def neighbors(c,n):
 r,k=divmod(c,n);return [v for ok,v in [(r>0,c-n),(r+1<n,c+n),(k>0,c-1),(k+1<n,c+1)] if ok]
def geometry(cells,n):
 allowed=set(cells);seen={cells[0]};q=list(seen)
 for c in q:
  for v in neighbors(c,n):
   if v in allowed and v not in seen:seen.add(v);q.append(v)
 if len(seen)!=len(cells):return False,None
 sr=min(c//n for c in cells)+max(c//n for c in cells);sc=min(c%n for c in cells)+max(c%n for c in cells)
 points=[(2*(c//n)-sr,2*(c%n)-sc) for c in cells];fixed=[]
 for t in range(7):
  mapped=[[(b,-a),(-a,-b),(-b,a),(a,-b),(-a,b),(b,a),(-b,-a)][t] for a,b in points]
  if set(mapped)==set(points):fixed.append([c for c,a,b in zip(cells,points,mapped) if a==b])
 if not fixed:return False,None
 return True,fixed[0][0] if len(fixed[0])==1 and all(f==fixed[0] for f in fixed) else None

def distances(labels,n):
 parts=collections.defaultdict(list)
 for c,label in enumerate(labels):parts[label].append(c)
 sizes=[0]*(n*n);caps=[]
 for cells in parts.values():
  legal,cap=geometry(cells,n);assert legal
  for c in cells:sizes[c]=len(cells)
  if cap is not None:caps.append(cap)
 d=[10**9]*(n*n);h=[]
 for c in caps:d[c]=0;heapq.heappush(h,(0,c))
 while h:
  value,c=heapq.heappop(h)
  if value!=d[c]:continue
  for v in neighbors(c,n):
   x=value+min(sizes[c],sizes[v])
   if x<d[v]:d[v]=x;heapq.heappush(h,(x,v))
 return d

def solve(puzzle,base,patch,seconds,hard=False,prebuilt=None,started=None):
 started=time.monotonic() if started is None else started;n=puzzle['n'];assert prebuilt is not None or len(patch)<=16
 outside=collections.defaultdict(list)
 for c,label in enumerate(base):outside[label].append(c)
 fixed=[cells for cells in outside.values() if not set(cells)&set(patch)]
 assert all(set(cells)<=set(patch) or not set(cells)&set(patch) for cells in outside.values())
 candidates=[] if prebuilt is None else prebuilt
 if prebuilt is None:
  for bits in range(1,1<<len(patch)):
   cells=[patch[i] for i in range(len(patch)) if bits>>i&1];legal,cap=geometry(cells,n)
   if legal:candidates.append((cells,cap))
 catalog=time.monotonic()-started
 bounds=derive(puzzle)
 max_area=max([len(cells) for cells,_ in candidates]+[len(cells) for cells in fixed],default=0)
 model=cp_model.CpModel();shapes=[(cells,cap,model.new_bool_var('shape'+str(i))) for i,(cells,cap) in enumerate(candidates)]
 for cells in fixed:
  legal,cap=geometry(cells,n);assert legal;shapes.append((cells,cap,1))
 bycell=[[] for _ in base];capchoices=[[] for _ in base]
 for cells,cap,b in shapes:
  for c in cells:bycell[c].append((len(cells),b))
  if cap is not None:capchoices[cap].append(b)
 size=[];cap=[];distance=[];maxd=n*n*(n*n-1)
 for c in range(n*n):
  model.add(sum(b for _,b in bycell[c])==1)
  s=model.new_int_var(1,n*n,'size'+str(c));model.add(s==sum(area*b for area,b in bycell[c]));size.append(s)
  z=model.new_bool_var('capital'+str(c));model.add(z==sum(capchoices[c]));cap.append(z)
  distance.append(model.new_int_var(0,maxd,'distance'+str(c)))
 model.add(sum(cap)>=1)
 weights={}
 for c in range(n*n):
  for v in neighbors(c,n):
   edge=tuple(sorted((c,v)))
   if edge not in weights:
    w=model.new_int_var(1,n*n,'edge'+str(edge));model.add_min_equality(w,[size[c],size[v]]);weights[edge]=w
 for c in range(n*n):
  minimum=model.new_int_var(1,maxd+n*n,'minimum'+str(c))
  model.add_min_equality(minimum,[distance[v]+weights[tuple(sorted((c,v)))] for v in neighbors(c,n)])
  model.add(distance[c]==0).only_enforce_if(cap[c]);model.add(distance[c]==minimum).only_enforce_if(cap[c].Not())
 errors=[];wrong=[]
 for c,target in enumerate(puzzle['clues']):
  if target<0:continue
  if hard:model.add(distance[c]==target)
  else:
   z=model.new_bool_var('wrong'+str(c));model.add(distance[c]!=target).only_enforce_if(z);model.add(distance[c]==target).only_enforce_if(z.Not());wrong.append(z)
   e=model.new_int_var(0,max(maxd,target),'error'+str(c));model.add_abs_equality(e,distance[c]-target);errors.append(e)
 if not hard:model.minimize((1+sum(max(maxd,t) for t in puzzle['clues'] if t>=0))*sum(wrong)+sum(errors))
 # Existing incumbent is a hint only; no planted answer enters domain construction.
 existing={tuple(cells) for cells in outside.values()}
 for cells,_,b in shapes:
  if not isinstance(b,int):model.add_hint(b,int(tuple(cells) in existing))
 invalid=model.validate();assert not invalid,invalid
 solver=cp_model.CpSolver();solver.parameters.num_search_workers=1;solver.parameters.max_time_in_seconds=max(.001,seconds-(time.monotonic()-started))
 status=solver.solve(model);labels=None;check=None
 if status in [cp_model.OPTIMAL,cp_model.FEASIBLE]:
  labels=[-1]*len(base)
  for i,(cells,_,b) in enumerate(shapes):
   if b==1 if isinstance(b,int) else solver.value(b):
    for c in cells:labels[c]=i
  check=evaluate(labels,n,puzzle['clues']);assert check['issues']==0
  computed=distances(labels,n);assert computed==[solver.value(d) for d in distance]
  if hard:assert check['solved']
 return dict(experiment='JSP-Oct26-Search-Escape',copyright='©2026 ThomasB',approach='CP-SAT',seconds=time.monotonic()-started,catalogSeconds=catalog,patchCells=len(patch),candidateShapes=len(candidates),completePatchDomain=prebuilt is None,fullBoardScope=len(patch)==n*n,globalDomain=prebuilt is None and len(patch)==n*n,status=solver.status_name(status),labels=labels,quality=check,hard=hard,branches=solver.num_branches,conflicts=solver.num_conflicts,solverVersion=__import__('ortools').__version__,clueBounds=bounds,maxDomainRegionSize=max_area,solutionExcludedByAreaBound=max_area<bounds['minimumLargestRegion'],patch=patch,baseLabels=base)

def global_candidates(base,n):
 """Restricted global domain: all rectangles plus transforms of incumbent regions."""
 parts=collections.defaultdict(list)
 for c,v in enumerate(base):parts[v].append(c)
 templates=set()
 for cells in parts.values():
  points=[divmod(c,n) for c in cells]
  for t in range(8):
   transformed=[[(a,b),(b,-a),(-a,-b),(-b,a),(a,-b),(-a,b),(b,a),(-b,-a)][t] for a,b in points]
   r=min(a for a,b in transformed);c=min(b for a,b in transformed);templates.add(tuple(sorted((a-r,b-c) for a,b in transformed)))
 for h in range(1,n+1):
  for w in range(1,n+1):templates.add(tuple((a,b) for a in range(h) for b in range(w)))
 unique={}
 for points in sorted(templates):
  h=1+max(a for a,b in points);w=1+max(b for a,b in points);cells=[a*n+b for a,b in points];legal,cap=geometry(cells,n);assert legal
  for r in range(n-h+1):
   for c in range(n-w+1):
    placed=tuple((a+r)*n+b+c for a,b in points);unique[placed]=None if cap is None else cap+r*n+c
 return [(list(cells),cap) for cells,cap in unique.items()]

def main():
 p=argparse.ArgumentParser();p.add_argument('--seed');p.add_argument('--output',required=True);p.add_argument('--seconds',type=float,default=15);a=p.parse_args()
 if a.seed:
  r=json.loads(pathlib.Path(a.seed).read_text());puzzle=r['puzzle'];w=min(r['workers'],key=lambda x:(x['quality']['issues'],x['quality']['wrong'],x['quality']['residual']));base=sum(w['labels'],[]);n=puzzle['n'];d=distances(base,n);focus=next(c for c,t in enumerate(puzzle['clues']) if t>=0 and t!=d[c]);parts=collections.defaultdict(list)
  for c,v in enumerate(base):parts[v].append(c)
  patch=set(parts[base[focus]])
  while len(patch)<12:
   choices={base[v] for c in patch for v in neighbors(c,n)}-{base[c] for c in patch};choices=[k for k in sorted(choices) if len(patch)+len(parts[k])<=16]
   if not choices:break
   patch.update(parts[min(choices,key=lambda k:len(parts[k]))])
  patch=sorted(patch);hard=False
 else:
  n=4;base=[ord(x) for row in ['AABC','AABC','DDEF','GGHF'] for x in row];d=distances(base,n);clues=[d[c] if c in [0,3,10,14] else -1 for c in range(16)];puzzle=dict(id='complete-domain-4',n=4,clues=clues);patch=list(range(16));hard=True
 result=solve(puzzle,base,patch,a.seconds,hard);result['puzzle']=puzzle;pathlib.Path(a.output).write_text(json.dumps(result,indent=2));print(json.dumps({k:v for k,v in result.items() if k not in ['labels','puzzle']}))
if __name__=='__main__':main()
