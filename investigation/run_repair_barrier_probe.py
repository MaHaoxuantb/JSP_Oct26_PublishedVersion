#!/usr/bin/env python3
"""Check local improvements excluded by the hard adjacent-singleton rule.

The temporary reference differs only by omitting that final-board condition.
Production source is neither changed nor executed as a service.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "investigation/IntegrityAudit.swift").read_text()
rule = '''                for one in c.constraints.clues.indices where c.constraints.clues[one] == 1
                    && (allowed.contains(one) || c.grid.neighbors(one).contains(where: { allowed.contains($0) })) {
                    if !c.grid.neighbors(one).contains(where: { sizes[$0] == 1 }) { return }
                }
'''
assert source.count(rule) == 1
source = source.replace(rule, "").replace("@main", "", 1)
with tempfile.TemporaryDirectory(prefix="jsp-repair-barrier-") as directory:
    scratch = Path(directory)
    reference = scratch / "Reference.swift"
    reference.write_text(source)
    runner = scratch / "Runner.swift"
    runner.write_text('''import Foundation
@main struct RepairBarrier {
    static func main() throws {
        let result = IntegrityAudit.searchPruning(IntegrityAudit.legalPartitions3())
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
''')
    sources = sorted(p for p in (ROOT / "JaneStreetPuzzle_Oct26").glob("*.swift") if p.name != "main.swift")
    binary = scratch / "probe"
    subprocess.run(["swiftc", "-O", "-D", "PATHS_CPU_ONLY", "-module-cache-path", str(scratch / "modules"),
                    *map(str, sources), str(reference), str(runner), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], check=True, text=True, capture_output=True)
    print(result.stdout, end="")
    (ROOT / "investigation/repair-barrier-results.json").write_text(result.stdout)
