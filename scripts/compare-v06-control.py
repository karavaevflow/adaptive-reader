#!/usr/bin/env python3
"""Investigate the text/selected threshold using alternating old/new Release binaries."""
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
a = p.parse_args()
root = Path(__file__).resolve().parent.parent
result = {'baselineCommit': '2a244f4e55f38b2d1bfa786d9006d2c556e3f423',
          'currentCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
          'startedUTC': datetime.now(timezone.utc).isoformat(),
          'binaryChecksums': {key: hashlib.sha256(path.read_bytes()).hexdigest() for key, path in [('baseline', a.baseline), ('current', a.current)]},
          'runs': []}
for run in range(1, 6):
    for label, binary in ([('baseline', a.baseline), ('current', a.current)] if run % 2 else [('current', a.current), ('baseline', a.baseline)]):
        row = json.loads(subprocess.check_output([str(binary.resolve()), 'scroll', str(root / 'Research/Fixtures/text.pdf'), 'selected']))
        row.update(version=label, run=run); result['runs'].append(row)
        a.output.write_text(json.dumps(result, indent=2) + '\n')
result['finishedUTC'] = datetime.now(timezone.utc).isoformat()
a.output.write_text(json.dumps(result, indent=2) + '\n')
