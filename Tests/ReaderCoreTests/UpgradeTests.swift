import Foundation
import Testing
@testable import ReaderCore

private let upgradePDF = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!
private var frozenLibrary: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Research/Upgrade/v0.6/Library")
}
private func upgradeCopy() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Adaptive-Upgrade-" + UUID().uuidString)
    try FileManager.default.copyItem(at: frozenLibrary, to: root)
    return root
}
private func contents(_ root: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let files = FileManager.default.enumerator(atPath: root.path)!
    for case let relative as String in files {
        let url = root.appendingPathComponent(relative)
        if try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular {
            result[relative] = try Data(contentsOf: url)
        }
    }
    return result
}

@Test func completeV06LibrarySurvivesReopenWithoutRewritingReaderData() async throws {
    let root = try upgradeCopy()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = try contents(root), store = LibraryStore(root: root)
    let books = try await store.books()
    #expect(Set(books.map(\.format)) == [.pdf, .epub])
    for book in books {
        let (_, bytes, state) = try await store.openBook(book.id)
        #expect(PDFReaderEngine.revision(bytes) == book.revision)
        #expect(book.favorite && state?.palette == .forest)
        #expect(try await store.bookmarks(for: book).count == 1)
        #expect(try await store.notes(for: book).first?.text == "Сохранить мою заметку при обновлении")
        let study = try await store.study(for: book)
        #expect(study.cards.count == 1 && study.highlights.count == 1 && study.listen != nil)
        #expect(study.cards[0].question == "What must survive an update?")
        try #require(state?.anchor).validate(bookID: book.id, revision: book.revision)
    }
    let knowledge = try await store.knowledge(), extended = try await store.extendedReading()
    #expect(knowledge.cards.count == 2 && knowledge.boards[0].edges.count == 1 && knowledge.paths[0].steps.count == 2)
    #expect(extended.fragments[0].translation == "Учимся читать" && extended.vocabulary[0].meaning == "читать")
    #expect(extended.replayEnabled && extended.insightsEnabled && extended.events.count == 1 && extended.metrics[0].activeSeconds == 42)
    #expect(extended.splitPosition?.anchor.bookID != upgradePDF)
    #expect(try await store.companionSettings().mode == .off)
    #expect(try contents(root) == before)
    // A subsequent edit must still round-trip without replacing neighboring domains.
    let book = try await store.bookRecord(upgradePDF)
    var note = try #require(try await store.notes(for: book).first)
    note.text = "Изменение после обновления"
    try await store.saveNote(note, for: book)
    let fresh = LibraryStore(root: root)
    #expect(try await fresh.notes(for: book).first?.text == note.text)
    let after = try contents(root), edited = "Notes/\(upgradePDF.uuidString).json"
    #expect(before.filter { $0.key != edited } == after.filter { $0.key != edited })
}

@Test(arguments: [1, 2]) func earlierBookMetadataUpgradesWithoutLosingLaterReaderDomains(version: Int) async throws {
    let root = try upgradeCopy()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("Books/\(upgradePDF.uuidString).json")
    var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
    metadata["schemaVersion"] = version; metadata.removeValue(forKey: "format")
    if version == 1 { metadata.removeValue(forKey: "source"); metadata["assetName"] = "\(upgradePDF.uuidString).pdf" }
    try JSONSerialization.data(withJSONObject: metadata).write(to: path, options: .atomic)
    let before = try contents(root), store = LibraryStore(root: root)
    let (book, _, state) = try await store.openBook(upgradePDF)
    #expect(book.schemaVersion == 3 && book.favorite && book.title == "Upgrade PDF")
    #expect(state?.palette == .forest)
    #expect(try await store.notes(for: book).count == 1)
    #expect(try await store.study(for: book).cards.count == 1)
    #expect(try await store.knowledge().boards[0].edges.count == 1)
    #expect(try await store.extendedReading().vocabulary.count == 1)
    let after = try contents(root), changed = "Books/\(upgradePDF.uuidString).json"
    #expect(before.filter { $0.key != changed } == after.filter { $0.key != changed })
    let rewritten = try JSONSerialization.jsonObject(with: #require(after[changed])) as! [String: Any]
    #expect(rewritten["schemaVersion"] as? Int == 3)
}

@Test(arguments: ["Books", "Study", "Knowledge", "ExtendedReading"])
func unsupportedFutureDataRemainsIntactInsteadOfBeingReset(domain: String) async throws {
    let root = try upgradeCopy()
    defer { try? FileManager.default.removeItem(at: root) }
    let relative = ["Books", "Study"].contains(domain) ? "\(domain)/\(upgradePDF.uuidString).json" : "\(domain)/Memory.json"
    let path = root.appendingPathComponent(relative)
    var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
    metadata["schemaVersion"] = 99
    try JSONSerialization.data(withJSONObject: metadata).write(to: path, options: .atomic)
    let before = try contents(root), store = LibraryStore(root: root)
    await #expect(throws: ReaderError.unsupportedAnchorVersion) {
        switch domain {
        case "Books": _ = try await store.books()
        case "Study": _ = try await store.study(for: store.bookRecord(upgradePDF))
        case "Knowledge": _ = try await store.knowledge()
        default: _ = try await store.extendedReading()
        }
    }
    #expect(try contents(root) == before)
}
