import SwiftUI
import ReaderCore
import PDFKit
import Combine
import Darwin

@MainActor
@Observable
final class ReaderSession {
    var engine: (any ReaderEngine)?
    var pdfEngine: PDFReaderEngine? { engine as? PDFReaderEngine }
    var epubEngine: EPUBReaderEngine? { engine as? EPUBReaderEngine }
    var surfaceView: NSView? { pdfEngine?.view ?? epubEngine?.view }
    var sectionCount: Int { pdfEngine?.document.pageCount ?? epubEngine?.publication.readingResources.count ?? 0 }
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
    var comfort = ReadingComfortPreferences()
    var ambientDefaults = AmbientReadingSettings()
    var systemDark = false
    var shellAppearance = ShellAppearance.system
    var readingTimer = ReadingSessionTimer()
    var autoScrolling = false
    var miniReaderActive = false
    var commandCenterVisible = false
    let companion = CompanionModel()
    let study = StudyModel()
    var companionVisible = false
    var companionViewportRevision = 0
    var pendingCompanionQuestion: String?
    let activity = ReadingActivityDriver()
    @ObservationIgnored var miniReader: MiniReaderController?
    @ObservationIgnored private var appliedAmbientPhase: Bool?
    @ObservationIgnored private var preferencesSaveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingComfort: (id: UUID, record: BookRecord, value: ReadingComfortPreferences)?
    @ObservationIgnored private var checkpointTask: Task<Void, Never>?
    @ObservationIgnored private var checkpointToken = UUID()
    @ObservationIgnored private var nextCheckpoint: TimeInterval = 0
    @ObservationIgnored private var nextSessionTick: TimeInterval = 0
    @ObservationIgnored private var nextAmbientTick: TimeInterval = 0
    @ObservationIgnored private var soakSamples: [[String: Any]] = []
    @ObservationIgnored private var lastSoakSample: TimeInterval = 0
    @ObservationIgnored private var diagnosticsTime: TimeInterval = 0
    @ObservationIgnored private var pendingAmbient: (id: UUID, value: AmbientReadingSettings)?
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let storageRoot: URL
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
        storageRoot = root
        store = ReaderStores.store(at: root)
        SessionRegistry.shared.add(self)
        companion.onSettingsChanged = { [weak self] in
            if let self { SessionRegistry.shared.refreshCompanion(except: self) }
        }
        activity.onTick = { [weak self] now, delta, date in self?.readingTick(now: now, delta: delta, date: date) }
    }

    func refreshLibrary() async {
        await flushPreferences()
        do {
            ambientDefaults = try await store.ambientDefaults()
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
            study.speech.stop(); await flush()
            let (record, data, state) = try await store.openBook(book.id)
            guard active, !Task.isCancelled else { return }
            try await load(record: record, data: data, state: state)
            try await store.setCurrentBook(record.id)
        } catch { report(error) }
    }

    private func load(record: BookRecord, data: Data, state: ReadingState?) async throws {
        let candidate = try await makeEngine(data: data, format: record.format, id: record.id)
        guard active, !Task.isCancelled else { return }
        try candidate.applyPagePalette(state?.palette ?? .original)
        let marks = try await store.bookmarks(for: record)
        let preferences = try await store.comfortPreferences(for: record)
        let defaults = try await store.ambientDefaults()
        guard active, !Task.isCancelled else { return }
        install(candidate, title: record.title, record: record, state: state, bookmarks: marks, data: data, preferences: preferences, defaults: defaults)
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
            try await importData(data, title: url.deletingPathExtension().lastPathComponent, reference: reference, format: url.pathExtension.lowercased() == "epub" ? .epub : .pdf)
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

    private func makeEngine(data: Data, format: BookFormat, id: UUID) async throws -> any ReaderEngine {
        if format == .epub {
            let worker = Task.detached(priority: .userInitiated) { (try EPUBPublication(data: data), PDFReaderEngine.revision(data)) }
            let (publication, revision) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            return EPUBReaderEngine(publication: publication, bookID: id, revision: revision)
        }
        let prepared = await Task.detached(priority: .userInitiated) { PreparedPDFSource(data: data) }.value
        return try PDFReaderEngine(source: prepared, bookID: id)
    }
    func importData(_ data: Data, title: String, reference: Data? = nil, format: BookFormat = .pdf) async throws {
        let candidate = try await makeEngine(data: data, format: format, id: UUID())
        guard active, !Task.isCancelled else { return }
        let record = try await store.importBook(data: data, id: candidate.bookID, title: title, revision: candidate.sourceRevision, reference: reference, pageCount: (candidate as? PDFReaderEngine)?.document.pageCount ?? 0, format: format)
        await flush()
        guard active, !Task.isCancelled else { return }
        let defaults = try await store.ambientDefaults()
        install(candidate, title: title, record: record, state: nil, bookmarks: [], data: data, defaults: defaults)
        await refreshLibrary()
    }

    func openReview(_ data: Data) throws {
        install(try PDFReaderEngine(data: data, bookID: UUID()), title: "Reading specimen", record: nil, state: nil, bookmarks: [], data: data)
    }

    private func install(_ candidate: any ReaderEngine, title: String, record: BookRecord?, state: ReadingState?, bookmarks: [ReaderBookmark], data: Data, preferences: ReadingComfortPreferences = ReadingComfortPreferences(), defaults: AmbientReadingSettings = AmbientReadingSettings()) {
        stopWork()
        awake.release(); keepAwake = false
        subscriptions.removeAll(); saving?.cancel()
        mounted = false; pendingState = state
        self.record = record; self.title = title; self.bookmarks = bookmarks
        comfort = preferences; ambientDefaults = defaults; appliedAmbientPhase = nil; readingTimer = ReadingSessionTimer()
        #if DEBUG || FOUNDATION_BENCHMARK
        if ProcessInfo.processInfo.arguments.contains("-comfortScheduleProbe") {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            var schedule = AmbientReadingSettings(); schedule.strategy = .schedule
            schedule.dayMinute = (minute + 1439) % 1440; schedule.nightMinute = (minute + 2) % 1440
            comfort.ambient = schedule
        }
        #endif
        engine = candidate; commands = ReaderCommands(engine: candidate)
        study.configure(record: record, store: store, session: self)
        companion.configure(data: data, bookID: candidate.bookID, revision: candidate.sourceRevision, title: title,
                            pageCount: (candidate as? PDFReaderEngine)?.document.pageCount ?? 0, record: record, store: store, epub: (candidate as? EPUBReaderEngine)?.publication)
        if let epub = candidate as? EPUBReaderEngine {
            epub.onInternalNavigation = { [weak self] in self?.navigate(to: $0) }
            epub.onManualInteraction = { [weak self] in self?.setAutoScroll(false) }
            epub.onPositionChanged = { [weak self] in self?.positionChanged() }
            epub.onSelectionChanged = { [weak self] in self?.updateCompanionSelection() }
            epub.onError = { [weak self] in self?.report($0) }
            return
        }
        guard let candidate = candidate as? PDFReaderEngine else { return }
        candidate.onInternalNavigation = { [weak self] anchor in self?.navigate(to: anchor) }
        candidate.onManualInteraction = { [weak self] in self?.setAutoScroll(false) }
        candidate.onSpotlightStep = { [weak self] direction in self?.stepSpotlight(direction) }
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
        if let epub = engine as? EPUBReaderEngine {
            mounted = true
            do {
                if let value = pendingState?.epubTypography { try commands?.perform(.setTypography(value)) }
                if let anchor = pendingState?.anchor { try epub.navigate(to: anchor) }
                epub.start()
            } catch { report(error) }
            pendingState = nil; positionChanged(); updateActivityDriver(); return
        }
        guard let engine = engine as? PDFReaderEngine else { return }
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
        positionChanged(); applyAmbient(at: Date()); updateActivityDriver()
    }

    private func positionChanged() {
        guard mounted, let engine else { return }
        if companion.smartMargins { companionViewportRevision &+= 1 }
        scale = Double(pdfEngine?.view.scaleFactor ?? 1)
        pdfEngine?.updateSpotlightLayout()
        if let epubEngine { pageNumber = epubEngine.chapterIndex + 1 }
        if let anchor = try? engine.currentAnchor(), case .pdf(let point) = anchor.position {
            pageNumber = point.pageIndex + 1
        }
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func navigate(page: Int) {
        if let epub = epubEngine {
            guard epub.publication.readingResources.indices.contains(page - 1) else { return }
            navigate(to: SourceAnchor(bookID: epub.bookID, sourceRevision: epub.sourceRevision, position: .epub(resource: epub.publication.readingResources[page - 1].resource, locator: EPUBTextLocator(offset: 0).encoded))); return
        }
        guard let engine = pdfEngine, let target = engine.document.page(at: page - 1) else { return }
        let bounds = target.bounds(for: .cropBox)
        navigate(to: SourceAnchor(bookID: engine.bookID, sourceRevision: engine.sourceRevision,
            position: .pdf(.init(pageIndex: page - 1, x: bounds.minX, y: bounds.maxY))))
    }
    func navigate(to anchor: SourceAnchor) {
        do { try commands?.perform(.navigate(anchor)); positionChanged() } catch { report(error) }
    }
    func setPalette(_ palette: PagePalette) {
        recordManualPaletteChoice(); applyPalette(palette)
    }
    private func recordManualPaletteChoice() {
        systemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let settings = effectiveAmbient
        if settings.strategy != .manual {
            if settings.manualBehavior == .disableAutomation {
                var manual = settings; manual.strategy = .manual; comfort.ambient = manual
            } else if settings.strategy == .schedule { comfort.manualOverrideUntil = settings.nextTransition(after: Date()) }
            else { comfort.manualOverrideSystemDark = systemDark }
            saveComfortPreferences()
        }
    }
    private func applyPalette(_ palette: PagePalette) {
        do { try commands?.perform(.setPalette(palette)); if pdfEngine != nil { subscriptions.removeAll(); mounted = false; mount() } else { positionChanged() } }
        catch { report(error) }
    }
    func undoPalette() {
        recordManualPaletteChoice()
        do { try commands?.undoPalette(); if pdfEngine != nil { subscriptions.removeAll(); mounted = false; mount() } else { positionChanged() } } catch { report(error) }
    }
    func zoom(by factor: Double) {
        guard let engine = pdfEngine else { return }
        do { try commands?.perform(.setScale(engine.view.scaleFactor * factor)); positionChanged() } catch { report(error) }
    }

    func search(_ query: String) {
        searchTask?.cancel(); engine?.cancelSearch()
        searchQuery = query; searchMatches = []; searching = false; searchLimitReached = false
        pdfEngine?.view.highlightedSelections = nil
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
        bookmarks.contains {
            switch $0.anchor.position {
            case .pdf(let point): point.pageIndex == pageNumber - 1
            case .epub(let resource, let encoded):
                if let current = try? epubEngine?.currentAnchor(), case .epub(let currentResource, let currentEncoded) = current.position,
                   let a = try? EPUBTextLocator(encoded: encoded), let b = try? EPUBTextLocator(encoded: currentEncoded) {
                    resource == currentResource && a.offset == b.offset
                } else { false }
            }
        }
    }
    func toggleBookmark() async {
        guard !bookmarkUpdating, let record, let engine else { return }
        bookmarkUpdating = true; defer { bookmarkUpdating = false }
        do {
            let updated = try await store.toggleBookmark(anchor: engine.currentAnchor(), title: pdfEngine?.view.currentSelection?.string ?? epubEngine?.selection?.text ?? companionChapterLabel ?? "", for: record)
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
        closeMiniReader(); stopReadingActivity(); awake.release(); keepAwake = false; focusMode = false
        stopWork(); await flush(); saving?.cancel(); subscriptions.removeAll()
        engine = nil; commands = nil; record = nil; mounted = false; bookmarks = []; title = "Adaptive Reader"
        do { try await store.setCurrentBook(nil) } catch { report(error) }
        await refreshLibrary(); writeComfortDiagnostics(force: true)
    }
    private func stopWork() {
        epubEngine?.stop()
        study.reset()
        companion.reset(); companionVisible = false
        checkpointTask?.cancel(); checkpointTask = nil; checkpointToken = UUID()
        closeMiniReader(); stopReadingActivity()
        searchTask?.cancel(); textTask?.cancel()
        engine?.cancelSearch(); searchQuery = ""; searchMatches = []; searching = false; checkingText = false
    }
    func suspend() {
        active = false; closeMiniReader(revealMain: false); stopReadingActivity(); awake.release(); keepAwake = false; stopWork(); saving?.cancel()
    }
    func flush() async {
        await study.flush()
        await flushPreferences()
        guard let engine, let commands, let record else { return }
        if !mounted {
            if let pendingState { do { try await store.save(pendingState, for: record) } catch { report(error) } }
            return
        }
        do {
            try await store.save(ReadingState(anchor: try engine.currentAnchor(), palette: commands.palette,
                scale: Double(pdfEngine?.view.scaleFactor ?? 1), autoScales: pdfEngine?.view.autoScales ?? false, pdfDisplayMode: pdfEngine?.view.displayMode.rawValue ?? 1, epubTypography: epubEngine?.typography), for: record)
        } catch { report(error) }
    }
    var effectiveAmbient: AmbientReadingSettings { comfort.ambient ?? ambientDefaults }
    func refreshComfortPreferences() async {
        guard active, let record else { return }
        await flushPreferences()
        do {
            let value = try await store.comfortPreferences(for: record)
            let defaults = try await store.ambientDefaults()
            guard self.record?.id == record.id else { return }
            comfort = value; ambientDefaults = defaults; applyAmbient(at: Date()); updateActivityDriver()
        } catch { report(error) }
    }
    func saveComfortPreferences() {
        guard let record else { return }
        do { try comfort.validate() } catch { report(error); return }
        pendingComfort = (UUID(), record, comfort)
        schedulePreferencesWrite(); applyAmbient(at: Date()); updateActivityDriver()
    }
    func updateAmbientSettings(_ value: AmbientReadingSettings, global: Bool) {
        do { try value.validate() } catch { report(error); return }
        if global { saveAmbientDefaults(value) }
        else {
            comfort.ambient = value; comfort.manualOverrideUntil = nil; comfort.manualOverrideSystemDark = nil
            saveComfortPreferences()
        }
    }
    func saveAmbientDefaults(_ value: AmbientReadingSettings) {
        do { try value.validate() } catch { report(error); return }
        ambientDefaults = value; appliedAmbientPhase = nil; pendingAmbient = (UUID(), value)
        schedulePreferencesWrite(); applyAmbient(at: Date()); updateActivityDriver()
    }
    private func schedulePreferencesWrite() {
        preferencesSaveTask?.cancel()
        preferencesSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.flushPreferences()
        }
    }
    private func flushPreferences() async {
        let changed = pendingAmbient != nil || pendingComfort != nil
        do {
            if let pending = pendingAmbient {
                try await store.saveAmbientDefaults(pending.value)
                if pendingAmbient?.id == pending.id { pendingAmbient = nil }
            }
            if let pending = pendingComfort {
                try await store.saveComfort(pending.value, for: pending.record)
                if pendingComfort?.id == pending.id { pendingComfort = nil }
            }
        } catch { report(error) }
        if changed { SessionRegistry.shared.refreshComfort(except: self) }
    }
    func sharesLibrary(with other: ReaderSession) -> Bool { storageRoot == other.storageRoot }
    func appearanceChanged(isDark: Bool) { systemDark = isDark; applyAmbient(at: Date()) }
    private func applyAmbient(at date: Date) {
        guard mounted, engine != nil else { return }
        systemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let settings = effectiveAmbient
        guard let palette = settings.palette(at: date, systemDark: systemDark),
              !comfort.overridesAutomation(at: date, systemDark: systemDark, strategy: settings.strategy) else { return }
        let phase = settings.isNight(at: date, systemDark: systemDark)
        if appliedAmbientPhase != phase || commands?.palette != palette {
            appliedAmbientPhase = phase; applyPalette(palette)
        }
    }
    @discardableResult func performReadingCommand(_ command: WorkspaceCommand) -> Bool {
        guard command.isEnabled(in: self) else { return true }
        switch command {
        case .study:
            companionVisible = false; focusMode = false; study.visible.toggle()
        case .newCard:
            companionVisible = false; focusMode = false; study.newCard()
        case .newNote:
            companionVisible = false; focusMode = false; study.newNote()
        case .highlightPassage:
            companionVisible = false; focusMode = false; Task { await study.addHighlight() }
        case .listenFromHere:
            companionVisible = false; focusMode = false; study.visible = true; study.tab = "listen"; study.listen(resumeSaved: false)
        case .resumeListening:
            companionVisible = false; focusMode = false; study.visible = true; study.tab = "listen"; study.listen(resumeSaved: true)
        case .toggleListening:
            switch study.speech.status {
            case .stopped: study.listen(resumeSaved: false)
            case .playing: study.speech.pause(); Task { await study.flush() }
            case .paused: study.speech.resume()
            }
        case .stopListening:
            study.speech.stop(); Task { await study.flush() }
        case .companion:
            study.visible = false
            closeMiniReader(); focusMode = false
            if let question = pendingCompanionQuestion {
                pendingCompanionQuestion = nil; companionVisible = true; companion.query = question
                companion.ask(page: pageNumber, question: question, chapter: companionChapterLabel)
            } else { companionVisible.toggle() }
            if !companionVisible { companion.cancel() }
        case .nextPassage: stepPassage(1)
        case .previousPassage: stepPassage(-1)
        case .back: smartBack()
        case .forward: smartForward()
        case .toggleSpotlight: toggleSpotlight()
        case .spotlightNext: stepSpotlight(1)
        case .spotlightPrevious: stepSpotlight(-1)
        case .toggleAutoScroll: setAutoScroll(!autoScrolling)
        case .toggleSession:
            switch readingTimer.status {
            case .running: pauseReadingSession()
            case .paused: resumeReadingSession()
            default: startReadingSession(minutes: 25)
            }
        case .stopSession: stopReadingSession()
        case .miniReader: showMiniReader()
        case .returnToReader: closeMiniReader()
        case .toggleFocus:
            focusMode.toggle()
            if focusMode { companionVisible = false; companion.cancel() }
        case .toggleAwake: setKeepAwake(!keepAwake)
        case .toggleBookmark: Task { await toggleBookmark() }
        case .zoomIn: zoom(by: 1.1)
        case .zoomOut: zoom(by: 1 / 1.1)
        case .closeBook: Task { await closeBook() }
        default: return false
        }
        return true
    }
    func stepPassage(_ direction: Int) {
        setAutoScroll(false)
        do { try commands?.perform(.advancePassage(direction)); positionChanged() } catch { report(error) }
    }
    func smartBack() { do { try commands?.perform(.back); positionChanged() } catch { report(error) } }
    func smartForward() { do { try commands?.perform(.forward); positionChanged() } catch { report(error) } }
    func toggleSpotlight() {
        do { try commands?.perform(.setSpotlight(!(pdfEngine?.spotlightEnabled ?? false))) } catch { report(error) }
    }
    func stepSpotlight(_ direction: Int) { do { try commands?.perform(.stepSpotlight(direction)); positionChanged() } catch { report(error) } }
    func setAutoScroll(_ enabled: Bool) {
        autoScrolling = enabled && engine?.capabilities.contains(.continuousScroll) == true
        updateActivityDriver()
    }
    func startReadingSession(minutes: Int?) {
        guard let engine else { return }
        do { try readingTimer.start(duration: minutes.map { Double($0) * 60 }, now: ProcessInfo.processInfo.systemUptime, anchor: try engine.currentAnchor()); updateActivityDriver() }
        catch { report(error) }
    }
    func pauseReadingSession() {
        readingTimer.pause(now: ProcessInfo.processInfo.systemUptime, anchor: try? engine?.currentAnchor())
        setAutoScroll(false)
    }
    func resumeReadingSession() { guard engine != nil else { return }; readingTimer.resume(now: ProcessInfo.processInfo.systemUptime); updateActivityDriver() }
    func stopReadingSession() {
        readingTimer.stop(now: ProcessInfo.processInfo.systemUptime, anchor: try? engine?.currentAnchor()); setAutoScroll(false)
    }
    func stopReadingActivity() { stopReadingSession(); activity.update(interval: nil); writeComfortDiagnostics(force: true) }
    private func updateActivityDriver() {
        let needed = active && engine != nil && (autoScrolling || readingTimer.status == .running || effectiveAmbient.strategy != .manual)
        let previous = activity.isRunning
        activity.update(interval: needed ? (autoScrolling ? 1.0 / 60 : 1) : nil)
        writeComfortDiagnostics(force: previous != activity.isRunning)
    }
    private func readingTick(now: TimeInterval, delta: TimeInterval, date: Date) {
        systemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if now >= nextSessionTick {
            nextSessionTick = now + 1
            let wasRunning = readingTimer.status == .running
            readingTimer.tick(now: now, anchor: try? engine?.currentAnchor())
            if wasRunning && readingTimer.status == .completed { autoScrolling = false }
        }
        if autoScrolling && now >= nextCheckpoint && checkpointTask == nil {
            nextCheckpoint = now + 5
            let token = UUID(); checkpointToken = token
            checkpointTask = Task { [weak self] in
                guard !Task.isCancelled, let self else { return }
                await self.flush()
                if self.checkpointToken == token { self.checkpointTask = nil }
            }
        }
        if autoScrolling {
            do {
                if try engine?.scroll(by: comfort.autoScrollSpeed * delta) != true { autoScrolling = false }
            } catch { autoScrolling = false; report(error) }
        }
        if now >= nextAmbientTick { nextAmbientTick = now + 1; applyAmbient(at: date) }
        updateActivityDriver()
    }
    func showMiniReader() {
        guard pdfEngine != nil, !miniReaderActive else { return }
        setAutoScroll(false)
        let controller = MiniReaderController(session: self)
        miniReader = controller; miniReaderActive = true
        controller.present()
    }
    func closeMiniReader(revealMain: Bool = true) {
        guard let controller = miniReader else { return }
        miniReader = nil; miniReaderActive = false
        controller.finish(revealMain: revealMain)
        writeComfortDiagnostics(force: true)
    }
    func prepareViewportTransfer() -> ReadingState? {
        guard let engine else { return nil }
        setAutoScroll(false)
        let value = ReadingState(anchor: try? engine.currentAnchor(), palette: engine.palette, scale: Double(pdfEngine?.view.scaleFactor ?? 1),
            autoScales: pdfEngine?.view.autoScales ?? false, pdfDisplayMode: pdfEngine?.view.displayMode.rawValue ?? 1, epubTypography: epubEngine?.typography)
        subscriptions.removeAll(); mounted = false; pendingState = value
        return value
    }

    func writeComfortDiagnostics(force: Bool) {
        #if DEBUG || FOUNDATION_BENCHMARK
        guard ProcessInfo.processInfo.arguments.contains("-comfortDiagnostics") else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - diagnosticsTime >= 1 else { return }; diagnosticsTime = now
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        var memory = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let memoryStatus = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), words, &count)
            }
        }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let value: [String: Any] = ["rssBytes": memoryStatus == KERN_SUCCESS ? Double(memory.resident_size) : -1, "peakRSSBytes": usage.ru_maxrss, "cpuSeconds": cpu, "driverActive": activity.isRunning, "autoScrolling": autoScrolling,
            "timerStatus": readingTimer.status.rawValue, "miniOpen": miniReaderActive,
            "documentOpen": engine != nil, "sessionActive": active, "page": pageNumber, "uptime": now,
            "elapsed": readingTimer.elapsed, "miniLevel": miniReader?.windowLevel ?? 0,
            "palette": engine?.palette.rawValue ?? "none", "ambientStrategy": effectiveAmbient.strategy.rawValue]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? data.write(to: storageRoot.appendingPathComponent("ComfortDiagnostics.json"), options: .atomic)
        }
        if ProcessInfo.processInfo.arguments.contains("-comfortSoak"), force || now - lastSoakSample >= 30 {
            lastSoakSample = now; soakSamples.append(value)
            if let data = try? JSONSerialization.data(withJSONObject: soakSamples, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: storageRoot.appendingPathComponent("ComfortSoakProgress.json"), options: .atomic)
            }
        }
        #endif
    }

    func prepareForTermination() {
        companion.reset()
        active = false; setKeepAwake(false); stopReadingActivity()
        searchTask?.cancel(); textTask?.cancel(); checkpointTask?.cancel(); saving?.cancel()
        engine?.cancelSearch()
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
    func refreshComfort(except origin: ReaderSession) {
        for entry in entries {
            guard let session = entry.session, session !== origin, session.sharesLibrary(with: origin) else { continue }
            Task { await session.refreshComfortPreferences() }
        }
    }
    func refreshCompanion(except origin: ReaderSession) {
        for entry in entries {
            guard let session = entry.session, session !== origin, session.sharesLibrary(with: origin) else { continue }
            session.companion.cancel()
            Task { await session.companion.refreshSettings() }
        }
    }
    func flush() async {
        for entry in entries { entry.session?.prepareForTermination() }
        for entry in entries { await entry.session?.flush() }
    }
}

@MainActor
final class ReaderAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await SessionRegistry.shared.flush(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
