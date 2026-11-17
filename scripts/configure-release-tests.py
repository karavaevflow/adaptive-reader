#!/usr/bin/env python3
"""Bind UI acceptance to an extracted production app on a disposable CI Mac."""
import argparse
import os
from pathlib import Path
import plistlib

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--products', type=Path, required=True)
p.add_argument('--app', type=Path, required=True)
a = p.parse_args()
if os.environ.get('GITHUB_ACTIONS') != 'true':
    raise RuntimeError('Production-container tests are restricted to disposable GitHub runners')
root = Path(__file__).resolve().parent.parent
info = plistlib.loads((a.app / 'Contents/Info.plist').read_bytes())
if info['CFBundleIdentifier'] != 'com.karavaevflow.AdaptiveReader':
    raise RuntimeError('Expected the extracted production Release app')
files = list(a.products.glob('AdaptiveReader_*.xctestrun'))
if len(files) != 1:
    raise RuntimeError('Expected exactly one native test-run description')
source = files[0]
value = plistlib.loads(source.read_bytes())
if 'TestConfigurations' in value:
    targets = [t for c in value['TestConfigurations'] for t in c['TestTargets'] if t.get('IsUITestBundle')]
else:
    targets = [t for t in value.values() if isinstance(t, dict) and t.get('IsUITestBundle')]
if len(targets) != 1:
    raise RuntimeError('Expected one UI test target')
variables = {'ADAPTIVE_RELEASE_CI_ONLY': 'YES', 'ADAPTIVE_RELEASE_APP_URL': str(a.app.resolve()),
             'ADAPTIVE_UPGRADE_FIXTURE': str(root / 'Research/Upgrade/v0.6/Library'),
             'ADAPTIVE_UPGRADE_ARCHIVE': str(root / 'Research/Upgrade/v0.6/Library.zip'),
             'ADAPTIVE_RELEASE_PDF': str(root / 'Research/Fixtures/text.pdf')}
for target in targets:
    target['UITargetAppPath'] = str(a.app.resolve())
    for key in ['EnvironmentVariables', 'TestingEnvironmentVariables']:
        target.setdefault(key, {}).update(variables)
out = source.with_name('ReleaseAcceptance.xctestrun')
if out.exists():
    raise RuntimeError('Refusing to overwrite a test-run description')
out.write_bytes(plistlib.dumps(value))
print(out)
