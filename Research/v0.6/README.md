# v0.6 Release measurements

Same control Mac as v0.5: MacBookAir10,1 / M1 / 8 GiB, macOS 15.8.3, 1440×900 pt / 2880×1800 px, 60 Hz. See `control-mac.json`. Source: `a838d9727f93b86f47f3407218269962237bdebb`. Raw `performance.json` includes all Swift source fingerprints and corpus SHA-256 values.

Five independent Release processes for every scenario. A large PDF on the left, scan PDF or reflowable EPUB on the right, 120 real PDFKit scroll/display calls per run. OCR uses real local Vision concurrently; cancellation is requested after six frames. No speech player or AI provider is initialized. The harness calls production ReaderEngineFactory and engines; it measures native surfaces, not the SwiftUI shell.

| Pair / workload | Open, ms | Peak client RSS, MiB | CPU frame, ms | OCR, ms | Cancel, ms | OCR overlap frames |
|---|---:|---:|---:|---:|---:|---:|
| pdf-pdf / idle | 54.93 | 78.8 | 1.402 | 0.00 | 0.00 | 0 |
| pdf-pdf / ocr | 53.81 | 174.1 | 1.394 | 525.55 | 0.00 | 29 |
| pdf-pdf / cancel | 52.36 | 137.0 | 1.406 | 173.70 | 65.17 | 10 |
| pdf-epub / idle | 257.55 | 86.8 | 1.405 | 0.00 | 0.00 | 0 |
| pdf-epub / ocr | 258.20 | 179.7 | 1.373 | 501.88 | 0.00 | 27 |
| pdf-epub / cancel | 261.00 | 146.2 | 1.388 | 171.55 | 63.57 | 10 |

Values are medians of five processes; frame values are medians of per-process medians. Open time includes both engines and WebKit readiness. All ten complete OCR runs returned recognized lines; all ten cancellations reported cancelled. Every worker became weakly unreferenced after its task finished. Framework/model caches can remain resident: release of the request does not promise an immediate return of RSS to idle. Peak RSS is **client-process memory**, excluding WebKit/GPU helper processes. CPU frame work is not GPU completion/FPS; intervals include an explicit 16 ms sleep and scheduling overhead.

## Inherited PDF controls

Thirty identical ColorResearch scenarios, compared with the frozen v0.5 report:

| Fixture / palette | Open change | Peak RSS change | CPU frame change | Current CPU, ms |
|---|---:|---:|---:|---:|
| large-text.pdf / original | +1.9% | -4.7% | -1.5% | 1.891 |
| large-text.pdf / selected | +0.8% | -1.6% | +14.6% | 2.384 |
| text.pdf / original | -5.5% | -3.5% | -3.3% | 0.504 |
| text.pdf / selected | -2.1% | -1.7% | +20.2% | 0.567 |
| scan.pdf / original | +3.6% | -1.7% | +7.3% | 0.431 |
| scan.pdf / selected | -6.4% | -1.4% | -10.7% | 0.352 |

## Threshold investigation

The initial text/selected CPU median crossed 20%: 0.471 → 0.567 ms (+20.2%). A quiet five-run follow-up measured 0.619 ms; both datasets are retained. We rebuilt the accepted v0.5 source `2a244f4e55f38b2d1bfa786d9006d2c556e3f423` in an isolated package with the same current Swift toolchain. `performance-ab.json` records five interleaved old/new pairs, alternating order, on the same PDF/display, with binary checksums.

Same-session baseline median: 0.530 ms; v0.6: 0.493 ms (-7.0%). Baseline per-process medians span 0.357–0.641 ms; v0.6 spans 0.369–0.573 ms. The unchanged renderer/scroll workload does not reproduce an adverse code regression in this comparison; OCR and activity are inactive in these controls. Sub-millisecond drawing varies between sessions. No historical or slower result has been discarded. Open time and peak memory stay below the investigation threshold in all six inherited scenarios. Maximum cancellation latency: 94.84 ms.

## Reproduce

```sh
swift build -c release --product ExtendedResearch
swift build -c release --product ColorResearch
python3 scripts/benchmark-v06.py .build/release/ExtendedResearch --pdf-binary .build/release/ColorResearch --output /private/tmp/v06-performance.json
python3 scripts/compare-v06-control.py /path/to/v05/ColorResearch .build/release/ColorResearch --output /private/tmp/v06-ab.json
```

Run without concurrent builds/UI tests. The harness opens/closes temporary native windows. Sources remain unchanged. These results do not establish arbitrary-document OCR accuracy, total WebKit helper memory, GPU latency or real-model answer quality.
