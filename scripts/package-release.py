#!/usr/bin/env python3
"""Package a verified universal macOS release with explicit local ad-hoc signing."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('app', type=Path)
p.add_argument('--version', required=True, help='v1.0.0 or v1.0.0-rc.1; legacy v0.6 is accepted')
p.add_argument('--source', required=True, help='Full application-source commit')
p.add_argument('--acceptance', default='docs/v0.6.md', help='Repository-relative acceptance report')
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parent.parent
if a.output.exists() or a.output.with_suffix('.sha256').exists():
    raise RuntimeError('Refusing to overwrite an archive or its checksum')
match = re.fullmatch(r'v?(\d+)\.(\d+)(?:\.(\d+))?(?:-(?:rc|beta|alpha)\.\d+)?', a.version)
if not match:
    raise ValueError('Expected a release version, optionally with an alpha/beta/rc suffix')
expected_version = '.'.join([match[1], match[2], match[3] or '0'])
if len(a.source) != 40 or not all(c in '0123456789abcdef' for c in a.source):
    raise ValueError('Expected a full source commit SHA')
if subprocess.check_output(['git', 'cat-file', '-t', a.source], cwd=root, text=True).strip() != 'commit':
    raise ValueError('Source must identify a commit')
production_paths = ['Sources', 'Package.swift', 'Package.resolved', 'AdaptiveReader.xcodeproj']
subprocess.run(['git', 'diff', '--exit-code', a.source, '--', *production_paths], cwd=root, check=True, stdout=subprocess.DEVNULL)
if subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '--', *production_paths], cwd=root, text=True).strip():
    raise RuntimeError('Untracked production files: commit the source before packaging')
acceptance = (root / a.acceptance).resolve()
acceptance.relative_to(root)
if not acceptance.is_file():
    raise ValueError('Acceptance report is missing')
source_app = a.app.resolve()
info = plistlib.loads((source_app / 'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != 'com.karavaevflow.AdaptiveReader':
    raise ValueError('Expected the production app, not a development or test bundle')
if info.get('CFBundleShortVersionString') != expected_version:
    raise ValueError('Requested version does not match the built application')
if info.get('LSMinimumSystemVersion') != '15.0':
    raise ValueError('Unexpected minimum macOS version')
licenses = {'LICENSE': root / 'LICENSE', 'THIRD-PARTY.txt': root / 'Sources/AdaptiveReader/Resources/ZIPFoundation-LICENSE.txt'}
if not all(path.is_file() for path in licenses.values()):
    raise RuntimeError('Resolve the pinned dependency and include its license before packaging')
stage = Path(tempfile.mkdtemp(prefix='Adaptive-Package-')) / ('AdaptiveReader-' + a.version)
stage.mkdir()
app = stage / 'AdaptiveReader.app'
subprocess.run(['ditto', str(source_app), str(app)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(root / 'Sources/AdaptiveReader/AdaptiveReader.entitlements'), str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
architectures = subprocess.check_output(['xcrun', 'lipo', '-archs', str(app / 'Contents/MacOS' / info['CFBundleExecutable'])], text=True).strip()
if set(architectures.split()) != {'arm64', 'x86_64'}:
    raise RuntimeError('Expected both arm64 and x86_64')
signed = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL)
entitlements = plistlib.loads(signed)
if entitlements.get('com.apple.security.get-task-allow') or not entitlements.get('com.apple.security.app-sandbox'):
    raise RuntimeError('Expected a sandboxed distribution app without a debugger entitlement')
shutil.copyfile(licenses['LICENSE'], stage / 'LICENSE')
(stage / 'THIRD-PARTY.txt').write_text('ZIPFoundation 0.9.20\nhttps://github.com/weichsel/ZIPFoundation\n\n' + licenses['THIRD-PARTY.txt'].read_text())
for name in ['NOTICE.md', 'PRIVACY.md', 'SECURITY.md', 'CHANGELOG.md']:
    if (root / name).is_file():
        shutil.copyfile(root / name, stage / name)
shutil.copyfile(acceptance, stage / 'ACCEPTANCE.md')
toolchain = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip()
metadata = {'version': a.version, 'applicationVersion': expected_version, 'build': info['CFBundleVersion'],
            'sourceCommit': a.source, 'toolchain': toolchain, 'sdk': sdk, 'architectures': architectures.split(),
            'minimumMacOS': info['LSMinimumSystemVersion'], 'bundleIdentifier': info['CFBundleIdentifier'],
            'signature': 'local ad-hoc', 'notarized': False, 'entitlements': entitlements,
            'acceptance': str(acceptance.relative_to(root))}
(stage / 'BUILD.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
(stage / 'BUILD.txt').write_text(f'Adaptive Reader {a.version}\nApplication source: {a.source}\n{toolchain}\nmacOS SDK: {sdk}\nArchitectures: {architectures}\nMinimum macOS: 15.0\nSignature: local ad-hoc; no Developer ID or notarization\nAcceptance: {a.acceptance}\n')
(stage / 'README.txt').write_text('Requires macOS 15+. Move AdaptiveReader.app to your preferred local folder.\nLocal ad-hoc build, not notarized. Gatekeeper may require an explicit trusted-app approval in macOS Settings.\nDo not disable Gatekeeper. See the repository installation guide and acceptance report.\nAI is optional and off by default. Original books are not rewritten.\nPrivacy, licenses, exact source and signing status are included.\n')
a.output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', str(stage), str(a.output.resolve())], check=True)
extracted = Path(tempfile.mkdtemp(prefix='Adaptive-Verify-'))
subprocess.run(['ditto', '-x', '-k', str(a.output.resolve()), str(extracted)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(extracted / stage.name / 'AdaptiveReader.app')], check=True)
sha = hashlib.sha256(a.output.read_bytes()).hexdigest()
a.output.with_suffix('.sha256').write_text(sha + '  ' + a.output.name + '\n')
print(sha, a.output)
