import Foundation

public struct BilingualFragment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let source: KnowledgeSource
    public var translation: String
    public var language: String
    public var explanation: String
    /// A reader-provided translation is deliberately distinct from a model's inference.
    public let provenance: String
    public init(id: UUID = UUID(), source: KnowledgeSource, translation: String, language: String, explanation: String = "") {
        self.id = id; self.source = source; self.translation = translation; self.language = language
        self.explanation = explanation; provenance = "reader"
    }
    public func validate() throws {
        try source.validate()
        guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, translation.count <= 8000,
              !language.isEmpty, language.count <= 80, explanation.count <= 8000, provenance == "reader" else { throw ReaderError.invalidAnchor }
    }
}
public struct VocabularyWord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let fragmentID: UUID
    public let word: String
    public let meaning: String
    public init(fragmentID: UUID, word: String, meaning: String) { id = UUID(); self.fragmentID = fragmentID; self.word = word; self.meaning = meaning }
}
public enum ReadingEventKind: String, Codable, CaseIterable, Sendable { case opened, navigation, noteCreated, questionAsked, chapterCompleted }
public struct ReadingEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let date: Date
    public let kind: ReadingEventKind
    public let anchor: SourceAnchor
    public init(kind: ReadingEventKind, anchor: SourceAnchor, date: Date = Date()) { id = UUID(); self.date = date; self.kind = kind; self.anchor = anchor }
}
public struct ReadingMetric: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { bookID }
    public let bookID: UUID
    public var activeSeconds: Double = 0
    public var notes: Int = 0
    public var completedChapters: [String] = []
    public init(bookID: UUID) { self.bookID = bookID }
}
public struct SplitPosition: Codable, Sendable, Equatable {
    public let anchor: SourceAnchor
    public let palette: PagePalette
    public init(anchor: SourceAnchor, palette: PagePalette) { self.anchor = anchor; self.palette = palette }
}
public struct ExtendedReadingSnapshot: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public var generation = UUID()
    public var replayEnabled = false
    public var insightsEnabled = false
    public var events: [ReadingEvent] = []
    public var metrics: [ReadingMetric] = []
    public var fragments: [BilingualFragment] = []
    public var vocabulary: [VocabularyWord] = []
    public var splitPosition: SplitPosition?
    public init() { schemaVersion = 1 }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ReaderError.unsupportedAnchorVersion }
        guard events.count <= 10000, metrics.count <= 10000, fragments.count <= 10000, vocabulary.count <= 20000,
              Set(fragments.map(\.id)).count == fragments.count, Set(metrics.map(\.bookID)).count == metrics.count,
              Set(events.map(\.id)).count == events.count, Set(vocabulary.map(\.id)).count == vocabulary.count else { throw ReaderError.invalidAnchor }
        for fragment in fragments { try fragment.validate() }
        let fragmentIDs = Set(fragments.map(\.id))
        for word in vocabulary {
            guard fragmentIDs.contains(word.fragmentID), !word.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, word.word.count <= 200,
                  !word.meaning.isEmpty, word.meaning.count <= 2000 else { throw ReaderError.invalidAnchor }
        }
        for event in events {
            try event.anchor.validate(bookID: event.anchor.bookID, revision: event.anchor.sourceRevision)
            guard event.date.timeIntervalSince1970.isFinite else { throw ReaderError.invalidAnchor }
        }
        for metric in metrics {
            guard metric.activeSeconds.isFinite, metric.activeSeconds >= 0, metric.notes >= 0,
                  metric.completedChapters.count <= 10000, metric.completedChapters.allSatisfy({ $0.count <= 2048 }) else { throw ReaderError.invalidAnchor }
        }
        if let anchor = splitPosition?.anchor { try anchor.validate(bookID: anchor.bookID, revision: anchor.sourceRevision) }
    }
}
public enum ExtendedReadingCommand: Sendable {
    case setTracking(replay: Bool, insights: Bool)
    case clearReplay, clearInsights
    case record(ReadingEvent, generation: UUID)
    /// At most one minute per sample; callers count only a visible, active reading window.
    case activeTime(book: UUID, seconds: Double, generation: UUID)
    case saveFragment(BilingualFragment), saveWord(VocabularyWord)
    case saveSplit(SplitPosition?)
}
extension LibraryStore {
    public func extendedReading() throws -> ExtendedReadingSnapshot {
        let url = root.appendingPathComponent("ExtendedReading/Memory.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ExtendedReadingSnapshot() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024 else { throw ReaderError.unsupportedCommand }
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1024 * 1024 else { throw ReaderError.unsupportedCommand }
        let value = try JSONDecoder().decode(ExtendedReadingSnapshot.self, from: data); try value.validate(); return value
    }
    @discardableResult public func performExtended(_ command: ExtendedReadingCommand) throws -> ExtendedReadingSnapshot {
        var value = try extendedReading()
        switch command {
        case .setTracking(let replay, let insights):
            value.replayEnabled = replay; value.insightsEnabled = insights; value.generation = UUID()
        case .clearReplay: value.events = []; value.generation = UUID()
        case .clearInsights: value.metrics = []; value.generation = UUID()
        case .record(let event, let generation):
            guard generation == value.generation, value.replayEnabled || value.insightsEnabled else { return value }
            let book = try bookRecord(event.anchor.bookID); try event.anchor.validate(bookID: book.id, revision: book.revision)
            if value.replayEnabled {
                value.events.append(event)
                if value.events.count > 10000 { value.events.removeFirst(value.events.count - 10000) }
            }
            if value.insightsEnabled {
                if !value.metrics.contains(where: { $0.bookID == book.id }) { value.metrics.append(ReadingMetric(bookID: book.id)) }
                let index = value.metrics.firstIndex { $0.bookID == book.id }!
                if event.kind == .noteCreated { value.metrics[index].notes += 1 }
                if event.kind == .chapterCompleted {
                    let key: String
                    switch event.anchor.position { case .pdf(let point): key = "page:\(point.pageIndex)"; case .epub(let resource, _): key = resource }
                    if !value.metrics[index].completedChapters.contains(key) { value.metrics[index].completedChapters.append(key) }
                }
            }
        case .activeTime(let book, let seconds, let generation):
            guard generation == value.generation, value.insightsEnabled else { return value }
            guard seconds.isFinite, seconds > 0, seconds <= 60 else { throw ReaderError.invalidAnchor }
            _ = try bookRecord(book)
            if !value.metrics.contains(where: { $0.bookID == book }) { value.metrics.append(ReadingMetric(bookID: book)) }
            value.metrics[value.metrics.firstIndex { $0.bookID == book }!].activeSeconds += seconds
        case .saveFragment(let fragment):
            try fragment.validate(); let book = try bookRecord(fragment.source.anchor.bookID)
            try fragment.source.anchor.validate(bookID: book.id, revision: book.revision)
            value.fragments.removeAll { $0.id == fragment.id }; value.fragments.append(fragment)
        case .saveWord(let word):
            value.vocabulary.removeAll { $0.id == word.id }; value.vocabulary.append(word)
        case .saveSplit(let position):
            if let position { let book = try bookRecord(position.anchor.bookID); try position.anchor.validate(bookID: book.id, revision: book.revision) }
            value.splitPosition = position
        }
        try value.validate()
        let data = try JSONEncoder().encode(value)
        guard data.count <= 16 * 1024 * 1024 else { throw ReaderError.unsupportedCommand }
        let url = root.appendingPathComponent("ExtendedReading/Memory.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic); return value
    }
}
