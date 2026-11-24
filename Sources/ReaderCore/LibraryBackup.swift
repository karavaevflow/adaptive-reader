import Foundation
import CryptoKit
import Darwin
import ZIPFoundation

public enum LibraryBackupError: Error, LocalizedError {
    case invalidArchive, unsupportedVersion, limitExceeded, libraryNotEmpty, outputExists, unsupportedLayout, backupInsideLibrary
    public var errorDescription: String? {
        switch self {
        case .backupInsideLibrary: "Save the backup outside the library folder."
        case .invalidArchive: "The library backup is damaged or incomplete. Current files were kept."
        case .unsupportedVersion: "This library backup needs a newer version of Adaptive Reader."
        case .limitExceeded: "The backup exceeds the supported size or file-count limits."
        case .libraryNotEmpty: "Restore is available only for an empty library. Existing books and reader data were kept."
        case .outputExists: "Choose a new backup filename. Existing archives are not replaced."
        case .unsupportedLayout: "The library contains an unsupported file layout. Keep a separate folder backup."
        }
    }
}
private struct BackupEntry: Codable {
    let path: String
    let bytes: UInt64
    let sha256: String
}
private struct BackupManifest: Codable {
    let schemaVersion: Int
    let entries: [BackupEntry]
}
private enum BackupLayout {
    static let manifest = "AdaptiveLibrary.json"
    static let maxTotal: UInt64 = 8 * 1024 * 1024 * 1024
    static let ignored: Set<String> = ["Cache", "AISettings.json", "AmbientDefaults.json", "Phase0Tests", "ComfortDiagnostics.json", ".DS_Store"]
    static func allowed(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts == ["LastBook"] { return true }
        if parts == ["Knowledge", "Memory.json"] || parts == ["ExtendedReading", "Memory.json"] { return true }
        guard parts.count == 2, let dot = parts[1].lastIndex(of: "."),
              let id = UUID(uuidString: String(parts[1][..<dot])), id.uuidString == String(parts[1][..<dot]) else { return false }
        let suffix = String(parts[1][parts[1].index(after: dot)...])
        if parts[0] == "Assets" { return suffix == "pdf" || suffix == "epub" }
        return ["Books", "ReadingState", "Annotations", "Comfort", "Notes", "Study"].contains(parts[0]) && suffix == "json"
    }
    static func validate(_ entry: BackupEntry) throws {
        guard allowed(entry.path), entry.sha256.count == 64, entry.sha256.allSatisfy(\.isHexDigit) else { throw LibraryBackupError.invalidArchive }
        let limit: UInt64 = entry.path.hasPrefix("Assets/") ? 2 * 1024 * 1024 * 1024 : 48 * 1024 * 1024
        guard entry.bytes <= limit else { throw LibraryBackupError.limitExceeded }
    }
    static func files(_ root: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard try FileManager.default.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory,
              let iterator = FileManager.default.enumerator(atPath: root.path) else { throw LibraryBackupError.unsupportedLayout }
        var result: [String] = []
        for case let relative as String in iterator {
            if relative.split(separator: "/").last == ".DS_Store" || ignored.contains(relative.split(separator: "/").first.map(String.init) ?? "") {
                iterator.skipDescendants(); continue
            }
            let type = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path)[.type] as? FileAttributeType
            if type == .typeDirectory { continue }
            guard type == .typeRegular, allowed(relative) else { throw LibraryBackupError.unsupportedLayout }
            result.append(relative)
            guard result.count <= 100_000 else { throw LibraryBackupError.limitExceeded }
        }
        return result.sorted()
    }
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 65536), !data.isEmpty { try Task.checkCancellation(); digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension LibraryStore {
    /// A point-in-time snapshot under the store actor. Managed sources and reader
    /// data are included; caches, provider settings and external originals are not.
    /// Export never replaces an existing file.
    public func writeLibraryBackup(to destination: URL) throws {
        try Task.checkCancellation()
        guard destination.isFileURL else { throw LibraryBackupError.unsupportedLayout }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let selected = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard selected != base && !selected.hasPrefix(base + "/") else { throw LibraryBackupError.backupInsideLibrary }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LibraryBackupError.outputExists }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Adaptive-Backup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let zip = temporary.appendingPathComponent("Library.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        var entries: [BackupEntry] = [], total: UInt64 = 0
        var assetHashes: [String: String] = [:]
        let paths = try BackupLayout.files(root)
        for path in paths {
            try Task.checkCancellation()
            let file = root.appendingPathComponent(path)
            let size = UInt64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard size <= BackupLayout.maxTotal - total else { throw LibraryBackupError.limitExceeded }
            try BackupLayout.validate(.init(path: path, bytes: size, sha256: String(repeating: "0", count: 64)))
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            var digest = SHA256(), read: Int64 = 0
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(size), compressionMethod: .deflate) { position, count in
                try Task.checkCancellation()
                guard position == read else { throw LibraryBackupError.invalidArchive }
                let data = try handle.read(upToCount: count) ?? Data()
                guard data.count == count else { throw LibraryBackupError.invalidArchive }
                digest.update(data: data); read += Int64(data.count); return data
            }
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            entries.append(.init(path: path, bytes: size, sha256: hash)); total += size
            if path.hasPrefix("Assets/") { assetHashes[path] = hash }
        }
        for path in paths where path.hasPrefix("Books/") {
            let record = try JSONDecoder().decode(BookRecord.self, from: Data(contentsOf: root.appendingPathComponent(path)))
            guard path == "Books/\(record.id.uuidString).json" else { throw LibraryBackupError.invalidArchive }
            if case .managed(let name) = record.source {
                guard name == "\(record.id.uuidString).\(record.format.rawValue)", assetHashes["Assets/" + name] == record.revision else { throw ReaderError.sourceChanged }
            }
        }
        let manifest = try JSONEncoder().encode(BackupManifest(schemaVersion: 1, entries: entries))
        guard manifest.count <= 16 * 1024 * 1024 else { throw LibraryBackupError.limitExceeded }
        try archive.addEntry(with: BackupLayout.manifest, type: .file, uncompressedSize: Int64(manifest.count), compressionMethod: .deflate) { offset, count in
            manifest.subdata(in: Int(offset)..<(Int(offset) + count))
        }
        // Exclusive creation and cancellable streaming protect an existing export.
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw LibraryBackupError.outputExists }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var own = stat(); let recordedIdentity = fstat(descriptor, &own) == 0
        var completed = false
        defer {
            try? output.close()
            if !completed {
                var current = stat()
                if recordedIdentity && lstat(destination.path, &current) == 0 && current.st_ino == own.st_ino && current.st_dev == own.st_dev { _ = unlink(destination.path) }
            }
        }
        let input = try FileHandle(forReadingFrom: zip); defer { try? input.close() }
        while let data = try input.read(upToCount: 65536), !data.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: data) }
        try output.synchronize(); completed = true
    }

    /// Validates into a sibling staging directory, then atomically exchanges whole
    /// directories. The old directory is retained, never deleted. No user records
    /// are overwritten or merged into a populated library.
    public func restoreLibraryBackup(from source: URL) async throws -> URL {
        try Task.checkCancellation()
        guard source.isFileURL else { throw LibraryBackupError.invalidArchive }
        guard try BackupLayout.files(root).isEmpty else { throw LibraryBackupError.libraryNotEmpty }
        guard (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 9 * 1024 * 1024 * 1024 else { throw LibraryBackupError.limitExceeded }
        let archive = try Archive(url: source, accessMode: .read)
        var zippedPaths = Set<String>(), manifestEntry: Entry?, zippedBytes: UInt64 = 0
        // Retain only short path strings, not all ZIP headers/comments. Entry
        // extraction below is a second linear scan, avoiding quadratic lookups.
        for item in archive {
            try Task.checkCancellation()
            guard item.type == .file, item.path.utf8.count <= 160, zippedPaths.insert(item.path).inserted,
                  zippedPaths.count <= 100_001 else { throw LibraryBackupError.invalidArchive }
            if item.path == BackupLayout.manifest {
                guard item.uncompressedSize <= 16 * 1024 * 1024 else { throw LibraryBackupError.limitExceeded }
                manifestEntry = item
            } else {
                try BackupLayout.validate(.init(path: item.path, bytes: item.uncompressedSize, sha256: String(repeating: "0", count: 64)))
                guard item.uncompressedSize <= BackupLayout.maxTotal - zippedBytes else { throw LibraryBackupError.limitExceeded }
                zippedBytes += item.uncompressedSize
            }
        }
        guard let entry = manifestEntry else { throw LibraryBackupError.invalidArchive }
        var data = Data()
        let crc = try archive.extract(entry) { chunk in
            try Task.checkCancellation()
            guard data.count + chunk.count <= 16 * 1024 * 1024 else { throw LibraryBackupError.limitExceeded }; data.append(chunk)
        }
        guard crc == entry.checksum else { throw LibraryBackupError.invalidArchive }
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: data)
        guard manifest.schemaVersion == 1 else { throw LibraryBackupError.unsupportedVersion }
        guard manifest.entries.count <= 100_000, Set(manifest.entries.map(\.path)).count == manifest.entries.count,
              zippedPaths == Set(manifest.entries.map(\.path) + [BackupLayout.manifest]) else { throw LibraryBackupError.invalidArchive }
        var total: UInt64 = 0
        for item in manifest.entries {
            try BackupLayout.validate(item)
            guard item.bytes <= BackupLayout.maxTotal - total else { throw LibraryBackupError.limitExceeded }
            total += item.bytes
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.deletingLastPathComponent().appendingPathComponent("AdaptiveReader-BeforeRestore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: stage) } }
        let expected = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.path, $0) })
        var extracted = Set<String>()
        for entry in archive {
            try Task.checkCancellation()
            guard extracted.insert(entry.path).inserted, zippedPaths.contains(entry.path) else { throw LibraryBackupError.invalidArchive }
            if entry.path == BackupLayout.manifest { continue }
            guard let item = expected[entry.path], entry.type == .file, entry.uncompressedSize == item.bytes else { throw LibraryBackupError.invalidArchive }
            let target = stage.appendingPathComponent(item.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw LibraryBackupError.invalidArchive }
            let handle = try FileHandle(forWritingTo: target); defer { try? handle.close() }
            var digest = SHA256(), count: UInt64 = 0
            let checksum = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard UInt64(chunk.count) <= item.bytes - count else { throw LibraryBackupError.invalidArchive }
                count += UInt64(chunk.count); digest.update(data: chunk); try handle.write(contentsOf: chunk)
            }
            guard count == item.bytes, checksum == entry.checksum, digest.finalize().map({ String(format: "%02x", $0) }).joined() == item.sha256 else { throw LibraryBackupError.invalidArchive }
        }
        guard extracted == zippedPaths else { throw LibraryBackupError.invalidArchive }
        let inspection = LibraryStore(root: stage), records = try await inspection.books()
        for book in records {
            if case .managed(let name) = book.source {
                guard try BackupLayout.hash(stage.appendingPathComponent("Assets/" + name)) == book.revision else { throw ReaderError.sourceChanged }
            }
            _ = try await inspection.readingState(for: book); _ = try await inspection.bookmarks(for: book)
            _ = try await inspection.notes(for: book); _ = try await inspection.study(for: book); _ = try await inspection.comfortPreferences(for: book)
        }
        _ = try await inspection.knowledge(); _ = try await inspection.extendedReading()
        if FileManager.default.fileExists(atPath: stage.appendingPathComponent("LastBook").path) {
            let id = try String(contentsOf: stage.appendingPathComponent("LastBook"), encoding: .utf8)
            guard records.contains(where: { $0.id.uuidString == id }) else { throw LibraryBackupError.invalidArchive }
        }
        // The actor may have serviced other calls while inspecting the staged store.
        guard try BackupLayout.files(root).isEmpty else { throw LibraryBackupError.libraryNotEmpty }
        for name in ["AISettings.json", "AmbientDefaults.json"] {
            let existing = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: existing.path) { try FileManager.default.copyItem(at: existing, to: stage.appendingPathComponent(name)) }
        }
        try Task.checkCancellation()
        guard renameatx_np(AT_FDCWD, root.path, AT_FDCWD, stage.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        committed = true
        return stage
    }
}
