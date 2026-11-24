#!/usr/bin/env python3
"""Wrap a verified Adaptive Reader release ZIP in a read-only macOS DMG."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("archive", type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
archive = args.archive.resolve()
output = args.output.resolve()
dmg_checksum = output.with_name(output.name + ".sha256")
if output.exists() or dmg_checksum.exists():
    raise RuntimeError("Refusing to overwrite a disk image or its checksum")
match = re.fullmatch(r"AdaptiveReader-(v\d+\.\d+\.\d+(?:-rc\.\d+)?)\.zip", archive.name)
if not match:
    raise ValueError("Expected a versioned AdaptiveReader release ZIP")
version = match[1]
checksum = archive.with_suffix(".sha256")
if not checksum.is_file():
    raise FileNotFoundError("The ZIP checksum sidecar is required")
expected = checksum.read_text().strip().split()
if len(expected) != 2 or expected[1] != archive.name or expected[0] != hashlib.sha256(archive.read_bytes()).hexdigest():
    raise ValueError("Release ZIP checksum does not match")
work = Path(tempfile.mkdtemp(prefix="Adaptive-DMG-"))
subprocess.run(["ditto", "-x", "-k", str(archive), str(work)], check=True)
package = work / f"AdaptiveReader-{version}"
app = package / "AdaptiveReader.app"
if not app.is_dir() or not (package / "BUILD.json").is_file():
    raise ValueError("Release ZIP is missing its app or build metadata")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
image = work / output.name
subprocess.run(["hdiutil", "create", "-quiet", "-format", "UDZO", "-fs", "HFS+",
                "-volname", f"Adaptive Reader {version}", "-srcfolder", str(package), str(image)], check=True)
subprocess.run(["hdiutil", "verify", "-quiet", str(image)], check=True)
output.parent.mkdir(parents=True, exist_ok=True)
shutil.move(str(image), str(output))
dmg_checksum.write_text(
    hashlib.sha256(output.read_bytes()).hexdigest() + "  " + output.name + "\n")
print(output)
