"""Independent integer rule checker. Does not import or call the Swift evaluator."""
from collections import defaultdict,deque
import heapq,math

def evaluate(labels,n,clues):
    if labels and isinstance(labels[0],list):labels=sum(labels,[])
    if len(labels)!=n*n:raise ValueError('Wrong partition dimensions')
    def neighbors(c):
        r,k=divmod(c,n)
        return [v for yes,v in [(r>0,c-n),(r+1<n,c+n),(k>0,c-1),(k+1<n,c+1)] if yes]
    groups=defaultdict(list)
    for c,v in enumerate(labels):groups[v].append(c)
    sizes=[0]*len(labels);caps=[];issues=0;invalid=0
    for cells in groups.values():
        allowed=set(cells);seen={cells[0]};queue=deque(seen)
        while queue:
            for v in neighbors(queue.popleft()):
                if v in allowed and v not in seen:seen.add(v);queue.append(v)
        sr=min(c//n for c in cells)+max(c//n for c in cells);sc=min(c%n for c in cells)+max(c%n for c in cells)
        coordinates=[(2*(c//n)-sr,2*(c%n)-sc) for c in cells];fixed=[]
        for t in range(7):
            mapped=[[(b,-a),(-a,-b),(-b,a),(a,-b),(-a,b),(b,a),(-b,-a)][t] for a,b in coordinates]
            if set(mapped)==set(coordinates):fixed.append({c for c,a,b in zip(cells,coordinates,mapped) if a==b})
        if seen!=allowed or not fixed:issues+=1;invalid+=len(cells)
        elif len(fixed[0])==1 and all(x==fixed[0] for x in fixed):caps.extend(fixed[0])
        for c in cells:sizes[c]=len(cells)
    distance=[math.inf]*len(labels);heap=[]
    for c in caps:distance[c]=0;heapq.heappush(heap,(0,c))
    while heap:
        d,c=heapq.heappop(heap)
        if d!=distance[c]:continue
        for v in neighbors(c):
            value=d+min(sizes[c],sizes[v])
            if value<distance[v]:distance[v]=value;heapq.heappush(heap,(value,v))
    targets=[(c,t) for c,t in enumerate(clues) if t>=0];wrong=sum(distance[c]!=t for c,t in targets)
    error=sum(abs(distance[c]-t)/max(distance[c],t,1) if math.isfinite(distance[c]) else 1 for c,t in targets)/max(1,len(targets))
    solved=not issues and not wrong
    answer=sum(sum(sizes[r*n:(r+1)*n])**2 for r in range(n)) if solved else None
    return {'issues':issues,'wrong':wrong,'residual':error,'solved':solved,'answer':answer,'invalidCellFraction':invalid/(n*n),'commonEnergy':(2*error+invalid/(n*n))/3}

def canonical_partition(labels):
    ids={};out=[]
    for x in labels:
        if x not in ids:ids[x]=len(ids)
        out.append(ids[x])
    return tuple(out)

def puzzle_orbit_key(puzzle):
    n=puzzle['n'];values=puzzle['clues'];variants=[]
    for t in range(8):
        out=[None]*(n*n)
        for r in range(n):
            for c in range(n):
                a,b=[(r,c),(c,n-1-r),(n-1-r,n-1-c),(n-1-c,r),(r,n-1-c),(n-1-r,c),(c,r),(n-1-c,n-1-r)][t];out[a*n+b]=values[r*n+c]
        variants.append(tuple(out))
    return min(variants)

def validate_certificate(certificate):
    if certificate.get('rules')!='symmetric-capitol-integer-paths-v1' or certificate.get('generator')!='orbit-connected-subsets-v1':raise ValueError('Incompatible certificate version')
    p=certificate['puzzle'];solutions=certificate['solutions'];count=certificate['solutionCount']
    if not certificate['exhausted'] or count not in [1,2,3] or len(solutions)!=count:raise ValueError('Unproven or excessive solution count')
    if len({canonical_partition(x) for x in solutions})!=count:raise ValueError('Duplicate partitions in certificate')
    answers=[]
    for labels in solutions:
        check=evaluate(labels,p['n'],p['clues'])
        if not check['solved']:raise ValueError('Invalid certified partition')
        answers.append(check['answer'])
    if sorted(set(answers))!=certificate['answers']:raise ValueError('Certified answer list differs')
    if sum(t>=0 for t in p['clues'])!=round(p['n']**2*33/121):raise ValueError('Wrong clue density')
    return {'independentlyValidatedSolutions':count,'answers':sorted(set(answers)),'countProof':'exhaustive Swift search; independent partition validation'}


def validate_fixture(record,allow_unproven=False):
    if record.get('exhausted'):return validate_certificate(record)
    if not allow_unproven or record.get('solutionCount') is not None:raise ValueError('Unproven fixture is not authorized or falsely claims an exact count')
    p=record['puzzle'];solutions=record['solutions']
    if record.get('rules')!='symmetric-capitol-integer-paths-v1' or record.get('generator')!='orbit-connected-subsets-v1':raise ValueError('Incompatible fixture version')
    if len(p['clues'])!=p['n']**2 or sum(t>=0 for t in p['clues'])!=round(p['n']**2*33/121):raise ValueError('Wrong clue density or dimensions')
    if not solutions or len({canonical_partition(x) for x in solutions})!=len(solutions):raise ValueError('Missing or duplicate known solutions')
    checks=[evaluate(x,p['n'],p['clues']) for x in solutions]
    if not all(x['solved'] for x in checks):raise ValueError('Invalid known solution')
    if sorted({x['answer'] for x in checks})!=record['answers']:raise ValueError('Known answer list differs')
    return {'independentlyValidatedSolutions':len(solutions),'answers':record['answers'],'countProof':'unproven; valid saved solutions only'}
