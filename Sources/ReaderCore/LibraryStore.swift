import Foundation

public enum BookSource: Codable, Sendable, Equatable {
    case managed(name: String)
    case reference(bookmark: Data)
}

public struct BookRecord: Codable, Sendable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public let title: String
    public let revision: String
    public let source: BookSource
    public var favorite: Bool
    public let addedAt: Date
    public let pageCount: Int
    public var assetName: String { if case .managed(let name) = source { name } else { "" } }
    public var isReference: Bool { if case .reference = source { true } else { false } }

    public init(id: UUID, title: String, revision: String, source: BookSource, favorite: Bool = false, addedAt: Date = Date(), pageCount: Int = 0) {
        schemaVersion = 2; self.id = id; self.title = title; self.revision = revision
        self.source = source; self.favorite = favorite; self.addedAt = addedAt; self.pageCount = pageCount
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, title, revision, source, assetName, favorite, addedAt, pageCount }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 || version == 2 else { throw ReaderError.unsupportedAnchorVersion }
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        revision = try values.decode(String.self, forKey: .revision)
        source = version == 1 ? .managed(name: try values.decode(String.self, forKey: .assetName)) : try values.decode(BookSource.self, forKey: .source)
        favorite = try values.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        addedAt = try values.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date(timeIntervalSince1970: 0)
        pageCount = try values.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        schemaVersion = 2
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion); try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title); try values.encode(revision, forKey: .revision)
        try values.encode(source, forKey: .source); try values.encode(favorite, forKey: .favorite)
        try values.encode(addedAt, forKey: .addedAt); try values.encode(pageCount, forKey: .pageCount)
    }
}

public struct ReadingState: Codable, Sendable {
    public let schemaVersion: Int
    public let anchor: SourceAnchor?
    public let palette: PagePalette
    public let scale: Double
    public let autoScales: Bool?
    public let pdfDisplayMode: Int?
    public init(anchor: SourceAnchor?, palette: PagePalette, scale: Double, autoScales: Bool = false, pdfDisplayMode: Int = 1) {
        schemaVersion = 1; self.anchor = anchor; self.palette = palette; self.scale = scale
        self.autoScales = autoScales; self.pdfDisplayMode = pdfDisplayMode
    }
}

public struct ReaderBookmark: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let anchor: SourceAnchor
    public let title: String
    public let createdAt: Date
    public init(anchor: SourceAnchor, title: String) {
        id = UUID(); self.anchor = anchor; self.title = title; createdAt = Date()
    }
}
private struct AnnotationRecord: Codable {
    let schemaVersion: Int
    var bookmarks: [ReaderBookmark]
}

