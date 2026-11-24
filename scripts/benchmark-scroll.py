#!/usr/bin/env python3
"""Run 5 independent Release PDFView scrolling trials per fixture and mode."""
import json
from pathlib import Path
import subprocess
import argparse
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', type=Path)
parser.add_argument('--output', type=Path)
parser.add_argument('--include-large', action='store_true')
parser.add_argument('--resume', action='store_true')
args = parser.parse_args()
binary = str(args.binary.resolve())
root = Path(__file__).resolve().parent.parent
destination = args.output or root / 'Research/Results/scroll.json'
destination.parent.mkdir(parents=True, exist_ok=True)
rows = json.loads(destination.read_text()) if args.resume and destination.exists() else []
fixtures = list((root / 'Research/Fixtures').glob('*.pdf'))
if args.include_large: fixtures += list((root / 'Research/Large').glob('*.pdf'))
for fixture in sorted(fixtures):
    for mode in ('original', 'selected'):
        for run in range(1, 6):
            if any(r['fixture'] == fixture.name and r['mode'] == mode and r['run'] == run for r in rows): continue
            row = json.loads(subprocess.check_output([binary, 'scroll', str(fixture), mode]))
            row['run'] = run
            rows.append(row)
            destination.write_text(json.dumps(rows, indent=2, sort_keys=True)+'\n')
    print(fixture.name, flush=True)
destination.write_text(json.dumps(rows, indent=2, sort_keys=True)+'\n')
