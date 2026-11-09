# Phase 0 acceptance

Phase 0 remains open. v0.1 is gated by all acceptance items below.

## Verified locally

- macOS 15.8.2 arm64, Xcode 26.3 (17C529), selected at `/Applications/Xcode.app/Contents/Developer`.
- Local Xcode build and UI test pass. The UI test opens the main window and the appearance popover.
- Xcode 26.3 required disambiguating the package executable name from the app target. The package preview is now AdaptiveReaderPreview.
- Swift package builds the SwiftUI application executable.
- Two Swift Testing tests pass, covering PDF/EPUB anchor round trips, source revision rejection, and position persistence after store recreation.
- Xcode project property-list syntax validates.
- Clean-clone local build and UI test pass on Xcode 26.3.
- Public macOS CI passes for eab24e8: https://github.com/karavaevflow/adaptive-reader/actions/runs/42517310702
- Phase 0 step 1 (reproducible build) is complete.
- Adaptive tokens, system typography, native components and RU/EN strings are implemented. See [design system](adaptive-design-system.md).
- A 32-image Library/Reader/Appearance/Inspector matrix and four component-catalogue captures passed locally for Light/Dark, en/ru and 800/1440 pt. Reference images live in `docs/screenshots`.
- Four UI tests and two core tests pass. Public CI passes for 07477ce: https://github.com/karavaevflow/adaptive-reader/actions/runs/42584005312
- Reduce Transparency was enabled on the control Mac and opaque panels were visually observed. Motion/transparency preferences were restored to their original off values. VoiceOver was also restored to its original off state after the computer-control tool timed out during the speech review.
- Toolbar and menu actions, Escape dismissal and native appearance/inspector shortcuts were checked. Native input was used for shortcuts because XCTest synthesis with the local input source did not reproduce them.
- Baseline contrast and accessible control names are checked independently. Manual VoiceOver speech and focus verification remain open.

## Remaining acceptance

- Validate Release universal binaries separately. Debug now uses the active architecture, matching normal Xcode development settings.
- Manual VoiceOver reading order and focus restoration with keyboard navigation enabled. Confirm reduced-motion transition behavior on the control Mac. The Reduce Transparency rendering path was visually checked.
- Color Engine study on text, multi-column/table, photo, chart, scanned, dark and protected PDFs. Keep licensed source fixtures and checksums. Compare Original, Core Image raster processing and selective recoloring before choosing the production pipeline.
- Per-fixture paired images, five Release runs of first/repeated render time and peak memory. Check selection, search, links, zoom and image colors. Document fallback to Original.
- Integrate ReaderEngine and SourceAnchor with PDFView and persistence after the rendering decision. Test command → navigation → save → reopen and palette changes without anchor drift.
- Restore window, source access, reading position and panel settings across app restarts.
- Fix benchmark Mac model/display and collect cold launch, panel latency, frame time during scrolling and memory baselines. Investigate later regressions exceeding 20% of baseline medians.

The shell has a reusable design system and Original PDF view. Phase 0 step 2 remains open for the manual accessibility checks above. Color Engine research follows within Phase 0.
