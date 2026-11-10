# PDFView baseline

Five independent Release processes per fixture and policy, 120 requested 60 Hz scroll steps each. Times include application-side work; GPU completion is asynchronous. See Research/README.md for the measurement boundaries.

| PDF | Policy | Open ms | Median CPU frame ms | p95 CPU frame ms | Median delivery interval ms | Peak MiB |
|---|---|---:|---:|---:|---:|---:|
| chart.pdf | original | 33.61 | 0.44 | 0.75 | 16.67 | 46.33 |
| chart.pdf | selected | 50.38 | 0.41 | 0.75 | 16.66 | 94.30 |
| columns-table.pdf | original | 30.73 | 0.42 | 0.75 | 16.67 | 47.36 |
| columns-table.pdf | selected | 50.59 | 0.48 | 0.76 | 16.67 | 95.39 |
| dark.pdf | original | 25.50 | 0.33 | 0.72 | 16.67 | 46.27 |
| dark.pdf | selected | 41.10 | 0.14 | 0.28 | 16.67 | 94.61 |
| nasa-apollo-earth.pdf | original | 29.37 | 0.17 | 0.30 | 16.67 | 59.80 |
| nasa-apollo-earth.pdf | selected | 58.75 | 0.18 | 0.29 | 16.67 | 106.64 |
| photo-caption.pdf | original | 30.94 | 0.50 | 0.72 | 16.67 | 83.44 |
| photo-caption.pdf | selected | 67.89 | 0.44 | 0.75 | 16.67 | 133.22 |
| protected.pdf | original | 33.50 | 0.48 | 0.87 | 16.66 | 48.12 |
| protected.pdf | selected | 51.66 | 0.53 | 0.88 | 16.67 | 94.92 |
| scan.pdf | original | 30.08 | 0.38 | 0.72 | 16.67 | 75.78 |
| scan.pdf | selected | 51.41 | 0.39 | 0.74 | 16.67 | 125.03 |
| text.pdf | original | 31.97 | 0.46 | 0.87 | 16.67 | 47.42 |
| text.pdf | selected | 52.55 | 0.45 | 0.84 | 16.67 | 94.59 |
| usgs-earth-as-home.pdf | original | 36.90 | 0.25 | 0.40 | 16.66 | 518.36 |
| usgs-earth-as-home.pdf | selected | 466.40 | 0.44 | 0.97 | 16.67 | 153.53 |
