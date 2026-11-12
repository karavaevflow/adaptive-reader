import Foundation
import Testing
import PDFKit
@testable import ReaderCore

private func studyFixture(_ name: String = "EPUB/reflow.epub") throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Research/Fixtures/" + name))
}

@Test @MainActor func studyRecordsSurviveReflowReopenAndUnrelatedMutations() async throws {
    let data = try studyFixture(), publication = try EPUBPublication(data: data), id = UUID(), revision = PDFReaderEngine.revision(data)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(root: root), engine = EPUBReaderEngine(publication: publication, bookID: id, revision: revision)
    defer { engine.stop() }
    let record = try await store.importBook(data: data, id: id, title: "Study", revision: revision, format: .epub)
    let text = publication.chapters[0].text, offset = (text as NSString).range(of: "Learning begins").location
    let anchor = SourceAnchor(bookID: id, sourceRevision: revision, position: .epub(resource: publication.chapters[0].resource, locator: EPUBTextLocator(offset: offset, quote: "Learning begins").encoded))
    let highlight = ReaderHighlight(anchor: anchor, quotation: "Learning begins", color: .green)
    var card = StudyCard(anchor: anchor, quotation: "Learning begins", question: "What comes first?", answer: "Attention.", now: Date(timeIntervalSince1970: 1000))
    let note = ReaderNote(anchor: anchor, text: "A reader note", quotation: "Learning begins")
    try await store.saveCard(card, for: record); try await store.saveHighlight(highlight, for: record); try await store.saveNote(note, for: record)
    let listen = ListenPosition(anchor: anchor, rate: 1.2, voiceIdentifier: nil)
    try await store.saveListenPosition(listen, for: record)
    card.answer = "Attention before retrieval."; card.review(remembered: true, now: Date(timeIntervalSince1970: 1000))
    try await store.saveCard(card, for: record)
    let commands = ReaderCommands(engine: engine)
    try commands.perform(.navigate(anchor)); var typography = EPUBTypography(); typography.fontSize = 29
    try commands.perform(.setTypography(typography)); try commands.perform(.setHighlights([highlight]))
    let fresh = LibraryStore(root: root), state = try await fresh.study(for: record)
    #expect(state.cards == [card] && state.highlights == [highlight] && state.listen == listen)
    #expect(try await fresh.notes(for: record) == [note])
    try commands.perform(.followPlayback(state.cards[0].anchor))
    #expect(try engine.currentAnchor() == anchor)
    #expect((try await fresh.openBook(id)).1 == data)
    try await fresh.removeCard(card.id, for: record)
    #expect(try await fresh.study(for: record).highlights == [highlight])
    #expect(try await fresh.study(for: record).listen == listen)
    let changed = BookRecord(id: id, title: "Other", revision: "different", source: record.source, format: .epub)
    await #expect(throws: ReaderError.sourceChanged) { try await fresh.saveHighlight(highlight, for: changed) }
}

