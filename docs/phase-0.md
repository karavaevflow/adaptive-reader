# Phase 0 acceptance

Phase 0 remains open. v0.1 is gated by all acceptance items below.

## Verified locally

- macOS 15.8.2 arm64, Xcode 26.3 (17C529), selected at `/Applications/Xcode.app/Contents/Developer`.
- Local Xcode build and UI test pass. The UI test opens the main window and the appearance popover.
- Xcode 26.3 required disambiguating the package executable name from the app target. The package preview is now AdaptiveReaderPreview.
- Swift package builds the SwiftUI application executable.
- Two Swift Testing tests pass, covering PDF/EPUB anchor round trips, source revision rejection, and position persistence after store recreation.
- Xcode project property-list syntax validates.

## Remaining acceptance

- Clean-clone local app build and UI tests.
- Validate Release universal binaries separately. Debug now uses the active architecture, matching normal Xcode development settings.
- Recheck public macOS CI after the final UI test selector change. The package-name compatibility fix passed public CI.
- Full Adaptive token palette, component states and RU/EN resources.
- Wide/compact window checks, focus restoration, VoiceOver, Reduce Motion and Reduce Transparency verification.
- Reference screenshots of Library, Reader and popover in Light/Dark at 800 and 1440 pt.
- Color Engine study on text, multi-column/table, photo, chart, scanned, dark and protected PDFs. Keep licensed source fixtures and checksums. Compare Original, Core Image raster processing and selective recoloring before choosing the production pipeline.
- Per-fixture paired images, five Release runs of first/repeated render time and peak memory. Check selection, search, links, zoom and image colors. Document fallback to Original.
- Integrate ReaderEngine and SourceAnchor with PDFView and persistence after the rendering decision. Test command → navigation → save → reopen and palette changes without anchor drift.
- Restore window, source access, reading position and panel settings across app restarts.
- Fix benchmark Mac model/display and collect cold launch, panel latency, frame time during scrolling and memory baselines. Investigate later regressions exceeding 20% of baseline medians.

The initial shell is a buildable starting point. Its component catalogue and Original PDF view require the visual and accessibility checks above before acceptance.
