# v0.6 visual references

Native application screenshots exported from successful XCTest scenarios. The 48-image matrix covers Split and all five Extended Reading tabs in RU/EN, Light/Dark, at window widths 800 and 1440 pt. Three further images capture real OCR, cleared/disabled privacy controls after restart, and independent PDF/EPUB reading after swapping sources.

- [Compact Russian Split](v06-Split-ru-800-light.png)
- [Wide dark Split](v06-Split-en-1440-dark.png)
- [Compact Russian translation](v06-Tools1-ru-800-dark.png)
- [Low-confidence OCR presentation](v06-Tools2-ru-800-light.png)
- [Actual Vision OCR](v06-OCR-flow.png)
- [PDF/EPUB workflow](v06-CrossFormat-flow.png)
- [Privacy after restart](v06-Privacy-flow.png)

The visual matrix uses isolated test libraries with real source anchors, reader-authored translation/vocabulary fixtures and metadata-only Replay/Insights examples. The explicit “Visual OCR fixture” at 42% confidence tests uncertain-result presentation; it is not presented as an actual Vision observation. Actual recognition is verified separately in the OCR workflow, core tests and Release measurements. Source titles/content are intentionally retained in their original language.

Reviewed all 51 images: pane ownership and separate positions are visible; compact controls fit; source/translation columns remain aligned; warnings sit next to uncertain text; explanations wrap without covering actions; Light/Dark and RU labels remain legible. See the [acceptance report](../v0.6.md) for the exact tested source/run, scope and limitations.
