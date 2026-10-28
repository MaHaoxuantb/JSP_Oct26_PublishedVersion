#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="jsp-integrity-") as folder:
    folder = Path(folder)
    sources = sorted(p for p in (root / "JaneStreetPuzzle_Oct26").glob("*.swift") if p.name != "main.swift")
    binary = folder / "audit"
    subprocess.run(["swiftc", "-O", "-D", "PATHS_CPU_ONLY", "-module-cache-path", str(folder / "modules"),
                    *map(str, sources), str(root / "investigation/IntegrityAudit.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(root / "investigation/integrity-results.json")], check=True)