@Test func recallSchedulesAreExplicitAndMarkdownIncludesPortableAnchors() throws {
    #expect(throws: ReaderError.invalidAnchor) { try EPUBTextLocator(offset: -1).validate(in: "text") }
    let now = Date(timeIntervalSince1970: 1000), id = UUID(), anchor = SourceAnchor(bookID: id, sourceRevision: "revision", position: .epub(resource: "chapter.xhtml", locator: EPUBTextLocator(offset: 5).encoded))
    var card = StudyCard(anchor: anchor, quotation: "Source quotation", question: "Why?", answer: "Because.", now: now)
    #expect(card.dueAt == now && card.intervalDays == 0)
    card.review(remembered: true, now: now); #expect(card.intervalDays == 1 && card.dueAt == now.addingTimeInterval(86400))
    card.review(remembered: true, now: now); #expect(card.intervalDays == 3)
    card.review(remembered: false, now: now); #expect(card.intervalDays == 0 && card.dueAt == now.addingTimeInterval(600))
    let note = ReaderNote(anchor: anchor, text: "My note", quotation: "Quoted source")
    let output = try StudyMarkdown.export(title: "Book", notes: [note], cards: [card], highlights: [ReaderHighlight(anchor: anchor, quotation: "Quoted source")])
    #expect(output.contains("## Notes") && output.contains("My note") && output.contains("## Cards") && output.contains("Because."))
    let line = try #require(output.components(separatedBy: .newlines).first(where: { $0.hasPrefix("<!-- AdaptiveSourceAnchor: ") }))
    let encoded = String(line.dropFirst("<!-- AdaptiveSourceAnchor: ".count).dropLast(" -->".count))
    let restored = try JSONDecoder().decode(SourceAnchor.self, from: #require(Data(base64Encoded: encoded)))
    #expect(restored == anchor)
}

@Test func cardArchiveRebasesOnlyExactSourcesAndDoesNotOverwriteEditedCards() async throws {
    let data = try studyFixture(), revision = PDFReaderEngine.revision(data)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(root: root)
    let record = try await store.importBook(data: data, id: UUID(), title: "Imported copy", revision: revision, format: .epub)
    let anchor = SourceAnchor(bookID: UUID(), sourceRevision: revision, position: .epub(resource: "EPUB/one.xhtml", locator: EPUBTextLocator(offset: 0).encoded))
    let card = StudyCard(anchor: anchor, quotation: "Reading", question: "What is reading?", answer: "An active process.")
    let archive = try StudyCardArchive(revision: revision, cards: [card]).encoded()
    #expect(try await store.importCards(archive, for: record) == 1)
    var imported = try #require(try await store.study(for: record).cards.first)
    #expect(imported.id == card.id && imported.anchor.bookID == record.id)
    imported.answer = "An edited answer"; try await store.saveCard(imported, for: record)
    #expect(try await store.importCards(archive, for: record) == 0)
    #expect(try await store.study(for: record).cards.first?.answer == "An edited answer")
    let bad = try StudyCardArchive(revision: "different", cards: [card]).encoded()
    await #expect(throws: ReaderError.sourceChanged) { try await store.importCards(bad, for: record) }
    #expect(try await store.study(for: record).cards.count == 1)
}

@Test @MainActor func epubSpeechPassagesAreBoundedExactAndAdvanceWithoutLosingText() throws {
    let data = try studyFixture(), publication = try EPUBPublication(data: data)
    let engine = EPUBReaderEngine(publication: publication, bookID: UUID(), revision: PDFReaderEngine.revision(data))
    defer { engine.stop() }
    var anchor: SourceAnchor? = try engine.currentAnchor(), joined = "", count = 0
    let first = try engine.textPassage(at: #require(anchor))
    #expect(first.text == "Reading and memory")
    let second = try engine.textPassage(at: #require(first.next))
    #expect(second.text.hasPrefix("Learning begins") && !first.text.contains("Learning"))
    while let current = anchor {
        count += 1; #expect(count < 2000)
        if count >= 2000 { break }
        let passage = try engine.textPassage(at: current)
        #expect(passage.text.count <= 500)
        joined += passage.text; anchor = passage.next
    }
    #expect(joined.filter { !$0.isWhitespace } == publication.chapters.map(\.text).joined().filter { !$0.isWhitespace })
    let origin = try engine.currentAnchor(), commands = ReaderCommands(engine: engine)
    let next = try engine.adjacentPassage(1)
    try commands.perform(.followPlayback(next))
    #expect(!commands.canGoBack)
    try commands.perform(.navigate(origin)); #expect(commands.canGoBack)
}

@Test @MainActor func imageOnlyEPUBDoesNotAdvertiseTextStudyOrSpeech() throws {
    let data = try studyFixture("EPUB/image-only.epub"), publication = try EPUBPublication(data: data)
    let engine = EPUBReaderEngine(publication: publication, bookID: UUID(), revision: PDFReaderEngine.revision(data))
    defer { engine.stop() }
    #expect(!engine.capabilities.contains(.textSelection) && !engine.capabilities.contains(.readAloud) && !engine.capabilities.contains(.search))
    #expect(engine.capabilities.contains(.reflow))
}

@Test @MainActor func pdfSpeechEndsWithoutRepeatingAndHighlightsNeverRewriteSource() throws {
    let data = try studyFixture("text.pdf"), engine = try PDFReaderEngine(data: data, bookID: UUID())
    var anchor: SourceAnchor? = try engine.currentAnchor(), count = 0
    var seen = Set<String>()
    while let current = anchor {
        let passage = try engine.textPassage(at: current)
        if passage.text.isEmpty { break }
        #expect(seen.insert(passage.text).inserted)
        count += 1; if count > 100 { Issue.record("Speech did not advance"); break }
        anchor = passage.next
    }
    #expect(count >= 3 && count <= 100)
    let firstPage = try #require(engine.document.page(at: 0))
    let line = try #require(firstPage.selection(for: firstPage.bounds(for: .cropBox))?.selectionsByLine().first)
    let bounds = line.bounds(for: firstPage)
    let location = SourceAnchor(bookID: engine.bookID, sourceRevision: engine.sourceRevision, position: .pdf(.init(pageIndex: 0, x: bounds.minX, y: bounds.maxY)))
    let highlight = ReaderHighlight(anchor: location, quotation: try #require(line.string))
    try ReaderCommands(engine: engine).perform(.setHighlights([highlight]))
    #expect(!engine.adaptiveHighlights.isEmpty)
    try engine.setHighlights([]); #expect(engine.adaptiveHighlights.isEmpty)
    #expect(PDFReaderEngine.revision(data) == engine.sourceRevision)
}
