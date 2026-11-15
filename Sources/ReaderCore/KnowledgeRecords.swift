import Foundation

public enum KnowledgeError: Error, LocalizedError {
    case invalidCard, invalidPath
    public var errorDescription: String? {
        switch self {
        case .invalidCard: "A card needs a title, text and one to eight valid sources. Shorten oversized fields or tags."
        case .invalidPath: "A reading path needs a goal and one to one hundred source-linked steps."
        }
    }
}

public enum KnowledgeKind: String, Codable, CaseIterable, Sendable { case quotation, readerNote, modelInference }
public struct KnowledgeSource: Codable, Equatable, Sendable, Identifiable {
    public let anchor: SourceAnchor
    public let bookTitle: String
    public let location: String
    public let quotation: String
    public var id: String { anchor.bookID.uuidString + ":" + anchor.sourceRevision + ":" + location + ":" + quotation }
    public init(anchor: SourceAnchor, bookTitle: String, location: String, quotation: String) {
        self.anchor = anchor; self.bookTitle = bookTitle; self.location = location; self.quotation = quotation
    }
    public func validate() throws {
        try anchor.validate(bookID: anchor.bookID, revision: anchor.sourceRevision)
        guard anchor.sourceRevision.count == 64, anchor.sourceRevision.allSatisfy(\.isHexDigit),
              !bookTitle.isEmpty, bookTitle.count <= 500, location.count <= 500,
              !quotation.isEmpty, quotation.count <= 1600 else { throw ReaderError.invalidAnchor }
        if case .epub(_, let locator) = anchor.position { _ = try EPUBTextLocator(encoded: locator) }
    }
}
public struct KnowledgeCard: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var kind: KnowledgeKind
    public var text: String
    public var comment: String
    public var tags: [String]
    public var sources: [KnowledgeSource]
    public let createdAt: Date
    public init(id: UUID = UUID(), title: String, kind: KnowledgeKind, text: String, comment: String = "", tags: [String] = [], sources: [KnowledgeSource], createdAt: Date = Date()) {
        self.id = id; self.title = title; self.kind = kind; self.text = text; self.comment = comment; self.tags = tags; self.sources = sources; self.createdAt = createdAt
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 8000,
              comment.count <= 8000, tags.count <= 32, tags.allSatisfy({ !$0.isEmpty && $0.count <= 80 }),
              (1...8).contains(sources.count), createdAt.timeIntervalSince1970.isFinite else { throw KnowledgeError.invalidCard }
        for source in sources { try source.validate() }
    }
}
public struct CanvasPoint: Codable, Sendable, Equatable {
    public var x: Double; public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public func validate() throws {
        guard x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { throw ReaderError.invalidAnchor }
    }
}
public struct CanvasNode: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { cardID }
    public let cardID: UUID
    public var point: CanvasPoint
    public var cluster: String
    public init(cardID: UUID, point: CanvasPoint, cluster: String = "") { self.cardID = cardID; self.point = point; self.cluster = cluster }
}
public struct CanvasEdge: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let from: UUID
    public let to: UUID
    public var label: String
    public init(id: UUID = UUID(), from: UUID, to: UUID, label: String) { self.id = id; self.from = from; self.to = to; self.label = label }
}
public struct KnowledgeBoard: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var nodes: [CanvasNode]
    public var edges: [CanvasEdge]
    public init(id: UUID = UUID(), title: String, nodes: [CanvasNode] = [], edges: [CanvasEdge] = []) { self.id = id; self.title = title; self.nodes = nodes; self.edges = edges }
}
public struct ReadingPathStep: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public let source: KnowledgeSource
    public var completed: Bool
    public init(title: String, source: KnowledgeSource) { id = UUID(); self.title = title; self.source = source; completed = false }
}
public struct KnowledgeReadingPath: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var goal: String
    public var steps: [ReadingPathStep]
    public init(id: UUID = UUID(), goal: String, steps: [ReadingPathStep]) { self.id = id; self.goal = goal; self.steps = steps }
}
public struct KnowledgeBookMetadata: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { bookID }
    public let bookID: UUID
    public var author: String
    public var collection: String
    public init(bookID: UUID, author: String = "", collection: String = "") { self.bookID = bookID; self.author = author; self.collection = collection }
}
/// User-owned memory. Search indexes never become hidden model memory.
public struct KnowledgeSnapshot: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public var cards: [KnowledgeCard]
    public var boards: [KnowledgeBoard]
    public var paths: [KnowledgeReadingPath]
    public var metadata: [KnowledgeBookMetadata]
    public init(cards: [KnowledgeCard] = [], boards: [KnowledgeBoard] = [], paths: [KnowledgeReadingPath] = [], metadata: [KnowledgeBookMetadata] = []) {
        schemaVersion = 1; self.cards = cards; self.boards = boards; self.paths = paths; self.metadata = metadata
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ReaderError.unsupportedAnchorVersion }
        guard cards.count <= 10_000, boards.count <= 100, paths.count <= 1000, metadata.count <= 10_000,
              Set(cards.map(\.id)).count == cards.count, Set(boards.map(\.id)).count == boards.count,
              Set(paths.map(\.id)).count == paths.count, Set(metadata.map(\.id)).count == metadata.count else { throw ReaderError.invalidAnchor }
        for card in cards { try card.validate() }
        let ids = Set(cards.map(\.id))
        for board in boards {
            guard !board.title.isEmpty, board.title.count <= 300, board.nodes.count <= 1000, board.edges.count <= 3000,
                  Set(board.nodes.map(\.id)).count == board.nodes.count, Set(board.edges.map(\.id)).count == board.edges.count else { throw ReaderError.invalidAnchor }
            let nodes = Set(board.nodes.map(\.id))
            for node in board.nodes { try node.point.validate(); guard ids.contains(node.id), node.cluster.count <= 100 else { throw ReaderError.invalidAnchor } }
            for edge in board.edges { guard edge.from != edge.to, nodes.contains(edge.from), nodes.contains(edge.to), !edge.label.isEmpty, edge.label.count <= 300 else { throw ReaderError.invalidAnchor } }
        }
        for path in paths {
            guard !path.goal.isEmpty, path.goal.count <= 4000, (1...100).contains(path.steps.count), Set(path.steps.map(\.id)).count == path.steps.count else { throw KnowledgeError.invalidPath }
            for step in path.steps { try step.source.validate(); guard !step.title.isEmpty, step.title.count <= 500 else { throw ReaderError.invalidAnchor } }
        }
        for item in metadata { guard item.author.count <= 300, item.collection.count <= 100 else { throw ReaderError.invalidAnchor } }
    }
    public func encoded() throws -> Data {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(self)
    }
    public func markdown() -> String {
        func quote(_ text: String) -> String { text.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n") }
        func source(_ value: KnowledgeSource) -> String {
            let anchor = (try? JSONEncoder().encode(value.anchor).base64EncodedString()) ?? ""
            return "\(value.bookTitle) · \(value.location)\n\n\(quote(value.quotation))\n\n<!-- AdaptiveSourceAnchor: \(anchor) -->"
        }
        var result = "# Adaptive Knowledge\n\n"
        for card in cards {
            result += "## \(card.title)\n\n\(card.kind.rawValue)\n\n\(card.text)\n\n\(card.comment)\n\nTags: \(card.tags.joined(separator: ", "))\n\n"
            result += card.sources.map(source).joined(separator: "\n\n") + "\n\n"
        }
        for board in boards {
            result += "## Canvas: \(board.title)\n\n"
            for edge in board.edges { result += "- \(cards.first { $0.id == edge.from }?.title ?? edge.from.uuidString) → \(cards.first { $0.id == edge.to }?.title ?? edge.to.uuidString): \(edge.label)\n" }
        }
        for path in paths {
            result += "\n## Reading path: \(path.goal)\n\n"
            for (index, step) in path.steps.enumerated() { result += "### \(index + 1). \(step.title)\n\n\(step.completed ? "[x]" : "[ ]")\n\n\(source(step.source))\n\n" }
        }
        return result
    }
}
/// All persistent mutations run inside LibraryStore's existing serial actor.
public enum KnowledgeCommand: Sendable {
    case saveCard(KnowledgeCard), removeCard(UUID), saveBoard(KnowledgeBoard), removeBoard(UUID)
    case placeNode(board: UUID, node: CanvasNode), connect(board: UUID, edge: CanvasEdge), disconnect(board: UUID, edge: UUID)
    case savePath(KnowledgeReadingPath), removePath(UUID), metadata(KnowledgeBookMetadata)
    case restoreCard(KnowledgeCard, boards: [KnowledgeBoard])
    case merge(KnowledgeSnapshot)
}
extension LibraryStore {
    public func knowledge() throws -> KnowledgeSnapshot {
        let url = root.appendingPathComponent("Knowledge/Memory.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return KnowledgeSnapshot() }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 48 * 1024 * 1024 else { throw CompanionError.limitExceeded }
        let value = try JSONDecoder().decode(KnowledgeSnapshot.self, from: Data(contentsOf: url)); try value.validate(); return value
    }
    @discardableResult public func performKnowledge(_ command: KnowledgeCommand) throws -> KnowledgeSnapshot {
        var value = try knowledge()
        func replace<T: Identifiable>(_ item: T, in values: inout [T]) { if let i = values.firstIndex(where: { $0.id == item.id }) { values[i] = item } else { values.append(item) } }
        func verify(_ source: KnowledgeSource) throws {
            let record = try bookRecord(source.anchor.bookID)
            try source.anchor.validate(bookID: record.id, revision: record.revision)
        }
        switch command {
        case .saveCard(let card): for source in card.sources { try verify(source) }; replace(card, in: &value.cards)
        case .removeCard(let id):
            value.cards.removeAll { $0.id == id }
            for i in value.boards.indices { value.boards[i].nodes.removeAll { $0.id == id }; value.boards[i].edges.removeAll { $0.from == id || $0.to == id } }
        case .saveBoard(let board): replace(board, in: &value.boards)
        case .removeBoard(let id): value.boards.removeAll { $0.id == id }
        case .placeNode(let id, let node):
            guard let i = value.boards.firstIndex(where: { $0.id == id }) else { throw ReaderError.invalidAnchor }; replace(node, in: &value.boards[i].nodes)
        case .connect(let id, let edge):
            guard let i = value.boards.firstIndex(where: { $0.id == id }) else { throw ReaderError.invalidAnchor }; replace(edge, in: &value.boards[i].edges)
        case .disconnect(let id, let edge):
            guard let i = value.boards.firstIndex(where: { $0.id == id }) else { throw ReaderError.invalidAnchor }; value.boards[i].edges.removeAll { $0.id == edge }
        case .savePath(let path): for step in path.steps { try verify(step.source) }; replace(path, in: &value.paths)
        case .removePath(let id): value.paths.removeAll { $0.id == id }
        case .metadata(let item): guard try books().contains(where: { $0.id == item.bookID }) else { throw ReaderError.unavailableSource }; replace(item, in: &value.metadata)
        case .restoreCard(let card, let boards):
            if !value.cards.contains(where: { $0.id == card.id }) { value.cards.append(card) }
            for old in boards {
                guard let i = value.boards.firstIndex(where: { $0.id == old.id }), let node = old.nodes.first(where: { $0.id == card.id }) else { continue }
                replace(node, in: &value.boards[i].nodes)
                let ids = Set(value.boards[i].nodes.map(\.id))
                for edge in old.edges where (edge.from == card.id || edge.to == card.id) && ids.contains(edge.from) && ids.contains(edge.to) {
                    if !value.boards[i].edges.contains(where: { $0.id == edge.id }) { value.boards[i].edges.append(edge) }
                }
            }
        case .merge(let incoming):
            try incoming.validate()
            // Archive imports preserve existing edits and retain unavailable sources explicitly.
            for card in incoming.cards where !value.cards.contains(where: { $0.id == card.id }) { value.cards.append(card) }
            for board in incoming.boards where !value.boards.contains(where: { $0.id == board.id }) { value.boards.append(board) }
            for path in incoming.paths where !value.paths.contains(where: { $0.id == path.id }) { value.paths.append(path) }
            for item in incoming.metadata where !value.metadata.contains(where: { $0.id == item.id }) { value.metadata.append(item) }
        }
        let data = try value.encoded(); guard data.count <= 48 * 1024 * 1024 else { throw CompanionError.limitExceeded }
        let url = root.appendingPathComponent("Knowledge/Memory.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic); return value
    }
}
