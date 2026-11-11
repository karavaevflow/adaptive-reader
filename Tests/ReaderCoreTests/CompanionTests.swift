import Foundation
import Testing
@testable import ReaderCore

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Research/Fixtures/\(name).pdf"))
}

@Test func evidenceRetrievalSurvivesCacheAndRejectsAnotherRevision() async throws {
    let data = try fixture("text"), id = UUID(), revision = PDFReaderEngine.revision(data)
    let index = try await PDFEvidenceIndex.build(data: data, bookID: id, revision: revision)
    let restored = try JSONDecoder().decode(PDFEvidenceIndex.self, from: JSONEncoder().encode(index))
    try restored.validate(bookID: id, revision: revision)
    let evidence = try restored.retrieve("reading", visiblePage: 0)
    #expect(!evidence.isEmpty)
    #expect(evidence.allSatisfy { $0.anchor.bookID == id && $0.text.count <= 1400 })
    #expect(throws: CompanionError.invalidEvidence) { try restored.validate(bookID: id, revision: "changed") }
    #expect(throws: CompanionError.invalidEvidence) { try CompanionAnswer(kind: .book, answer: "Invented", sourceIDs: ["fake"]).validate(sources: evidence, pageCount: 3) }
    try CompanionAnswer(kind: .book, answer: "Grounded", sourceIDs: [evidence[0].id]).validate(sources: evidence, pageCount: 3)
}

