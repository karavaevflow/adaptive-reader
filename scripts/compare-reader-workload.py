#!/usr/bin/env python3
"""Alternate frozen/current Release processes for a flagged reader workload."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('baseline', type=Path)
p.add_argument('current', type=Path)
p.add_argument('--baseline-source', required=True)
p.add_argument('--current-source', required=True)
p.add_argument('--scenario', choices=['epub-speech', 'split-cancel'], required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
for revision in [a.baseline_source, a.current_source]:
    if len(revision) != 40 or any(c not in '0123456789abcdef' for c in revision):
        p.error('Source revisions must be full hexadecimal commit SHAs')
if a.output.exists():
    p.error('Choose a new output; retain earlier evidence')
root = Path(__file__).resolve().parent.parent
result = dict(baselineCommit=a.baseline_source, currentCommit=a.current_source,
              startedUTC=datetime.now(timezone.utc).isoformat(), scenario=a.scenario,
              binaryChecksums={name: hashlib.sha256(path.read_bytes()).hexdigest() for name,path in [('baseline',a.baseline),('current',a.current)]},
              runs=[])
a.output.parent.mkdir(parents=True, exist_ok=True)
for pair in (['pdf-pdf', 'pdf-epub'] if a.scenario == 'split-cancel' else [None]):
    for run in range(1, 6):
        order = [('baseline',a.baseline),('current',a.current)]
        if run % 2 == 0:
            order.reverse()
        for version, binary in order:
            arguments = [str(root),'cancel',pair] if pair else [str(root/'Research/Fixtures/EPUB/reflow.epub'),'--speech']
            row = json.loads(subprocess.check_output([str(binary.resolve()),*arguments],cwd=root))
            if pair:
                if row['ocrStatus'] != 'cancelled' or not row['workerReleased']:
                    raise RuntimeError('Cancellation/release was not exercised')
            elif row['nativeWordCallbacks'] <= 0 or row['lateWordCallbacksAfterStop'] != 0:
                raise RuntimeError('Muted native speech/stop was not exercised')
            row.update(version=version,run=run)
            result['runs'].append(row)
            a.output.write_text(json.dumps(result,indent=2)+'\n')
        print(a.scenario,pair or '',run,'/ 5',flush=True)
result['finishedUTC'] = datetime.now(timezone.utc).isoformat()
a.output.write_text(json.dumps(result,indent=2)+'\n')
