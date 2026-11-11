import Foundation

extension LibraryStore {
    public func companionSettings() throws -> CompanionSettings {
        let path = root.appendingPathComponent("AISettings.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return CompanionSettings() }
        let value = try JSONDecoder().decode(CompanionSettings.self, from: Data(contentsOf: path))
        guard value.schemaVersion == 1 else { throw ReaderError.unsupportedAnchorVersion }
        return value
    }
    public func saveCompanionSettings(_ value: CompanionSettings) throws {
        guard value.schemaVersion == 1, value.endpoint.count <= 2000, value.model.count <= 200 else { throw CompanionError.configuration }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent("AISettings.json"), options: .atomic)
    }
    private func evidenceURL(bookID: UUID, revision: String) throws -> URL {
        guard revision.count == 64, revision.allSatisfy({ $0.isHexDigit }) else { throw CompanionError.invalidEvidence }
        return root.appendingPathComponent("Cache/AI/\(bookID.uuidString)-\(revision).json")
    }
    public func cachedEvidence(bookID: UUID, revision: String) throws -> PDFEvidenceIndex? {
        let url = try evidenceURL(bookID: bookID, revision: revision)
        guard FileManager.default.fileExists(atPath: url.path),
              (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 40 * 1024 * 1024 else { return nil }
        guard let value = try? JSONDecoder().decode(PDFEvidenceIndex.self, from: Data(contentsOf: url)),
              (try? value.validate(bookID: bookID, revision: revision)) != nil else { return nil }
        return value
    }
    public func cacheEvidence(_ index: PDFEvidenceIndex) throws {
        try index.validate(bookID: index.bookID, revision: index.revision)
        let url = try evidenceURL(bookID: index.bookID, revision: index.revision)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: url, options: .atomic)
    }
    public func clearEvidence(bookID: UUID, revision: String) throws {
        let url = try evidenceURL(bookID: bookID, revision: revision)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
