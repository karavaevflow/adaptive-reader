import Foundation
import Observation
import ReaderCore

@MainActor @Observable
final class KnowledgeModel {
    var visible = false
    var tab = "memory"
    var memory = KnowledgeSnapshot()
    var books: [BookRecord] = []
    var query = ""
    var titleFilter = ""
    var authorFilter = ""
    var collectionFilter = ""
    var savedOnly = false
    var selectedBooks = Set<UUID>()
    var hits: [KnowledgeSearchHit] = []
    var selectedHits = Set<String>()
    var issues: [String] = []
    var semanticAvailable = false
    var truncated = false
    var busy = false
    var progress = 0.0
    var operationLabel = "Searching library"
    var hasSearched = false
    var errorMessage: String?
    var statusMessage: String?
    var draft: KnowledgeCard?
    var boardID: UUID?
    var selectedNodes = Set<UUID>()
    var timelineBook: UUID?
    var timeline: [ReadingPathStep] = []
    var answer: CompanionAnswer?
    var answerSources: [KnowledgeSearchHit] = []
    var settings = CompanionSettings()
    var deleted: KnowledgeSnapshot?
    var deletedCardID: UUID?
    var comparisonVisible = false
    private var pendingCompanionPresentation = false
    var undoMovement: (UUID, CanvasNode)?
    @ObservationIgnored private var store: LibraryStore?
    @ObservationIgnored private var index: KnowledgeSearchIndex?
    @ObservationIgnored private weak var session: ReaderSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var reloading = false
    var canCapture: Bool { session?.record != nil && session?.engine?.capabilities.contains(.textSelection) == true }
    var board: KnowledgeBoard? { memory.boards.first { $0.id == boardID } }
    func configure(store: LibraryStore, session: ReaderSession) { self.store = store; self.session = session; index = KnowledgeSearchIndex(store: store) }
    func show() { visible = true; Task { await reload() } }
    func reload() async {
        guard let store, !reloading else { return }
        reloading = true; defer { reloading = false }
        do {
            memory = try await store.knowledge(); books = try await store.books(); settings = try await store.companionSettings()
            #if DEBUG || FOUNDATION_BENCHMARK
            let args = ProcessInfo.processInfo.arguments
            let isolatedStore = args.firstIndex(of: "-phase0Store").flatMap { i in args.indices.contains(i + 1) ? UUID(uuidString: args[i + 1]) : nil } != nil
            if memory.cards.isEmpty, args.contains("-knowledgeReview"), isolatedStore, let session, session.record != nil {
                let (anchor, text) = try session.study.source()
                let source = KnowledgeSource(anchor: anchor, bookTitle: session.title, location: KnowledgeSearchIndex.location(anchor), quotation: String(text.prefix(1600)))
                let cards = [
                    KnowledgeCard(title: "A source passage", kind: .quotation, text: source.quotation, sources: [source]),
                    KnowledgeCard(title: "A reader's idea", kind: .readerNote, text: "A reader-authored connection between attention and recall.", comment: "My working idea", tags: ["Memory"], sources: [source]),
                    KnowledgeCard(title: "Visual inference fixture", kind: .modelInference, text: "Visual test fixture only. No model request was made.", sources: [source])
                ]
                for card in cards { memory = try await store.performKnowledge(.saveCard(card)) }
                let nodes = cards.enumerated().map { CanvasNode(cardID: $0.element.id, point: .init(x: Double($0.offset % 2) * 300, y: Double($0.offset / 2) * 210), cluster: "Memory") }
                let board = KnowledgeBoard(title: "Reading Canvas", nodes: nodes, edges: [.init(from: cards[0].id, to: cards[1].id, label: "Reader connection")])
                memory = try await store.performKnowledge(.saveBoard(board))
                memory = try await store.performKnowledge(.savePath(.init(goal: "Visual fixture path", steps: [.init(title: "Return to the source", source: source)])))
            }
            #endif
            if !memory.boards.contains(where: { $0.id == boardID }) { boardID = memory.boards.first?.id }
            if timelineBook == nil { timelineBook = session?.record?.id ?? books.first?.id }
        } catch { report(error) }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false }
    func close() { cancel(); visible = false }
    func report(_ error: Error) { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Knowledge error") }
    @discardableResult func perform(_ command: KnowledgeCommand) async -> Bool {
        guard let store else { return false }
        do { memory = try await store.performKnowledge(command)
            switch command {
            case .saveCard, .removeCard, .restoreCard, .merge: await index?.clearTransientCache()
            default: break
            }
            errorMessage = nil; return true }
        catch { report(error); return false }
    }
    func capture(kind: KnowledgeKind = .quotation) {
        do {
            guard let session else { return }
            let (anchor, text) = try session.study.source()
            let source = KnowledgeSource(anchor: anchor, bookTitle: session.title, location: KnowledgeSearchIndex.location(anchor), quotation: String(text.prefix(1600)))
            draft = .init(title: String(source.quotation.prefix(60)), kind: kind, text: kind == .quotation ? source.quotation : "", sources: [source]); show(); tab = "memory"
        } catch { report(error); show() }
    }
    func saveDraft(_ value: KnowledgeCard) async {
        if await perform(.saveCard(value)) { draft = nil }
    }
    func captureCompanionAnswer() {
        guard let session, let answer = session.companion.answer, answer.kind == .book else { return }
        let sources = session.companion.evidence.filter { answer.sourceIDs.contains($0.id) }.map {
            KnowledgeSource(anchor: $0.anchor, bookTitle: session.title, location: KnowledgeSearchIndex.location($0.anchor), quotation: String($0.text.prefix(1600)))
        }
        guard !sources.isEmpty else { return }
        draft = .init(title: String(session.companion.query.prefix(120)), kind: .modelInference, text: answer.answer, sources: sources)
        tab = "memory"
        let compact = (session.surfaceView?.window?.contentView?.bounds.width ?? 800) < Adaptive.Layout.inspectorThreshold
        pendingCompanionPresentation = compact
        session.companionVisible = false
        if !compact { show() }
    }
    func finishCompanionTransition() {
        if pendingCompanionPresentation { pendingCompanionPresentation = false; show() }
    }
    func saveHit(_ hit: KnowledgeSearchHit) {
        draft = .init(title: String(hit.text.prefix(60)), kind: hit.kind, text: hit.text, sources: [hit.source])
    }
    func removeCard(_ id: UUID) async {
        let previous = memory
        if await perform(.removeCard(id)) { deleted = previous; deletedCardID = id }
    }
    func undoDeletion() async {
        guard let deleted, let card = deleted.cards.first(where: { $0.id == deletedCardID }) else { return }
        if await perform(.restoreCard(card, boards: deleted.boards)) { self.deleted = nil }
    }
    func newBoard() async {
        let base = NSLocalizedString("Reading Canvas", comment: "Board")
        let names = Set(memory.boards.map(\.title))
        var title = base, suffix = 2
        while names.contains(title) { title = base + " " + String(suffix); suffix += 1 }
        let board = KnowledgeBoard(title: title)
        if await perform(.saveBoard(board)) { boardID = board.id; tab = "canvas" }
    }
    func addToBoard(_ card: KnowledgeCard) async {
        if board == nil { await newBoard() }
        guard let board, !board.nodes.contains(where: { $0.id == card.id }) else { tab = "canvas"; return }
        let count = board.nodes.count
        _ = await perform(.placeNode(board: board.id, node: .init(cardID: card.id, point: .init(x: Double(count % 3) * 300, y: Double(count / 3) * 210))))
        tab = "canvas"
    }
    func move(_ node: CanvasNode, to point: CanvasPoint) async {
        guard let boardID else { return }; var moved = node; moved.point = point
        if await perform(.placeNode(board: boardID, node: moved)) { undoMovement = (boardID, node) }
    }
    func connect(label: String) async {
        guard let boardID, selectedNodes.count == 2 else { return }
        let ids = selectedNodes.sorted { $0.uuidString < $1.uuidString }
        _ = await perform(.connect(board: boardID, edge: .init(from: ids[0], to: ids[1], label: label)))
    }
    func search() {
        guard let index else { return }; cancel(); answer = nil; answerSources = []; selectedHits = []; errorMessage = nil; statusMessage = nil; hits = []; busy = true; hasSearched = true; operationLabel = "Searching library"
        let token = generation, query = query
        let progressModel = self
        let filter = KnowledgeSearchFilter(bookIDs: selectedBooks, title: titleFilter, author: authorFilter, collection: collectionFilter, savedOnly: savedOnly)
        task = Task { [weak self] in
            do {
                let result = try await index.search(query, filter: filter) { done, count in
                    await progressModel.updateProgress(done, total: count, token: token)
                }
                guard let self, !Task.isCancelled, generation == token else { return }
                hits = result.hits; issues = result.issues; semanticAvailable = result.semanticAvailable; truncated = result.truncated; busy = false; task = nil
            } catch { guard let self, !Task.isCancelled, generation == token else { return }; busy = false; report(error) }
        }
    }
    private func updateProgress(_ done: Int, total: Int, token: UUID) {
        if generation == token { progress = Double(done) / Double(max(1, total)) }
    }
    func open(_ source: KnowledgeSource) async {
        guard let session else { return }
        do {
            guard let book = books.first(where: { $0.id == source.anchor.bookID }) else { throw ReaderError.unavailableSource }
            try source.anchor.validate(bookID: book.id, revision: book.revision)
            try await session.openKnowledgeSource(source)
            close()
        } catch { report(error) }
    }
    func resetIndex() async {
        guard let store else { return }
        cancel(); busy = true; operationLabel = "Resetting index"; defer { busy = false }; hits = []; answer = nil; answerSources = []
        await index?.clearTransientCache()
        do {
            for book in try await store.books() { try await store.invalidateKnowledgeCache(for: book) }
            statusMessage = NSLocalizedString("Index cleared. The next search rebuilds it locally.", comment: "Index status")
        } catch { report(error) }
    }
    func loadTimeline() {
        guard let index, let book = books.first(where: { $0.id == timelineBook }) else { return }
        cancel(); busy = true; operationLabel = "Preparing timeline"; timeline = []; errorMessage = nil
        let token = generation, memory = memory
        task = Task { [weak self] in
            do {
                let values = try await index.timeline(for: book, memory: memory)
                guard let self, !Task.isCancelled, generation == token else { return }; timeline = values; busy = false
            } catch { guard let self, !Task.isCancelled, generation == token else { return }; busy = false; report(error) }
        }
    }
    func suggestPath() async {
        let selected = hits.filter { selectedHits.isEmpty || selectedHits.contains($0.id) }
        let path = KnowledgeSearchIndex.suggestPath(goal: query, hits: selected)
        if await perform(.savePath(path)) { tab = "paths" }
    }
    func ask(compare: Bool) {
        guard let store else { return }
        let chosen = hits.filter { selectedHits.contains($0.id) && $0.kind == .quotation }.prefix(8)
        let sources = Array(chosen)
        guard !sources.isEmpty, !compare || Set(sources.map { $0.source.anchor.bookID }).count >= 2 else { errorMessage = NSLocalizedString("Select excerpts from at least two books to compare.", comment: "Comparison"); return }
        cancel(); busy = true; operationLabel = "Receiving answer"; errorMessage = nil; answer = nil; answerSources = sources
        let token = generation, query = query
        task = Task { [weak self] in await self?.runQuestion(store: store, sources: sources, token: token, query: query, compare: compare) }
    }
    private func runQuestion(store: LibraryStore, sources: [KnowledgeSearchHit], token: UUID, query: String, compare: Bool) async {
        do {
            let settings = try await store.companionSettings()
            _ = try settings.validatedURL(); try await store.authorizeCompanion(settings)
            let key: String
            if settings.mode == .cloud { key = try await CompanionKeyVault.shared.read(settings.destination) } else { key = "" }
            try Task.checkCancellation(); try await store.authorizeCompanion(settings)
            let evidence: [EvidencePassage] = sources.map { hit in
                let label = "Book: " + hit.source.bookTitle + "\nLocation: " + hit.source.location
                return EvidencePassage(id: hit.id, anchor: hit.source.anchor, text: String((label + "\nExcerpt: " + hit.source.quotation).prefix(1400)))
            }
            let prefix = compare ? "Compare these selected books. " : ""
            let question = String((prefix + query).prefix(3900))
            let request = CompanionRequest(question: question, title: "Selected library sources", page: nil, sources: evidence, scope: .library)
            var response = ""
            for try await chunk in CompanionHTTPProvider(settings: settings, apiKey: key).response(to: request) {
                try Task.checkCancellation(); response += chunk; guard response.count <= 64000 else { throw CompanionError.limitExceeded }
            }
            let answer = try JSONDecoder().decode(CompanionAnswer.self, from: Data(response.utf8))
            try answer.validateLibrary(sources: evidence, comparing: compare)
            guard !Task.isCancelled, generation == token else { return }; self.answer = answer; busy = false; task = nil
        } catch { guard !Task.isCancelled, generation == token else { return }; busy = false; task = nil; report(error) }
    }

    func saveAnswer() {
        guard let answer, answer.kind == .book else { return }
        let sources = answerSources.filter { answer.sourceIDs.contains($0.id) }.map(\.source)
        draft = .init(title: String(query.prefix(120)), kind: .modelInference, text: answer.answer, sources: sources)
    }
}
