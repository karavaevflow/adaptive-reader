import Testing
import Foundation
import AppKit
import PDFKit
@testable import ReaderCore

private var fixtures: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Research/Fixtures")
}

@MainActor
private func window(for engine: PDFReaderEngine) -> NSWindow {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 650),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = engine.view
    engine.view.layoutSubtreeIfNeeded()
    engine.view.layoutDocumentView()
    return window
}

@Test @MainActor
func commandNavigationSurvivesReopenAndPalette() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = try Data(contentsOf: fixtures.appendingPathComponent("text.pdf"))
    let engine = try PDFReaderEngine(data: data, bookID: UUID())
    let host = window(for: engine)
    defer { host.close() }
    #expect(engine.document.page(at: 0) is AdaptivePDFPage)
    #expect(engine.capabilities.contains(.search))
    let commands = ReaderCommands(engine: engine)
    let target = SourceAnchor(bookID: engine.bookID, sourceRevision: engine.sourceRevision,
                              position: .pdf(.init(pageIndex: 1, x: 0, y: 650)))
    try commands.perform(.navigate(target))
    let selection = try #require(engine.document.findString("stable anchor", withOptions: .caseInsensitive).first)
    engine.view.setCurrentSelection(selection, animate: false)
    let before = try engine.currentAnchor()
    try commands.perform(.setPalette(.midnight))
    let after = try engine.currentAnchor()
    #expect(before == after)
    if case .pdf(let point) = before.position { #expect(point.pageIndex == 1) }
    #expect(engine.palette == .midnight)
    #expect(engine.view.currentSelection?.string == selection.string)
    #expect(!engine.document.findString("stable anchor", withOptions: .caseInsensitive).isEmpty)
    #expect(engine.document.page(at: 0)?.annotations.contains { $0.url != nil } == true)
    let store = LibraryStore(root: root)
    let record = try await store.importBook(data: data, id: engine.bookID, title: "Test", revision: engine.sourceRevision)
    try await store.save(ReadingState(anchor: after, palette: commands.palette, scale: engine.view.scaleFactor), for: record)
    let (restoredRecord, restoredData, state) = try #require(try await LibraryStore(root: root).lastBook())
    #expect(restoredData == data)
    let reopened = try PDFReaderEngine(data: restoredData, bookID: restoredRecord.id)
    let reopenedHost = window(for: reopened)
    defer { reopenedHost.close() }
    reopened.view.autoScales = false
    reopened.view.scaleFactor = try #require(state?.scale)
    try reopened.applyPagePalette(try #require(state?.palette))
    try reopened.navigate(to: try #require(state?.anchor))
    let position = try reopened.currentAnchor()
    guard case .pdf(let expected) = after.position, case .pdf(let actual) = position.position else {
        Issue.record("Expected PDF anchors"); return
    }
    #expect(actual.pageIndex == expected.pageIndex)
    #expect(abs(actual.y - expected.y) < 2)
    try commands.undoPalette()
    #expect(engine.palette == .original)
    #expect(try Data(contentsOf: root.appendingPathComponent("Assets/\(record.assetName)")) == data)
}

@Test @MainActor
func invalidCommandsAndProtectedDocumentsPreserveState() throws {
    let data = try Data(contentsOf: fixtures.appendingPathComponent("text.pdf"))
    let engine = try PDFReaderEngine(data: data, bookID: UUID())
    let host = window(for: engine)
    defer { host.close() }
    let commands = ReaderCommands(engine: engine)
    let wrongFormat = SourceAnchor(bookID: engine.bookID, sourceRevision: engine.sourceRevision,
                                   position: .epub(resource: "chapter.xhtml", locator: "cfi"))
    #expect(throws: ReaderError.unsupportedCommand) { try commands.perform(.navigate(wrongFormat)) }
    let invalid = SourceAnchor(bookID: engine.bookID, sourceRevision: engine.sourceRevision,
                               position: .pdf(.init(pageIndex: 999, x: 0, y: 100)))
    #expect(throws: ReaderError.invalidAnchor) { try commands.perform(.navigate(invalid)) }
    let protected = try Data(contentsOf: fixtures.appendingPathComponent("protected.pdf"))
    #expect(throws: ReaderError.lockedDocument) { _ = try PDFReaderEngine(data: protected, bookID: UUID()) }
    let scan = try PDFReaderEngine(data: Data(contentsOf: fixtures.appendingPathComponent("scan.pdf")), bookID: UUID())
    #expect(!scan.capabilities.contains(.textSelection))
}

@Test
func conservativeColorPolicyAndChromaticPreservation() throws {
    let renderer = PDFColorRenderer()
    for name in ["scan.pdf", "photo-caption.pdf", "dark.pdf", "nasa-apollo-earth.pdf", "usgs-earth-as-home.pdf"] {
        let document = try #require(CGPDFDocument(fixtures.appendingPathComponent(name) as CFURL))
        let page = try #require(document.page(at: 1))
        #expect(renderer.support(for: page) != .available)
    }
    let document = try #require(CGPDFDocument(fixtures.appendingPathComponent("chart.pdf") as CFURL))
    let page = try #require(document.page(at: 1))
    #expect(renderer.support(for: page) == .available)
    let original = try #require(renderer.original(page: page))
    let selected = try #require(renderer.render(page: page, palette: .midnight))
    #expect(original.width == selected.width)
    #expect(original.dataProvider?.data != selected.dataProvider?.data)
    func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }
    let raw = pixels(original), adapted = pixels(selected)
    for target in [[UInt8](arrayLiteral: 255, 0, 0), [0, 255, 0], [0, 0, 255]] {
        let offset = try #require(stride(from: 0, to: raw.count, by: 4).first { i in
            Array(raw[i..<i+3]) == target
        })
        for channel in 0..<3 { #expect(abs(Int(raw[offset+channel]) - Int(adapted[offset+channel])) <= 1) }
    }
}

