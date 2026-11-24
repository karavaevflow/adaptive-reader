import Foundation

public enum HighlightColor: String, Codable, CaseIterable, Sendable { case yellow, green, blue, purple }

public struct ReaderHighlight: Codable, Sendable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public let anchor: SourceAnchor
    public let quotation: String
    public let displayQuotation: String?
    public var color: HighlightColor
    public let createdAt: Date
    public init(anchor: SourceAnchor, quotation: String, color: HighlightColor = .yellow, displayQuotation: String? = nil) {
        schemaVersion = 1; id = UUID(); self.anchor = anchor; self.quotation = quotation; self.color = color; createdAt = Date(); self.displayQuotation = displayQuotation
    }
    public func validate(for record: BookRecord) throws {
        try anchor.validate(bookID: record.id, revision: record.revision)
        guard schemaVersion == 1, !quotation.isEmpty, quotation.utf16.count <= 8000, (displayQuotation?.count ?? 0) <= 16000 else { throw ReaderError.invalidAnchor }
    }
}

public struct StudyCard: Codable, Equatable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public private(set) var anchor: SourceAnchor
    public let quotation: String
    public var question: String
    public var answer: String
    public var archived: Bool
    public private(set) var reviewCount: Int
    public private(set) var intervalDays: Int
    public private(set) var dueAt: Date
    public let createdAt: Date
    public init(anchor: SourceAnchor, quotation: String, question: String, answer: String, now: Date = Date()) {
        schemaVersion = 1; id = UUID(); self.anchor = anchor; self.quotation = quotation
        self.question = question; self.answer = answer; archived = false; reviewCount = 0; intervalDays = 0; dueAt = now; createdAt = now
    }
    public func validate(for record: BookRecord) throws {
        try anchor.validate(bookID: record.id, revision: record.revision)
        guard schemaVersion == 1, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.count <= 2000, answer.count <= 8000, quotation.utf16.count <= 8000,
              (0...1_000_000).contains(reviewCount), (0...365).contains(intervalDays), dueAt.timeIntervalSince1970.isFinite else { throw ReaderError.unsupportedCommand }
    }
    public mutating func review(remembered: Bool, now: Date = Date()) {
        reviewCount = min(reviewCount, 999_999) + 1
        if remembered { intervalDays = intervalDays == 0 ? 1 : min(365, intervalDays * 2 + 1); dueAt = now.addingTimeInterval(Double(intervalDays) * 86400) }
        else { intervalDays = 0; dueAt = now.addingTimeInterval(600) }
    }
    public func rebased(for record: BookRecord) throws -> Self {
        guard anchor.sourceRevision == record.revision else { throw ReaderError.sourceChanged }
        var value = self
        value.anchor = SourceAnchor(bookID: record.id, sourceRevision: record.revision, position: anchor.position)
        try value.validate(for: record)
        return value
    }
}

public struct StudyCardArchive: Codable, Sendable {
    public let schemaVersion: Int
    public let sourceRevision: String
    public let cards: [StudyCard]
    public init(revision: String, cards: [StudyCard]) { schemaVersion = 1; sourceRevision = revision; self.cards = cards }
    public func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(self) }
}

public struct ListenPosition: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let anchor: SourceAnchor
    public let rate: Double
    public let voiceIdentifier: String?
    public let completed: Bool?
    public init(anchor: SourceAnchor, rate: Double, voiceIdentifier: String?, completed: Bool = false) { schemaVersion = 1; self.anchor = anchor; self.rate = rate; self.voiceIdentifier = voiceIdentifier; self.completed = completed }
    public func validate(for record: BookRecord) throws {
        try anchor.validate(bookID: record.id, revision: record.revision)
        guard schemaVersion == 1, rate.isFinite, (0.5...2).contains(rate), (voiceIdentifier?.count ?? 0) <= 300 else { throw ReaderError.invalidAnchor }
    }
}

public struct StudySnapshot: Sendable {
    public let cards: [StudyCard]
    public let highlights: [ReaderHighlight]
    public let listen: ListenPosition?
}
private struct StudyRecord: Codable {
    var schemaVersion = 1
    var cards: [StudyCard] = []
    var highlights: [ReaderHighlight] = []
    var listen: ListenPosition?
}

