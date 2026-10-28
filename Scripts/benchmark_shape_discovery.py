#!/usr/bin/env python3
"""Compile and optionally run bounded shape discovery, without solution fixtures."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) < 2 or sys.argv[1] != "--run":
        print("Idle. Pass --run [seeds=5] [batches-per-seed=16] for bounded shape discovery.")
        return
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="jsp-shape-benchmark-") as scratch:
        scratch = Path(scratch)
        sources = sorted(p for p in (root / "JaneStreetPuzzle_Oct26").glob("*.swift") if p.name != "main.swift")
        binary = scratch / "shape-benchmark"
        subprocess.run(["swiftc", "-O", "-D", "PATHS_CPU_ONLY", "-module-cache-path", str(scratch / "modules"),
                        *map(str, sources), str(root / "Tests/ShapeDiscoveryBenchmark.swift"), "-o", str(binary)], check=True)
        subprocess.run([str(binary), *sys.argv[1:]], check=True)


if __name__ == "__main__":
    main()
