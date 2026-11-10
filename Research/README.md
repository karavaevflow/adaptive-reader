# Color Engine decision — Phase 0

The production Reader keeps PDFKit as the authority for document geometry, text, search, selection, links and navigation. `AdaptivePDFPage.draw` replaces drawing only on eligible pages. EPUB will supply its own renderer through the same ReaderEngine contract. AI never receives direct access to PDFView.

## Corpus and rights

Nine fixed PDFs are committed in Fixtures, with SHA-256 values in checksums.json. Seven generated documents cover text, columns/table, colored vectors, photo/caption, scan, originally dark pages and a password-protected document. `ColorResearch` contains the generator. Generated fixtures are MIT licensed. The password `phase0` belongs only to our own test fixture.

Two real publications broaden the corpus:

- [USGS Earth as Home](https://www.usgs.gov/media/files/earth-home), explicitly marked Public Domain by USGS. Source: https://d9-wret.s3.us-west-2.amazonaws.com/assets/palladium/production/s3fs-public/atoms/files/earth_as_home.pdf
- [NASA Apollo 17 View of Earth](https://www.nasa.gov/stem-content/apollo-17-view-of-earth/), credited to NASA. Source: https://www.nasa.gov/wp-content/uploads/2009/07/58159main_Apollo.17.View_.of_.Earth_.pdf . Used for technical comparison under [NASA media guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/). NASA imagery and identifiers are excluded from the project's MIT license. No endorsement is implied.

The generated photo/caption fixture embeds the NASA lithograph for the same study. Preserve NASA attribution when reusing it. Repository MIT licensing applies to code and our original fixture content.

## Three compared paths

1. Original, using the same CGPDFPage used by PDFKit. The running Original view uses native PDFKit drawing.
2. Whole-page Core Image CIColorInvert. It changes photographs and colored charts unacceptably and is retained only in the research executable.
3. Selective Core Image CIColorCube: replace achromatic white/black components, retaining the chromatic residual. This avoids white antialiasing fringes around colored glyphs. Saturated RGB vector bars remain within 1/255 of their source values in the pixel test.

Selected eligibility is intentionally conservative: unrotated crop box starting at zero, size at most 2000 pt, fonts present, no image/form XObjects, no annotation appearances, only ordinary link annotations, and light corners. Otherwise the page uses Original. Dark, scanned, photo, form-backed and protected-fixture pages fall back. The UI explains fallback while retaining the requested palette for eligible pages elsewhere in the book. Original is always available in the same menu.

This is selective raster color adaptation, not a PDF content-stream rewrite. Mixed pastel colors can change; only saturated primaries are invariant. White corners cannot prove that every region is light. The reader can select Original for unexpected content. Eligible pages rasterize at 2 px/pt; high zoom retains selection/geometry but can soften text. The cache is bounded to 8 images / 64 MiB. Native Original remains vector-sharp. Future higher-resolution cache keys can be added without changing ReaderEngine or SourceAnchor.

## Measurement method

Release Swift 6.2 / Xcode 26.3, macOS 15.8.2, MacBookAir10,1 Apple M1, 8 GiB, 1440×900 pt / 2880×1800 px, 60 Hz. Control descriptor is Results/control-mac.json. Each fixture/mode runs in five independent worker processes. First and second raw render are measured separately at 2 px/pt. Peak resident memory is process ru_maxrss, including frameworks and GPU-related allocations visible to that process. Classification is performed before the raw-render stopwatch; full PDFView opening is measured separately by the scroll harness. Filesystem caches are not purged. These are cold processes, not cold disks.

Results/measurements.json contains all 135 samples. Images named original, invert and selected use identical page/crop/scale. Fallback selected images have identical raw pixel hashes to Original. Protected measurement explicitly unlocks our fixture; the app rejects locked imports with an actionable error.

| PDF | Original first/repeat ms | Invert first/repeat ms | Selected first/repeat ms | Selected peak MiB | Policy |
|---|---:|---:|---:|---:|---|
| chart.pdf | 1.46 / 1.21 | 14.15 / 7.63 | 17.03 / 8.78 | 62.5 | available |
| columns-table.pdf | 2.21 / 1.72 | 16.32 / 8.26 | 17.40 / 8.97 | 63.4 | available |
| dark.pdf | 1.68 / 1.30 | 14.88 / 7.88 | 1.79 / 1.38 | 20.6 | darkBackground |
| nasa-apollo-earth.pdf | 16.21 / 10.49 | 29.75 / 16.22 | 17.04 / 10.62 | 26.6 | complexGraphics |
| photo-caption.pdf | 19.01 / 1.33 | 31.78 / 9.80 | 19.50 / 1.41 | 25.9 | complexGraphics |
| protected.pdf | 3.77 / 1.28 | 17.19 / 8.05 | 3.40 / 1.30 | 20.7 | complexGraphics |
| scan.pdf | 5.70 / 1.63 | 18.75 / 8.35 | 5.49 / 1.44 | 27.6 | complexGraphics |
| text.pdf | 1.62 / 1.32 | 15.85 / 8.35 | 16.26 / 8.77 | 62.7 | available |
| usgs-earth-as-home.pdf | 400.00 / 12.45 | 412.72 / 18.14 | 396.58 / 12.29 | 137.9 | complexGraphics |

## Functional checks and reproduction

The core contract test exercises typed navigation, exact anchor equality across palette changes, retained PDFKit search and link annotations, save/recreate/reopen within 2 pt, palette undo and unchanged source bytes. Separate tests cover scanned text capabilities, locked import, invalid positions, changed and missing assets, PDF/EPUB serialization and source-version errors. The UI integration test checks page, zoom, palette, inspector and window restoration across normal Quit.

```sh
swift build -c release --product ColorResearch
.build/release/ColorResearch Research
python3 scripts/benchmark-scroll.py .build/release/ColorResearch
swift scripts/control-mac.swift
```

The scroll runner opens an actual 800×650 pt PDFView window and traverses all pages in 120 requested 60 Hz steps, five independent processes per PDF and policy. Results/scroll.json retains every CPU display duration and actual main-runloop interval, open latency and peak RSS. CPU frame duration includes clip movement and displayIfNeeded; it is not a GPU/compositor frame-time claim. Timer intervals expose delayed main-thread delivery. Compare the same metric on the same control Mac; do not compare a CI VM against this baseline.

A median time or peak-memory increase above 20% on the fixed corpus triggers regression investigation before release. Original fallback costs remain visible in the same results. The research harness is separate from application behavior; global inversion never ships in the app.
