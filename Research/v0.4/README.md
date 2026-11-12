# v0.4 Release measurements

Application/core source: `0c5d73c1376b46928a78f6d8a27a35adc1a41a2c`. Five independent processes for each EPUB workload and five per PDF/policy control; warm filesystem caches. Control: MacBookAir10,1, Apple M1, 8 GiB, macOS 15.8.2, Xcode 26.3, 1440 × 900 pt / 2880 × 1800 px, 60 Hz. No concurrent builds or UI tests during measurements.

## EPUB and real native speech

The production ReaderCore `SpeechPlayer` uses AVFoundation and an installed macOS voice, with volume zero. This is real on-device speech progress, not a paced fixture or model response. The 1,800-paragraph chapter, bilingual text, illustration and footnotes are project-authored deterministic fixtures. Source checksums and source-file fingerprints are in `performance.json`.

| Workload | First layout ms | Reflow ms | Locator ms | First word ms | Input round trip ms | Run-loop p95 ms | Client peak MiB | Client + new WebKit sampled MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Idle | 287.24 | 28.20 | 5.37 | — | 6.67 | 21.35 | 71.39 | 198.78 |
| Native speech | 282.50 | 25.18 | 12.15 | 550.34 | 5.84 | 17.49 | 96.19 | 227.31 |

Medians of five runs. Each spoken run receives native word callbacks; all ten runs have zero word callbacks in the 300 ms after stop. The separate `speech-controls.json` probe starts speech, immediately pauses/resumes during voice preparation, receives real progress, then stops without late callbacks.

**Measurement scope:** an unshown 800 × 700 pt native WebKit window forces actual DOM layout. First-layout time includes reading/parsing the source and loading the long chapter after AppKit initialization. Reflow/locator timings include WebKit IPC and layout completion, with a 5 ms polling interval. These are not onscreen first-photon, compositor/GPU frame times or full-application launch measurements. Real app visibility and interactions are covered by the UI tests and screenshots. Run-loop intervals target 60 Hz while the page scrolls during speech; they are responsiveness proxies.

Client peak is process `ru_maxrss`. The additional WebKit metric samples client RSS plus newly appearing `com.apple.WebKit` processes every ~20 ms on the quiet control Mac. PID observations are retained. It is an operational estimate, not an OS ownership/coalition accounting guarantee. Shared system speech services and WindowServer are excluded. Idle versus speech is additional workload, not the same-scenario release-regression comparison.

## PDF controls against v0.3

| PDF | Policy | Open ms | Peak MiB | Median CPU draw ms | Open Δ | Peak Δ |
|---|---|---:|---:|---:|---:|---:|
| large-text.pdf | original | 48.69 | 51.1 | 1.878 | +2.5% | -3.1% |
| large-text.pdf | selected | 67.22 | 91.1 | 2.120 | +3.2% | -1.7% |
| text.pdf | original | 37.24 | 46.0 | 0.469 | +5.5% | -3.9% |
| text.pdf | selected | 57.78 | 93.5 | 0.515 | -2.2% | -1.6% |
| scan.pdf | original | 31.80 | 75.7 | 0.439 | +11.5% | -1.2% |
| scan.pdf | selected | 53.16 | 124.4 | 0.459 | +4.0% | -1.0% |

No PDF open-time or peak-memory median exceeds the 20% investigation threshold against the frozen v0.3 idle controls. CPU drawing in two sub-millisecond/low-millisecond scenarios exceeded the historical relative threshold, so both were investigated rather than dismissed.

## CPU timing investigation

The exact historical v0.3 measurement source `0e5511e` was archived into a separate temporary directory and rebuilt with the same current Xcode toolchain. Five old/new processes were interleaved for each flagged scenario on the current Mac; fixture bytes and command protocol are identical. `paired-pdf-controls.json` retains all 20 observations.

| Scenario | Rebuilt v0.3 CPU ms | v0.4 CPU ms | Difference |
|---|---:|---:|---:|
| text.pdf / original | 0.519 | 0.493 | -5.1% |
| large-text.pdf / selected | 2.082 | 2.090 | +0.4% |

The increase is also present in the unchanged rebuilt old version. The paired comparison does not reproduce a v0.4 code regression; historical environment/timing drift is the supported explanation. Median delivery remains approximately 16.67 ms. CPU draw timings are not GPU/compositor timings. Original evidence from earlier releases is unchanged.

## Reproduction

```sh
swift build -c release --product EPUBResearch
swift build -c release --product ColorResearch
python3 scripts/benchmark-v04.py .build/release/EPUBResearch --pdf-binary .build/release/ColorResearch --output /private/tmp/v04-performance.json
.build/release/EPUBResearch Research/Fixtures/EPUB/reflow.epub --speech --probe-controls
```

Do not run builds, UI tests or other intensive work concurrently. Record `control-mac.json`, the source revision and fixture hashes. Re-run the same protocol and investigate future median time/peak-memory growth above 20% before release.

## Acceptance provenance

`acceptance.json` identifies the exact application source, passed full CI run and verified universal archive checksum. `ci-ui-summary.json` is exported from that run: 26 passed, five opt-in tests skipped, zero failures. The 69 v0.4 Study/editor/interaction PNGs in `docs/v0.4/` are exported from the same passed result bundle; two earlier EPUB foundation references are retained separately.
