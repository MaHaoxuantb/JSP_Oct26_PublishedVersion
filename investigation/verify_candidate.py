#!/usr/bin/env python3
"""Independently check a published candidate; does not search or contact a service.

Run from any directory: python3 /absolute/path/investigation/verify_candidate.py
Only investigation/verification.json and investigation/solution.svg are written.
Coordinates in the output are one-based. No production solver code is imported.
"""
from pathlib import Path
import heapq
import json

ROOT = Path(__file__).resolve().parent
SOURCE = "https://ashrithanumala.github.io/w/its-a-metric-too.html"
SIZES = [list(map(int, row.split())) for row in """
4 4 4 4 7 10 5 5 5 5 5
7 7 7 7 7 10 10 10 7 7 7
7 37 37 37 37 10 1 10 7 12 7
11 37 37 37 37 10 10 10 7 12 7
11 11 37 37 37 37 5 10 2 12 12
11 37 37 37 37 37 5 5 2 12 1
11 11 11 2 37 37 37 5 5 12 12
10 10 11 2 4 37 37 37 37 37 12
10 11 11 4 4 37 37 37 37 12 12
10 10 11 10 4 3 37 37 37 37 12
10 10 10 10 3 3 37 37 37 37 12
""".strip().splitlines()]
CLUES = [list(map(int, row.split())) for row in """
-1 8 4 -1 -1 11 -1 -1 -1 5 -1
-1 -1 -1 -1 -1 -1 -1 11 -1 -1 -1
-1 -1 7 -1 -1 1 -1 -1 -1 -1 14
28 -1 -1 51 -1 -1 1 -1 6 -1 -1
-1 22 -1 -1 -1 -1 -1 -1 4 -1 1
-1 -1 -1 15 -1 10 -1 0 -1 -1 -1
11 -1 11 -1 -1 -1 -1 -1 -1 9 -1
-1 -1 17 -1 14 -1 -1 10 -1 -1 13
30 -1 -1 -1 -1 6 -1 -1 45 -1 -1
-1 -1 -1 10 -1 -1 -1 -1 -1 -1 -1
-1 26 -1 -1 -1 0 -1 -1 77 61 -1
""".strip().splitlines()]
N = 11


def neighbors(p):
    r, c = p
    for dr, dc in ((-1, 0), (0, -1), (0, 1), (1, 0)):
        q = r + dr, c + dc
        if 0 <= q[0] < N and 0 <= q[1] < N:
            yield q


def one(p):
    return [p[0] + 1, p[1] + 1]