@Test func scanHasNoInventedEvidenceAndIndexCancellationPropagates() async throws {
    let data = try fixture("scan")
    await #expect(throws: CompanionError.noText) { try await PDFEvidenceIndex.build(data: data, bookID: UUID(), revision: PDFReaderEngine.revision(data)) }
    let task = Task { try await PDFEvidenceIndex.build(data: fixture("text"), bookID: UUID(), revision: PDFReaderEngine.revision(fixture("text"))) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func rareEvidenceOutranksRepeatedCommonQueryWords() throws {
    let id = UUID(), revision = String(repeating: "a", count: 64)
    let texts = [String(repeating: "reading ", count: 100), "rareterm explains this reading", "reading about another topic"]
    let passages = texts.enumerated().map { index, text in
        EvidencePassage(id: String(repeating: String(index + 1), count: 24),
            anchor: .init(bookID: id, sourceRevision: revision, position: .pdf(.init(pageIndex: index, x: 0, y: 600))), text: text)
    }
    let index = PDFEvidenceIndex(schemaVersion: 1, bookID: id, revision: revision, pageCount: 3, passages: passages, truncated: false)
    #expect(try index.retrieve("please explain rareterm reading", visiblePage: 0).first?.id == passages[1].id)
}

@Test func cloudConsentIsDestinationSpecificAndLocalCannotSendRemotely() throws {
    var value = CompanionSettings(); value.mode = .local; value.model = "test-model"
    _ = try value.validatedURL()
    value.endpoint = "http://example.com/api/chat"
    #expect(throws: CompanionError.configuration) { try value.validatedURL() }
    value.mode = .cloud; value.endpoint = "https://example.com/v1/chat/completions"
    #expect(throws: CompanionError.consentRequired) { try value.validatedURL() }
    value.consentDestination = value.destination; _ = try value.validatedURL()
    value.model = "another-model"
    #expect(throws: CompanionError.consentRequired) { try value.validatedURL() }
    value.endpoint = "https://user:secret@example.com/v1/chat/completions"
    #expect(throws: CompanionError.configuration) { try value.validatedURL() }
}

@Test func providerFramesDistinguishCompletionTruncationAndErrors() throws {
    let local = try CompanionHTTPProvider.decodeLine(Data(#"{"message":{"content":"hello"},"done":true}"#.utf8), mode: .local)
    #expect(local.text == "hello" && local.done)
    let cloud = try CompanionHTTPProvider.decodeLine(Data(#"data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}"#.utf8), mode: .cloud)
    #expect(cloud.text == "hello" && !cloud.done)
    #expect(try CompanionHTTPProvider.decodeLine(Data("data: [DONE]".utf8), mode: .cloud).done)
    #expect(throws: CompanionError.invalidResponse) { try CompanionHTTPProvider.decodeLine(Data(#"data: {"choices":[{"finish_reason":"length"}]}"#.utf8), mode: .cloud) }
    #expect(throws: CompanionError.invalidResponse) { try CompanionHTTPProvider.decodeLine(Data(#"{"error":"unavailable"}"#.utf8), mode: .local) }
}

@Test func notesPersistAndUndoWithoutChangingSourceBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = try fixture("text"), id = UUID(), revision = PDFReaderEngine.revision(data), store = LibraryStore(root: root)
    let record = try await store.importBook(data: data, id: id, title: "Notes", revision: revision)
    let anchor = SourceAnchor(bookID: id, sourceRevision: revision, position: .pdf(.init(pageIndex: 0, x: 0, y: 600)))
    let note = ReaderNote(anchor: anchor, text: "A reader note", quotation: "Source evidence")
    try await store.saveNote(note, for: record)
    #expect(try await LibraryStore(root: root).notes(for: record) == [note])
    try await store.removeNote(note.id, for: record)
    #expect(try await store.notes(for: record).isEmpty)
    #expect(try await store.openBook(id).1 == data)
}

@Test func companionCacheIsDisposableWhileSettingsAndNotesPersist() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(root: root), data = try fixture("text"), id = UUID(), revision = PDFReaderEngine.revision(data)
    let record = try await store.importBook(data: data, id: id, title: "Cache", revision: revision)
    let index = try await PDFEvidenceIndex.build(data: data, bookID: id, revision: revision)
    try await store.cacheEvidence(index)
    var settings = CompanionSettings(); settings.mode = .cloud; settings.endpoint = "https://fixture.example/v1/chat/completions"
    settings.model = "fixture"; settings.consentDestination = settings.destination
    try await store.saveCompanionSettings(settings)
    let note = ReaderNote(anchor: index.passages[0].anchor, text: "Reader data", quotation: index.passages[0].text)
    try await store.saveNote(note, for: record)
    let reopened = LibraryStore(root: root)
    #expect(try await reopened.cachedEvidence(bookID: id, revision: revision)?.passages == index.passages)
    let cache = root.appendingPathComponent("Cache/AI/\(id.uuidString)-\(revision).json")
    try Data("corrupted cache".utf8).write(to: cache)
    #expect(try await reopened.cachedEvidence(bookID: id, revision: revision) == nil)
    try await reopened.clearEvidence(bookID: id, revision: revision)
    #expect(try await reopened.companionSettings() == settings)
    #expect(try await reopened.notes(for: record) == [note])
    #expect(try await reopened.openBook(id).1 == data)
}

@Test func companionRequestRetainsEpubLocatorWithoutInventingPageNumbers() throws {
    let anchor = SourceAnchor(bookID: UUID(), sourceRevision: "revision", position: .epub(resource: "chapter.xhtml", locator: "text=stable"))
    let source = EvidencePassage(id: "epub-evidence", anchor: anchor, text: "A reflowed passage")
    let request = CompanionRequest(question: "Explain", title: "EPUB", page: nil, sources: [source], chapter: "Chapter")
    let content = try #require(try request.messages.last?["content"])
    #expect(content.contains("Format: EPUB"))
    #expect(content.contains("Visible page: reflowed source"))
    try CompanionAnswer(kind: .book, answer: "Evidence", sourceIDs: [source.id], actions: [.init(kind: .navigateToPassage, sourceID: source.id)]).validate(sources: [source], pageCount: 0)
    #expect(throws: ReaderError.invalidAnchor) { try CompanionAction(kind: .goToPage, page: 1).validate(pageCount: 0, sources: [source]) }
}

@Test func protectedEvidenceRequiresUnlockRatherThanClaimingMissingOcr() async throws {
    let data = try fixture("protected")
    await #expect(throws: ReaderError.lockedDocument) {
        try await PDFEvidenceIndex.build(data: data, bookID: UUID(), revision: PDFReaderEngine.revision(data))
    }
}

@Test func cancellingAnActiveIndexDoesNotReturnPartialEvidence() async throws {
    let data = try fixture("../Large/large-text"), revision = PDFReaderEngine.revision(data)
    let gate = AsyncStream<Int>.makeStream()
    let worker = Task {
        defer { gate.continuation.finish() }
        return try await PDFEvidenceIndex.build(data: data, bookID: UUID(), revision: revision) { count, _ in
            if count == 1 { gate.continuation.yield(count) }
        }
    }
    for await _ in gate.stream { worker.cancel(); break }
    await #expect(throws: CancellationError.self) { try await worker.value }
}

@Test func revokedCloudConsentCannotAuthorizeAnOlderWindowSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = LibraryStore(root: root), second = LibraryStore(root: root)
    var value = CompanionSettings(); value.mode = .cloud; value.endpoint = "https://fixture.example/v1/chat/completions"
    value.model = "fixture"; value.consentDestination = value.destination
    try await first.saveCompanionSettings(value)
    try await second.authorizeCompanion(value)
    var revoked = value; revoked.mode = .off; revoked.consentDestination = nil
    try await first.saveCompanionSettings(revoked)
    await #expect(throws: CompanionError.consentRequired) { try await second.authorizeCompanion(value) }
    await #expect(throws: CompanionError.configuration) { try await second.authorizeCompanion(revoked) }
}
