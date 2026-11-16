import SwiftUI
import ReaderCore
import PDFKit
import Combine

@MainActor @Observable
final class ExtendedReadingModel {
    var visible = false
    var tab = "split"
    var snapshot = ExtendedReadingSnapshot()
    var books: [BookRecord] = []
    var secondary: SplitPane?
    var activePane = "primary"
    var syncPositions = false
    var errorMessage: String?
    var busy = false
    var ocrRunning = false
    var ocrPage: OCRPage?
    var ocrQuery = ""
    var translation = ""
    var language = "Русский"
    var explanation = ""
    var capturedSource: KnowledgeSource?
    var word = ""
    var meaning = ""
    var selectedFragment: UUID?
    @ObservationIgnored private var store: LibraryStore?
    @ObservationIgnored private weak var session: ReaderSession?
    @ObservationIgnored private var ocrTask: Task<Void, Never>?
    @ObservationIgnored private var ocrWorker: DocumentOCR?
    @ObservationIgnored private var ocrToken = UUID()
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var openToken = UUID()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var lastAnchor: SourceAnchor?
    @ObservationIgnored private var lastInteraction = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var pendingSeconds = 0.0
    @ObservationIgnored private var pendingBook: UUID?
    @ObservationIgnored private var lastSecondaryAnchor: SourceAnchor?
    @ObservationIgnored private var readingClock = ActiveReadingClock()
    @ObservationIgnored private var pendingExplanation: KnowledgeSource?
    @ObservationIgnored private var reviewSeeded = false
    var trackingTime: Bool { snapshot.insightsEnabled }
    var activeAnchor: SourceAnchor? {
        if activePane == "secondary", let secondary { return try? secondary.engine.currentAnchor() }
        return try? session?.engine?.currentAnchor()
    }

