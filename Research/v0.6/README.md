# v0.6 Release measurements

Control Mac: MacBookAir10,1 / M1 / 8 GiB, macOS 15.8.3, 1440×900 pt / 2880×1800 px, 60 Hz. See `control-mac.json`. Measured source: `5f0ebcde94c454bde98ba93b078a9d320754dbf5`. Final application source `d42b72bb7dfea8e6ec1b8ee1ded79d41a3973e7a` changes only English Replay labels and the matching UI assertion; all ReaderCore/harness source fingerprints remain unchanged. `performance-cpu-final.json` records source fingerprints, corpus checksums and five independent Release processes per scenario. Earlier measurements remain available; no slower dataset was discarded.

The harness opens a large PDF on the left and a scan PDF or reflowable EPUB on the right, making 120 real PDFKit scroll/display calls per process. Real local Vision OCR runs concurrently; cancellation is requested after six frames. Production OCR explicitly selects a supported CPU compute device for each Vision stage and requests background processing. No speech player or AI provider is initialized. The harness uses production ReaderEngineFactory/engines and native surfaces, not the SwiftUI shell or Insights rendering.

| Pair / workload | Open, ms | Peak client RSS, MiB | CPU frame, ms | OCR, ms | Cancel, ms | OCR overlap frames |
|---|---:|---:|---:|---:|---:|---:|
| pdf-pdf / idle | 56.53 | 78.7 | 1.420 | 0.00 | 0.00 | 0 |
| pdf-pdf / ocr | 53.59 | 177.5 | 1.419 | 430.85 | 0.00 | 25 |
| pdf-pdf / cancel | 52.69 | 138.3 | 1.437 | 114.80 | 9.30 | 7 |
| pdf-epub / idle | 268.02 | 86.2 | 1.427 | 0.00 | 0.00 | 0 |
| pdf-epub / ocr | 257.28 | 189.2 | 1.377 | 375.46 | 0.00 | 22 |
| pdf-epub / cancel | 248.82 | 148.1 | 1.385 | 115.07 | 11.39 | 7 |

Values are medians of five processes; frame values are medians of per-process medians. All ten complete OCR runs returned recognized lines; all ten cancellation runs reported cancelled. Every worker became weakly unreferenced after completion. Maximum final-source cancellation latency: 41.46 ms. Framework/model caches can remain resident: releasing a request does not promise RSS returns immediately to idle. Peak RSS is **client-process memory**, excluding WebKit/GPU helpers. CPU work is not GPU completion or display FPS; intervals include an explicit 16 ms sleep and scheduling overhead.

## Inherited PDF controls

Thirty final-source ColorResearch scenarios compared with the frozen v0.5 report (`performance-cpu-final.json`, `pdfIdle`):

| Fixture / palette | Open change | Peak RSS change | CPU frame change | Current CPU, ms |
|---|---:|---:|---:|---:|
| large-text.pdf / original | +3.0% | -3.6% | +0.4% | 1.927 |
| large-text.pdf / selected | +1.2% | -1.6% | +10.7% | 2.303 |
| text.pdf / original | -3.2% | -2.9% | +2.2% | 0.533 |
| text.pdf / selected | -2.8% | -1.5% | +37.6% | 0.649 |
| scan.pdf / original | +6.0% | -1.2% | +52.8% | 0.613 |
| scan.pdf / selected | -7.0% | -1.5% | -18.7% | 0.320 |

## Threshold investigation

Initial text/selected CPU work crossed 20% (0.471 → 0.567 ms); a quiet follow-up reached 0.619 ms. Earlier alternating old/new trials and the pre-CPU-backend final report remain in `performance-ab.json`, `performance-ab-final.json`, `performance-final.json` and `performance-followup.json`. Final-source historical comparisons again crossed the threshold for text/selected and scan/original, so neither was accepted without investigation.

The accepted v0.5 source `2a244f4e55f38b2d1bfa786d9006d2c556e3f423` was rebuilt in an isolated package using the same current Swift toolchain. `performance-cpu-ab.json` first compared text/selected (0.609 vs 0.612 ms, +0.5%). `performance-all-controls-ab.json` then ran **60 alternating baseline/current processes across all six controls**, alternating order each round and recording binary checksums. Results:

| Fixture / palette | Open change | Peak RSS change | CPU work change | Baseline → current CPU, ms |
|---|---:|---:|---:|---:|
| large-text.pdf / original | -1.1% | -1.2% | +2.2% | 1.877 → 1.917 |
| large-text.pdf / selected | +9.6% | -1.3% | -7.7% | 2.235 → 2.064 |
| text.pdf / original | +1.0% | -3.0% | -6.8% | 0.547 → 0.510 |
| text.pdf / selected | +1.1% | -1.3% | +4.5% | 0.582 → 0.608 |
| scan.pdf / original | +1.5% | -1.5% | -13.9% | 0.520 → 0.448 |
| scan.pdf / selected | +10.1% | +0.0% | -2.1% | 0.306 → 0.299 |

All paired changes stay below 20%. The adverse historical differences were not reproduced against the old implementation in the same session; sub-millisecond native rendering varied substantially between sessions. This resolves the investigation for this corpus/control Mac, without claiming all arbitrary workloads are regression-free.

## Reproduce

```sh
swift build -c release --product ExtendedResearch
swift build -c release --product ColorResearch
python3 scripts/benchmark-v06.py .build/release/ExtendedResearch --pdf-binary .build/release/ColorResearch --output /private/tmp/v06-performance.json
python3 scripts/compare-v06-control.py /path/to/v05/ColorResearch .build/release/ColorResearch --all-controls --output /private/tmp/v06-ab.json
```

Run without concurrent builds/UI tests. Temporary native windows open/close; source files remain unchanged. Results do not establish arbitrary-document OCR accuracy, helper-process memory, GPU latency or real-model answer quality.