@Test
func changedAndMissingAssetsAreReported() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = try Data(contentsOf: fixtures.appendingPathComponent("text.pdf"))
    let store = LibraryStore(root: root)
    let record = try await store.importBook(data: data, id: UUID(), title: "Test", revision: PDFReaderEngine.revision(data))
    let asset = root.appendingPathComponent("Assets/\(record.assetName)")
    try Data("changed".utf8).write(to: asset)
    await #expect(throws: ReaderError.sourceChanged) { try await store.lastBook() }
    try FileManager.default.removeItem(at: asset)
    await #expect(throws: ReaderError.unavailableSource) { try await store.lastBook() }
}

@MainActor private final class LimitedEngine: ReaderEngine {
    let bookID = UUID()
    let sourceRevision = "v1"
    var capabilities: Set<ReaderCapability> { [] }
    func currentAnchor() throws -> SourceAnchor { throw ReaderError.unsupportedCommand }
    func navigate(to anchor: SourceAnchor) throws { Issue.record("Dispatcher must reject unsupported navigation") }
}

@Test @MainActor func unsupportedCommandsDoNotCommitHistory() throws {
    let engine = LimitedEngine(), commands = ReaderCommands(engine: LimitedEngine())
    #expect(throws: ReaderError.unsupportedCommand) { try commands.perform(.setPalette(.forest)) }
    #expect(throws: ReaderError.unsupportedCommand) { try commands.perform(.setScale(2)) }
    #expect(throws: ReaderError.unsupportedCommand) {
        try commands.perform(.navigate(SourceAnchor(bookID: engine.bookID, sourceRevision: "v1", position: .epub(resource: "chapter", locator: "cfi"))))
    }
    #expect(commands.palette == .original)
    #expect(!commands.canUndoPalette)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func asynchronousSearchReturnsAnchorsAndRetainsNativeSelection() async throws {
    let engine = try PDFReaderEngine(data: Data(contentsOf: fixtures.appendingPathComponent("text.pdf")), bookID: UUID())
    let host = window(for: engine); defer { host.close() }
    let commands = ReaderCommands(engine: engine)
    var matches: [ReaderSearchMatch] = []
    for try await match in try commands.search("stable anchor") { matches.append(match) }
    #expect(matches.count == 3)
    #expect(matches.allSatisfy { $0.snippet.contains("original source") })
    try commands.perform(.showSearchMatch(matches[1]))
    #expect(engine.view.currentSelection?.string?.localizedCaseInsensitiveContains("stable anchor") == true)
    if case .pdf(let position) = try engine.currentAnchor().position { #expect(position.pageIndex == 1) }
    let cancelled = try commands.search("Reading")
    engine.cancelSearch()
    var count = 0
    for try await _ in cancelled { count += 1 }
    #expect(count == 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func largeSearchStopsAtLimitAndAllowsANewQuery() async throws {
    let source = fixtures.deletingLastPathComponent().appendingPathComponent("Large/large-text.pdf")
    let engine = try PDFReaderEngine(data: Data(contentsOf: source), bookID: UUID())
    let host = window(for: engine); defer { host.close() }
    let commands = ReaderCommands(engine: engine)
    var count = 0
    for try await _ in try commands.search("responsive") { count += 1 }
    #expect(count == 1000)
    var chapters = [ReaderSearchMatch]()
    for try await match in try commands.search("Chapter") { chapters.append(match) }
    #expect(chapters.count == 600)
    let last = try #require(chapters.last)
    try commands.perform(.showSearchMatch(last))
    #expect(engine.view.currentSelection?.string?.localizedCaseInsensitiveContains("Chapter") == true)
    if case .pdf(let position) = last.anchor.position { #expect(position.pageIndex == 599) }
}

@Test @MainActor
func continuousScrollAnchorTracksVisiblePage() throws {
    let source = fixtures.deletingLastPathComponent().appendingPathComponent("Large/large-text.pdf")
    let engine = try PDFReaderEngine(data: Data(contentsOf: source), bookID: UUID())
    let host = window(for: engine); defer { host.close() }
    let clip = try #require(engine.view.documentView?.enclosingScrollView?.contentView)
    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: 5000))
    clip.enclosingScrollView?.reflectScrolledClipView(clip)
    guard case .pdf(let point) = try engine.currentAnchor().position else { Issue.record("Expected PDF position"); return }
    #expect(point.pageIndex > 0)
    let visible = try engine.currentAnchor()
    try engine.applyPagePalette(.midnight)
    let restored = try engine.currentAnchor()
    guard case .pdf(let originalPoint) = visible.position, case .pdf(let restoredPoint) = restored.position else {
        Issue.record("Expected PDF anchors"); return
    }
    #expect(restoredPoint.pageIndex == originalPoint.pageIndex)
    #expect(abs(restoredPoint.x - originalPoint.x) < 2)
    #expect(abs(restoredPoint.y - originalPoint.y) < 2)
}