def check():
    assert len(SIZES) == N and all(len(row) == N for row in SIZES)
    labels, states = {}, []
    for r in range(N):
        for c in range(N):
            start = r, c
            if start in labels:
                continue
            region = {start}
            queue = [start]
            labels[start] = len(states)
            for p in queue:
                for q in neighbors(p):
                    if q not in labels and SIZES[q[0]][q[1]] == SIZES[r][c]:
                        labels[q] = len(states)
                        region.add(q)
                        queue.append(q)
            # Equal-size connected components are an explicit candidate partition.
            # The equality here checks that this interpretation has the claimed area.
            assert len(region) == SIZES[r][c], (start, len(region), SIZES[r][c])
            states.append(region)

    # D4 as integer matrices, independently translated to the occupied bounds.
    matrices = [
        ("rotation90", (0, -1, 1, 0)),
        ("rotation180", (-1, 0, 0, -1)),
        ("rotation270", (0, 1, -1, 0)),
        ("mirror_horizontal", (-1, 0, 0, 1)),
        ("mirror_vertical", (1, 0, 0, -1)),
        ("mirror_diagonal", (0, 1, 1, 0)),
        ("mirror_antidiagonal", (0, -1, -1, 0)),
    ]
    caps, geometry = [], []
    for i, state in enumerate(states):
        symmetries, fixed_sets = [], []
        for name, (a, b, c, d) in matrices:
            transformed = {p: (a*p[0] + b*p[1], c*p[0] + d*p[1]) for p in state}
            offset = tuple(min(p[k] for p in state) - min(q[k] for q in transformed.values()) for k in (0, 1))
            mapped = {p: (q[0]+offset[0], q[1]+offset[1]) for p, q in transformed.items()}
            if set(mapped.values()) == state:
                symmetries.append(name)
                fixed_sets.append({p for p, q in mapped.items() if p == q})
        assert symmetries, (i, "asymmetric")
        cap = next(iter(fixed_sets[0])) if len(fixed_sets[0]) == 1 and all(s == fixed_sets[0] for s in fixed_sets) else None
        if cap is not None:
            caps.append(cap)
        geometry.append(dict(id=chr(65+i), size=len(state), cells=sorted(map(one, state)),
                             symmetries=symmetries, fixed_counts=list(map(len, fixed_sets)),
                             capitol=one(cap) if cap is not None else None))

    distances = {p: 0 for p in caps}
    parent = {p: None for p in caps}
    heap = [(0, p) for p in caps]
    heapq.heapify(heap)
    while heap:
        dist, p = heapq.heappop(heap)
        if distances[p] != dist:
            continue
        for q in neighbors(p):
            cost = min(len(states[labels[p]]), len(states[labels[q]]))
            candidate = dist + cost
            if candidate < distances.get(q, float("inf")):
                distances[q] = candidate
                parent[q] = p
                heapq.heappush(heap, (candidate, q))

    checks = []
    for r in range(N):
        for c in range(N):
            if CLUES[r][c] < 0:
                continue
            p = r, c
            path, costs = [p], []
            while parent[path[-1]] is not None:
                a, b = path[-1], parent[path[-1]]
                costs.append(min(len(states[labels[a]]), len(states[labels[b]])))
                path.append(b)
            assert distances[p] == CLUES[r][c], (p, distances[p], CLUES[r][c])
            checks.append(dict(cell=one(p), expected=CLUES[r][c], actual=distances[p],
                               path=list(map(one, path)), step_costs=costs,
                               target_capitol=one(path[-1])))
    rows = list(map(sum, SIZES))
    report = dict(candidate_source=SOURCE, provenance="Published candidate, independently checked; not independently discovered.",
                  valid=True, uniqueness_proved=False, states=geometry,
                  capitols=sorted(map(one, caps)), clues_checked=len(checks), clue_checks=checks,
                  labels=[[labels[r, c] for c in range(N)] for r in range(N)],
                  cell_sizes=SIZES, row_sums=rows, answer=sum(x*x for x in rows),
                  distances=[[distances[r, c] for c in range(N)] for r in range(N)])
    (ROOT / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    draw(report)
    print(json.dumps({k: report[k] for k in ("valid", "clues_checked", "capitols", "row_sums", "answer", "uniqueness_proved")}, indent=2))
    print("States:", ", ".join(f"{s['id']}={s['size']}" for s in geometry))


def draw(report):
    palette = ["#bae6fd", "#c4b5fd", "#fcd34d", "#99f6e4", "#c7d2fe", "#fecaca", "#e2e8f0", "#d9f99d",
               "#fdba74", "#f0abfc", "#a5f3fc", "#cbd5e1", "#f5d0fe", "#a7f3d0", "#ddd6fe", "#fde68a"]
    cell, ox, oy = 50, 38, 65
    svg = ['<svg xmlns="http://www.w3.org/2000/svg" width="680" height="720" viewBox="0 0 680 720">',
           '<rect width="680" height="720" fill="#fff"/>',
           '<g font-family="system-ui, sans-serif" fill="#172033">',
           '<text x="38" y="28" font-size="20" font-weight="700">Verified partition · answer 408,951</text>',
           '<text x="38" y="49" font-size="12">Cell numbers = state sizes · dots = capitols · all 33 clues verified</text>']
    caps = {tuple(p) for p in report["capitols"]}
    for r in range(N):
        svg.append(f'<text x="25" y="{oy+r*cell+30}" font-size="12" text-anchor="end">{r+1}</text>')
        for c in range(N):
            x, y = ox+c*cell, oy+r*cell
            state = report["labels"][r][c]
            svg.append(f'<rect x="{x}" y="{y}" width="{cell}" height="{cell}" fill="{palette[state]}" stroke="#fff" stroke-width="1"/>')
            svg.append(f'<text x="{x+25}" y="{y+31}" text-anchor="middle" font-size="18">{SIZES[r][c]}</text>')
            if (r+1, c+1) in caps:
                svg.append(f'<circle cx="{x+39}" cy="{y+11}" r="4" fill="#172033"/>')
            if r == 0:
                svg.append(f'<text x="{x+25}" y="{oy-5}" font-size="12" text-anchor="middle">{c+1}</text>')
            for dr, dc, edge in ((-1, 0, (x, y, x+cell, y)), (0, -1, (x, y, x, y+cell))):
                rr, cc = r+dr, c+dc
                if rr < 0 or cc < 0 or report["labels"][rr][cc] != state:
                    svg.append(f'<path d="M{edge[0]} {edge[1]} L{edge[2]} {edge[3]}" stroke="#172033" stroke-width="2"/>')
        svg.append(f'<text x="605" y="{oy+r*cell+30}" font-size="14">{report["row_sums"][r]}</text>')
    svg.extend([f'<path d="M{ox} {oy+N*cell} H{ox+N*cell} V{oy}" fill="none" stroke="#172033" stroke-width="2"/>',
                '<text x="601" y="59" font-size="12">Row sum</text>',
                '<text x="38" y="648" font-size="13">16 connected symmetric states · 8 capitols · 121 cells</text>',
                '<text x="38" y="674" font-size="12">Published candidate independently verified in Python and Swift.</text>',
                '<text x="38" y="695" font-size="12">This verification establishes validity, not uniqueness.</text>', '</g></svg>'])
    (ROOT / "solution.svg").write_text("\n".join(svg) + "\n")


if __name__ == "__main__":
    check()
