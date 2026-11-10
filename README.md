# Adaptive Reader

Native macOS reading workspace, Phase 0 foundation. Requires macOS 15 or later. SwiftUI and AppKit provide the shell, PDFKit displays documents. MIT licensed.

## Build

Install full Xcode with macOS SDK and select it under Xcode Settings → Locations → Command Line Tools. Open `AdaptiveReader.xcodeproj`, choose the shared AdaptiveReader scheme, and run.

```sh
swift test
xcodebuild -project AdaptiveReader.xcodeproj -scheme AdaptiveReader -destination 'platform=macOS' build
xcodebuild -project AdaptiveReader.xcodeproj -scheme AdaptiveReader -destination 'platform=macOS' test
```

`swift run AdaptiveReaderPreview` also launches the development executable. The Xcode project builds the sandboxed application bundle with local signing. Developer ID credentials are needed for future signed public distribution.

## Current behavior

Open a PDF from the toolbar or empty state. The application stores a managed local copy and verifies its SHA-256 on reopen. It restores the last document, page position, zoom and palette after Quit. The appearance popover changes the shell between System, Light and Dark. The More menu opens the component catalogue. Sidebar and inspector visibility preferences persist. Compact windows expose those panels as a popover and sheet. The app bundle includes English and Russian translations.

The [Adaptive design system](docs/adaptive-design-system.md) documents tokens, controls and shortcuts. [Reference screenshots](docs/screenshots) cover both languages, appearances and window sizes.

The foundation includes versioned PDF/EPUB source anchors, validated navigation commands, reversible palette commands and atomic position records. PDFKit retains native selection, search and links. Page palettes use the bounded selective Color Engine for eligible text/vector pages; complex pages preserve Original and display a fallback explanation. [Color Engine evidence and reproduction](Research/README.md) include nine PDFs, paired images and five-run Release measurements. [Reader contracts](docs/reader-architecture.md) describe the boundaries for EPUB and AI. Full library browsing, EPUB and AI belong to later releases.

Books stay on the device. This build has no AI provider or network feature.

See [Phase 0 acceptance](docs/phase-0.md) for verified results and remaining work.
