import Foundation

public struct BookRecord: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: UUID
    public let title: String
    public let revision: String
    public let assetName: String
}

public struct ReadingState: Codable, Sendable {
    public let schemaVersion: Int
    public let anchor: SourceAnchor?
    public let palette: PagePalette
    public let scale: Double
    public let autoScales: Bool?
    public let pdfDisplayMode: Int?

    public init(anchor: SourceAnchor?, palette: PagePalette, scale: Double, autoScales: Bool = false, pdfDisplayMode: Int = 1) {
        schemaVersion = 1
        self.anchor = anchor
        self.palette = palette
        self.scale = scale
        self.autoScales = autoScales
        self.pdfDisplayMode = pdfDisplayMode
    }
}

/// Immutable managed assets, portable user records and disposable cache directories
/// have distinct locations. All metadata writes are serialized and atomic.
public actor LibraryStore {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func importBook(data: Data, id: UUID, title: String, revision: String) throws -> BookRecord {
        guard PDFReaderEngine.revision(data) == revision else { throw ReaderError.sourceChanged }
        try prepare()
        let record = BookRecord(schemaVersion: 1, id: id, title: title, revision: revision, assetName: "\(id.uuidString).pdf")
        let asset = root.appendingPathComponent("Assets").appendingPathComponent(record.assetName)
        let metadata = recordURL(id)
        do {
            try data.write(to: asset, options: .atomic)
            try JSONEncoder().encode(record).write(to: metadata, options: .atomic)
            try Data(id.uuidString.utf8).write(to: root.appendingPathComponent("LastBook"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: asset)
            try? FileManager.default.removeItem(at: metadata)
            throw error
        }
        return record
    }

    public func lastBook() throws -> (BookRecord, Data, ReadingState?)? {
        let last = root.appendingPathComponent("LastBook")
        guard FileManager.default.fileExists(atPath: last.path) else { return nil }
        guard let id = UUID(uuidString: try String(contentsOf: last, encoding: .utf8)) else { throw ReaderError.unavailableSource }
        let record = try JSONDecoder().decode(BookRecord.self, from: Data(contentsOf: recordURL(id)))
        guard record.schemaVersion == 1, record.id == id, record.assetName == "\(id.uuidString).pdf" else { throw ReaderError.unsupportedAnchorVersion }
        let asset = root.appendingPathComponent("Assets").appendingPathComponent(record.assetName)
        guard FileManager.default.fileExists(atPath: asset.path) else { throw ReaderError.unavailableSource }
        let data = try Data(contentsOf: asset)
        guard PDFReaderEngine.revision(data) == record.revision else { throw ReaderError.sourceChanged }
        let stateURL = stateURL(id)
        var state: ReadingState?
        if FileManager.default.fileExists(atPath: stateURL.path) {
            state = try JSONDecoder().decode(ReadingState.self, from: Data(contentsOf: stateURL))
            guard state?.schemaVersion == 1, let scale = state?.scale, scale.isFinite, scale > 0 else { throw ReaderError.invalidAnchor }
            try state?.anchor?.validate(bookID: id, revision: record.revision)
        }
        return (record, data, state)
    }

    public func save(_ state: ReadingState, for record: BookRecord) throws {
        guard state.scale.isFinite, state.scale > 0 else { throw ReaderError.invalidAnchor }
        try state.anchor?.validate(bookID: record.id, revision: record.revision)
        try prepare()
        try JSONEncoder().encode(state).write(to: stateURL(record.id), options: .atomic)
    }

    private func prepare() throws {
        for name in ["Assets", "Books", "ReadingState", "Cache"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }
    private func recordURL(_ id: UUID) -> URL { root.appendingPathComponent("Books/\(id.uuidString).json") }
    private func stateURL(_ id: UUID) -> URL { root.appendingPathComponent("ReadingState/\(id.uuidString).json") }
}
