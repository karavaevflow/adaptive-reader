# v0.3 integration performance

Control: MacBookAir10,1, Apple M1, 8 GiB, macOS 15.8.2, Xcode 26.3, 1440 x 900 pt / 2880 x 1800 px, 60 Hz. Release builds, warm filesystem caches, five independent processes per fixture/policy/workload. No concurrent builds or UI tests during measurements.

The paced research response is synthetic. This exercises indexing, retrieval, chunk accumulation and cancellation while PDFKit scrolls; it does not measure actual model inference, network latency, model memory or answer quality.

| PDF | Policy | Workload | Open ms | Peak MiB | CPU display ms | Delivery ms | Index ms | Max cancel ms |
|---|---|---|---:|---:|---:|---:|---:|---:|
| large-text.pdf | original | idle | 47.52 | 52.7 | 1.67 | 16.67 | 0.00 | 0.00 |
| large-text.pdf | original | index/fixture | 45.75 | 130.0 | 1.55 | 16.67 | 679.26 | 5.95 |
| large-text.pdf | selected | idle | 65.17 | 92.7 | 1.54 | 16.67 | 0.00 | 0.00 |
| large-text.pdf | selected | index/fixture | 66.22 | 153.6 | 1.61 | 16.67 | 680.04 | 5.95 |
| scan.pdf | original | idle | 28.53 | 76.6 | 0.42 | 16.67 | 0.00 | 0.00 |
| scan.pdf | original | index/fixture | 29.00 | 76.6 | 0.50 | 16.67 | 0.00 | 0.01 |
| scan.pdf | selected | idle | 51.10 | 125.7 | 0.49 | 16.67 | 0.00 | 0.00 |
| scan.pdf | selected | index/fixture | 52.05 | 125.6 | 0.44 | 16.67 | 0.00 | 0.01 |
| text.pdf | original | idle | 35.30 | 47.9 | 0.21 | 16.67 | 0.00 | 0.00 |
| text.pdf | original | index/fixture | 38.70 | 48.9 | 0.33 | 16.67 | 3.14 | 6.34 |
| text.pdf | selected | idle | 59.09 | 95.1 | 0.52 | 16.67 | 0.00 | 0.00 |
| text.pdf | selected | index/fixture | 58.17 | 95.7 | 0.52 | 16.67 | 3.19 | 6.36 |

## Interpretation

All 30 active-workload tasks finished. Text fixtures received at least 25 chunks before cancellation; maximum observed cancellation completion was 6.36 ms. The 600-page index contains 7,200 passages; median build time across both policies was 679.40 ms. Scans reported no accessible text without starting a response.

Idle controls are compared with the same frozen v0.2 scenarios. Index/response peak memory includes a second worker-confined PDFDocument and evidence, so its increase over idle is additional workload, not the same-scenario regression metric. CPU display timings are not GPU/compositor frame time.

20% investigation triggers in idle comparisons: none.

The measurements use the Release research build from application/core source 0e5511e. Subsequent changes harden authorization and protected-source errors and correct citation horizontal coordinates/cache invalidation. They do not change the measured scrolling or paced-response protocol. The final application source and checks are recorded in docs/v0.3.md.

Reproduce: `swift build -c release --product ColorResearch`, then `python3 scripts/benchmark-v03.py .build/release/ColorResearch --output /private/tmp/v03-overlap.json`. Do not run other builds or UI tests concurrently. Keep earlier release evidence unchanged.
