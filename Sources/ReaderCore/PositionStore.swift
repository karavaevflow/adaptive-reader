import Foundation

/// User records live separately from source documents and disposable render caches.
public actor PositionStore {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func save(_ anchor: SourceAnchor) throws {
        try anchor.validate(bookID: anchor.bookID, revision: anchor.sourceRevision)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(anchor)
        try data.write(to: file(for: anchor.bookID), options: .atomic)
    }

    public func load(bookID: UUID, revision: String) throws -> SourceAnchor? {
        let url = file(for: bookID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let anchor = try JSONDecoder().decode(SourceAnchor.self, from: Data(contentsOf: url))
        try anchor.validate(bookID: bookID, revision: revision)
        return anchor
    }

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}
