import Foundation

public struct ReaderNote: Codable, Sendable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public let anchor: SourceAnchor
    public var text: String
    public let quotation: String
    public let createdAt: Date
    public init(anchor: SourceAnchor, text: String, quotation: String) {
        schemaVersion = 1; id = UUID(); self.anchor = anchor; self.text = text
        self.quotation = quotation; createdAt = Date()
    }
    public func validate(for record: BookRecord) throws {
        guard schemaVersion == 1, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 8000, quotation.count <= 1600 else { throw ReaderError.unsupportedCommand }
        try anchor.validate(bookID: record.id, revision: record.revision)
    }
}

extension LibraryStore {
    public func notes(for record: BookRecord) throws -> [ReaderNote] {
        try verifyRecord(record)
        let url = root.appendingPathComponent("Notes/\(record.id.uuidString).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try JSONDecoder().decode([ReaderNote].self, from: Data(contentsOf: url))
        for note in values { try note.validate(for: record) }
        return values
    }
    public func saveNote(_ note: ReaderNote, for record: BookRecord) throws {
        try note.validate(for: record)
        var values = try notes(for: record)
        values.removeAll { $0.id == note.id }; values.append(note)
        try writeNotes(values, for: record)
    }
    public func removeNote(_ id: UUID, for record: BookRecord) throws {
        var values = try notes(for: record); values.removeAll { $0.id == id }
        try writeNotes(values, for: record)
    }
    private func writeNotes(_ values: [ReaderNote], for record: BookRecord) throws {
        try verifyRecord(record)
        let folder = root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: folder.appendingPathComponent("\(record.id.uuidString).json"), options: .atomic)
    }
}
