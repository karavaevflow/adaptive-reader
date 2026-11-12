#!/usr/bin/env python3
"""Five independent Release processes per EPUB workload and matching PDF idle controls.

Run on the quiet control Mac, after builds/UI tests finish. EPUB windows stay hidden;
the real production speech player runs with volume zero. No model or network calls.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('binary', type=Path)
p.add_argument('--pdf-binary', type=Path)
p.add_argument('--output', type=Path, default=Path('Research/v0.4/performance.json'))
a = p.parse_args()
root = Path(__file__).resolve().parent.parent
result = {'epub': [], 'pdfIdle': []}
a.output.parent.mkdir(parents=True, exist_ok=True)

def processes():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,rss=,comm='], text=True)
    found = {}
    for line in rows.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            found[int(fields[0])] = (int(fields[1]) * 1024, fields[2])
    return found

def save():
    a.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')

for run in range(1, 6):
    for speech in [False, True]:
        before = processes()
        command = [str(a.binary.resolve()), str(root / 'Research/Fixtures/EPUB/reflow.epub')]
        if speech:
            command.append('--speech')
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        peak = 0
        webkit_peak = 0
        observed = set()
        while child.poll() is None:
            current = processes()
            webkit = {pid: item for pid, item in current.items() if pid not in before and 'com.apple.WebKit' in item[1]}
            observed.update(webkit)
            total = sum(item[0] for item in webkit.values())
            webkit_peak = max(webkit_peak, total)
            peak = max(peak, current.get(child.pid, (0, ''))[0] + total)
            time.sleep(0.02)
        stdout, stderr = child.communicate()
        if child.returncode:
            raise RuntimeError(f'{command}: {stderr}')
        row = json.loads(stdout)
        row.update(run=run, sampledClientAndNewWebKitPeakBytes=peak, sampledNewWebKitPeakBytes=webkit_peak, observedNewWebKitPIDs=sorted(observed))
        result['epub'].append(row)
        save()
        print(f'EPUB {run}/5 speech={speech}', flush=True)

if a.pdf_binary:
    for source in ['Research/Large/large-text.pdf', 'Research/Fixtures/text.pdf', 'Research/Fixtures/scan.pdf']:
        for mode in ['original', 'selected']:
            for run in range(1, 6):
                row = json.loads(subprocess.check_output([str(a.pdf_binary.resolve()), 'scroll', str(root / source), mode]))
                row.update(run=run)
                result['pdfIdle'].append(row)
                save()
            print(source, mode, flush=True)
