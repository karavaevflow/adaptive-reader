# v0.3 integration performance

Control: MacBookAir10,1, Apple M1, 8 GiB, macOS 15.8.2, Xcode 26.3, 1440 x 900 pt / 2880 x 1800 px, 60 Hz. Release, five independent processes per fixture/policy/workload. Warm filesystem caches. No concurrent builds/UI tests during measurements.

The paced research response is explicitly synthetic: it exercises background indexing, retrieval, chunk accumulation and cancellation while PDFKit scrolls. It does not measure a real model, network latency, inference memory or answer quality.

| PDF | Policy | Workload | Open ms | Peak MiB | CPU display ms | Delivery ms | Index ms | Max cancel ms |
|---|---|---|---:|---:|---:|---:|---:|---:|
| large-text.pdf | original | idle | 49.09 | 51.8 | 1.68 | 16.67 | 0.00 | 0.00 |
| large-text.pdf | original | index/fixture | 47.77 | 123.0 | 1.67 | 16.67 | 704.49 | 5.46 |
| large-text.pdf | selected | idle | 66.42 | 92.8 | 2.12 | 16.67 | 0.00 | 0.00 |
| large-text.pdf | selected | index/fixture | 65.89 | 152.7 | 1.86 | 16.67 | 667.40 | 5.41 |
| scan.pdf | original | idle | 30.14 | 74.4 | 0.51 | 16.66 | 0.00 | 0.00 |
| scan.pdf | original | index/fixture | 29.06 | 76.2 | 0.50 | 16.67 | 0.00 | 0.01 |
| scan.pdf | selected | idle | 50.01 | 125.5 | 0.51 | 16.66 | 0.00 | 0.00 |
| scan.pdf | selected | index/fixture | 49.82 | 125.7 | 0.52 | 16.67 | 0.00 | 0.01 |
| text.pdf | original | idle | 36.84 | 48.0 | 0.51 | 16.67 | 0.00 | 0.00 |
| text.pdf | original | index/fixture | 34.52 | 48.8 | 0.49 | 16.67 | 3.15 | 5.23 |
| text.pdf | selected | idle | 55.65 | 95.3 | 0.52 | 16.67 | 0.00 | 0.00 |
| text.pdf | selected | index/fixture | 54.15 | 95.9 | 0.55 | 16.67 | 2.90 | 5.79 |

## Interpretation

All same-scenario idle controls stay within the project's 20% investigation threshold relative to frozen v0.2. During overlap, the 600-page index holds 7,200 passages and completes in roughly 0.7 seconds. Extra memory is the separate worker-confined PDFDocument plus bounded evidence; its peak is reported rather than compared with idle as if it were the same workload. CPU display timings are not GPU/compositor frame times.

All 30 active-workload runs finished their task. Text documents received at least 21 paced chunks before cancellation; maximum observed cancellation completion was 5.79 ms. Scans returned an explicit no-text/OCR state without starting a response. HTTP cancellation is additionally covered by URLProtocol-backed core tests that observe stopLoading.

Reproduce with `swift build -c release --product ColorResearch`, then `python3 scripts/benchmark-v03.py .build/release/ColorResearch --output /private/tmp/v03-overlap.json`. Do not run other builds or UI tests concurrently. The protocol adds a paced test provider only inside the research executable; it is not part of the normal application.
