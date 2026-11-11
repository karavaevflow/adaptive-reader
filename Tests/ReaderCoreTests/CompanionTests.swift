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
