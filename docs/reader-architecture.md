# Reader contracts

ReaderCore contains domain contracts, the native PDF engine, source identity and local storage. The SwiftUI shell owns ReaderSession; the engine owns its PDFView. Page rendering never owns navigation state.

## Stable boundaries

- `ReaderEngine` exposes source identity, capabilities, current anchor, validated navigation, scale and palette commands. Unsupported operations throw. EPUB can support reflow and reject page palettes without changes to bookmarks, notes or AI tools.
- `SourceAnchor` schema 1 stores book UUID, source SHA-256 and a typed position. PDF positions use zero-based pages and unrotated crop-box coordinates. EPUB positions store a resource and stable textual locator. Unsupported versions, changed sources and invalid locators produce explicit errors. Reflow does not use PDF coordinates.
- `ReaderCommands` is the typed entry point for menu, toolbar and future AI tools. It commits state/history only after the engine succeeds. Palette undo uses the same validated engine path. New commands must declare capability checks and undo semantics. A future AI adapter will receive this dispatcher, not native views or arbitrary file access.
- `PDFReaderEngine` uses PDFKit for search, selection, links and currentDestination. `AdaptivePDFPage` alters drawing only after the research eligibility check. Palette redraw rebinds the same PDFDocument through public PDFKit APIs, then restores the anchor and scale. No private tile APIs or PDF rewriting are used.

## Storage schema 1

Under Application Support/AdaptiveReader (inside the app sandbox), Assets stores immutable managed copies, Books stores versioned metadata, ReadingState stores user positions/palette/scale, and Cache is disposable. All JSON writes are atomic and serialized by LibraryStore. Source checksums are verified on reopen. A source revision mismatch is surfaced instead of silently reusing an anchor.

ReaderSession debounces saves during scrolling and flushes them through a normal termination delegate before Quit completes. Native scene restoration and window frame autosave preserve windows; AppStorage preserves panel/theme settings. The Phase 0 import is a managed copy. Reference import, a full library browser and migration UI belong to later releases.

ReadingState's optional auto-scale/display-mode fields decode the first schema-1 form. No earlier released storage schema exists. At the first schema-version change, retain a fixture of this schema and add a migration test before changing the writer.

The research command-line program owns global-inversion experiments and measurements. The app only contains the selected, bounded rendering path. Raster scale/cache policy can evolve within the rendering boundary without changing ReaderEngine or SourceAnchor.

## Shell commands and native focus

`WorkspaceCommand` gives native menus and toolbar a single typed dispatcher for opening a source, panels and zoom. Document operations delegate to ReaderCommands, so future command-centre and AI adapters share the same validation path.

Popover/sheet dismissal requests focus by semantic toolbar identifier. WindowIntegration waits for the parent NSWindow to become key, finds the actual accessibility element and restores native keyboard/accessibility focus using public AppKit APIs. This avoids relying on a fixed animation delay. Escape is handled at popover content as well as by the native presentation.
