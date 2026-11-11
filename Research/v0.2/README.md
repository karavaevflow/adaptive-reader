# v0.2 performance acceptance

Control: MacBookAir10,1, Apple M1, 8 GiB, macOS 15.8.2, Xcode 26.3, 1440 × 900 pt / 2880 × 1800 px, 60 Hz. Release builds; fixed corpus and warm filesystem caches. Five independent processes per PDF/policy. v0.1 and Phase 0 evidence remains unchanged.

| PDF | Policy | Open ms | Peak MiB | CPU display ms | Delivery ms | Open vs v0.1 | Memory vs v0.1 |
|---|---|---:|---:|---:|---:|---:|---:|
| chart.pdf | original | 33.36 | 47.3 | 0.47 | 16.67 | -8.8% | +0.8% |
| chart.pdf | selected | 54.98 | 95.2 | 0.53 | 16.67 | -0.3% | +0.4% |
| columns-table.pdf | original | 36.09 | 48.3 | 0.48 | 16.67 | +1.7% | +0.2% |
| columns-table.pdf | selected | 53.97 | 96.2 | 0.47 | 16.67 | +6.5% | +0.5% |
| dark.pdf | original | 32.67 | 47.4 | 0.51 | 16.67 | +5.7% | +1.0% |
| dark.pdf | selected | 49.44 | 95.5 | 0.55 | 16.67 | -0.2% | +0.3% |
| large-text.pdf | original | 49.30 | 54.1 | 1.93 | 16.67 | +2.5% | +4.9% |
| large-text.pdf | selected | 68.93 | 92.8 | 2.10 | 16.67 | +4.6% | +0.5% |
| nasa-apollo-earth.pdf | original | 36.36 | 60.8 | 0.44 | 16.66 | +1.7% | +1.0% |
| nasa-apollo-earth.pdf | selected | 68.40 | 107.3 | 0.47 | 16.67 | +3.9% | +0.2% |
| photo-caption.pdf | original | 30.55 | 84.5 | 0.49 | 16.67 | -2.7% | +0.4% |
| photo-caption.pdf | selected | 68.70 | 135.3 | 0.52 | 16.67 | -0.2% | +1.4% |
| protected.pdf | original | 35.97 | 48.5 | 0.55 | 16.67 | +2.7% | +2.0% |
| protected.pdf | selected | 56.03 | 95.5 | 0.55 | 16.67 | +4.6% | +0.6% |
| scan.pdf | original | 29.53 | 76.4 | 0.47 | 16.67 | -1.5% | +1.0% |
| scan.pdf | selected | 51.16 | 125.8 | 0.52 | 16.67 | +2.9% | +0.6% |
| text.pdf | original | 34.94 | 48.0 | 0.49 | 16.67 | -0.2% | +1.7% |
| text.pdf | selected | 55.38 | 95.2 | 0.56 | 16.67 | +5.4% | +0.7% |
| usgs-earth-as-home.pdf | original | 45.46 | 561.6 | 0.22 | 16.67 | +5.7% | -4.5% |
| usgs-earth-as-home.pdf | selected | 454.22 | 156.6 | 0.58 | 16.66 | +3.0% | +0.3% |

## CPU investigation

Five scenarios exceeded +20% median CPU display time against the sequential v0.1 baseline. `paired.json` alternates five archived v0.1/current processes for each case. The archived CLI is the accepted v0.1 performance build from `c3a20ec`; later v0.1 changes cover search retention, linked-file operations and visible-page choice, without changing this no-search initial-palette scroll protocol.

| PDF | Policy | v0.1 CPU ms | v0.2 CPU ms | Difference | Open difference | Memory difference |
|---|---|---:|---:|---:|---:|---:|
| dark.pdf | selected | 0.518 | 0.515 | -0.6% | +1.9% | +0.0% |
| nasa-apollo-earth.pdf | original | 0.449 | 0.423 | -6.0% | +1.0% | +0.2% |
| nasa-apollo-earth.pdf | selected | 0.477 | 0.461 | -3.4% | +5.3% | -0.6% |
| scan.pdf | selected | 0.475 | 0.511 | +7.5% | -5.2% | +0.0% |
| usgs-earth-as-home.pdf | original | 0.218 | 0.209 | -4.1% | -0.6% | +1.7% |

Interleaved CPU differences span −6.0% to +7.5%, with no persistent >20% regression in the investigated cases. This supports timing/cache variation as the reason for the initial tiny absolute differences. The new native overlay and event routing remain enabled in every current run. Delivery medians remain approximately 16.67 ms at 60 Hz. CPU display duration includes clip movement and `displayIfNeeded`; it does not measure GPU/compositor frame time.

## Full application UI protocol

Five independent Release processes (`ui.json`) give a 5,441.80 ms launch-to-AX-ready median and 1,650.05 ms panel interaction median, +4.5% and +0.4% relative to v0.1. Five 600-page copy imports (`large-ui.json`) give 6,163.12 ms from Open click to captured window, +5.3%. These include XCTest activation, accessibility and screenshot overhead; they are not engine render timings.

## Reproduction

```sh
swift build -c release --product ColorResearch
python3 scripts/benchmark-scroll.py .build/release/ColorResearch --output /private/tmp/v02-scroll.json --include-large
# Run the common Xcode Release test scheme with FOUNDATION_BENCHMARK to capture
# the five launch/panel and large-import observations.
sh scripts/benchmark-v02-soak.sh /private/tmp/v02-soak.xcresult
```

For paired investigation, alternate the archived v0.1 and current `ColorResearch scroll PDF policy` executables for five runs of each PDF/policy in the table. Do not run other builds or UI benchmarks concurrently. Original fixture checksums and earlier release data are unchanged.

## Real 25-minute Release session

`soak.json` retains 51 samples at approximately 30-second intervals from the real Mini Reader/auto-scroll session on the 600-page fixture, Original palette, 32 pt/s, explicit floating window. The timer reached 1,500 seconds and stopped automatic scrolling and the activity driver. The native test passed in 1,549.97 seconds including launch, file selection, capture, viewport return and book closure. Result: `/private/tmp/adaptive-v02-soak3.xcresult`.

After the first five minutes, sampled RSS ranged from 80.7 to 121.3 MiB; completion RSS was 83.8 MiB. Process peak RSS was 342.8 MiB including startup and native automation caches. Cumulative CPU growth during the sampled session corresponds to 27.55% of one CPU core. This is one real long run, not five repeated sessions and not an energy measurement.

`soak-after-close.json` confirms documentOpen=false, miniOpen=false, autoScrolling=false, driverActive=false and timerStatus=completed after closure. Its RSS is 275.3 MiB after capture/viewport transfer; process RSS includes retained framework caches, so the activity assertions do not claim all cached memory is released immediately. Native main-window closure is independently covered by the regular lifecycle test.

The soak and full local Release suite use application/test source `11998b3`. The later `5e62476` change adds Enter execution for a filtered palette and extends its keyboard test; the activity driver, engine and persistence implementation are identical. Full CI on `5e62476` passed. Interrupted earlier harness attempts are excluded from accepted measurements.
