import Foundation
import Testing
import AppKit
import PDFKit
@testable import ReaderCore

private func extendedFixture(_ name: String = "text.pdf") throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Research/Fixtures/" + name))
}
private func extendedBook() async throws -> (LibraryStore, BookRecord, SourceAnchor) {
    let store = LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("ExtendedTests-" + UUID().uuidString)), data = try extendedFixture()
    let book = try await store.importBook(data: data, id: UUID(), title: "Reading", revision: PDFReaderEngine.revision(data))
    return (store, book, .init(bookID: book.id, sourceRevision: book.revision, position: .pdf(.init(pageIndex: 0, x: 30, y: 500))))
}
@Test func extendedTrackingIsOptInAndOldWritesCannotRestoreClearedData() async throws {
    let (store, book, anchor) = try await extendedBook(), initial = try await store.extendedReading()
    #expect(!initial.replayEnabled && !initial.insightsEnabled)
    let event = ReadingEvent(kind: .noteCreated, anchor: anchor)
    let disabled = try await store.performExtended(.record(event, generation: initial.generation))
    #expect(disabled.events.isEmpty && disabled.metrics.isEmpty)
    let enabled = try await store.performExtended(.setTracking(replay: true, insights: true))
    try await store.performExtended(.record(event, generation: enabled.generation))
    try await store.performExtended(.activeTime(book: book.id, seconds: 30, generation: enabled.generation))
    let populated = try await store.extendedReading()
    #expect(populated.events.count == 1 && populated.metrics[0].notes == 1 && populated.metrics[0].activeSeconds == 30)
    let cleared = try await store.performExtended(.clearReplay)
    #expect(cleared.events.isEmpty && cleared.metrics[0].notes == 1)
    try await store.performExtended(.record(event, generation: enabled.generation))
    try await store.performExtended(.clearInsights)
    try await store.performExtended(.activeTime(book: book.id, seconds: 30, generation: cleared.generation))
    let fresh = try await LibraryStore(root: await store.root).extendedReading()
    #expect(fresh.events.isEmpty && fresh.metrics.isEmpty)
    let off = try await store.performExtended(.setTracking(replay: false, insights: false))
    try await store.performExtended(.record(event, generation: off.generation))
    #expect(try await store.extendedReading().events.isEmpty)
}
@Test func extendedBilingualAndSplitRoundTripSeparatelyFromPrimaryPosition() async throws {
    let (store, book, anchor) = try await extendedBook()
    let source = KnowledgeSource(anchor: anchor, bookTitle: book.title, location: "p. 1", quotation: "Learning to read")
    let fragment = BilingualFragment(source: source, translation: "Учимся читать", language: "Русский", explanation: "to read — читать")
    try await store.performExtended(.saveFragment(fragment))
    try await store.performExtended(.saveWord(.init(fragmentID: fragment.id, word: "read", meaning: "читать")))
    try await store.performExtended(.saveSplit(.init(anchor: anchor, palette: .paper)))
    let fresh = LibraryStore(root: await store.root), snapshot = try await fresh.extendedReading()
    #expect(snapshot.fragments == [fragment] && snapshot.vocabulary.count == 1 && snapshot.splitPosition?.anchor == anchor)
    #expect(try await fresh.readingState(for: book) == nil)
    let before = snapshot
    await #expect(throws: ReaderError.self) { try await store.performExtended(.saveWord(.init(fragmentID: UUID(), word: "bad", meaning: "orphan"))) }
    #expect(try await store.extendedReading() == before)
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]; object["schemaVersion"] = 99
    let future = try JSONDecoder().decode(ExtendedReadingSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: ReaderError.unsupportedAnchorVersion) { try future.validate() }
}
@Test @MainActor func extendedSplitEnginesHaveIndependentPositionsAndCommands() async throws {
    let data = try extendedFixture(), id = UUID()
    let first = try await ReaderEngineFactory.open(data: data, format: .pdf, bookID: id)
    let second = try await ReaderEngineFactory.open(data: data, format: .pdf, bookID: id)
    let commands = ReaderCommands(engine: second), before = first.palette
    try commands.perform(.setPalette(.midnight))
    #expect(first !== second && first.palette == before && second.palette == .midnight)
    #expect(first.bookID == second.bookID && first.sourceRevision == second.sourceRevision)
}
@Test func extendedOCRCancellationAndSourceValidation() async throws {
    let data = try extendedFixture(), ocr = DocumentOCR(); ocr.cancel()
    await #expect(throws: CancellationError.self) { try await ocr.recognize(data: data, bookID: UUID(), revision: PDFReaderEngine.revision(data), pageIndex: 0) }
    await #expect(throws: ReaderError.sourceChanged) { try await DocumentOCR().recognize(data: data, bookID: UUID(), revision: String(repeating: "0", count: 64), pageIndex: 0) }
}
@Test func extendedOCRRecognizesFixtureAndCachesWithoutChangingSource() async throws {
    let (store, book, _) = try await extendedBook(), data = try extendedFixture()
    let page = try await DocumentOCR().recognize(data: data, bookID: book.id, revision: book.revision, pageIndex: 0)
    #expect(!page.lines.isEmpty)
    #expect(page.lines.map(\.text).joined(separator: " ").localizedCaseInsensitiveContains("Reading specimen"))
    try await store.cacheOCR(page, for: book)
    #expect(try await store.cachedOCR(for: book, pageIndex: 0) == page)
    #expect(try await store.openBook(book.id).1 == data)
}

