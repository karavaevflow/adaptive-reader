# rc.2 native PDF page regression

Application source: `8e79df7666303ae42fb47901cf1aa34e7cb32c5f`. The public, repository-authored `Research/Fixtures/text.pdf` is the only input in this folder. No reader-owned book, library data or derived private page image is published.

## Actual PDFKit drawing

[Raw measurements](native-page-metrics.json) contain five independent Release processes per palette on the same MacBookAir10,1 / Apple M1 / 8 GiB, macOS 15.8.3 (24H241), Xcode 26.3 / SDK 26.2 as the previous control. Rendering is offscreen at 512×664 pixels. No local build or UI automation overlapped these measurements; the owner's Reader remained open, so this is not an otherwise idle whole-system benchmark.

| Median | Original | Midnight |
|---|---:|---:|
| Engine + palette preflight | 81.489 ms | 114.449 ms |
| First draw, chapters 1 / 2 / 3 | 2.090 / 1.053 / 1.089 ms | 4.956 / 13.030 / 12.939 ms |
| Repeat draw, chapters 1 / 2 / 3 | 0.983 / 0.988 / 0.983 ms | 0.920 / 0.906 / 0.866 ms |
| Peak client RSS | 35.03 MiB | 93.78 MiB |

Each process asserts three distinct page pixel hashes and an identical repeat hash for each page. Midnight preflight prepares the first page; its first draw therefore does not include a cold color conversion. Drawing timings include forced pixel retrieval and SHA-256, not on-screen frame presentation. RSS excludes WindowServer, GPU and other processes. These are native `PDFPage.draw` calls on the actual subclass instances returned by PDFKit, unlike the earlier standalone renderer observations.

This is a **new correct-render baseline**. The previous faulty path reused another page's cached pixels and cannot serve as a performance baseline for correct drawing. Midnight's additional conversion time and roughly 59 MiB client memory are retained explicitly; no claim of a <20% difference from Original or the historical invalid native path is made. The five-run files from rc.1 remain frozen historical observations and do not certify this changed native rendering path.

## Reproduce

From the repository root, create a temporary Swift package outside the source tree. Its dependency is the existing local package; it adds no dependency to the application:

```sh
probe=$(mktemp -d /private/tmp/Adaptive-Native-Page-XXXXXX)
mkdir -p "$probe/Sources/NativePageProbe"
cp Research/v1.0-rc.2/native-page-probe.swift "$probe/Sources/NativePageProbe/main.swift"
python3 - "$PWD" "$probe" <<'PY'
import json, pathlib, sys
root, probe = sys.argv[1:]
pathlib.Path(probe, 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NativePageProbe", platforms: [.macOS(.v15)],
    dependencies: [.package(name: "AdaptiveReader", path: ROOT)],
    targets: [.executableTarget(name: "NativePageProbe", dependencies: [
        .product(name: "ReaderCore", package: "AdaptiveReader")])])
'''.replace('ROOT', json.dumps(root)))
PY
swift build --package-path "$probe" -c release
for palette in original midnight; do
  for run in 1 2 3 4 5; do
    "$probe/.build/release/NativePageProbe" "$PWD/Research/Fixtures/text.pdf" "$palette"
  done
done
```

Each output line is one independent process. Keep all ten observations and record the tested commit, toolchain and control hardware with any new report. This probe does not open windows, request speech, connect a model or modify a source file.
