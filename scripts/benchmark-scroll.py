#!/usr/bin/env python3
"""Run 5 independent Release PDFView scrolling trials per fixture and mode."""
import json
from pathlib import Path
import subprocess
import sys
binary = str(Path(sys.argv[1]).resolve())
root = Path(__file__).resolve().parent.parent
destination = root / 'Research/Results/scroll.json'
rows = json.loads(destination.read_text()) if destination.exists() else []
for fixture in sorted((root / 'Research/Fixtures').glob('*.pdf')):
    for mode in ('original', 'selected'):
        for run in range(1, 6):
            if any(r['fixture'] == fixture.name and r['mode'] == mode and r['run'] == run for r in rows): continue
            row = json.loads(subprocess.check_output([binary, 'scroll', str(fixture), mode]))
            row['run'] = run
            rows.append(row)
            destination.write_text(json.dumps(rows, indent=2, sort_keys=True)+'\n')
    print(fixture.name, flush=True)
(root / 'Research/Results/scroll.json').write_text(json.dumps(rows, indent=2, sort_keys=True)+'\n')
