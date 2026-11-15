import Foundation
import NaturalLanguage
import PDFKit

public struct KnowledgeSearchFilter: Sendable {
    public var bookIDs: Set<UUID>
    public var title: String
    public var author: String
    public var collection: String
    public var savedOnly: Bool
    public init(bookIDs: Set<UUID> = [], title: String = "", author: String = "", collection: String = "", savedOnly: Bool = false) {
        self.bookIDs = bookIDs; self.title = title; self.author = author; self.collection = collection; self.savedOnly = savedOnly
    }
    public func includes(_ book: BookRecord, metadata: [KnowledgeBookMetadata]) -> Bool {
        let value = metadata.first { $0.bookID == book.id }
        return (bookIDs.isEmpty || bookIDs.contains(book.id)) && (title.isEmpty || book.title.localizedCaseInsensitiveContains(title)) &&
            (author.isEmpty || (value?.author ?? "").localizedCaseInsensitiveContains(author)) &&
            (collection.isEmpty || (value?.collection ?? "").localizedCaseInsensitiveContains(collection))
    }
}
public struct KnowledgeSearchHit: Sendable, Identifiable, Equatable {
    public let id: String
    public let source: KnowledgeSource
    public let kind: KnowledgeKind
    public let text: String
    public let cardID: UUID?
    public init(id: String, source: KnowledgeSource, kind: KnowledgeKind, text: String, cardID: UUID? = nil) {
        self.id = id; self.source = source; self.kind = kind; self.text = text; self.cardID = cardID
    }
    public var evidence: EvidencePassage { EvidencePassage(id: id, anchor: source.anchor, text: String(source.quotation.prefix(1400))) }
}
public struct KnowledgeSearchResult: Sendable {
    public let hits: [KnowledgeSearchHit]
    public let issues: [String]
    public let truncated: Bool
    public let semanticAvailable: Bool
}
private struct KnowledgeIndexCache: Codable { let schemaVersion: Int; let passages: [EvidencePassage]; let truncated: Bool }
extension LibraryStore {
    public func cachedKnowledgePassages(for book: BookRecord) throws -> ([EvidencePassage], Bool)? {
        let url = root.appendingPathComponent("Cache/Knowledge/\(book.id.uuidString)-\(book.revision).json")
        guard FileManager.default.fileExists(atPath: url.path), (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 40 * 1024 * 1024,
              let value = try? JSONDecoder().decode(KnowledgeIndexCache.self, from: Data(contentsOf: url)), value.schemaVersion == 1,
              value.passages.count <= 32_000, value.passages.reduce(0, { $0 + $1.text.utf8.count }) <= 25 * 1024 * 1024,
              Set(value.passages.map(\.id)).count == value.passages.count else { return nil }
        for passage in value.passages {
            guard !passage.id.isEmpty, passage.id.count <= 100, !passage.text.isEmpty, passage.text.count <= 1600,
                  (try? passage.anchor.validate(bookID: book.id, revision: book.revision)) != nil else { return nil }
        }
        return (value.passages, value.truncated)
    }
    public func cacheKnowledgePassages(_ passages: [EvidencePassage], truncated: Bool, for book: BookRecord) throws {
        let url = root.appendingPathComponent("Cache/Knowledge/\(book.id.uuidString)-\(book.revision).json")
        guard passages.count <= 32_000 else { throw CompanionError.limitExceeded }
        let data = try JSONEncoder().encode(KnowledgeIndexCache(schemaVersion: 1, passages: passages, truncated: truncated))
        guard data.count <= 40 * 1024 * 1024 else { throw CompanionError.limitExceeded }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
/// Serial extraction worker, with one immutable source resident at a time. No PDFKit
/// object crosses actors; all user records remain in LibraryStore, not this cache.
public actor KnowledgeSearchIndex {
    private let store: LibraryStore
    public init(store: LibraryStore) { self.store = store }
    public func passages(for book: BookRecord) async throws -> ([EvidencePassage], Bool) {
        try Task.checkCancellation()
        // Always validate source access/checksum before using disposable cached text.
        let (_, data, _) = try await store.openBook(book.id)
        try Task.checkCancellation()
        if let cached = try await store.cachedKnowledgePassages(for: book) { return cached }
        let passages: [EvidencePassage], truncated: Bool
        switch book.format {
        case .pdf:
            let index = try await PDFEvidenceIndex.build(data: data, bookID: book.id, revision: book.revision)
            passages = index.passages; truncated = index.truncated
        case .epub:
            let index = try EPUBEvidenceIndex(publication: EPUBPublication(data: data), bookID: book.id, revision: book.revision)
            passages = index.passages; truncated = index.truncated
        }
        try Task.checkCancellation()
        try await store.cacheKnowledgePassages(passages, truncated: truncated, for: book)
        return (passages, truncated)
    }
    public func search(_ query: String, filter: KnowledgeSearchFilter = KnowledgeSearchFilter(), progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> KnowledgeSearchResult {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 4000 else { throw ReaderError.unsupportedCommand }
        let memory = try await store.knowledge()
        let books = try await store.books().filter { filter.includes($0, metadata: memory.metadata) }
        var hits: [KnowledgeSearchHit] = [], issues: [String] = [], truncated = false
        let allowed = Set(books.map(\.id))
        for (index, book) in books.prefix(500).enumerated() {
            try Task.checkCancellation(); await progress(index, min(500, books.count))
            do {
                if !filter.savedOnly {
                    let (passages, clipped) = try await passages(for: book); truncated = truncated || clipped
                    for item in try EvidenceRanking.retrieve(query, passages: passages, limit: 8, isVisible: { _ in false }) {
                        hits.append(Self.hit(item, book: book))
                    }
                }
                let notes = try await store.notes(for: book)
                for note in notes where Self.matches(query, note.text + " " + note.quotation) {
                    let source = KnowledgeSource(anchor: note.anchor, bookTitle: book.title, location: Self.location(note.anchor), quotation: String(note.quotation.prefix(1600)))
                    if !source.quotation.isEmpty { hits.append(.init(id: "note:" + note.id.uuidString, source: source, kind: .readerNote, text: note.text)) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append(book.title + ": " + error.localizedDescription) }
            if hits.count >= 400 { truncated = true; break }
        }
        let saved = memory.cards.filter { $0.sources.contains { allowed.contains($0.anchor.bookID) } }
        let (ranked, semantic) = try Self.rankSaved(query, cards: saved)
        for card in ranked {
            guard let source = card.sources.first(where: { allowed.contains($0.anchor.bookID) }) else { continue }
            hits.append(.init(id: "card:" + card.id.uuidString, source: source, kind: card.kind, text: card.text, cardID: card.id))
        }
        try Task.checkCancellation(); await progress(min(500, books.count), min(500, books.count))
        return KnowledgeSearchResult(hits: Array(hits.prefix(400)), issues: issues, truncated: truncated || books.count > 500, semanticAvailable: semantic)
    }
    public static func hit(_ item: EvidencePassage, book: BookRecord) -> KnowledgeSearchHit {
        .init(id: book.id.uuidString + ":" + item.id, source: .init(anchor: item.anchor, bookTitle: book.title, location: location(item.anchor), quotation: String(item.text.prefix(1600))), kind: .quotation, text: item.text)
    }
    public static func location(_ anchor: SourceAnchor) -> String {
        switch anchor.position {
        case .pdf(let point): "p. \(point.pageIndex + 1)"
        case .epub(let resource, _): resource
        }
    }
    public static func matches(_ query: String, _ text: String) -> Bool {
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let value = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return !terms.isEmpty && terms.contains { value.contains($0) }
    }
    /// Uses only installed Apple sentence embeddings; never requests a model download.
    /// Explicit lexical fallback when a language/model is absent.
    public static func rankSaved(_ query: String, cards: [KnowledgeCard]) throws -> ([KnowledgeCard], Bool) {
        let language = NLLanguageRecognizer.dominantLanguage(for: query)
        let embedding = language.flatMap { NLEmbedding.sentenceEmbedding(for: $0) }
        let q = embedding?.vector(for: String(query.prefix(500)))
        var scored: [(KnowledgeCard, Double)] = []
        for (index, card) in cards.enumerated() {
            if index % 32 == 0 { try Task.checkCancellation() }
            let content = card.title + " " + card.text + " " + card.comment + " " + card.tags.joined(separator: " ")
            var score = matches(query, content) ? 2.0 : 0
            if let q, let vector = embedding?.vector(for: String(content.prefix(500))), q.count == vector.count {
                let dot = zip(q, vector).reduce(0) { $0 + $1.0 * $1.1 }
                let norm = sqrt(q.reduce(0) { $0 + $1 * $1 } * vector.reduce(0) { $0 + $1 * $1 })
                if norm > 0, dot / norm > 0.55 { score += dot / norm }
            }
            if score > 0 { scored.append((card, score)) }
        }
        return (scored.sorted { $0.1 == $1.1 ? $0.0.id.uuidString < $1.0.id.uuidString : $0.1 > $1.1 }.prefix(100).map(\.0), q != nil)
    }
    public func timeline(for book: BookRecord, memory: KnowledgeSnapshot) async throws -> [ReadingPathStep] {
        let (_, data, _) = try await store.openBook(book.id)
        var steps: [ReadingPathStep] = []
        if book.format == .epub {
            let publication = try EPUBPublication(data: data)
            for chapter in publication.readingResources where !chapter.text.isEmpty {
                let locator = EPUBTextLocator(offset: 0, quote: String(chapter.text.prefix(60)))
                let source = KnowledgeSource(anchor: .init(bookID: book.id, sourceRevision: book.revision, position: .epub(resource: chapter.resource, locator: locator.encoded)), bookTitle: book.title, location: chapter.title, quotation: String(chapter.text.prefix(1600)))
                steps.append(.init(title: chapter.title, source: source))
            }
        }
        if book.format == .pdf {
            guard let document = PDFDocument(data: data) else { throw ReaderError.unavailableSource }
            guard !document.isLocked else { throw ReaderError.lockedDocument }
            guard document.allowsCopying else { throw CompanionError.restrictedSource }
            func visit(_ outline: PDFOutline, depth: Int) throws {
                try Task.checkCancellation()
                guard depth < 32, steps.count < 1000 else { return }
                if let title = outline.label, !title.isEmpty, let destination = outline.destination,
                   let page = destination.page, let text = page.string, !text.isEmpty {
                    let anchor = SourceAnchor(bookID: book.id, sourceRevision: book.revision, position: .pdf(.init(pageIndex: document.index(for: page), x: destination.point.x, y: destination.point.y)))
                    steps.append(.init(title: String(title.prefix(500)), source: .init(anchor: anchor, bookTitle: book.title, location: Self.location(anchor), quotation: String(text.prefix(1600)))))
                }
                for i in 0..<min(outline.numberOfChildren, 1000) { if let child = outline.child(at: i) { try visit(child, depth: depth + 1) } }
            }
            if let root = document.outlineRoot { try visit(root, depth: 0) }
        }
        // Explicit saved events/ideas, never inferred fictional chapters or events.
        for card in memory.cards.sorted(by: { $0.createdAt < $1.createdAt }) {
            for source in card.sources where source.anchor.bookID == book.id { steps.append(.init(title: card.title, source: source)) }
        }
        return Array(steps.prefix(1000))
    }
    public static func suggestPath(goal: String, hits: [KnowledgeSearchHit]) -> KnowledgeReadingPath {
        var seen = Set<String>(), steps: [ReadingPathStep] = []
        for hit in hits where hit.kind == .quotation {
            let key = hit.source.anchor.bookID.uuidString + ":" + location(hit.source.anchor)
            if seen.insert(key).inserted {
                steps.append(.init(title: hit.source.bookTitle + " · " + hit.source.location, source: hit.source))
            }
            if steps.count == 12 { break }
        }
        return .init(goal: goal, steps: steps)
    }
}