@Test @MainActor
func internalFootnoteAndSearchShareSmartBackHistory() throws {
    let engine = try PDFReaderEngine(data: Data(contentsOf: fixtures.appendingPathComponent("text.pdf")), bookID: UUID())
    let host = window(for: engine); defer { host.close() }
    let commands = ReaderCommands(engine: engine)
    let origin = try engine.currentAnchor()
    engine.onInternalNavigation = { anchor in
        do { try commands.perform(.navigate(anchor)) } catch { Issue.record("Internal link failed: \(error)") }
    }
    let page = try #require(engine.document.page(at: 2))
    engine.view.perform(PDFActionGoTo(destination: PDFDestination(page: page, at: NSPoint(x: 0, y: 600))))
    #expect(commands.canGoBack)
    try commands.perform(.back)
    let back = try engine.currentAnchor()
    if case .pdf(let a) = origin.position, case .pdf(let b) = back.position { #expect(a.pageIndex == b.pageIndex); #expect(abs(a.y - b.y) < 2) }
    #expect(commands.canGoForward)
    let wrong = SourceAnchor(bookID: UUID(), sourceRevision: engine.sourceRevision, position: origin.position)
    #expect(throws: ReaderError.sourceChanged) { try commands.perform(.navigate(wrong)) }
    #expect(commands.canGoForward)
    try commands.perform(.forward)
    if case .pdf(let point) = try engine.currentAnchor().position { #expect(point.pageIndex == 2) }
}

@Test @MainActor
func spotlightPreservesSelectionAndFallsBackToRegionForScans() throws {
    let engine = try PDFReaderEngine(data: Data(contentsOf: fixtures.appendingPathComponent("text.pdf")), bookID: UUID())
    let host = window(for: engine); defer { host.close() }
    let selection = try #require(engine.document.findString("stable anchor", withOptions: []).first)
    engine.view.setCurrentSelection(selection, animate: false)
    try ReaderCommands(engine: engine).perform(.setSpotlight(true))
    #expect(engine.view.currentSelection?.string == selection.string)
    #expect(throws: ReaderError.unsupportedCommand) { try ReaderCommands(engine: engine).perform(.stepSpotlight(Int.min)) }
    let scan = try PDFReaderEngine(data: Data(contentsOf: fixtures.appendingPathComponent("scan.pdf")), bookID: UUID())
    let scanHost = window(for: scan); defer { scanHost.close() }
    try scan.setSpotlight(true)
    #expect(scan.spotlightEnabled)
    #expect(!scan.spotlightUsesText)
}

@Test @MainActor
func textBlockAdvanceUsesCommonAnchorsAndCanGoBack() throws {
    let engine = try PDFReaderEngine(data: Data(contentsOf: fixtures.appendingPathComponent("text.pdf")), bookID: UUID())
    let host = window(for: engine); defer { host.close() }
    let origin = try engine.currentAnchor(), commands = ReaderCommands(engine: engine)
    try commands.perform(.advancePassage(1))
    #expect(commands.canGoBack)
    let moved = try engine.currentAnchor()
    #expect(moved != origin)
    try commands.perform(.back)
    if case .pdf(let a) = origin.position, case .pdf(let b) = try engine.currentAnchor().position { #expect(a.pageIndex == b.pageIndex); #expect(abs(a.y-b.y) < 2) }
    #expect(throws: ReaderError.unsupportedCommand) { try commands.perform(.advancePassage(Int.min)) }
}
