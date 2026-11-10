import Foundation
import Testing
@testable import ReaderCore

private var sample: Data {
    get throws { try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Research/Fixtures/text.pdf")) }
}

@Test func foundationMetadataMigratesWithoutChangingAssetOrPosition() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = try sample, id = UUID(), revision = PDFReaderEngine.revision(data)
    let store = LibraryStore(root: root)
    let record = try await store.importBook(data: data, id: id, title: "Before upgrade", revision: revision)
    let anchor = SourceAnchor(bookID: id, sourceRevision: revision, position: .pdf(.init(pageIndex: 1, x: 0, y: 500)))
    try await store.save(ReadingState(anchor: anchor, palette: .forest, scale: 1.2), for: record)
    let old: [String: Any] = ["schemaVersion": 1, "id": id.uuidString, "title": "Before upgrade", "revision": revision, "assetName": "\(id.uuidString).pdf"]
    let metadata = root.appendingPathComponent("Books/\(id.uuidString).json")
    try JSONSerialization.data(withJSONObject: old).write(to: metadata)
    let (migrated, restored, state) = try #require(try await LibraryStore(root: root).lastBook())
    #expect(migrated.schemaVersion == 2)
    #expect(restored == data)
    #expect(state?.anchor == anchor)
    #expect(state?.palette == .forest)
    #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])?["schemaVersion"] as? Int == 2)
    #expect(try Data(contentsOf: root.appendingPathComponent("Assets/\(id.uuidString).pdf")) == data)
}

@Test func referenceImportAndBookmarksSurviveReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.pdf"), data = try sample
    try data.write(to: source)
    let bookmark = try source.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    let store = LibraryStore(root: root.appendingPathComponent("Library"))
    let record = try await store.importBook(data: data, id: UUID(), title: "Reference", revision: PDFReaderEngine.revision(data), reference: bookmark)
    #expect(record.isReference)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Library/Assets").path).isEmpty)
    let anchor = SourceAnchor(bookID: record.id, sourceRevision: record.revision, position: .pdf(.init(pageIndex: 2, x: 0, y: 600)))
    let mark = ReaderBookmark(anchor: anchor, title: "Passage")
    try await store.saveBookmarks([mark], for: record)
    try await store.setFavorite(true, for: record.id)
    let fresh = LibraryStore(root: root.appendingPathComponent("Library"))
    let (opened, bytes, _) = try await fresh.openBook(record.id)
    #expect(bytes == data)
    #expect(opened.favorite)
    #expect(try await fresh.bookmarks(for: opened) == [mark])
    try await fresh.setCurrentBook(nil)
    #expect(try await fresh.lastBook() == nil)
    #expect(try await fresh.books().count == 1)
    let moved = root.appendingPathComponent("moved.pdf")
    try FileManager.default.moveItem(at: source, to: moved)
    let (_, movedData, _) = try await fresh.openBook(record.id)
    #expect(movedData == data)
    try Data("modified".utf8).write(to: moved)
    await #expect(throws: ReaderError.sourceChanged) { try await fresh.openBook(record.id) }
}

@Test func awakeAssertionHasExplicitAndAutomaticLifetime() throws {
    let awake = DisplayAwake()
    #expect(!awake.isActive)
    try awake.setEnabled(true)
    #expect(awake.isActive)
    try awake.setEnabled(true)
    awake.release()
    #expect(!awake.isActive)
}

@Test func bookmarkMutationsMergeOnTheSharedStore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(root: root), data = try sample
    let record = try await store.importBook(data: data, id: UUID(), title: "Book", revision: PDFReaderEngine.revision(data))
    let first = SourceAnchor(bookID: record.id, sourceRevision: record.revision, position: .pdf(.init(pageIndex: 0, x: 0, y: 600)))
    let second = SourceAnchor(bookID: record.id, sourceRevision: record.revision, position: .pdf(.init(pageIndex: 2, x: 0, y: 600)))
    async let a = store.toggleBookmark(anchor: first, title: "First", for: record)
    async let b = store.toggleBookmark(anchor: second, title: "Second", for: record)
    _ = try await (a, b)
    let marks = try await store.bookmarks(for: record)
    #expect(marks.count == 2)
    let remaining = try await store.removeBookmark(marks[0].id, for: record)
    #expect(remaining.count == 1)
    #expect(remaining[0].id == marks[1].id)
}

@Test func bookmarkWriterRejectsAnotherSourceRevision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(root: root), data = try sample
    let record = try await store.importBook(data: data, id: UUID(), title: "Book", revision: PDFReaderEngine.revision(data))
    let wrong = SourceAnchor(bookID: record.id, sourceRevision: "different", position: .pdf(.init(pageIndex: 0, x: 0, y: 100)))
    await #expect(throws: ReaderError.sourceChanged) { try await store.toggleBookmark(anchor: wrong, title: "Wrong", for: record) }
    #expect(try await store.bookmarks(for: record).isEmpty)
}
