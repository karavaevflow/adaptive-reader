import Foundation
import Testing
@testable import ReaderCore

private func knowledgeFixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Research/Fixtures/" + name))
}
private func knowledgeSource(_ book: BookRecord) -> KnowledgeSource {
    .init(anchor: .init(bookID: book.id, sourceRevision: book.revision, position: .pdf(.init(pageIndex: 0, x: 0, y: 600))), bookTitle: book.title, location: "p. 1", quotation: "Adaptive Reader")
}
private func knowledgeStore() -> LibraryStore { LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeTests-" + UUID().uuidString)) }
private func importKnowledgePDF(_ store: LibraryStore, title: String = "Learning") async throws -> BookRecord {
    let data = try knowledgeFixture("text.pdf")
    return try await store.importBook(data: data, id: UUID(), title: title, revision: PDFReaderEngine.revision(data))
}

@Test func knowledgeCommandsPersistGraphAndUndoWithoutLosingConcurrentEdits() async throws {
    let store = knowledgeStore(), book = try await importKnowledgePDF(store), source = knowledgeSource(book)
    let a = KnowledgeCard(title: "Attention", kind: .quotation, text: source.quotation, sources: [source])
    let b = KnowledgeCard(title: "Recall", kind: .readerNote, text: "My idea", sources: [source])
    async let saveA = store.performKnowledge(.saveCard(a)); async let saveB = store.performKnowledge(.saveCard(b))
    _ = try await (saveA, saveB)
    let board = KnowledgeBoard(title: "Memory", nodes: [.init(cardID: a.id, point: .init(x: -200, y: 20)), .init(cardID: b.id, point: .init(x: 200, y: 20))], edges: [.init(from: a.id, to: b.id, label: "supports")])
    try await store.performKnowledge(.saveBoard(board))
    try await store.performKnowledge(.removeCard(a.id))
    var changed = b; changed.comment = "Concurrent edit remains"
    try await store.performKnowledge(.saveCard(changed))
    try await store.performKnowledge(.placeNode(board: board.id, node: .init(cardID: b.id, point: .init(x: 999, y: 55), cluster: "Practice")))
    try await store.performKnowledge(.restoreCard(a, boards: [board]))
    let fresh = LibraryStore(root: await store.root), memory = try await fresh.knowledge()
    #expect(memory.cards.count == 2)
    #expect(memory.cards.first { $0.id == b.id }?.comment == "Concurrent edit remains")
    #expect(memory.boards[0].edges == board.edges)
    #expect(memory.boards[0].nodes.first { $0.id == b.id }?.point.x == 999)
    let export = try memory.encoded(), decoded = try JSONDecoder().decode(KnowledgeSnapshot.self, from: export)
    #expect(decoded == memory)
    #expect(memory.markdown().contains("AdaptiveSourceAnchor:") && memory.markdown().contains("supports"))
    let original = try knowledgeFixture("text.pdf")
    #expect((try await fresh.openBook(book.id)).1 == original)
}
@Test func knowledgeValidationRejectsBrokenGraphsVersionsAndSourcesAtomically() async throws {
    let store = knowledgeStore(), book = try await importKnowledgePDF(store), source = knowledgeSource(book)
    let card = KnowledgeCard(title: "Idea", kind: .readerNote, text: "Content", sources: [source])
    try await store.performKnowledge(.saveCard(card))
    let before = try await store.knowledge()
    let bad = KnowledgeBoard(title: "Broken", nodes: [.init(cardID: UUID(), point: .init(x: 0, y: 0))])
    await #expect(throws: ReaderError.invalidAnchor) { try await store.performKnowledge(.saveBoard(bad)) }
    let badPoint = KnowledgeBoard(title: "Infinite", nodes: [.init(cardID: card.id, point: .init(x: .infinity, y: 0))])
    await #expect(throws: ReaderError.invalidAnchor) { try await store.performKnowledge(.saveBoard(badPoint)) }
    let changed = KnowledgeSource(anchor: .init(bookID: book.id, sourceRevision: String(repeating: "0", count: 64), position: source.anchor.position), bookTitle: book.title, location: source.location, quotation: source.quotation)
    await #expect(throws: ReaderError.sourceChanged) { try await store.performKnowledge(.saveCard(.init(title: "Wrong revision", kind: .quotation, text: "Text", sources: [changed]))) }
    #expect(try await store.knowledge() == before)
    let data = try before.encoded(), object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var future = object; future["schemaVersion"] = 999
    let decoded = try JSONDecoder().decode(KnowledgeSnapshot.self, from: JSONSerialization.data(withJSONObject: future))
    #expect(throws: ReaderError.unsupportedAnchorVersion) { try decoded.validate() }
}
@Test func portableKnowledgeKeepsUserEditsAndUnavailableSourcesExplicit() async throws {
    let store = knowledgeStore(), book = try await importKnowledgePDF(store), source = knowledgeSource(book)
    var card = KnowledgeCard(title: "Original", kind: .quotation, text: source.quotation, sources: [source])
    let archive = KnowledgeSnapshot(cards: [card])
    try await store.performKnowledge(.saveCard(card)); card.comment = "Edited locally"; try await store.performKnowledge(.saveCard(card))
    try await store.performKnowledge(.merge(archive))
    #expect(try await store.knowledge().cards[0].comment == "Edited locally")
    let elsewhere = knowledgeStore(); try await elsewhere.performKnowledge(.merge(archive))
    #expect(try await elsewhere.knowledge().cards[0].sources == [source])
    await #expect(throws: (any Error).self) { try await elsewhere.openBook(source.anchor.bookID) }
}
@Test func crossBookIndexFiltersSourceIdentityAndCancellation() async throws {
    let store = knowledgeStore(), first = try await importKnowledgePDF(store, title: "First book"), second = try await importKnowledgePDF(store, title: "Second book")
    try await store.performKnowledge(.metadata(.init(bookID: first.id, author: "Author A", collection: "Research")))
    let index = KnowledgeSearchIndex(store: store)
    let (passages, _) = try await index.passages(for: first), passage = try #require(passages.first)
    #expect(try await store.cachedKnowledgePassages(for: first) != nil)
    try await store.invalidateKnowledgeCache(for: first)
    #expect(try await store.cachedKnowledgePassages(for: first) == nil)
    _ = try await index.passages(for: first)
    let query = String(passage.text.split(whereSeparator: { !$0.isLetter }).first(where: { $0.count > 3 }) ?? "Adaptive")
    let result = try await index.search(query)
    #expect(Set(result.hits.map { $0.source.anchor.bookID }) == [first.id, second.id])
    #expect(Set(result.hits.map(\.id)).count == result.hits.count)
    let filtered = try await index.search(query, filter: .init(author: "Author A", collection: "Research"))
    #expect(Set(filtered.hits.map { $0.source.anchor.bookID }) == [first.id])
    let task = Task { try await index.search(query) }; task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let root = await store.root, asset = root.appendingPathComponent("Assets/" + second.assetName), moved = root.appendingPathComponent("TemporarilyUnavailable.pdf")
    try await store.saveNote(.init(anchor: knowledgeSource(second).anchor, text: query + " my saved thought", quotation: "A saved quote"), for: second)
    try FileManager.default.moveItem(at: asset, to: moved)
    let partial = try await index.search(query)
    #expect(!partial.issues.isEmpty && partial.hits.filter { $0.kind == .quotation }.allSatisfy { $0.source.anchor.bookID == first.id })
    #expect(partial.hits.contains { $0.kind == .readerNote && $0.source.anchor.bookID == second.id })
    try FileManager.default.moveItem(at: moved, to: asset)
}
@Test @MainActor func librarySourceCommandsCrossFormatsReopenAndPaths() async throws {
    let store = knowledgeStore(), pdf = try await importKnowledgePDF(store), epubData = try knowledgeFixture("EPUB/reflow.epub")
    let epub = try await store.importBook(data: epubData, id: UUID(), title: "Memory EPUB", revision: PDFReaderEngine.revision(epubData), format: .epub)
    let index = KnowledgeSearchIndex(store: store)
    let (epubPassages, _) = try await index.passages(for: epub), passage = try #require(epubPassages.first)
    let hit = KnowledgeSearchIndex.hit(passage, book: epub)
    var path = KnowledgeSearchIndex.suggestPath(goal: "Read both", hits: [hit, hit, .init(id: "pdf", source: knowledgeSource(pdf), kind: .quotation, text: "PDF")])
    #expect(path.steps.count == 2)
    path.steps.swapAt(0, 1); path.steps[0].completed = true; path.goal = "My edited route"
    try await store.performKnowledge(.savePath(path))
    #expect(try await store.knowledge().paths[0] == path)
    let engine = EPUBReaderEngine(publication: try EPUBPublication(data: epubData), bookID: epub.id, revision: epub.revision)
    defer { engine.stop() }
    let commands = ReaderCommands(engine: engine); try commands.perform(.navigate(hit.source.anchor))
    try await store.save(.init(anchor: try engine.currentAnchor(), palette: .paper, scale: 1), for: epub)
    #expect((try await store.openBook(epub.id)).2?.anchor == hit.source.anchor)
    let timeline = try await index.timeline(for: epub, memory: KnowledgeSnapshot())
    #expect(!timeline.isEmpty && timeline.allSatisfy { $0.source.anchor.bookID == epub.id })
}
@Test func libraryAnswersRequireBothSourcesAndNoExecutableActions() throws {
    let a = SourceAnchor(bookID: UUID(), sourceRevision: String(repeating: "a", count: 64), position: .pdf(.init(pageIndex: 0, x: 0, y: 100)))
    let b = SourceAnchor(bookID: UUID(), sourceRevision: String(repeating: "b", count: 64), position: .pdf(.init(pageIndex: 0, x: 0, y: 100)))
    let sources = [EvidencePassage(id: "a", anchor: a, text: "First author's words"), EvidencePassage(id: "b", anchor: b, text: "Second author's words")]
    try CompanionAnswer(kind: .book, answer: "A comparison", sourceIDs: ["a", "b"]).validateLibrary(sources: sources, comparing: true)
    #expect(throws: CompanionError.invalidEvidence) { try CompanionAnswer(kind: .book, answer: "Unsupported comparison", sourceIDs: ["a"]).validateLibrary(sources: sources, comparing: true) }
    #expect(throws: CompanionError.invalidResponse) { try CompanionAnswer(kind: .book, answer: "An action", sourceIDs: ["a", "b"], actions: [.init(kind: .setFocus, enabled: true)]).validateLibrary(sources: sources, comparing: true) }
    let messages = try CompanionRequest(question: "Compare", title: "Library", page: nil, sources: sources, scope: .library).messages
    #expect(messages[0]["content"]?.contains("multi-book") == true)
}

@Test func canvasViewportCullsOffscreenCardsAndKeepsConnectionsAndDragAligned() throws {
    let book = BookRecord(id: UUID(), title: "Test", revision: String(repeating: "a", count: 64), source: .managed(name: "unused.pdf"))
    let source = knowledgeSource(book)
    let cards = (0..<1000).map { KnowledgeCard(title: "Card \($0)", kind: .quotation, text: "Text", sources: [source]) }
    let nodes = cards.enumerated().map { CanvasNode(cardID: $0.element.id, point: .init(x: Double($0.offset % 20) * 300, y: Double($0.offset / 20) * 210)) }
    let edge = CanvasEdge(from: cards[0].id, to: cards[1].id, label: "Related")
    let board = KnowledgeBoard(title: "Large board", nodes: nodes, edges: [edge])
    let layout = KnowledgeCanvasLayout(board: board, cards: cards, origin: .init(x: 0, y: 0), zoom: 1, viewport: .init(x: 800, y: 560), translations: [cards[0].id: .init(x: 30, y: 40)])
    #expect(layout.visibleNodes.count < 15)
    #expect(layout.connections.first?.start == layout.centers[cards[0].id])
    #expect(layout.centers[cards[0].id] == .init(x: 155, y: 115))
    let filtered = KnowledgeCanvasLayout(board: board, cards: cards, origin: .init(x: 0, y: 0), zoom: 1, viewport: .init(x: 800, y: 560), query: "Card 0")
    #expect(!filtered.visibleNodes.isEmpty)
}

@Test func librarySearchDisclosesImageOnlyAndLockedSources() async throws {
    let store = knowledgeStore()
    let image = try knowledgeFixture("EPUB/image-only.epub")
    let book = try await store.importBook(data: image, id: UUID(), title: "Image-only EPUB", revision: PDFReaderEngine.revision(image), format: .epub)
    let locked = try knowledgeFixture("protected.pdf")
    _ = try await store.importBook(data: locked, id: UUID(), title: "Locked PDF", revision: PDFReaderEngine.revision(locked))
    let index = KnowledgeSearchIndex(store: store)
    await #expect(throws: CompanionError.noText) { try await index.passages(for: book) }
    let result = try await index.search("stable")
    #expect(result.hits.isEmpty)
    #expect(result.issues.contains { $0.contains("Image-only EPUB") })
    #expect(result.issues.contains { $0.contains("Locked PDF") })
}