/// Source assets, user metadata and disposable cache have independent locations.
/// Schema-1 metadata is upgraded atomically; source bytes are never rewritten.
public actor LibraryStore {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func importBook(data: Data, id: UUID, title: String, revision: String, reference: Data? = nil, pageCount: Int = 0) throws -> BookRecord {
        guard PDFReaderEngine.revision(data) == revision else { throw ReaderError.sourceChanged }
        try prepare()
        let record = BookRecord(id: id, title: title, revision: revision,
            source: reference.map { .reference(bookmark: $0) } ?? .managed(name: "\(id.uuidString).pdf"), pageCount: pageCount)
        let asset = root.appendingPathComponent("Assets/\(record.assetName)")
        guard !FileManager.default.fileExists(atPath: recordURL(id).path) else { throw ReaderError.invalidAnchor }
        do {
            if reference == nil { try data.write(to: asset, options: .atomic) }
            try write(record)
            try setCurrentBook(id)
        } catch {
            if reference == nil { try? FileManager.default.removeItem(at: asset) }
            try? FileManager.default.removeItem(at: recordURL(id))
            throw error
        }
        return record
    }

    public func books() throws -> [BookRecord] {
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Books"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw ReaderError.invalidAnchor }
                return try readRecord(id)
            }.sorted { $0.addedAt > $1.addedAt }
    }

    public func lastBook() throws -> (BookRecord, Data, ReadingState?)? {
        let url = root.appendingPathComponent("LastBook")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let id = UUID(uuidString: try String(contentsOf: url, encoding: .utf8)) else { throw ReaderError.unavailableSource }
        return try openBook(id)
    }

    public func openBook(_ id: UUID) throws -> (BookRecord, Data, ReadingState?) {
        var record = try readRecord(id)
        let url: URL
        var grant = false
        switch record.source {
        case .managed(let name): url = root.appendingPathComponent("Assets/\(name)")
        case .reference(let bookmark):
            var stale = false
            do { url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
            catch { throw ReaderError.unavailableSource }
            grant = url.startAccessingSecurityScopedResource()
            if stale {
                do {
                    let renewed = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                    record = BookRecord(id: record.id, title: record.title, revision: record.revision, source: .reference(bookmark: renewed), favorite: record.favorite, addedAt: record.addedAt, pageCount: record.pageCount)
                    try write(record)
                } catch { if grant { url.stopAccessingSecurityScopedResource() }; throw ReaderError.unavailableSource }
            }
        }
        defer { if grant { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReaderError.unavailableSource }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ReaderError.unavailableSource }
        guard PDFReaderEngine.revision(data) == record.revision else { throw ReaderError.sourceChanged }
        return (record, data, try readingState(for: record))
    }

    public func readingState(for record: BookRecord) throws -> ReadingState? {
        let url = stateURL(record.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let state = try JSONDecoder().decode(ReadingState.self, from: Data(contentsOf: url))
        guard state.schemaVersion == 1, state.scale.isFinite, state.scale > 0 else { throw ReaderError.invalidAnchor }
        try state.anchor?.validate(bookID: record.id, revision: record.revision)
        return state
    }

    public func comfortPreferences(for record: BookRecord) throws -> ReadingComfortPreferences {
        _ = try readRecord(record.id)
        let url = root.appendingPathComponent("Comfort/\(record.id.uuidString).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ReadingComfortPreferences() }
        let value = try JSONDecoder().decode(ReadingComfortPreferences.self, from: Data(contentsOf: url))
        try value.validate(); return value
    }
    public func saveComfort(_ value: ReadingComfortPreferences, for record: BookRecord) throws {
        _ = try readRecord(record.id); try value.validate(); try prepare()
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent("Comfort/\(record.id.uuidString).json"), options: .atomic)
    }
    public func ambientDefaults() throws -> AmbientReadingSettings {
        let url = root.appendingPathComponent("AmbientDefaults.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return AmbientReadingSettings() }
        let value = try JSONDecoder().decode(AmbientReadingSettings.self, from: Data(contentsOf: url))
        try value.validate(); return value
    }
    public func saveAmbientDefaults(_ value: AmbientReadingSettings) throws {
        try value.validate(); try prepare()
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent("AmbientDefaults.json"), options: .atomic)
    }

    public func setCurrentBook(_ id: UUID?) throws {
        try prepare()
        let url = root.appendingPathComponent("LastBook")
        if let id { try Data(id.uuidString.utf8).write(to: url, options: .atomic) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func relink(_ id: UUID, data: Data, bookmark: Data) throws -> BookRecord {
        let previous = try readRecord(id)
        guard previous.isReference else { throw ReaderError.unsupportedCommand }
        guard PDFReaderEngine.revision(data) == previous.revision else { throw ReaderError.sourceChanged }
        let updated = BookRecord(id: id, title: previous.title, revision: previous.revision,
            source: .reference(bookmark: bookmark), favorite: previous.favorite, addedAt: previous.addedAt, pageCount: previous.pageCount)
        try write(updated)
        return updated
    }

    public func toggleFavorite(_ id: UUID) throws {
        var record = try readRecord(id); record.favorite.toggle(); try write(record)
    }

    public func setFavorite(_ favorite: Bool, for id: UUID) throws {
        var record = try readRecord(id); record.favorite = favorite; try write(record)
    }

    public func bookmarks(for record: BookRecord) throws -> [ReaderBookmark] {
        let url = annotationURL(record.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let annotations = try JSONDecoder().decode(AnnotationRecord.self, from: Data(contentsOf: url))
        guard annotations.schemaVersion == 1 else { throw ReaderError.unsupportedAnchorVersion }
        for item in annotations.bookmarks { try item.anchor.validate(bookID: record.id, revision: record.revision) }
        return annotations.bookmarks
    }

    public func toggleBookmark(anchor: SourceAnchor, title: String, for record: BookRecord) throws -> [ReaderBookmark] {
        try anchor.validate(bookID: record.id, revision: record.revision)
        var marks = try bookmarks(for: record)
        func sameLocation(_ other: SourceAnchor) -> Bool {
            if case .pdf(let a) = anchor.position, case .pdf(let b) = other.position { return a.pageIndex == b.pageIndex }
            return anchor.position == other.position
        }
        if marks.contains(where: { sameLocation($0.anchor) }) { marks.removeAll { sameLocation($0.anchor) } }
        else { marks.append(ReaderBookmark(anchor: anchor, title: String(title.prefix(200)))) }
        try saveBookmarks(marks, for: record)
        return marks
    }

    public func removeBookmark(_ id: UUID, for record: BookRecord) throws -> [ReaderBookmark] {
        let marks = try bookmarks(for: record).filter { $0.id != id }
        try saveBookmarks(marks, for: record)
        return marks
    }

    public func saveBookmarks(_ bookmarks: [ReaderBookmark], for record: BookRecord) throws {
        for item in bookmarks { try item.anchor.validate(bookID: record.id, revision: record.revision) }
        try prepare()
        try JSONEncoder().encode(AnnotationRecord(schemaVersion: 1, bookmarks: bookmarks))
            .write(to: annotationURL(record.id), options: .atomic)
    }

    public func save(_ state: ReadingState, for record: BookRecord) throws {
        guard state.scale.isFinite, state.scale > 0 else { throw ReaderError.invalidAnchor }
        try state.anchor?.validate(bookID: record.id, revision: record.revision)
        try prepare()
        try JSONEncoder().encode(state).write(to: stateURL(record.id), options: .atomic)
    }

    private func readRecord(_ id: UUID) throws -> BookRecord {
        let url = recordURL(id), data = try Data(contentsOf: url)
        let record = try JSONDecoder().decode(BookRecord.self, from: data)
        guard record.id == id else { throw ReaderError.invalidAnchor }
        if case .managed(let name) = record.source, name != "\(id.uuidString).pdf" { throw ReaderError.invalidAnchor }
        // Rewrite only metadata whose on-disk version predates the current schema.
        let version = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int
        if version == 1 { try write(record) }
        return record
    }
    private func write(_ record: BookRecord) throws { try JSONEncoder().encode(record).write(to: recordURL(record.id), options: .atomic) }
    private func prepare() throws {
        for name in ["Assets", "Books", "ReadingState", "Annotations", "Comfort", "Cache"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }
    private func recordURL(_ id: UUID) -> URL { root.appendingPathComponent("Books/\(id.uuidString).json") }
    private func stateURL(_ id: UUID) -> URL { root.appendingPathComponent("ReadingState/\(id.uuidString).json") }
    private func annotationURL(_ id: UUID) -> URL { root.appendingPathComponent("Annotations/\(id.uuidString).json") }
}
