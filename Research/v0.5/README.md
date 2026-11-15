# v0.5 Release measurements

Application/core source: `2a244f4e55f38b2d1bfa786d9006d2c556e3f423`. Five independent Release processes on MacBookAir10,1 / Apple M1 / 8 GiB, macOS 15.8.3, Xcode 26.3, 1440 × 900 pt / 2880 × 1800 pixels, 60 Hz. The original v0.4 control used macOS 15.8.2 on the same Mac/display; that OS difference is explicit. No local builds or UI automation ran during the primary measurements.

## Fixed knowledge workload

Twenty managed books (ten copies of each authored PDF/EPUB fixture), 1,000 saved cards, 1,000 board nodes and 1,997 edges. The EPUB contains 1,800 paragraphs. Each process creates a fresh isolated library, preserving the same input bytes/content and scenario while generating fresh local UUIDs. Fixture revisions and source-file fingerprints are retained in `performance.json`. No speech player, model provider or network request is used.

| Scenario | Median of five runs |
|---|---:|
| First search, fresh derived caches/vectors | 7990.71 ms |
| Repeat search with derived caches/vectors | 381.08 ms |
| Open/decode the saved board and memory records | 29.92 ms |
| Canvas projection/culling, median of 120 pan/zoom/drag frames | 0.640 ms |
| Canvas projection/culling, p95 of 120 frames | 0.700 ms |
| Atomic node-position save, 1.8 MB snapshot | 66.16 ms |
| Cooperative search cancellation | 31.77 ms |
| Peak client process RSS | 73.89 MiB |

All five runs reported actual installed local semantic-model availability, successful cancellation, nonempty results and no source errors. JSON round-trip equality is checked by the harness. At most 42 card views are candidates in the measured moving viewport, rather than all 1,000.

**Scope:** the harness uses the actual ReaderCore search, LibraryStore persistence and the same KnowledgeCanvasLayout called by SwiftUI. Timings cover shared CPU/data work. The first-search figure includes extraction/index creation and installed-model/vector preparation, not a cold OS or full-application launch. Node saves run off the UI actor after drag completion. Projection timing is not GPU/compositor presentation latency or a claim of a measured on-screen frame rate. Client RSS excludes the full reader shell, WebKit/WindowServer and shared OS services.

The supplemental `native-readiness.json` records five real on-screen Canvas openings and five accessible moves on an isolated signed Release QA copy at earlier source `45bb773`, using one PDF/two cards/one edge. Its medians are 842 ms and 807 ms **including CUA/IPC/accessibility observation overhead**. It is supporting UI evidence, not the primary fixed-library baseline or a GPU measurement. Quote/note creation, a named relationship, source return and focus restoration were visibly checked; the QA app was quit. No sound was enabled.

## Inherited PDF controls

Five processes per PDF/policy, using the unchanged ColorResearch scroll protocol. v0.4 raw evidence remains unmodified.

| PDF | Policy | Open ms | Client peak MiB | CPU draw ms | Open Δ | Peak Δ | CPU Δ |
|---|---|---:|---:|---:|---:|---:|---:|
| large-text.pdf | original | 48.98 | 52.11 | 1.919 | +0.6% | +2.0% | +2.2% |
| large-text.pdf | selected | 67.76 | 91.62 | 2.081 | +0.8% | +0.6% | -1.8% |
| text.pdf | original | 38.06 | 46.81 | 0.521 | +2.2% | +1.7% | +11.1% |
| text.pdf | selected | 56.59 | 93.97 | 0.471 | -2.1% | +0.5% | -8.4% |
| scan.pdf | original | 28.33 | 74.95 | 0.401 | -10.9% | -0.9% | -8.5% |
| scan.pdf | selected | 54.21 | 124.61 | 0.394 | +2.0% | +0.2% | -14.3% |

No inherited median open time, CPU draw time, delivery interval proxy or peak memory increased beyond the project's 20% investigation threshold. Median delivery intervals stay approximately 16.67 ms. These controls use CPU drawing/timer delivery, not GPU frames. The minor OS update prevents treating small differences as pure code effects; no threshold crossing was found. The earlier `performance-source45.json` pilot/baseline is retained separately and is not substituted for final-source data.

## Reproduction

```sh
swift build -c release --product KnowledgeResearch
swift build -c release --product ColorResearch
python3 scripts/benchmark-v05.py .build/release/KnowledgeResearch --pdf-binary .build/release/ColorResearch --output /private/tmp/v05-performance.json
```

Use a quiet control Mac, the same corpus and five independent processes; do not run builds/UI tests concurrently. Record control-mac.json, source revision, source fingerprints, fixture checksums and the exact scope. This becomes the v0.5 baseline for future same-scenario regression comparisons. No real-model response, cloud latency or semantic-answer quality is claimed.

## Acceptance provenance

`acceptance.json` pins the application source, fully passed CI and archive checksum. The tested commit `8447ef6` only adds a modal-readiness wait to application source `2a244f4`; source/package/project diffs are empty. `ci-knowledge-summary.json` and `ci-regression-summary.json` are exported from the passed run: 3 + 26 UI tests passed, five opt-in tests skipped, no failures. All 46 v0.5 reference PNGs come from that same passed result bundle.
