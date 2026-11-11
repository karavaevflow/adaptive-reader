# v0.1 PDF performance

Control: MacBookAir10,1, Apple M1, 8 GiB, macOS 15.8.2, Xcode 26.3, 1440×900 pt / 2880×1800 px, 60 Hz. Release builds. Five independent processes per scenario, warm filesystem caches. The 600-page fixed text fixture is in `../Large`; original corpus and Phase 0 data remain unchanged.

`scroll.json` contains 100 observations: nine fixed PDFs plus the large fixture, two policies, five runs. `paired.json` contains 140 interleaved Foundation/current observations for opening-time and CPU-display investigations. `large-search.json` contains ten observations with asynchronous search and scrolling. All per-step CPU durations and main-runloop delivery intervals are retained.

## Fixed corpus and large document

| PDF | Policy | Open ms | Peak MiB | Median CPU display ms | Median delivery ms | Open change vs Phase 0 | Memory change |
|---|---|---:|---:|---:|---:|---:|---:|
| chart.pdf | original | 36.60 | 46.9 | 0.70 | 16.67 | +8.9% | +1.2% |
| chart.pdf | selected | 55.14 | 94.8 | 0.74 | 16.67 | +9.4% | +0.5% |
| columns-table.pdf | original | 35.47 | 48.3 | 0.59 | 16.67 | +15.4% | +1.9% |
| columns-table.pdf | selected | 50.70 | 95.7 | 0.59 | 16.67 | +0.2% | +0.3% |
| dark.pdf | original | 30.92 | 46.9 | 0.46 | 16.67 | +21.2% | +1.5% |
| dark.pdf | selected | 49.54 | 95.2 | 0.41 | 16.67 | +20.5% | +0.6% |
| large-text.pdf | original | 48.08 | 51.6 | 1.80 | 16.67 | new scenario | new scenario |
| large-text.pdf | selected | 65.88 | 92.3 | 2.23 | 16.67 | new scenario | new scenario |
| nasa-apollo-earth.pdf | original | 35.76 | 60.2 | 0.30 | 16.67 | +21.8% | +0.6% |
| nasa-apollo-earth.pdf | selected | 65.80 | 107.0 | 0.38 | 16.67 | +12.0% | +0.4% |
| photo-caption.pdf | original | 31.39 | 84.2 | 0.56 | 16.67 | +1.5% | +1.0% |
| photo-caption.pdf | selected | 68.83 | 133.5 | 0.67 | 16.67 | +1.4% | +0.2% |
| protected.pdf | original | 35.03 | 47.6 | 0.53 | 16.67 | +4.6% | -1.1% |
| protected.pdf | selected | 53.57 | 95.0 | 0.58 | 16.67 | +3.7% | +0.1% |
| scan.pdf | original | 29.97 | 75.6 | 0.42 | 16.66 | -0.4% | -0.2% |
| scan.pdf | selected | 49.72 | 125.0 | 0.37 | 16.67 | -3.3% | +0.0% |
| text.pdf | original | 35.00 | 47.2 | 0.53 | 16.67 | +9.5% | -0.5% |
| text.pdf | selected | 52.57 | 94.6 | 0.58 | 16.67 | +0.0% | +0.0% |
| usgs-earth-as-home.pdf | original | 43.01 | 588.3 | 0.14 | 16.67 | +16.6% | +13.5% |
| usgs-earth-as-home.pdf | selected | 440.79 | 156.2 | 0.58 | 16.67 | -5.5% | +1.7% |

## Investigation of the 20% threshold

The initial sequential comparison with the frozen Phase 0 baseline exceeded +20% open latency for dark Original/selected and NASA Original. We repeated those cases and the text control with alternating Foundation/current processes on the same Mac. This distinguishes desktop/timing drift from a persistent implementation regression.

