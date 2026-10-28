#!/usr/bin/env python3
"""Compile and run all six bounded core suites, without a full-puzzle search."""

from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    names = [
        "SymmetryEnergyTests", "RealAIMEnergyTests", "CombinedEnergyTests",
        "RepairTests", "OptimizationTests", "SolverTests",
    ]
    with tempfile.TemporaryDirectory(prefix="jsp-core-tests-") as work:
        work = Path(work)
        copies = []
        for name in names:
            source = (root / "Tests" / f"{name}.swift").read_text()
            copy = work / f"{name}.swift"
            # Keep the existing standalone entry points usable, while running
            # their checks through one compiled executable in CI.
            copy.write_text(source.replace("@main", "", 1))
            copies.append(copy)
        runner = work / "CoreTestRunner.swift"
        runner.write_text("""import Foundation
@main struct CoreTestRunner {
    static func main() async throws {
        SymmetryEnergyTests.main()
        RealAIMEnergyTests.main()
        CombinedEnergyTests.main()
        await RepairTests.main()
        try await OptimizationTests.main()
        try await SolverTests.main()
    }
}
""")
        sources = sorted(p for p in (root / "JaneStreetPuzzle_Oct26").glob("*.swift") if p.name != "main.swift")
        executable = work / "core-tests"
        subprocess.run([
            "swiftc", "-O", "-D", "PATHS_CPU_ONLY", "-module-cache-path", str(work / "module-cache"),
            *map(str, sources), *map(str, copies), str(runner), "-o", str(executable),
        ], check=True, cwd=root)
        subprocess.run([str(executable)], check=True, cwd=root)


if __name__ == "__main__":
    main()
