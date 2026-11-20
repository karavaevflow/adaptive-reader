import Foundation
import Testing
import ZIPFoundation
@testable import ReaderCore

private var backupFixture: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Research/Upgrade/v0.6/Library")
}
private func backupFiles(_ root: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    guard let iterator = FileManager.default.enumerator(atPath: root.path) else { return [:] }
    for case let name as String in iterator {
        let file = root.appendingPathComponent(name)
        if try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular { files[name] = try Data(contentsOf: file) }
    }
    return files
}
@Test func completeLibraryBackupRoundTripsAndKeepsLocalConsentAndPreviousFolder() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackupTest-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("Source"), target = directory.appendingPathComponent("Target"), zip = directory.appendingPathComponent("Backup.zip")
    try FileManager.default.copyItem(at: backupFixture, to: source)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("Cache"), withIntermediateDirectories: true)
    try Data("private cache".utf8).write(to: source.appendingPathComponent("Cache/Sentinel"))
    try Data("excluded provider configuration".utf8).write(to: source.appendingPathComponent("AISettings.json"))
    let before = try backupFiles(source)
    await #expect(throws: LibraryBackupError.backupInsideLibrary) { try await LibraryStore(root: source).writeLibraryBackup(to: source.appendingPathComponent("nested.zip")) }
    try await LibraryStore(root: source).writeLibraryBackup(to: zip)
    #expect(try backupFiles(source) == before)
    let archive = try Archive(url: zip, accessMode: .read)
    #expect(archive["AISettings.json"] == nil && archive["Cache/Sentinel"] == nil)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let localConsent = try JSONEncoder().encode(CompanionSettings())
    try localConsent.write(to: target.appendingPathComponent("AISettings.json"))
    let store = LibraryStore(root: target), previous = try await store.restoreLibraryBackup(from: zip)
    #expect(FileManager.default.fileExists(atPath: previous.path))
    #expect(try Data(contentsOf: previous.appendingPathComponent("AISettings.json")) == localConsent)
    #expect(try Data(contentsOf: target.appendingPathComponent("AISettings.json")) == localConsent)
    let oldFiles = try backupFiles(backupFixture), restored = try backupFiles(target)
    #expect(oldFiles.allSatisfy { restored[$0.key] == $0.value })
    #expect(try await store.books().count == 2)
    #expect(try await store.knowledge().boards[0].edges.count == 1)
    #expect(try await store.extendedReading().vocabulary.count == 1)
    await #expect(throws: LibraryBackupError.libraryNotEmpty) { try await store.restoreLibraryBackup(from: zip) }
    await #expect(throws: LibraryBackupError.outputExists) { try await store.writeLibraryBackup(to: zip) }
    #expect(try backupFiles(target) == restored)
}

private func artificialBackup(_ zip: URL, path: String, payload: Data, schema: Int = 1, wrongHash: Bool = false, type: Entry.EntryType = .file, bytes: UInt64? = nil) throws {
    let archive = try Archive(url: zip, accessMode: .create)
    try archive.addEntry(with: path, type: type, uncompressedSize: Int64(payload.count)) { offset, size in payload.subdata(in: Int(offset)..<(Int(offset) + size)) }
    let manifest: [String: Any] = ["schemaVersion": schema, "entries": [["path": path, "bytes": bytes ?? UInt64(payload.count), "sha256": wrongHash ? String(repeating: "0", count: 64) : PDFReaderEngine.revision(payload)]]]
    let data = try JSONSerialization.data(withJSONObject: manifest)
    try archive.addEntry(with: "AdaptiveLibrary.json", type: .file, uncompressedSize: Int64(data.count)) { offset, size in data.subdata(in: Int(offset)..<(Int(offset) + size)) }
}
@Test(arguments: ["traversal", "symlink", "checksum", "future", "quota"])
func unsafeLibraryArchivesCannotChangeCurrentFiles(kind: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackupReject-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("Target"), zip = directory.appendingPathComponent("Input.zip")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("retain local settings".utf8).write(to: root.appendingPathComponent("AISettings.json"))
    let path = kind == "traversal" ? "../Escape" : "Books/B0000000-0000-4000-8000-000000000001.json"
    try artificialBackup(zip, path: path, payload: Data("{}".utf8), schema: kind == "future" ? 99 : 1,
                         wrongHash: kind == "checksum", type: kind == "symlink" ? .symlink : .file,
                         bytes: kind == "quota" ? UInt64(64 * 1024 * 1024) : nil)
    let before = try backupFiles(root)
    await #expect(throws: LibraryBackupError.self) { try await LibraryStore(root: root).restoreLibraryBackup(from: zip) }
    #expect(try backupFiles(root) == before)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Escape").path))
}
@Test func cancelledLibraryBackupNeverPublishesAnArchive() async throws {
    let zip = FileManager.default.temporaryDirectory.appendingPathComponent("Cancelled-" + UUID().uuidString + ".zip")
    let store = LibraryStore(root: backupFixture)
    let operation = Task {
        while !Task.isCancelled { await Task.yield() }
        try await store.writeLibraryBackup(to: zip)
    }
    operation.cancel()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(!FileManager.default.fileExists(atPath: zip.path))
}

@Test func futureReaderRecordsInBackupCannotReplaceAnEmptyDestination() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BackupFuture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("Source"), target = folder.appendingPathComponent("Target"), zip = folder.appendingPathComponent("Future.zip")
    try FileManager.default.copyItem(at: backupFixture, to: source)
    let record = source.appendingPathComponent("Study/B0000000-0000-4000-8000-000000000001.json")
    var data = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as! [String: Any]
    data["schemaVersion"] = 99
    try JSONSerialization.data(withJSONObject: data).write(to: record, options: .atomic)
    try await LibraryStore(root: source).writeLibraryBackup(to: zip)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let settings = try JSONEncoder().encode(CompanionSettings())
    try settings.write(to: target.appendingPathComponent("AISettings.json"))
    let before = try backupFiles(target)
    await #expect(throws: ReaderError.unsupportedAnchorVersion) { try await LibraryStore(root: target).restoreLibraryBackup(from: zip) }
    #expect(try backupFiles(target) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix("AdaptiveReader-BeforeRestore-") })
}
