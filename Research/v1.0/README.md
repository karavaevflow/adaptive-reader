# v1.0 candidate Release measurements

Measured application/core source: `630247735cc3f3078b8c5e4918a479380d9d0fb1`. UI-test-only commits `6121a5702363e0454da8f7cd59a85bff53b13ac4` and `cf16f94f576a8bbdf1515b8747a6faf1a9469630` preserve all production source. Control Mac: MacBookAir10,1 / Apple M1 / 8 GiB, macOS 15.8.3, Xcode 26.3, 1440×900 pt / 2880×1800 px, 60 Hz. [Control metadata](control-mac.json), [binary/source provenance](build-provenance.json).

Five independent Release processes per scenario. No local build or UI automation overlapped primary measurements. Filesystem/model caches were not flushed. The three preliminary `prebackup/` reports at source 644827d remain separate; final conclusions use the complete final-source files below. No slower dataset was discarded.

## Native process launch

Five fresh QA identities/libraries: median **806.82 ms**, range 799.07–2605.98 ms; median sampled RSS 74.53 MiB. All five owned processes terminated normally. [Raw runs](launch.json).

This supplemental metric measures the first layer-0 WindowServer window ≥400×200 pt, using an inactive QA copy of the production Release app. It does not prove first readable pixels, interactive readiness, cold OS startup or exact production bundle trust behavior. One RSS sample is taken after the window appears; it is not peak RSS. QA identities protect the owner's production library/preferences. No speech/model action runs. This is a new baseline, not an interchangeable comparison with older XCTest launch instrumentation.

## Independent readers and real CPU OCR

| Pair / workload | Open ms | Peak client MiB | CPU frame ms | OCR ms | Cancel ms |
|---|---:|---:|---:|---:|---:|
| pdf-pdf / idle | 53.50 | 79.03 | 1.342 | 0.00 | 0.00 |
| pdf-pdf / ocr | 55.40 | 175.94 | 1.331 | 411.66 | 0.00 |
| pdf-pdf / cancel | 52.57 | 141.81 | 1.345 | 118.20 | 14.41 |
| pdf-epub / idle | 260.90 | 86.33 | 1.347 | 0.00 | 0.00 |
| pdf-epub / ocr | 244.21 | 188.47 | 1.322 | 396.55 | 0.00 |
| pdf-epub / cancel | 253.35 | 148.75 | 1.325 | 137.25 | 33.72 |

All ten full OCR runs recognized lines during overlapping scroll frames; all ten cancellation runs cancelled in flight. Every worker was released. [30 reader runs and 30 inherited PDF controls](extended-performance.json). CPU frames are per-process median CPU display work, not compositor/GPU latency. Client RSS excludes WebKit/GPU helpers, the SwiftUI shell and Insights rendering.

## EPUB and local speech at volume zero

| Workload | Layout ms | Reflow ms | Locator ms | First word ms | Input ms | Client peak MiB | Sampled client + new WebKit MiB |
|---|---:|---:|---:|---:|---:|---:|---:|
| Idle | 319.01 | 29.16 | 5.63 | 0.00 | 5.71 | 69.23 | 197.64 |
| Muted native speech | 293.63 | 23.50 | 5.73 | 680.29 | 5.58 | 94.66 | 225.75 |

[Ten runs](epub-performance.json) use the actual production SpeechPlayer at **volume 0** and the same authored 1,800-paragraph chapter. Every speaking process received native word callbacks; no run received late callbacks in the 300 ms after stop. Hidden native WebKit windows force real DOM layout. Timings include IPC/polling, not on-screen presentation. Additional memory is an approximately 20 ms sample of the client plus newly observed WebKit processes, not authoritative coalition ownership. Shared system speech services and WindowServer are excluded.

## Fixed Knowledge library

Twenty managed books, 1,000 cards, 1,000 board nodes and 1,997 edges, five fresh isolated libraries. Same corpus/workload as v0.5; no speech/model requests. [Raw runs](knowledge-performance.json).

| Metric | Median |
|---|---:|
| coldSearchMS | 8184.216 ms |
| cachedSearchMS | 365.330 ms |
| boardDataOpenMS | 28.152 ms |
| canvasLayoutMedianMS | 0.600 ms |
| canvasLayoutP95MS | 0.661 ms |
| nodeSaveMedianMS | 62.351 ms |
| cancelMS | 30.034 ms |
| Peak client RSS | 73.31 MiB |

All five cancellations completed, source issues stayed empty, round trips preserved records and search returned real results. CPU projection/culling is shared production layout work, not on-screen GPU performance. First search includes extraction, local index/vector initialization and installed system semantic-model preparation.

