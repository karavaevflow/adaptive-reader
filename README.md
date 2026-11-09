# Adaptive Reader

Native macOS reading workspace, currently in Phase 0 development. Requires macOS 15 or later. SwiftUI and AppKit provide the shell, PDFKit displays documents. MIT licensed.

## Build

Install full Xcode with macOS SDK and select it under Xcode Settings → Locations → Command Line Tools. Open `AdaptiveReader.xcodeproj`, choose the shared AdaptiveReader scheme, and run.

```sh
swift test
xcodebuild -project AdaptiveReader.xcodeproj -scheme AdaptiveReader -destination 'platform=macOS' build
xcodebuild -project AdaptiveReader.xcodeproj -scheme AdaptiveReader -destination 'platform=macOS' test
```

`swift run AdaptiveReaderPreview` also launches the development executable. The Xcode project builds the sandboxed application bundle with local signing. Developer ID credentials are needed for future signed public distribution.

## Current behavior

Open a PDF from the toolbar or empty state. The application owns an in-memory copy while reading. The appearance popover changes the shell between System, Light and Dark. The More menu opens the component catalogue. Sidebar and inspector visibility preferences persist. Compact windows expose those panels as a popover and sheet. The app bundle includes English and Russian translations.

The [Adaptive design system](docs/adaptive-design-system.md) documents tokens, controls and shortcuts. [Reference screenshots](docs/screenshots) cover both languages, appearances and window sizes.

The foundation includes versioned PDF/EPUB source anchors, validated navigation commands, reversible palette commands and atomic position records. The running PDF view currently uses Original rendering. Integration of the engine contracts, full library persistence, page palettes, EPUB and AI are upcoming work.

Books stay on the device. This build has no AI provider or network feature.

See [Phase 0 acceptance](docs/phase-0.md) for verified results and remaining work.
