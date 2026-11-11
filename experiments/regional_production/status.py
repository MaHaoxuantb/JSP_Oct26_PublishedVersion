from pathlib import Path
import json
p=Path(__file__).resolve().parent / (Path(__file__).resolve().parent/'latest-run.txt').read_text().strip()
s=json.loads((p/'status.json').read_text())
print(s)
if s.get('running'):
    for f in (p/s['running']/'logs').glob('*.jsonl'):
        for line in reversed(f.read_text().splitlines()):
            try: e=json.loads(line)
            except json.JSONDecodeError: continue
            v=e['event']
            if v.get('best'):
                print({'seconds':e['elapsedSeconds'],'native':v['best']['total'],'wrong':v.get('clueMismatchCount'),'issues':v.get('structuralIssueCount'),'iteration':v['iteration']}); break
