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
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private var record: BookRecord?
    @ObservationIgnored private var pendingState: ReadingState?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var mounted = false

    init() {
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AdaptiveReader", isDirectory: true)
        #if DEBUG || FOUNDATION_BENCHMARK
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-phase0Store"), index + 1 < arguments.count,
           let id = UUID(uuidString: arguments[index + 1]) {
            root = root.appendingPathComponent("Phase0Tests/\(id.uuidString)")
        }
        #endif
        store = LibraryStore(root: root)
        SessionRegistry.shared.add(self)
    }

    func restore() async {
        guard engine == nil else { return }
        busy = true
        defer { busy = false }
        do {
            guard let (record, data, state) = try await store.lastBook() else { return }
            let engine = try PDFReaderEngine(data: data, bookID: record.id)
            try engine.applyPagePalette(state?.palette ?? .original)
            install(engine, title: record.title, record: record, state: state)
        } catch { report(error) }
    }

    func importURL(_ url: URL) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let grant = url.startAccessingSecurityScopedResource()
                defer { if grant { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }.value
            try await importData(data, title: url.deletingPathExtension().lastPathComponent)
        } catch { report(error) }
    }

    func importData(_ data: Data, title: String) async throws {
        let candidate = try PDFReaderEngine(data: data, bookID: UUID())
        let record = try await store.importBook(data: data, id: candidate.bookID, title: title, revision: candidate.sourceRevision)
        await flush()
        install(candidate, title: title, record: record, state: nil)
    }

    func openReview(_ data: Data) throws {
        install(try PDFReaderEngine(data: data, bookID: UUID()), title: "Reading specimen", record: nil, state: nil)
    }

    private func install(_ candidate: PDFReaderEngine, title: String, record: BookRecord?, state: ReadingState?) {
        subscriptions.removeAll()
        saving?.cancel()
        mounted = false
        pendingState = state
        self.record = record
        self.title = title
        engine = candidate
        commands = ReaderCommands(engine: candidate)
    }

    func mount() {
        guard let engine, !mounted else { return }
        engine.view.layoutDocumentView()
        if let state = pendingState {
            if let raw = state.pdfDisplayMode, let mode = PDFDisplayMode(rawValue: raw) { engine.view.displayMode = mode }
            engine.view.autoScales = state.autoScales ?? false
            if !engine.view.autoScales { engine.view.scaleFactor = state.scale }
            engine.view.layoutDocumentView()
            if let anchor = state.anchor {
                do { try engine.navigate(to: anchor) } catch { report(error) }
            }
        }
        pendingState = nil
        mounted = true
        scale = engine.view.scaleFactor
        pageNumber = engine.document.index(for: engine.view.currentPage ?? engine.document.page(at: 0)!) + 1
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
            center.publisher(for: name, object: engine.view).sink { [weak self] _ in
                Task { @MainActor in self?.positionChanged() }
            }.store(in: &subscriptions)
        }
        if let clip = engine.view.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            center.publisher(for: NSView.boundsDidChangeNotification, object: clip).sink { [weak self] _ in
                Task { @MainActor in self?.positionChanged() }
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
        do {
            let bounds = target.bounds(for: .cropBox)
            let anchor = SourceAnchor(bookID: engine.bookID, sourceRevision: engine.sourceRevision,
                                      position: .pdf(.init(pageIndex: page - 1, x: bounds.minX, y: bounds.maxY)))
            try commands?.perform(.navigate(anchor))
            positionChanged()
        } catch { report(error) }
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
        do { try commands?.perform(.setScale(engine.view.scaleFactor * factor)); positionChanged() }
        catch { report(error) }
    }

    func flush() async {
        guard mounted, let engine, let commands, let record else { return }
        do {
            try await store.save(ReadingState(anchor: try engine.currentAnchor(), palette: commands.palette,
                                             scale: engine.view.scaleFactor, autoScales: engine.view.autoScales,
                                             pdfDisplayMode: engine.view.displayMode.rawValue), for: record)
        } catch { report(error) }
    }

    func report(_ error: Error) { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Reader error") }
}

@MainActor
final class SessionRegistry {
    static let shared = SessionRegistry()
    private struct Entry { weak var session: ReaderSession? }
    private var entries: [Entry] = []
    func add(_ session: ReaderSession) { entries.removeAll { $0.session == nil }; entries.append(Entry(session: session)) }
    func flush() async { for entry in entries { await entry.session?.flush() } }
}

@MainActor
final class ReaderAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await SessionRegistry.shared.flush(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