@Test @MainActor func extendedOCRScanSearchAndSourceGeometryRemainStableAcrossPalette() async throws {
    let data = try extendedFixture("scan.pdf"), id = UUID(), engine = try PDFReaderEngine(data: data, bookID: id)
    let recognized = try await DocumentOCR().recognize(data: data, bookID: id, revision: engine.sourceRevision, pageIndex: 0)
    #expect(!recognized.lines.isEmpty)
    try engine.installRecognizedPage(recognized)
    #expect(engine.capabilities.contains(.recognizedText) && engine.capabilities.contains(.search))
    #expect(engine.capabilities.contains(.textSelection) == engine.hasText) // PDFKit may independently provide Live Text.
    let line = try #require(recognized.lines.first), box = try #require(engine.document.page(at: 0)).bounds(for: .cropBox)
    #expect(box.contains(line.bounds))
    let passage = try engine.textPassage(at: .init(bookID: id, sourceRevision: engine.sourceRevision, position: .pdf(.init(pageIndex: 0, x: box.minX, y: box.maxY))))
    #expect(passage.text.contains(line.text))
    var hits: [ReaderSearchMatch] = []
    for try await hit in try engine.search(line.text) { hits.append(hit) }
    #expect(hits.first?.anchor == line.anchor, "native=\(engine.document.page(at: 0)?.string.debugDescription ?? "nil") query=\(line.text.debugDescription) recognized=\(engine.recognizedPages.count)")
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 750), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = engine.view; window.orderFrontRegardless()
    defer { window.close() }
    engine.view.autoScales = false; engine.view.scaleFactor = 1; engine.view.layoutDocumentView()
    try ReaderCommands(engine: engine).perform(.showSearchMatch(try #require(hits.first)))
    let before = try engine.currentAnchor()
    try engine.applyPagePalette(.midnight)
    #expect(try engine.currentAnchor() == before)
    let bad = OCRPage(bookID: id, revision: engine.sourceRevision, pageIndex: 0, lines: [OCRLine(anchor: line.anchor, text: line.text, confidence: .nan, bounds: line.bounds)])
    #expect(throws: ReaderError.self) { try engine.installRecognizedPage(bad) }
    #expect(engine.recognizedPages[0] == recognized)
}

@Test @MainActor func extendedOCRCropOriginAndLockedDocument() async throws {
    let source = try #require(PDFDocument(data: extendedFixture("scan.pdf"))), page = try #require(source.page(at: 0))
    page.setBounds(CGRect(x: 20, y: 30, width: 560, height: 700), for: .cropBox)
    let data = try #require(source.dataRepresentation()), id = UUID(), revision = PDFReaderEngine.revision(data)
    let result = try await DocumentOCR().recognize(data: data, bookID: id, revision: revision, pageIndex: 0)
    #expect(!result.lines.isEmpty)
    let engine = try PDFReaderEngine(data: data, bookID: id)
    try engine.installRecognizedPage(result)
    #expect(result.lines.allSatisfy { $0.bounds.minX >= 20 && $0.bounds.minY >= 30 })
    let protected = try extendedFixture("protected.pdf")
    await #expect(throws: ReaderError.lockedDocument) { try await DocumentOCR().recognize(data: protected, bookID: UUID(), revision: PDFReaderEngine.revision(protected), pageIndex: 0) }
}