extension LibraryStore {
    private func studyURL(_ record: BookRecord) -> URL { root.appendingPathComponent("Study/\(record.id.uuidString).json") }
    private func readStudy(_ record: BookRecord) throws -> StudyRecord {
        try verifyRecord(record)
        let url = studyURL(record)
        guard FileManager.default.fileExists(atPath: url.path) else { return StudyRecord() }
        let data = try Data(contentsOf: url)
        guard data.count <= 32 * 1024 * 1024 else { throw ReaderError.unsupportedCommand }
        let value = try JSONDecoder().decode(StudyRecord.self, from: data)
        guard value.schemaVersion == 1, value.cards.count <= 10000, value.highlights.count <= 10000,
              Set(value.cards.map(\.id)).count == value.cards.count,
              Set(value.highlights.map(\.id)).count == value.highlights.count else { throw ReaderError.unsupportedAnchorVersion }
        for card in value.cards { try card.validate(for: record) }
        for highlight in value.highlights { try highlight.validate(for: record) }
        try value.listen?.validate(for: record)
        return value
    }
    private func writeStudy(_ value: StudyRecord, for record: BookRecord) throws {
        try verifyRecord(record)
        let data = try JSONEncoder().encode(value)
        guard data.count <= 32 * 1024 * 1024, value.cards.count <= 10000, value.highlights.count <= 10000 else { throw ReaderError.unsupportedCommand }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Study"), withIntermediateDirectories: true)
        try data.write(to: studyURL(record), options: .atomic)
    }
    public func study(for record: BookRecord) throws -> StudySnapshot {
        let value = try readStudy(record)
        return StudySnapshot(cards: value.cards, highlights: value.highlights, listen: value.listen)
    }
    public func saveCard(_ card: StudyCard, for record: BookRecord) throws {
        try card.validate(for: record); var value = try readStudy(record)
        value.cards.removeAll { $0.id == card.id }; value.cards.append(card); try writeStudy(value, for: record)
    }
    /// Import only new IDs and only for the exact same source revision. Rebase the
    /// library-local UUID so portable cards can return to a newly imported copy.
    public func importCards(_ data: Data, for record: BookRecord) throws -> Int {
        guard data.count <= 16 * 1024 * 1024 else { throw ReaderError.unsupportedCommand }
        let archive = try JSONDecoder().decode(StudyCardArchive.self, from: data)
        guard archive.schemaVersion == 1, archive.cards.count <= 10000 else { throw ReaderError.unsupportedAnchorVersion }
        guard archive.sourceRevision == record.revision else { throw ReaderError.sourceChanged }
        let imported = try archive.cards.map { try $0.rebased(for: record) }
        guard Set(imported.map(\.id)).count == imported.count else { throw ReaderError.invalidAnchor }
        var value = try readStudy(record), known = Set(value.cards.map(\.id)), added = 0
        for card in imported where !known.contains(card.id) { known.insert(card.id); value.cards.append(card); added += 1 }
        try writeStudy(value, for: record); return added
    }
    public func removeCard(_ id: UUID, for record: BookRecord) throws {
        var value = try readStudy(record); value.cards.removeAll { $0.id == id }; try writeStudy(value, for: record)
    }
    public func saveHighlight(_ highlight: ReaderHighlight, for record: BookRecord) throws {
        try saveHighlights([highlight], for: record)
    }
    public func saveHighlights(_ highlights: [ReaderHighlight], for record: BookRecord) throws {
        for highlight in highlights { try highlight.validate(for: record) }
        let ids = Set(highlights.map(\.id))
        guard ids.count == highlights.count else { throw ReaderError.invalidAnchor }
        var value = try readStudy(record)
        value.highlights.removeAll { ids.contains($0.id) }; value.highlights.append(contentsOf: highlights); try writeStudy(value, for: record)
    }
    public func removeHighlight(_ id: UUID, for record: BookRecord) throws {
        var value = try readStudy(record); value.highlights.removeAll { $0.id == id }; try writeStudy(value, for: record)
    }
    public func saveListenPosition(_ position: ListenPosition, for record: BookRecord) throws {
        try position.validate(for: record); var value = try readStudy(record); value.listen = position; try writeStudy(value, for: record)
    }
}

public enum StudyMarkdown {
    public static func export(title: String, notes: [ReaderNote], cards: [StudyCard], highlights: [ReaderHighlight], chapterTitles: [String: String] = [:]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "#", with: "\\#").replacingOccurrences(of: "<", with: "&lt;") }
        func quote(_ value: String) -> String { value.components(separatedBy: .newlines).map { "> " + escape($0) }.joined(separator: "\n") }
        func source(_ anchor: SourceAnchor) throws -> String {
            let location: String
            switch anchor.position {
            case .pdf(let point): location = "Page \(point.pageIndex + 1)"
            case .epub(let resource, _): location = chapterTitles[resource] ?? "EPUB passage"
            }
            return "\n\nSource: " + escape(title).replacingOccurrences(of: "\n", with: " ") + " · " + escape(location) + "\n\n<!-- AdaptiveSourceAnchor: " + (try encoder.encode(anchor)).base64EncodedString() + " -->\n"
        }
        var output = "# " + escape(title).replacingOccurrences(of: "\n", with: " ") + "\n\n## Highlights\n"
        for item in highlights { output += "\n" + quote(item.displayQuotation ?? item.quotation) + "\n\nColor: " + item.color.rawValue + (try source(item.anchor)) }
        output += "\n## Notes\n"
        for item in notes { output += "\n" + quote(item.quotation) + "\n\n" + escape(item.text) + (try source(item.anchor)) }
        output += "\n## Cards\n"
        for item in cards { output += "\n### " + escape(item.question).replacingOccurrences(of: "\n", with: " ") + "\n\n" + escape(item.answer) + "\n\n" + quote(item.quotation) + "\n\nArchived: \(item.archived)" + (try source(item.anchor)) }
        return output
    }
}
