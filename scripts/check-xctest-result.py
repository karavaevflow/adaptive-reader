#!/usr/bin/env python3
"""Fail release gates when a required XCTest scenario was skipped or absent."""
import argparse
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('result', type=Path)
p.add_argument('--passed', type=int, required=True)
p.add_argument('--minimum-seconds', type=float, default=0)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(a.result.resolve())]))
if (summary.get('passedTests'), summary.get('failedTests'), summary.get('skippedTests')) != (a.passed, 0, 0):
    raise RuntimeError('Required XCTest scenario did not pass exactly, without failures/skips')
if summary.get('finishTime', 0) - summary.get('startTime', 0) < a.minimum_seconds:
    raise RuntimeError('Required real elapsed duration was not reached')
a.output.write_text(json.dumps(summary, indent=2) + '\n')
print(f"Passed {a.passed} required test(s), no failures/skips")
