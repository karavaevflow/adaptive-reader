#!/usr/bin/env python3
"""Investigate PDF performance thresholds using alternating old/new Release binaries."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('baseline', type=Path)
p.add_argument('current', type=Path)
p.add_argument('--output', type=Path, default=Path('Research/v0.6/performance-ab.json'))
p.add_argument('--all-controls', action='store_true', help='Compare all six inherited PDF scenarios')
p.add_argument('--baseline-source', default='2a244f4e55f38b2d1bfa786d9006d2c556e3f423', help='Full source revision used to build the baseline binary')
p.add_argument('--companion', action='store_true', help='Include the deterministic indexing/fixture-response workload, never a real model')
a = p.parse_args()
if len(a.baseline_source) != 40 or any(c not in '0123456789abcdef' for c in a.baseline_source):
    p.error('--baseline-source must be a full hexadecimal commit SHA')
root = Path(__file__).resolve().parent.parent
result = {'baselineCommit': a.baseline_source,
          'currentCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
          'startedUTC': datetime.now(timezone.utc).isoformat(),
          'binaryChecksums': {key: hashlib.sha256(path.read_bytes()).hexdigest() for key, path in [('baseline', a.baseline), ('current', a.current)]},
          'runs': []}
sources = ['Research/Large/large-text.pdf', 'Research/Fixtures/text.pdf', 'Research/Fixtures/scan.pdf'] if a.all_controls else ['Research/Fixtures/text.pdf']
modes = ['original', 'selected'] if a.all_controls else ['selected']
for source in sources:
    for mode in modes:
        for run in range(1, 6):
            for label, binary in ([('baseline', a.baseline), ('current', a.current)] if run % 2 else [('current', a.current), ('baseline', a.baseline)]):
                row = json.loads(subprocess.check_output([str(binary.resolve()), 'scroll', str(root / source), mode] + (['companion'] if a.companion else [])))
                row.update(version=label, run=run); result['runs'].append(row)
                a.output.write_text(json.dumps(result, indent=2) + '\n')
result['finishedUTC'] = datetime.now(timezone.utc).isoformat()
a.output.write_text(json.dumps(result, indent=2) + '\n')