| PDF | Policy | Foundation open ms | Current open ms | Open difference | Memory difference | CPU display difference |
|---|---|---:|---:|---:|---:|---:|
| chart.pdf | original | 32.77 | 35.19 | +7.4% | +0.6% | +2.2% |
| chart.pdf | selected | 51.15 | 53.59 | +4.8% | +0.4% | -1.3% |
| columns-table.pdf | original | 34.52 | 37.99 | +10.0% | +1.3% | -1.6% |
| columns-table.pdf | selected | 45.02 | 56.58 | +25.7% | -0.1% | +6.8% |
| dark.pdf | original | 32.20 | 31.57 | -2.0% | +0.4% | -3.3% |
| dark.pdf | selected | 50.05 | 55.70 | +11.3% | +0.5% | +3.2% |
| nasa-apollo-earth.pdf | original | 37.88 | 34.80 | -8.2% | -0.6% | +4.5% |
| nasa-apollo-earth.pdf | selected | 69.55 | 68.01 | -2.2% | -0.2% | -2.9% |
| photo-caption.pdf | original | 34.83 | 36.83 | +5.7% | +0.1% | +2.3% |
| photo-caption.pdf | selected | 72.05 | 74.19 | +3.0% | -0.7% | +0.4% |
| text.pdf | original | 38.07 | 39.54 | +3.9% | +0.3% | +5.2% |
| text.pdf | selected | 59.60 | 56.20 | -5.7% | +0.2% | +5.4% |
| usgs-earth-as-home.pdf | original | 31.76 | 42.12 | +32.6% | +0.0% | -2.5% |
| usgs-earth-as-home.pdf | selected | 441.42 | 450.66 | +2.1% | +2.1% | +2.2% |

Every scenario that exceeded the 20% opening/CPU-display threshold in the sequential baseline comparison was investigated with interleaved builds. The original opening-time cases span −8.2% to +11.3%; additional pairing found opening differences of +25.7% for selected columns/table and +32.6% for USGS Original. A separate five-run interleaved probe-isolation experiment quantifies the synchronous first-page text check; this diagnostic change does not ship in the app. Paired CPU-display medians span −3.3% to +6.8%. Main-runloop delivery remains approximately 16.67 ms. The initial CPU-display exceedances do not reproduce under interleaving. The two opening-time differences are retained as measured costs, with their isolation result below. This supports scheduling/desktop timing variability as the explanation, rather than an absolute performance guarantee. Production rendering and cache limits are unchanged. Whole-book text availability and SHA computation run outside the main actor.

## First-page text probe isolation

`probe-isolation.json` contains 20 further observations. Two otherwise identical research builds alternate with the first-page `.string` capability check enabled and disabled. Disabling it is a diagnostic experiment, not an application fallback.

| Scenario | With probe ms | Without probe ms | Absolute cost |
|---|---:|---:|---:|
| columns/table selected | 55.04 | 50.41 | 4.63 ms |
| USGS Original | 42.02 | 32.68 | 9.34 ms |

The probe explains a measurable opening increment; absolute costs are small while percentages against 30–50 ms baselines can exceed 20%. We accept this bounded first-page work for immediate text capabilities. Whole-book discovery and hashing are on workers. The >20% rule is an investigation trigger, not a blanket claim that every metric is unchanged. Core tests and the native large-document flow verify that search, physical scrolling, Focus and closure continue to function. The full Release UI/import protocol supplies the separate application-level evidence.

To reproduce the isolation, build `ColorResearch` from `0826496` in two temporary copies; in only the diagnostic copy replace `self.hasText = document.page(at: 0)?.string?.isEmpty == false` with `self.hasText = false`. Alternate `scroll` invocations for the two scenarios above, five runs each, without concurrent builds or UI tests. Keep the normal application source unchanged.

## Large PDF during search

| Policy | Open ms | Peak MiB | Median CPU display ms | Median delivery ms | Search results in each run |
|---|---:|---:|---:|---:|---|
| original | 47.36 | 68.3 | 1.89 | 16.67 | 1000, 1000, 1000, 1000, 1000 |
| selected | 67.82 | 94.7 | 2.22 | 16.67 | 1000, 1000, 1000, 1000, 1000 |

The 1,000-result cap bounds retained selections. Search can finish before scrolling ends; this measures overlap during a bounded query, not permanent indexing load. UI integration separately scrolls a 600-page document while results arrive, invokes Focus, and closes the book. CPU display duration includes clip movement and displayIfNeeded; it is **not GPU/compositor frame time**. Peak RSS includes PDFKit/framework caches. USGS has a much larger native image/cache footprint; compare against its PDFView baseline, not the separate raw-raster experiment.

## Reproduction

```sh
swift build -c release --product ColorResearch
python3 scripts/benchmark-scroll.py .build/release/ColorResearch --output Research/v0.1/scroll.json --include-large
python3 scripts/benchmark-v01.py /path/to/frozen-foundation/ColorResearch .build/release/ColorResearch
sh scripts/benchmark-v01-ui.sh /private/tmp/adaptive-v01-ui-measurement.xcresult
```

Use the archived Foundation CLI built from `d7c5952`; keep source fixtures and control display unchanged. UI import-to-capture measurements include automation overhead and are recorded separately. Palette reference images in `palettes` use production eligibility for Original, Paper, Dusk, Midnight and Forest. Photo pages fall back to unchanged Original.
