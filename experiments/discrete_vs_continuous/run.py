#!/usr/bin/env python3
"""Build only in a unique /private/tmp directory; never touch installed workers."""
import argparse
import hashlib
from datetime import datetime, timezone
import json
import platform
import subprocess
import tempfile
from pathlib import Path

here = Path(__file__).resolve().parent
root = here.parents[1]
p = argparse.ArgumentParser()
p.add_argument('--trials', type=int, default=5)
p.add_argument('--seconds', type=float, default=3)
p.add_argument('--pool-size', type=int, default=256)
p.add_argument('--output', type=Path, default=here / 'results')
a = p.parse_args()
assert a.trials > 0 and a.seconds > 0 and a.pool_size > 0
a.output = a.output.resolve()
a.output.mkdir(parents=True, exist_ok=True)
sources = sorted(x for x in (root / 'JaneStreetPuzzle_Oct26').glob('*.swift') if x.name != 'main.swift')
with tempfile.TemporaryDirectory(prefix='jsp-number-experiment-', dir='/private/tmp') as scratch:
    binary = Path(scratch) / 'experiment'
    version = subprocess.check_output(['swiftc', '--version'], text=True)
    command = ['swiftc', '-O', '-D', 'PATHS_CPU_ONLY', '-module-cache-path', str(Path(scratch)/'module-cache'), *map(str, sources), str(here/'Experiment.swift'), '-o', str(binary)]
    subprocess.run(command, check=True, cwd=root)
    metadata = {'platform': platform.platform(), 'machine': platform.machine(), 'compiler': version,
                'git_commit': subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
                'trials': a.trials, 'seconds_per_trial': a.seconds, 'pool_size': a.pool_size,
                'build_flags': ['-O', '-D', 'PATHS_CPU_ONLY'], 'single_worker': True,
                'recorded_at_utc': datetime.now(timezone.utc).isoformat(),
                'source_sha256': {str(x.relative_to(root)): hashlib.sha256(x.read_bytes()).hexdigest() for x in [*sources, here/'Experiment.swift']}}
    (a.output/'metadata.json').write_text(json.dumps(metadata, indent=2)+'\n')
    subprocess.run([str(binary), str(a.output), str(a.trials), str(a.seconds), str(a.pool_size)],check=True,cwd=scratch)
subprocess.run(['python3', str(here/'summarize.py'), str(a.output)], check=True)
