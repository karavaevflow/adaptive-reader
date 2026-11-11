# v0.1 PDF performance

Control: MacBookAir10,1, Apple M1, 8 GiB, macOS 15.8.2, Xcode 26.3, 1440×900 pt / 2880×1800 px, 60 Hz. Release builds. Five independent processes per scenario, warm filesystem caches. The 600-page fixed text fixture is in `../Large`; original corpus and Phase 0 data remain unchanged.

`scroll.json` contains 100 observations: nine fixed PDFs plus the large fixture, two policies, five runs. `paired.json` contains 60 interleaved Foundation/current observations for the opening-time investigation. `large-search.json` contains ten observations with asynchronous search and scrolling. All per-step CPU durations and main-runloop delivery intervals are retained.

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

| PDF | Policy | Foundation open ms | Current open ms | Difference | Memory difference |
|---|---|---:|---:|---:|---:|
| dark.pdf | original | 32.20 | 31.57 | -2.0% | +0.4% |
| dark.pdf | selected | 50.05 | 55.70 | +11.3% | +0.5% |
| nasa-apollo-earth.pdf | original | 37.88 | 34.80 | -8.2% | -0.6% |
| nasa-apollo-earth.pdf | selected | 69.55 | 68.01 | -2.2% | -0.2% |
| text.pdf | original | 38.07 | 39.54 | +3.9% | +0.3% |
| text.pdf | selected | 59.60 | 56.20 | -5.7% | +0.2% |

The paired open differences span −8.2% to +11.3%; peak RSS differs by at most +0.5%. The initial opening-time exceedance did not reproduce under interleaving. Sub-millisecond CPU-display changes in the sequential comparison are sensitive to scheduling; paired medians differ by −3.3% to +5.4% with stable median 16.67 ms main-runloop delivery. This supports timing variability as the explanation, rather than claiming an absolute performance guarantee. Production rendering and cache limits are unchanged. The added first-page text probe remains bounded; whole-book text availability and SHA computation run outside the main actor.

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
