#!/usr/bin/env python3
"""Attach final evidence to a CI-tested candidate without changing its signed app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--archive', type=Path, required=True)
p.add_argument('--results', type=Path, required=True, help='Installed-production XCTest result bundle')
p.add_argument('--source', required=True)
p.add_argument('--run-url', required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parent.parent
if a.output.exists() or a.output.with_suffix('.sha256').exists():
    raise RuntimeError('Refusing to replace a candidate or checksum')
if len(a.source) != 40 or not all(c in '0123456789abcdef' for c in a.source):
    raise ValueError('Expected the full tested source commit')
documents = ['docs/v1.0.md', 'docs/distribution.md', 'PRIVACY.md', 'SECURITY.md', 'CHANGELOG.md']
subprocess.run(['git', 'diff', '--exit-code', 'HEAD', '--', *documents], cwd=root, check=True, stdout=subprocess.DEVNULL)
original_sha = hashlib.sha256(a.archive.read_bytes()).hexdigest()
if a.archive.with_suffix('.sha256').read_text().split()[0] != original_sha:
    raise RuntimeError('CI archive checksum mismatch')
summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(a.results.resolve())]))
if (summary.get('passedTests'), summary.get('failedTests'), summary.get('skippedTests')) != (1, 0, 0):
    raise RuntimeError('Installed-production test must pass once with zero failures/skips')
subprocess.run(['git', 'diff', '--exit-code', a.source, '--', 'Sources', 'Package.swift', 'Package.resolved', 'AdaptiveReader.xcodeproj'], cwd=root, check=True, stdout=subprocess.DEVNULL)
folder = Path(tempfile.mkdtemp(prefix='Adaptive-Finalize-'))
subprocess.run(['ditto', '-x', '-k', str(a.archive.resolve()), str(folder)], check=True)
entries = list(folder.iterdir())
if len(entries) != 1 or not entries[0].is_dir():
    raise RuntimeError('Expected one candidate folder')
stage = entries[0]
metadata = json.loads((stage / 'BUILD.json').read_text())
if metadata['sourceCommit'] != a.source or '-rc.' not in metadata['version']:
    raise RuntimeError('Expected this source revision and a release candidate, never a stable tag')
app = stage / 'AdaptiveReader.app'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)

def app_files(directory):
    return {str(path.relative_to(directory)): ('link:' + os.readlink(path) if path.is_symlink() else hashlib.sha256(path.read_bytes()).hexdigest())
            for path in sorted(directory.rglob('*')) if path.is_symlink() or path.is_file()}

before = app_files(app)
documentation_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()

def published_document(source):
    path = root / source
    def link(match):
        target = match.group(2)
        if target.startswith(('#', 'https://', 'http://', 'mailto:')):
            return match.group(0)
        relative, separator, anchor = target.partition('#')
        resolved = (path.parent / relative).resolve()
        if not resolved.exists():
            raise RuntimeError('Missing published document link: ' + target)
        repository_path = resolved.relative_to(root).as_posix()
        url = f'https://github.com/karavaevflow/adaptive-reader/blob/{documentation_commit}/{repository_path}'
        return '[' + match.group(1) + '](' + url + (separator + anchor if separator else '') + ')'
    return re.sub(r'\[([^\]]+)\]\(([^)]+)\)', link, path.read_text())

for source, destination in [('docs/v1.0.md', 'ACCEPTANCE.md'), ('docs/distribution.md', 'INSTALL.md'),
                            ('PRIVACY.md', 'PRIVACY.md'), ('SECURITY.md', 'SECURITY.md'), ('CHANGELOG.md', 'CHANGELOG.md')]:
    (stage / destination).write_text(published_document(source))
metadata['documentationCommit'] = documentation_commit
metadata['finalizedFromCIArchiveSHA256'] = original_sha
metadata['acceptanceReportSHA256'] = hashlib.sha256((stage / 'ACCEPTANCE.md').read_bytes()).hexdigest()
metadata['installedProductionTest'] = {'passed': 1, 'failed': 0, 'skipped': 0, 'run': a.run_url}
(stage / 'BUILD.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
if app_files(app) != before:
    raise RuntimeError('Finalization must not mutate the signed app')
a.output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', str(stage), str(a.output.resolve())], check=True)
verify = Path(tempfile.mkdtemp(prefix='Adaptive-Final-Verify-'))
subprocess.run(['ditto', '-x', '-k', str(a.output.resolve()), str(verify)], check=True)
extracted_app = verify / stage.name / 'AdaptiveReader.app'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(extracted_app)], check=True)
if app_files(extracted_app) != before:
    raise RuntimeError('Signed app changed during final archive creation')
sha = hashlib.sha256(a.output.read_bytes()).hexdigest()
a.output.with_suffix('.sha256').write_text(sha + '  ' + a.output.name + '\n')
print(sha, a.output)