## PDF indexing / fixture-response overlap

[Sixty five-process observations](companion-overlap.json) repeat all three PDF fixtures in Original/selected policy, idle and indexing/paced-response modes. The response is deterministic synthetic data, **not a real model**. All text workload runs complete indexing/response processing and exercise cancellation; scans explicitly report no accessible text. Opening/peak-memory results remain below the historical 20% threshold. Historical CPU crossings are retained and investigated below.

## Threshold investigation

[Historical comparison](historical-comparison.json) retains **132 metric comparisons and eight >20% triggers**: OCR cancellation in both reader pairs, selected scan CPU work, muted native first-word latency and four PDF CPU observations against the older v0.3 baseline. Baselines include the same control Mac with macOS 15.8.2 (v0.3/v0.4) and 15.8.3 (v0.5/v0.6); cross-session differences are not attributed to code by inference alone.

Exact historical source was rebuilt separately with the current toolchain: v0.4 `0c5d73c1376b46928a78f6d8a27a35adc1a41a2c` for speech, v0.6 `5f0ebcde94c454bde98ba93b078a9d320754dbf5` for OCR cancellation. The preserved v0.6 ColorResearch binary's SHA-256 was matched to the frozen v0.6 report before use. Each old/new order alternates over five rounds:

- [60 PDF idle trials](pdf-paired-controls.json), all six controls.
- [60 PDF index/fixture-response trials](companion-paired-controls.json), all six controls.
- [Ten muted native speech trials](epub-speech-paired.json).
- [20 real OCR cancellation trials](ocr-cancel-paired.json).

**All 61 paired metric comparisons stay below +20%.** [Machine-readable paired comparison](paired-comparison.json). First-word median is 675.22 → 625.93 ms (−7.3%); cancellation is 18.60 → 14.95 ms for PDF/PDF and 30.76 → 31.35 ms for PDF/EPUB. Maximum cancellation in these paired trials is 141.61 ms in the old binary and 33.28 ms in the current binary; request/model scheduling has substantial variance. Releasing a worker does not promise an immediate return of framework RSS to idle. Same-session comparisons do not reproduce a new-code regression for this corpus/Mac; they do not establish arbitrary-workload performance or OCR accuracy.

The paired idle PDF session overlapped a CI-artifact download/extraction during late trials; raw observations are retained. No local application build or UI test ran during those trials. No performance conclusion uses the CI runner as an interchangeable control Mac.

## Reproduce

```sh
swift build -c release
python3 scripts/benchmark-v06.py .build/release/ExtendedResearch --pdf-binary .build/release/ColorResearch --output /private/tmp/v1-extended.json
python3 scripts/benchmark-v04.py .build/release/EPUBResearch --output /private/tmp/v1-epub.json
python3 scripts/benchmark-v05.py .build/release/KnowledgeResearch --output /private/tmp/v1-knowledge.json
python3 scripts/benchmark-v03.py .build/release/ColorResearch --output /private/tmp/v1-companion.json
swift scripts/benchmark-launch.swift /path/to/Release/AdaptiveReader.app . SOURCE_SHA /private/tmp/v1-launch.json
python3 scripts/compare-v06-control.py /path/to/frozen/ColorResearch .build/release/ColorResearch --baseline-source BASELINE_SHA --all-controls --output /private/tmp/v1-pdf-paired.json
python3 scripts/compare-v06-control.py /path/to/frozen/ColorResearch .build/release/ColorResearch --baseline-source BASELINE_SHA --all-controls --companion --output /private/tmp/v1-companion-paired.json
python3 scripts/compare-reader-workload.py /path/to/frozen/EPUBResearch .build/release/EPUBResearch --baseline-source BASELINE_SHA --current-source SOURCE_SHA --scenario epub-speech --output /private/tmp/v1-speech-paired.json
python3 scripts/compare-reader-workload.py /path/to/frozen/ExtendedResearch .build/release/ExtendedResearch --baseline-source BASELINE_SHA --current-source SOURCE_SHA --scenario split-cancel --output /private/tmp/v1-ocr-paired.json
```

Use new output paths to retain evidence; never relabel a current binary as an old source. Run on a quiet fixed Mac with no concurrent builds/UI automation. The original checksums/source fingerprints, raw five-run rows and all threshold crossings remain in this directory. `scripts/summarize-v1-performance.py` reproduces the comparison files from these retained inputs. Actual long-session hosted CI evidence and installed-package references are recorded separately in [v1.0 acceptance](../../docs/v1.0.md). Exact macOS 15.0 runtime, fresh system accessibility review and downloaded Gatekeeper/old-binary upgrade remain open stable gates.
