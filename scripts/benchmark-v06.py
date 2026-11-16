#!/usr/bin/env python3
"""Five independent Release processes per scenario; real OCR, no speech or AI."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('binary', type=Path)
p.add_argument('--pdf-binary', type=Path)
p.add_argument('--output', type=Path, default=Path('Research/v0.6/performance.json'))
a = p.parse_args()
root = Path(__file__).resolve().parent.parent
result = {
    'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    'startedUTC': datetime.now(timezone.utc).isoformat(),
    'sourceFiles': {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted((root / 'Sources').rglob('*.swift'))},
    'fixtureChecksums': {path: hashlib.sha256((root / path).read_bytes()).hexdigest() for path in [
        'Research/Large/large-text.pdf', 'Research/Fixtures/scan.pdf', 'Research/Fixtures/text.pdf', 'Research/Fixtures/EPUB/reflow.epub']},
    'extended': [], 'pdfIdle': [],
}
a.output.parent.mkdir(parents=True, exist_ok=True)

def save():
    a.output.write_text(json.dumps(result, indent=2) + '\n')

for pair in ['pdf-pdf', 'pdf-epub']:
    for mode in ['idle', 'ocr', 'cancel']:
        for run in range(1, 6):
            row = json.loads(subprocess.check_output([str(a.binary.resolve()), str(root), mode, pair], cwd=root))
            row['run'] = run
            if mode == 'ocr' and (row['ocrStatus'] != 'completed' or not row['recognizedLines'] or not row['overlapFrames']):
                raise RuntimeError('OCR overlap did not execute: ' + repr(row))
            if mode == 'cancel' and row['ocrStatus'] != 'cancelled':
                raise RuntimeError('In-flight cancellation was not exercised: ' + repr(row))
            if not row['workerReleased']:
                raise RuntimeError('OCR worker remained retained')
            result['extended'].append(row)
            save()
        print(pair, mode, flush=True)
if a.pdf_binary:
    for source in ['Research/Large/large-text.pdf', 'Research/Fixtures/text.pdf', 'Research/Fixtures/scan.pdf']:
        for mode in ['original', 'selected']:
            for run in range(1, 6):
                row = json.loads(subprocess.check_output([str(a.pdf_binary.resolve()), 'scroll', str(root / source), mode], cwd=root))
                row['run'] = run
                result['pdfIdle'].append(row)
                save()
            print(source, mode, flush=True)
result['finishedUTC'] = datetime.now(timezone.utc).isoformat()
save()
