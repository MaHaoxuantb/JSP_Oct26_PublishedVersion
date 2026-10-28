#!/usr/bin/env python3
"""Compare isolated historical cores against an exported, read-only live leader.

Usage: python3 investigation/run_history_probe.py /tmp/status.json
Only bounded diagnostic runs are launched. No production services are touched.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REVISIONS = ["11251e6", "2614f8a", "c9feaaa", "91d4012"]


def main():
    status = Path(sys.argv[1]).resolve()
    revisions = sys.argv[2:] or REVISIONS
    filename = "partial-repair-probe-results.json" if revisions == ["working-tree"] else "history-probe-results.json"
    output = ROOT / "investigation" / filename
    results = json.loads(output.read_text()) if output.exists() else {}
    work = Path(tempfile.mkdtemp(prefix="jsp-history-"))
    print("Temporary builds:", work, flush=True)
    for rev in revisions:
        base_rev = rev.removesuffix("-legacy-constraints")
        target = work / rev
        target.mkdir()
        if rev == "working-tree":
            names = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "JaneStreetPuzzle_Oct26").glob("*.swift"))
        else:
            names = subprocess.check_output(
                ["git", "ls-tree", "--name-only", base_rev, "JaneStreetPuzzle_Oct26/"], cwd=ROOT, text=True
            ).splitlines()
        sources = []
        for name in names:
            if name.endswith(".swift") and not name.endswith("/main.swift"):
                p = target / Path(name).name
                p.write_bytes((ROOT / name).read_bytes() if rev == "working-tree" else
                              subprocess.check_output(["git", "show", f"{base_rev}:{name}"], cwd=ROOT))
                sources.append(p)
        if rev.endswith("-legacy-constraints"):
            # Isolate deduction strength, retaining the new generators, caches,
            # discovery preservation and search lifecycle unchanged. This is an
            # ablation in a temporary source copy, not a proposed production fix.
            exact = target / "ExactSearch.swift"
            source = exact.read_text()
            start = source.index("    init(grid: Grid, clues: [Int])", source.index("struct ClueConstraints"))
            end = source.index("    /// A zero", start)
            constructor = '''    init(grid: Grid, clues: [Int]) {
        self.grid = grid; self.clues = clues
        var sizes = Array(repeating: 1, count: grid.count)
        for cell in clues.indices where clues[cell] >= 0 {
            for neighbor in grid.neighbors(cell) where clues[neighbor] >= 0 {
                sizes[cell] = max(sizes[cell], abs(clues[cell] - clues[neighbor]))
            }
        }
        minimumSizes = sizes
        forcedSingletons = []
        singletonCandidates = Set(clues.indices)
        distanceUpperBounds = clues.map { $0 >= 0 ? $0 : Int.max }
        pairBounds = []
    }
'''
            exact.write_text(source[:start] + constructor + source[end:])
        flags = ["-D", "PATHS_CPU_ONLY"]
        if base_rev != "11251e6":
            flags += ["-D", "HISTORY_RUN"]
        if base_rev in ("c9feaaa", "91d4012", "working-tree"):
            flags += ["-D", "HISTORY_GPU"]
        command = ["swiftc", "-O", *flags, "-module-cache-path", str(work / "modules"),
                   *map(str, sources), str(ROOT / "investigation/HistoryProbe.swift"), "-o", str(target / "probe")]
        subprocess.run(command, check=True, cwd=ROOT)
        run = subprocess.run([str(target / "probe"), str(status), str(target / "logs")],
                             check=True, capture_output=True, text=True, cwd=ROOT)
        rows = [json.loads(line) for line in run.stdout.splitlines() if line.startswith("{")]
        rows[0]["source_sha256"] = hashlib.sha256(b"\n".join(
            p.name.encode() + b"\0" + p.read_bytes() for p in sorted(sources)
        )).hexdigest()
        rows[0]["fixture_sha256"] = hashlib.sha256(status.read_bytes()).hexdigest()
        results[rev] = rows
        print(rev, json.dumps(rows), flush=True)
        output.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
