# Adaptive Reader

Native macOS reading workspace with an offline PDF library and an in-progress EPUB reader. Requires macOS 15 or later. SwiftUI and AppKit provide the shell, PDFKit displays documents. MIT licensed.

## Build

Install full Xcode with macOS SDK and select it under Xcode Settings → Locations → Command Line Tools. Open `AdaptiveReader.xcodeproj`, choose the shared AdaptiveReader scheme, and run.

```sh
swift test
xcodebuild -project AdaptiveReader.xcodeproj -scheme AdaptiveReader -destination 'platform=macOS' build
xcodebuild -project AdaptiveReader.xcodeproj -scheme AdaptiveReader -destination 'platform=macOS' test
```

`swift run AdaptiveReaderPreview` also launches the development executable. The Xcode project builds the sandboxed application bundle with local signing. Developer ID credentials are needed for future signed public distribution.

## Current behavior

Import a PDF or reflowable EPUB as a managed copy, or choose **Import linked book** to retain a read-only reference to the original file. The library shows reading progress and favorites. Both modes verify the source SHA-256 on reopen; a changed file produces an explicit error. A linked book can be reauthorized through its library context menu using the same source bytes.

Search text, jump to a result, bookmark the current page, or enter Focus to hide surrounding panels. Keep Awake prevents idle display sleep only while enabled in an open reading session; closing the book, window or app releases it. Quit and reopen restores the document, fragment, zoom and palette. Books, positions and bookmarks stay on disk.

Smart Back/Forward returns to the source after a footnote, search result or command jump. Open the offline Command Center with ⌘K. Reading tools provide line/area Spotlight, timed or free sessions, adjustable auto-scroll and a separate Mini Reader. Manual reading input stops automatic scrolling; closing the book or window ends active reading work. Mini Reader stays above other windows only when explicitly enabled. Ambient Reading follows System, a day/night schedule or manual palettes, with library defaults and per-book overrides.

| Shortcut | Action |
|---|---|
| ⌘O / ⇧⌘O | Import copy / linked book |
| ⇧⌘W | Close book and show library |
| ⌘F | Search book or library titles |
| ⌘D | Toggle page bookmark |
| ⇧⌘F / Escape | Enter / leave Focus |
| ⇧⌘K | Toggle Keep Awake |
| ⌘K | Command Center |
| ⌘[ / ⌘] | Smart Back / Forward |
| ⌘⌥↑ / ⌘⌥↓ | Previous / next text block |
| ⌥↑ / ⌥↓ | Move enabled Spotlight in the document |

The appearance popover changes the shell between System, Light and Dark independently of the page palette. Compact windows retain commands in More. The app includes English and Russian translations. The [Adaptive design system](docs/adaptive-design-system.md) documents the shared components; [v0.1 acceptance](docs/v0.1.md) freezes the offline baseline; [v0.2 acceptance](docs/v0.2.md) tracks the daily reading additions.

Versioned PDF/EPUB source anchors, typed navigation/search commands and atomic records preserve the shared architecture for EPUB and further AI features. PDFKit retains native selection, links and document geometry. Eligible text/vector pages use the bounded selective Color Engine; complex pages preserve Original with a fallback explanation. [Color Engine evidence](Research/README.md) and [reader contracts](docs/reader-architecture.md) describe the boundaries and limitations. EPUB implementation is underway; OCR is a later milestone.

AI is off by default. The PDF Companion can use a local Ollama model or an explicitly enabled HTTPS Chat Completions endpoint with streaming JSON mode. Keys are stored in macOS Keychain. On an explicit question, cloud mode sends the question, book title, current page and at most eight selected/retrieved excerpts; opening a book never sends a model request. Provider retention follows the selected service's policy.

The Companion resolves citations to versioned source anchors, retains evidence for Explain Again, and offers reviewed reader actions and editable notes with Undo. Selection tools preserve the native PDF selection; Smart Margins is opt-in and hidden in Focus. [v0.3 integration evidence](docs/v0.3.md) records tests, limits and the deferred real-model check.

To connect later, open **View → AI Companion → AI settings**. Local mode expects a running Ollama service at `http://127.0.0.1:11434/api/chat` and your installed model identifier. Cloud mode requires your full HTTPS Chat Completions URL, a model supporting JSON responses, optional API key and explicit consent for that endpoint/model. The integration build has no default model. It supports the documented streaming/JSON protocol, not every provider-specific API variation.

Phase 0, the v0.1 offline PDF workflow and v0.2 daily reading have passed acceptance. The v0.2 report includes the real 25-minute Release session, final-source CI and the precise local automation limitation. v0.3 adds the optional AI integration; connecting a real model and judging its answers are deferred by the owner. See [acceptance evidence](docs/phase-0.md) and the [release gates](docs/release-gates.md) for all milestones. The first UI-test run may require confirming macOS “Enable UI Automation”.

The [v0.4 work log](docs/v0.4.md) records the EPUB foundation and remaining learning tools/acceptance. This branch is development work, not an accepted v0.4 release. EPUB typography lives in Appearance, separately from the shell theme.
