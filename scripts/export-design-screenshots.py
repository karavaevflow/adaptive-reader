#!/usr/bin/env python3
"""Export only application reference images from the visual acceptance test."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("result", type=Path, help="Xcode .xcresult bundle")
parser.add_argument("destination", type=Path, help="Reference image directory")
parser.add_argument("--release", choices=("phase0", "v02", "v03", "v04-foundation", "v04", "v04-flows", "v04-export"), default="phase0")
args = parser.parse_args()
expected = {
    f"{screen}-{language}-{width}-{theme}"
    for screen in ("Library", "Reader", "Appearance", "Inspector")
    for language in ("en", "ru")
    for width in (800, 1440)
    for theme in ("light", "dark")
}
expected |= {f"Components-{language}-{theme}" for language in ("en", "ru") for theme in ("light", "dark")}
if args.release == "v02":
    expected = {
        f"v02-{screen}-{language}-{width}-{theme}"
        for screen in ("Commands", "Tools", "Spotlight", "Mini")
        for language in ("en", "ru")
        for width in (800, 1440)
        for theme in ("light", "dark")
    }
if args.release == "v03":
    expected = {
        f"v03-{screen}-{language}-{width}-{theme}"
        for screen in ("Companion", "Settings")
        for language in ("en", "ru")
        for width in (800, 1440)
        for theme in ("light", "dark")
    }
if args.release == "v04-foundation":
    expected = {"v04-epub-reflow", "v04-epub-restored"}
if args.release == "v04":
    expected = {f"v04-{screen}-{language}-{width}-{theme}" for screen in ("Notes", "NoteEditor", "Cards", "CardEditor", "Recall", "Highlights", "Listen", "Reader") for language in ("en", "ru") for width in (800, 1440) for theme in ("light", "dark")}
if args.release == "v04-flows":
    expected = {"v04-recall-flow", "v04-highlight-reflow-flow", "v04-study-restored-flow", "v04-listen-paused-flow"}
if args.release == "v04-export":
    expected = {"v04-markdown-export-flow"}
with tempfile.TemporaryDirectory(prefix="adaptive-design-") as temporary:
    directory = Path(temporary)
    subprocess.run([
        "xcrun", "xcresulttool", "export", "attachments",
        "--path", str(args.result.resolve()), "--output-path", str(directory),
    ], check=True, stdout=subprocess.DEVNULL)
    manifest = json.loads((directory / "manifest.json").read_text())
    images = {}
    for test in manifest:
        for attachment in test["attachments"]:
            name = attachment["suggestedHumanReadableName"]
            expected_name = next((candidate for candidate in expected if name.startswith(candidate + "_")), None)
            if expected_name and attachment["exportedFileName"].endswith(".png"):
                images[expected_name] = directory / attachment["exportedFileName"]
    missing = expected - images.keys()
    if missing:
        parser.error("Incomplete reference matrix: " + ", ".join(sorted(missing)))
    args.destination.mkdir(parents=True, exist_ok=True)
    for name in sorted(expected):
        shutil.copyfile(images[name], args.destination / f"{name}.png")
print(f"Exported {len(expected)} reference images to {args.destination}")
