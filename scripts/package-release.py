#!/usr/bin/env python3
"""Package and verify a universal, locally signed macOS app without notarization."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('app', type=Path)
p.add_argument('--version', required=True)
p.add_argument('--source', required=True, help='Full application-source commit')
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parent.parent
if a.output.exists():
    raise RuntimeError('Refusing to overwrite an existing archive')
if len(a.source) != 40 or not all(c in '0123456789abcdef' for c in a.source):
    raise ValueError('Expected a full source commit SHA')
stage = Path(tempfile.mkdtemp(prefix='Adaptive-Package-')) / ('AdaptiveReader-' + a.version)
stage.mkdir()
app = stage / 'AdaptiveReader.app'
subprocess.run(['ditto', str(a.app.resolve()), str(app)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(root / 'Sources/AdaptiveReader/AdaptiveReader.entitlements'), str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
architectures = subprocess.check_output(['xcrun', 'lipo', '-archs', str(app / 'Contents/MacOS/AdaptiveReader')], text=True).strip()
if set(architectures.split()) != {'arm64', 'x86_64'}:
    raise RuntimeError('Expected both arm64 and x86_64')
shutil.copyfile(root / 'LICENSE', stage / 'LICENSE')
dependency_license = root / '.build/checkouts/ZIPFoundation/LICENSE'
if not dependency_license.is_file():
    raise RuntimeError('Resolve the pinned ZIPFoundation dependency before packaging its license')
(stage / 'THIRD-PARTY.txt').write_text('ZIPFoundation 0.9.20\nhttps://github.com/weichsel/ZIPFoundation\n\n' + dependency_license.read_text())
toolchain = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip()
(stage / 'BUILD.txt').write_text(f'Adaptive Reader {a.version}\nApplication source: {a.source}\n{toolchain}\nmacOS SDK: {sdk}\nArchitectures: {architectures}\nMinimum macOS: 15.0\nSignature: local ad-hoc; no Developer ID or notarization\nAcceptance: docs/v0.6.md in the source repository\n')
(stage / 'README.txt').write_text('Move AdaptiveReader.app to your preferred local folder. Requires macOS 15+.\nLocal ad-hoc build, not notarized. MIT license.\nView > Extended reading (Shift-Command-E): split panes, translations/vocabulary, local OCR and opt-in history/statistics.\nApplication menus address the primary pane; second-pane controls address that pane.\nNo original source is rewritten. AI stays off until explicitly configured.\n')
a.output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', str(stage), str(a.output.resolve())], check=True)
extracted = Path(tempfile.mkdtemp(prefix='Adaptive-Verify-'))
subprocess.run(['ditto', '-x', '-k', str(a.output.resolve()), str(extracted)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(extracted / stage.name / 'AdaptiveReader.app')], check=True)
sha = hashlib.sha256(a.output.read_bytes()).hexdigest()
a.output.with_suffix('.sha256').write_text(sha + '  ' + a.output.name + '\n')
print(sha, a.output)
