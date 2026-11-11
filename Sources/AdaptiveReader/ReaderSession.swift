import SwiftUI
import ReaderCore
import PDFKit
import Combine

@MainActor
@Observable
final class ReaderSession {
    var engine: PDFReaderEngine?
    var commands: ReaderCommands?
    var title = "Adaptive Reader"
    var busy = false
    var errorMessage: String?
    var pageNumber = 1
    var scale = 1.0
    var books: [BookRecord] = []
    var states: [UUID: ReadingState] = [:]
    var bookmarks: [ReaderBookmark] = []
    var searchQuery = ""
    var searchMatches: [ReaderSearchMatch] = []
    var searching = false
    var searchLimitReached = false
    var checkingText = false
    var keepAwake = false
    var focusMode = false
    var record: BookRecord?
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let awake = DisplayAwake()
    @ObservationIgnored private var pendingState: ReadingState?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var textTask: Task<Void, Never>?
    @ObservationIgnored private var mounted = false
    @ObservationIgnored private var bookmarkUpdating = false
    @ObservationIgnored private var active = true

    init() {
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AdaptiveReader", isDirectory: true)
        #if DEBUG || FOUNDATION_BENCHMARK
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-designReview") {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaptiveReader-DesignReview-\(UUID().uuidString)")
        } else if let index = arguments.firstIndex(of: "-phase0Store"), index + 1 < arguments.count,
           let id = UUID(uuidString: arguments[index + 1]) {
            root = root.appendingPathComponent("Phase0Tests/\(id.uuidString)")
        }
        #endif
        store = ReaderStores.store(at: root)
        SessionRegistry.shared.add(self)
    }

    func refreshLibrary() async {
        do {
            books = try await store.books()
            var positions: [UUID: ReadingState] = [:]
            for book in books { positions[book.id] = try await store.readingState(for: book) }
            states = positions
        } catch { report(error) }
    }

    func restore() async {
        guard engine == nil else { return }
        busy = true
        defer { busy = false }
        await refreshLibrary()
        do {
            guard let (record, data, state) = try await store.lastBook(), active, !Task.isCancelled else { return }
            try await load(record: record, data: data, state: state)
        } catch { report(error) }
    }

    func openBook(_ book: BookRecord) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            await flush()
            let (record, data, state) = try await store.openBook(book.id)
            guard active, !Task.isCancelled else { return }
            try await load(record: record, data: data, state: state)
            try await store.setCurrentBook(record.id)
        } catch { report(error) }
    }

    private func load(record: BookRecord, data: Data, state: ReadingState?) async throws {
        let prepared = await Task.detached(priority: .userInitiated) { PreparedPDFSource(data: data) }.value
        guard active, !Task.isCancelled else { return }
        let candidate = try PDFReaderEngine(source: prepared, bookID: record.id)
        try candidate.applyPagePalette(state?.palette ?? .original)
        let marks = try await store.bookmarks(for: record)
        guard active, !Task.isCancelled else { return }
        install(candidate, title: record.title, record: record, state: state, bookmarks: marks, data: data)
    }

    func importURL(_ url: URL, asReference: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let (data, reference): (Data, Data?) = try await Task.detached(priority: .userInitiated) {
                let grant = url.startAccessingSecurityScopedResource()
                defer { if grant { url.stopAccessingSecurityScopedResource() } }
                let bookmark = asReference ? try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
                return (try Data(contentsOf: url), bookmark)
            }.value
            guard active, !Task.isCancelled else { return }
            try await importData(data, title: url.deletingPathExtension().lastPathComponent, reference: reference)
        } catch { report(error) }
    }

    func relinkURL(_ url: URL, book: BookRecord) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let (data, bookmark) = try await Task.detached(priority: .userInitiated) {
                let grant = url.startAccessingSecurityScopedResource()
                defer { if grant { url.stopAccessingSecurityScopedResource() } }
                return (try Data(contentsOf: url), try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil))
            }.value
            guard active, !Task.isCancelled else { return }
            let updated = try await store.relink(book.id, data: data, bookmark: bookmark)
            await flush()
            let state = try await store.readingState(for: updated)
            try await load(record: updated, data: data, state: state)
            try await store.setCurrentBook(updated.id)
            await refreshLibrary()
        } catch { report(error) }
    }

    func importData(_ data: Data, title: String, reference: Data? = nil) async throws {
        let prepared = await Task.detached(priority: .userInitiated) { PreparedPDFSource(data: data) }.value
        guard active, !Task.isCancelled else { return }
        let candidate = try PDFReaderEngine(source: prepared, bookID: UUID())
        let record = try await store.importBook(data: data, id: candidate.bookID, title: title, revision: candidate.sourceRevision, reference: reference, pageCount: candidate.document.pageCount)
        await flush()
        guard active, !Task.isCancelled else { return }
        install(candidate, title: title, record: record, state: nil, bookmarks: [], data: data)
        await refreshLibrary()
    }

    func openReview(_ data: Data) throws {
        install(try PDFReaderEngine(data: data, bookID: UUID()), title: "Reading specimen", record: nil, state: nil, bookmarks: [], data: data)
    }

    private func install(_ candidate: PDFReaderEngine, title: String, record: BookRecord?, state: ReadingState?, bookmarks: [ReaderBookmark], data: Data) {
        stopWork()
        awake.release(); keepAwake = false
        subscriptions.removeAll(); saving?.cancel()
        mounted = false; pendingState = state
        self.record = record; self.title = title; self.bookmarks = bookmarks
        engine = candidate; commands = ReaderCommands(engine: candidate)
        checkingText = true
        // An independent PDFDocument stays confined to this worker; no PDFKit objects cross actors.
        textTask = Task { [weak self, weak candidate] in
            let worker = Task.detached(priority: .utility) {
                guard let document = PDFDocument(data: data), document.allowsCopying else { return false }
                for index in 0..<document.pageCount {
                    if Task.isCancelled { return false }
                    if document.page(at: index)?.string?.isEmpty == false { return true }
                }
                return false
            }
            let available = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self, let candidate, self.engine === candidate else { return }
            candidate.updateTextAvailability(available); self.checkingText = false
            if !self.searchQuery.isEmpty { self.search(self.searchQuery) }
        }
    }

    func mount() {
        guard let engine, !mounted else { return }
        engine.view.layoutDocumentView()
        if let state = pendingState {
            if let raw = state.pdfDisplayMode, let mode = PDFDisplayMode(rawValue: raw) { engine.view.displayMode = mode }
            engine.view.autoScales = state.autoScales ?? false
            if !engine.view.autoScales { engine.view.scaleFactor = state.scale }
            engine.view.layoutDocumentView()
            if let anchor = state.anchor { do { try engine.navigate(to: anchor) } catch { report(error) } }
        }
        pendingState = nil; mounted = true
        scale = engine.view.scaleFactor
        pageNumber = engine.document.index(for: engine.view.currentPage ?? engine.document.page(at: 0)!) + 1
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
            center.publisher(for: name, object: engine.view).receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.positionChanged() }
            }.store(in: &subscriptions)
        }
        if let clip = engine.view.documentView?.enclosingScrollView?.contentView {
            clip.enclosingScrollView?.setAccessibilityIdentifier("reader.pages")
            clip.postsBoundsChangedNotifications = true
            center.publisher(for: NSView.boundsDidChangeNotification, object: clip).receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.positionChanged() }
            }.store(in: &subscriptions)
        }
        positionChanged()
    }

    private func positionChanged() {
        guard mounted, let engine else { return }
        scale = engine.view.scaleFactor
        if let page = engine.view.currentPage { pageNumber = engine.document.index(for: page) + 1 }
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func navigate(page: Int) {
        guard let engine, let target = engine.document.page(at: page - 1) else { return }
        let bounds = target.bounds(for: .cropBox)
        navigate(to: SourceAnchor(bookID: engine.bookID, sourceRevision: engine.sourceRevision,
            position: .pdf(.init(pageIndex: page - 1, x: bounds.minX, y: bounds.maxY))))
    }
    func navigate(to anchor: SourceAnchor) {
        do { try commands?.perform(.navigate(anchor)); positionChanged() } catch { report(error) }
    }
    func setPalette(_ palette: PagePalette) {
        do { try commands?.perform(.setPalette(palette)); subscriptions.removeAll(); mounted = false; mount() }
        catch { report(error) }
    }
    func undoPalette() {
        do { try commands?.undoPalette(); subscriptions.removeAll(); mounted = false; mount() } catch { report(error) }
    }
    func zoom(by factor: Double) {
        guard let engine else { return }
        do { try commands?.perform(.setScale(engine.view.scaleFactor * factor)); positionChanged() } catch { report(error) }
    }

    func search(_ query: String) {
        searchTask?.cancel(); engine?.cancelSearch()
        searchQuery = query; searchMatches = []; searching = false; searchLimitReached = false
        engine?.view.highlightedSelections = nil
        guard let engine, engine.capabilities.contains(.search), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searching = true
        searchTask = Task { [weak self, weak engine] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, let engine, self.engine === engine else { return }
            do {
                guard let commands = self.commands else { return }
                for try await match in try commands.search(query) {
                    guard !Task.isCancelled, self.engine === engine else { return }
                    self.searchMatches.append(match)
                }
                guard !Task.isCancelled, self.engine === engine else { return }
                self.searching = false; self.searchLimitReached = self.searchMatches.count >= 1000
            } catch { if !Task.isCancelled { self.searching = false; self.report(error) } }
        }
    }
    func selectMatch(_ match: ReaderSearchMatch) {
        do { try commands?.perform(.showSearchMatch(match)); positionChanged() } catch { report(error) }
    }

    var pageIsBookmarked: Bool {
        bookmarks.contains { if case .pdf(let point) = $0.anchor.position { point.pageIndex == pageNumber - 1 } else { false } }
    }
    func toggleBookmark() async {
        guard !bookmarkUpdating, let record, let engine else { return }
        bookmarkUpdating = true; defer { bookmarkUpdating = false }
        do {
            let updated = try await store.toggleBookmark(anchor: engine.currentAnchor(), title: engine.view.currentSelection?.string ?? "", for: record)
            if self.record?.id == record.id { bookmarks = updated }
        } catch { report(error) }
    }
    func removeBookmark(_ mark: ReaderBookmark) async {
        guard let record else { return }
        do {
            let updated = try await store.removeBookmark(mark.id, for: record)
            if self.record?.id == record.id { bookmarks = updated }
        } catch { report(error) }
    }
    func refreshBookmarks() async {
        guard let record else { return }
        do {
            let latest = try await store.bookmarks(for: record)
            if self.record?.id == record.id { bookmarks = latest }
        } catch { report(error) }
    }
    func toggleFavorite(_ book: BookRecord) async {
        do { try await store.toggleFavorite(book.id); await refreshLibrary() } catch { report(error) }
    }
    func setKeepAwake(_ enabled: Bool) {
        do { try awake.setEnabled(enabled && engine != nil); keepAwake = awake.isActive } catch { report(error) }
    }
    func closeBook() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        awake.release(); keepAwake = false; focusMode = false
        stopWork(); await flush(); saving?.cancel(); subscriptions.removeAll()
        engine = nil; commands = nil; record = nil; mounted = false; bookmarks = []; title = "Adaptive Reader"
        do { try await store.setCurrentBook(nil) } catch { report(error) }
        await refreshLibrary()
    }
    private func stopWork() {
        searchTask?.cancel(); textTask?.cancel()
        engine?.cancelSearch(); searchQuery = ""; searchMatches = []; searching = false; checkingText = false
    }
    func suspend() {
        active = false; awake.release(); keepAwake = false; stopWork(); saving?.cancel()
    }
    func flush() async {
        guard mounted, let engine, let commands, let record else { return }
        do {
            try await store.save(ReadingState(anchor: try engine.currentAnchor(), palette: commands.palette,
                scale: engine.view.scaleFactor, autoScales: engine.view.autoScales, pdfDisplayMode: engine.view.displayMode.rawValue), for: record)
        } catch { report(error) }
    }
    func report(_ error: Error) { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Reader error") }
}

@MainActor
private enum ReaderStores {
    static var stores: [URL: LibraryStore] = [:]
    static func store(at root: URL) -> LibraryStore {
        let key = root.standardizedFileURL
        if let store = stores[key] { return store }
        let store = LibraryStore(root: key); stores[key] = store; return store
    }
}

@MainActor
final class SessionRegistry {
    static let shared = SessionRegistry()
    private struct Entry { weak var session: ReaderSession? }
    private var entries: [Entry] = []
    func add(_ session: ReaderSession) { entries.removeAll { $0.session == nil }; entries.append(Entry(session: session)) }
    func flush() async { for entry in entries { entry.session?.setKeepAwake(false); await entry.session?.flush() } }
}

@MainActor
final class ReaderAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await SessionRegistry.shared.flush(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