    func configure(store: LibraryStore, session: ReaderSession) { self.store = store; self.session = session }
    func show() {
        visible = true
        Task { await reload() }
    }
    func reload() async {
        guard let store else { return }
        do {
            snapshot = try await store.extendedReading(); books = try await store.books()
            #if DEBUG || FOUNDATION_BENCHMARK
            let args = ProcessInfo.processInfo.arguments
            let isolated = args.firstIndex(of: "-phase0Store").flatMap { i in args.indices.contains(i + 1) ? UUID(uuidString: args[i + 1]) : nil } != nil
            if args.contains("-extendedReview"), isolated, !reviewSeeded, let session, let book = session.record {
                reviewSeeded = true
                let (anchor, text) = try session.study.source()
                let source = KnowledgeSource(anchor: anchor, bookTitle: book.title, location: "1", quotation: String(text.prefix(1600)))
                let fragment = BilingualFragment(source: source, translation: "Тихое место для чтения. Книга открывает пространство для мысли.", language: "Русский", explanation: "A quiet place — тихое место; reader-authored visual fixture.")
                snapshot = try await store.performExtended(.saveFragment(fragment))
                snapshot = try await store.performExtended(.saveWord(.init(fragmentID: fragment.id, word: "quiet", meaning: "тихий, спокойный")))
                snapshot = try await store.performExtended(.setTracking(replay: true, insights: true))
                snapshot = try await store.performExtended(.record(.init(kind: .opened, anchor: anchor, date: Date(timeIntervalSince1970: 1800000000)), generation: snapshot.generation))
                snapshot = try await store.performExtended(.record(.init(kind: .chapterCompleted, anchor: anchor, date: Date(timeIntervalSince1970: 1800000060)), generation: snapshot.generation))
                snapshot = try await store.performExtended(.activeTime(book: book.id, seconds: 60, generation: snapshot.generation))
                snapshot = try await store.performExtended(.setTracking(replay: false, insights: false))
                if let pdf = session.pdfEngine, let page = pdf.document.page(at: 0) {
                    let box = page.bounds(for: .cropBox), bounds = CGRect(x: box.minX + 64, y: box.maxY - 100, width: 300, height: 20)
                    let lineAnchor = SourceAnchor(bookID: book.id, sourceRevision: book.revision, position: .pdf(.init(pageIndex: 0, x: bounds.minX, y: bounds.maxY)))
                    ocrPage = OCRPage(bookID: book.id, revision: book.revision, pageIndex: 0, lines: [.init(anchor: lineAnchor, text: "Visual OCR fixture: check this uncertain word", confidence: 0.42, bounds: bounds)])
                }
            }
            #endif
        }
        catch { errorMessage = error.localizedDescription }
    }
    func perform(_ command: ExtendedReadingCommand) async {
        guard let store else { return }
        switch command {
        case .clearInsights, .clearReplay, .setTracking:
            pendingSeconds = 0; pendingBook = nil; readingClock.reset(); interaction(); eventTask?.cancel(); eventTask = nil
        default: break
        }
        do { snapshot = try await store.performExtended(command); errorMessage = nil; session?.refreshExtendedActivity() }
        catch { errorMessage = error.localizedDescription }
    }
    func startSplit(_ book: BookRecord, anchor: SourceAnchor? = nil) {
        openTask?.cancel(); let token = UUID(); openToken = token; busy = true
        openTask = Task { [weak self] in
            guard let self, let store else { return }
            do {
                let (record, data, state) = try await store.openBook(book.id)
                let engine = try await ReaderEngineFactory.open(data: data, format: record.format, bookID: record.id)
                try Task.checkCancellation(); guard openToken == token else { return }
                let saved = anchor ?? (snapshot.splitPosition?.anchor.bookID == book.id ? snapshot.splitPosition?.anchor : state?.anchor)
                let palette = snapshot.splitPosition?.anchor.bookID == book.id ? snapshot.splitPosition?.palette : state?.palette
                let pane = SplitPane(record: record, engine: engine, anchor: saved, palette: palette ?? .original)
                pane.onChange = { [weak self] in self?.secondaryMoved() }
                pane.onInteraction = { [weak self] in self?.activePane = "secondary"; self?.interaction() }
                session?.prepareSurfaceTransition()
                secondary?.close(); secondary = pane; activePane = "secondary"; visible = false
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
            if openToken == token { busy = false; openTask = nil }
        }
    }
    func closeSplit() {
        if secondary != nil { session?.prepareSurfaceTransition() }
        saveTask?.cancel(); saveTask = nil
        if let pane = secondary, let anchor = try? pane.engine.currentAnchor() {
            let position = SplitPosition(anchor: anchor, palette: pane.engine.palette)
            saveTask = Task { await perform(.saveSplit(position)) }
        }
        secondary?.close(); secondary = nil; activePane = "primary"; syncPositions = false; lastSecondaryAnchor = nil
    }
    func swap() {
        guard let session, let pane = secondary, let primary = session.record,
              let left = try? session.engine?.currentAnchor(), let right = try? pane.engine.currentAnchor() else { return }
        let target = pane.record
        Task {
            closeSplit(); await session.openBook(target)
            guard session.record?.id == target.id else { return }
            session.navigate(to: right); startSplit(primary, anchor: left)
        }
    }
    func flush() async { await saveTask?.value }
    func primaryMoved() {
        guard let anchor = try? session?.engine?.currentAnchor() else { return }
        if lastAnchor != anchor { record(.navigation, anchor: anchor); lastAnchor = anchor }
        if syncPositions, activePane == "primary", let pane = secondary, pane.record.id == anchor.bookID,
           (try? pane.engine.currentAnchor()) != anchor { pane.navigate(anchor) }
    }
    private func secondaryMoved() {
        guard let pane = secondary, let anchor = try? pane.engine.currentAnchor() else { return }
        if activePane == "secondary", lastSecondaryAnchor != anchor { record(.navigation, anchor: anchor); lastSecondaryAnchor = anchor }
        saveTask?.cancel()
        let position = SplitPosition(anchor: anchor, palette: pane.engine.palette)
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)); try Task.checkCancellation(); await self?.perform(.saveSplit(position)) } catch {}
        }
        // Synchronization is explicit and restricted to identical source revisions.
        if syncPositions, activePane == "secondary", let session, session.record?.id == pane.record.id,
           session.record?.revision == pane.record.revision, (try? session.engine?.currentAnchor()) != anchor { session.navigate(to: anchor) }
    }
    func capture() {
        do {
            guard let session, let engine = session.engine, let record = session.record else { throw ReaderError.unavailableSource }
            let passage = try engine.textPassage(at: engine.currentAnchor())
            guard !passage.text.isEmpty else { throw ReaderError.unsupportedCommand }
            capturedSource = KnowledgeSource(anchor: passage.anchor, bookTitle: record.title, location: "\(session.pageNumber)", quotation: String(passage.text.prefix(1600)))
            translation = ""; explanation = ""
        } catch { errorMessage = error.localizedDescription }
    }
    func saveTranslation() async {
        guard let capturedSource else { return }
        let fragment = BilingualFragment(source: capturedSource, translation: translation, language: language, explanation: explanation)
        await perform(.saveFragment(fragment)); selectedFragment = fragment.id
    }
    func explain(_ source: KnowledgeSource) {
        pendingExplanation = source; visible = false
    }
    func finishPresentation() {
        guard let source = pendingExplanation, let session else { return }; pendingExplanation = nil
        session.companion.selection = EvidencePassage(id: "bilingual-" + UUID().uuidString, anchor: source.anchor, text: source.quotation)
        session.companion.selectionLabel = String(source.quotation.prefix(80))
        session.companion.query = String(format: NSLocalizedString("Translate the selected fragment into %@ and explain idioms and word meanings in context. Cite the original. Label any uncertain interpretation.", comment: "Bilingual prompt"), language)
        session.companionVisible = true
    }
    func saveWord() async {
        guard let selectedFragment else { return }
        await perform(.saveWord(.init(fragmentID: selectedFragment, word: word, meaning: meaning)))
        if errorMessage == nil { word = ""; meaning = "" }
    }
    func recognizePage() {
        cancelOCR(); errorMessage = nil
        guard let session, let book = session.record, let pdf = session.pdfEngine,
              case .pdf(let position) = try? pdf.currentAnchor().position, let store else { return }
        let worker = DocumentOCR(), token = UUID(); ocrWorker = worker; ocrToken = token; ocrRunning = true; ocrPage = nil
        ocrTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: OCRPage
                if let cached = try await store.cachedOCR(for: book, pageIndex: position.pageIndex) { result = cached }
                else {
                    let (_, data, _) = try await store.openBook(book.id)
                    result = try await worker.recognize(data: data, bookID: book.id, revision: book.revision, pageIndex: position.pageIndex)
                    try Task.checkCancellation(); guard ocrToken == token else { return }
                    try await store.cacheOCR(result, for: book)
                }
                try Task.checkCancellation(); guard ocrToken == token, session.record?.id == book.id else { return }
                try pdf.installRecognizedPage(result)
                ocrPage = result
            } catch is CancellationError {} catch { if ocrToken == token { errorMessage = error.localizedDescription } }
            if ocrToken == token { ocrRunning = false; ocrWorker = nil; ocrTask = nil }
        }
    }
    func cancelOCR() { ocrToken = UUID(); ocrWorker?.cancel(); ocrTask?.cancel(); ocrWorker = nil; ocrTask = nil; ocrRunning = false }
    func reveal(_ anchor: SourceAnchor) {
        guard let session else { return }
        visible = false
        Task {
            if session.record?.id != anchor.bookID, let book = books.first(where: { $0.id == anchor.bookID }) { await session.openBook(book) }
            session.navigate(to: anchor)
        }
    }
    func record(_ kind: ReadingEventKind, anchor: SourceAnchor? = nil) {
        guard snapshot.replayEnabled || snapshot.insightsEnabled,
              let anchor = anchor ?? (try? session?.engine?.currentAnchor()), let store else { return }
        let generation = snapshot.generation, event = ReadingEvent(kind: kind, anchor: anchor)
        // Navigation is debounced; note/open/question events are retained individually.
        if kind == .navigation { eventTask?.cancel() }
        let task = Task { [weak self] in
            do {
                if kind == .navigation { try await Task.sleep(for: .seconds(2)) }
                try Task.checkCancellation()
                let updated = try await store.performExtended(.record(event, generation: generation))
                self?.snapshot = updated
            } catch is CancellationError {} catch { self?.errorMessage = error.localizedDescription }
        }
        if kind == .navigation { eventTask = task }
    }
    func interaction() { lastInteraction = ProcessInfo.processInfo.systemUptime }
    func primaryInteraction() { activePane = "primary"; interaction() }
    func tick(now: Double) {
        let eligible = snapshot.insightsEnabled && NSApp.isActive && session?.surfaceView?.window?.isKeyWindow == true
            && session?.surfaceView?.window?.occlusionState.contains(.visible) == true && !visible && now - lastInteraction < 60
        let elapsed = readingClock.sample(now: now, eligible: eligible)
        guard elapsed > 0, let anchor = activeAnchor else { return }
        if let pendingBook, pendingBook != anchor.bookID { checkpointTime() }
        pendingBook = anchor.bookID
        pendingSeconds += elapsed
        if pendingSeconds >= 15 { checkpointTime() }
    }
    private func checkpointTime() {
        guard let book = pendingBook, pendingSeconds > 0 else { return }
        let seconds = min(pendingSeconds, 60), generation = snapshot.generation
        pendingSeconds = 0; pendingBook = nil
        Task { await perform(.activeTime(book: book, seconds: seconds, generation: generation)) }
    }
    func stop() {
        checkpointTime()
        readingClock.reset()
        cancelOCR(); openToken = UUID(); openTask?.cancel(); openTask = nil; busy = false
        eventTask?.cancel(); eventTask = nil; closeSplit(); lastAnchor = nil; pendingSeconds = 0
        capturedSource = nil; ocrPage = nil; translation = ""; explanation = ""; selectedFragment = nil
    }
}

