#!/usr/bin/env python3
"""Compile the read-only pathway probe with current production sources."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="jsp-pathways-") as scratch:
    scratch = Path(scratch)
    sources = sorted(p for p in (root / "JaneStreetPuzzle_Oct26").glob("*.swift") if p.name != "main.swift")
    executable = scratch / "inspect"
    subprocess.run(["swiftc", "-O", "-D", "PATHS_CPU_ONLY", "-module-cache-path", str(scratch / "module-cache"),
                    *map(str, sources), str(root / "investigation/InspectPathways.swift"), "-o", str(executable)], check=True)
    result = subprocess.run([str(executable), str(root / "investigation/verification.json")], check=True,
                            capture_output=True, text=True)
    print(result.stdout, end="")
    (root / "investigation/swift-inspection.txt").write_text(result.stdout)
