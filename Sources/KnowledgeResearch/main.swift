import Foundation
import ReaderCore
import Darwin

func milliseconds<T>(_ action: () throws -> T) rethrows -> (T, Double) {
    let start = ProcessInfo.processInfo.systemUptime
    let value = try action(); return (value, (ProcessInfo.processInfo.systemUptime - start) * 1000)
}
func percentile(_ values: [Double], _ p: Double) -> Double { let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }

@main struct KnowledgeResearch {
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else { throw ReaderError.unsupportedCommand }
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Adaptive-KnowledgeResearch-" + UUID().uuidString)
        let store = LibraryStore(root: root), index = KnowledgeSearchIndex(store: store)
        var books: [BookRecord] = [], sources: [KnowledgeSource] = []
        for i in 0..<20 {
            let epub = i % 2 == 1
            let data = try Data(contentsOf: fixtures.appendingPathComponent(epub ? "EPUB/reflow.epub" : "text.pdf"))
            let book = try await store.importBook(data: data, id: UUID(), title: "Control book \(i + 1)", revision: PDFReaderEngine.revision(data), format: epub ? .epub : .pdf)
            books.append(book)
            let anchor: SourceAnchor
            let quote: String
            if epub {
                let publication = try EPUBPublication(data: data), chapter = publication.readingResources[0]
                anchor = .init(bookID: book.id, sourceRevision: book.revision, position: .epub(resource: chapter.resource, locator: EPUBTextLocator(offset: 0, quote: String(chapter.text.prefix(60))).encoded))
                quote = String(chapter.text.prefix(300))
            } else { anchor = .init(bookID: book.id, sourceRevision: book.revision, position: .pdf(.init(pageIndex: 0, x: 0, y: 700))); quote = "Reading specimen. A stable anchor connects the reader to the original source." }
            sources.append(.init(anchor: anchor, bookTitle: book.title, location: KnowledgeSearchIndex.location(anchor), quotation: quote))
        }
        let cards = (0..<1000).map { i in KnowledgeCard(title: "Saved idea \(i)", kind: i % 3 == 0 ? .quotation : .readerNote, text: "Stable source anchors connect knowledge across books and keep reading routes traceable.", tags: ["Sources"], sources: [sources[i % sources.count]]) }
        let nodes = cards.enumerated().map { CanvasNode(cardID: $0.element.id, point: .init(x: Double($0.offset % 20) * 300, y: Double($0.offset / 20) * 210), cluster: "Group \($0.offset / 100)") }
        var edges: [CanvasEdge] = []
        for i in 0..<999 { edges.append(.init(from: cards[i].id, to: cards[i + 1].id, label: "Related")); if i < 998 { edges.append(.init(from: cards[i].id, to: cards[i + 2].id, label: "Supports")) } }
        let board = KnowledgeBoard(title: "Control board", nodes: nodes, edges: edges)
        try await store.performKnowledge(.merge(.init(cards: cards, boards: [board])))
        let coldStart = ProcessInfo.processInfo.systemUptime
        let cold = try await index.search("stable source anchors")
        let coldMS = (ProcessInfo.processInfo.systemUptime - coldStart) * 1000
        let warmStart = ProcessInfo.processInfo.systemUptime
        let warm = try await index.search("stable source anchors")
        let warmMS = (ProcessInfo.processInfo.systemUptime - warmStart) * 1000
        let openStart = ProcessInfo.processInfo.systemUptime
        let memory = try await store.knowledge()
        let openMS = (ProcessInfo.processInfo.systemUptime - openStart) * 1000
        var layoutTimes: [Double] = [], visibleCounts: [Int] = []
        for frame in 0..<120 {
            let (layout, time) = milliseconds {
                KnowledgeCanvasLayout(board: board, cards: cards, origin: .init(x: -Double(frame) * 20, y: -Double(frame) * 10), zoom: 0.8 + Double(frame % 20) / 100, viewport: .init(x: 1440, y: 760), translations: [nodes[0].id: .init(x: Double(frame), y: Double(frame))])
            }
            layoutTimes.append(time); visibleCounts.append(layout.visibleNodes.count)
        }
        var moveTimes: [Double] = []
        for i in 0..<5 {
            var node = nodes[i]; node.point.x += 40
            let start = ProcessInfo.processInfo.systemUptime
            try await store.performKnowledge(.placeNode(board: board.id, node: node))
            moveTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let task = Task { try await index.search("cancelled query") }
        let cancelStart = ProcessInfo.processInfo.systemUptime; task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        let cancelMS = (ProcessInfo.processInfo.systemUptime - cancelStart) * 1000
        let archive = try memory.encoded()
        let roundtrip = try JSONDecoder().decode(KnowledgeSnapshot.self, from: archive)
        guard roundtrip == memory, cold.hits.count > 0, warm.hits.count > 0, cancelled else { throw ReaderError.invalidAnchor }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let value: [String: Any] = ["books": books.count, "cards": cards.count, "nodes": nodes.count, "edges": edges.count,
            "coldSearchMS": coldMS, "cachedSearchMS": warmMS, "boardDataOpenMS": openMS,
            "canvasLayoutMedianMS": percentile(layoutTimes, 0.5), "canvasLayoutP95MS": percentile(layoutTimes, 0.95),
            "visibleCardCountMax": visibleCounts.max() ?? 0, "nodeSaveMedianMS": percentile(moveTimes, 0.5),
            "cancelMS": cancelMS, "cancelled": cancelled, "peakClientBytes": usage.ru_maxrss,
            "semanticAvailable": warm.semanticAvailable, "hits": warm.hits.count, "sourceIssues": warm.issues,
            "archiveBytes": archive.count, "markdownBytes": memory.markdown().utf8.count,
            "fixtureRevisions": Array(Set(books.map(\.revision))).sorted()]
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