@MainActor @Observable
final class SplitPane {
    let id = UUID()
    let record: BookRecord
    let engine: any ReaderEngine
    let commands: ReaderCommands
    var errorMessage: String?
    var onChange: (() -> Void)?
    var onInteraction: (() -> Void)?
    var section = 1
    @ObservationIgnored private var initialAnchor: SourceAnchor?
    @ObservationIgnored private var initialPalette: PagePalette
    @ObservationIgnored private var mounted = false
    @ObservationIgnored private var observers = Set<AnyCancellable>()
    init(record: BookRecord, engine: any ReaderEngine, anchor: SourceAnchor?, palette: PagePalette) {
        self.record = record; self.engine = engine; self.commands = ReaderCommands(engine: engine); initialAnchor = anchor; initialPalette = palette
    }
    func mount() {
        guard !mounted else { return }; mounted = true
        do {
            try commands.perform(.setPalette(initialPalette))
            if let pdf = engine as? PDFReaderEngine {
                pdf.view.layoutDocumentView(); pdf.view.autoScales = true
                NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: pdf.view).sink { [weak self] _ in Task { @MainActor in self?.changed() } }.store(in: &observers)
                if let clip = pdf.view.documentView?.enclosingScrollView?.contentView {
                    clip.postsBoundsChangedNotifications = true
                    NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: clip).sink { [weak self] _ in Task { @MainActor in self?.changed() } }.store(in: &observers)
                }
                pdf.onManualInteraction = { [weak self] in self?.onInteraction?() }
            }
            if let epub = engine as? EPUBReaderEngine {
                epub.onPositionChanged = { [weak self] in self?.changed() }
                epub.onManualInteraction = { [weak self] in self?.onInteraction?() }; epub.start()
            }
            if let initialAnchor { try commands.perform(.navigate(initialAnchor)) }
            changed()
        } catch { errorMessage = error.localizedDescription }
    }
    func changed() {
        if let anchor = try? engine.currentAnchor() {
            switch anchor.position {
            case .pdf(let point): section = point.pageIndex + 1
            case .epub(let resource, _): section = ((engine as? EPUBReaderEngine)?.publication.readingResources.firstIndex { $0.resource == resource } ?? 0) + 1
            }
        }
        onChange?()
    }
    func nextSection() {
        do {
            let anchor: SourceAnchor
            if let pdf = engine as? PDFReaderEngine {
                let index = min(section, pdf.document.pageCount - 1)
                guard let page = pdf.document.page(at: index) else { return }
                let box = page.bounds(for: .cropBox)
                anchor = .init(bookID: engine.bookID, sourceRevision: engine.sourceRevision, position: .pdf(.init(pageIndex: index, x: box.minX, y: box.maxY)))
            } else if let epub = engine as? EPUBReaderEngine {
                let index = min(section, epub.publication.readingResources.count - 1)
                anchor = .init(bookID: engine.bookID, sourceRevision: engine.sourceRevision, position: .epub(resource: epub.publication.readingResources[index].resource, locator: EPUBTextLocator(offset: 0).encoded))
            } else { return }
            try commands.perform(.navigate(anchor)); changed()
        } catch { errorMessage = error.localizedDescription }
    }
    func navigate(_ anchor: SourceAnchor) { perform(.navigate(anchor)) }
    func perform(_ command: ApplicationCommand) {
        do { try commands.perform(command); changed() } catch { errorMessage = error.localizedDescription }
    }
    func close() { observers.removeAll(); engine.cancelSearch(); (engine as? EPUBReaderEngine)?.stop(); onChange = nil }
}
