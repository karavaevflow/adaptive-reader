import SwiftUI
import ReaderCore
import PDFKit
import WebKit
import CoreText
import UniformTypeIdentifiers

private enum LibrarySection: String, CaseIterable, Identifiable {
    case all, reading, favorites
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .all: "All Books"
        case .reading: "Reading"
        case .favorites: "Favorites"
        }
    }
    var symbol: String {
        switch self {
        case .all: "books.vertical"
        case .reading: "book"
        case .favorites: "star"
        }
    }
}

struct WorkspaceView: View {
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("inspectorVisible") private var inspectorVisible = false
    @AppStorage("shellAppearance") private var appearance = ShellAppearance.system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var session = ReaderSession()
    @SceneStorage("workspaceWindowID") private var windowID = UUID().uuidString
    private var windowAutosaveName: String {
        #if DEBUG || FOUNDATION_BENCHMARK
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-designReview") { return "" }
        if let index = arguments.firstIndex(of: "-phase0Store"), index + 1 < arguments.count { return "AdaptiveReader.Test.\(arguments[index + 1])" }
        #endif
        return "AdaptiveReader.\(windowID)"
    }
    private var document: PDFDocument? { session.pdfEngine?.document }
    private var hasBook: Bool { session.engine != nil }
    private var title: String { session.title }
    @State private var importing = false
    @State private var importReference = false
    @State private var repairBook: BookRecord?
    @State private var searchVisible = false
    @State private var libraryQuery = ""
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var librarySearchFocused: Bool
    @State private var appearanceVisible = false
    @State private var catalogVisible = false
    @State private var readingToolsVisible = false
    @State private var pendingCommand: WorkspaceCommand?
    @State private var compactSidebarVisible = false
    @State private var compactInspectorVisible = false
    @State private var section = LibrarySection.all
    @FocusState private var toolbarFocus: ToolbarFocus?
    @State private var nativeFocusRequest: NativeFocusRequest?
    private enum ToolbarFocus: Hashable { case sidebar, appearance, inspector }

    var body: some View {
        GeometryReader { geometry in
            workspace(width: geometry.size.width)
                .toolbar { toolbar(width: geometry.size.width) }
                .focusedSceneValue(\.workspaceActions, WorkspaceActions(hasBook: hasBook, canSearch: session.engine?.capabilities.contains(.search) == true || (!hasBook && !session.books.isEmpty), canGoBack: session.commands?.canGoBack == true, canGoForward: session.commands?.canGoForward == true, canStepReading: session.engine?.capabilities.contains(.passageNavigation) == true, enabledCommands: Set(WorkspaceCommand.allCases.filter { $0.isEnabled(in: session) }), perform: { command in
                    perform(command, width: geometry.size.width)
                }))
        }
        .background(Adaptive.background)
        .background(WindowIntegration(autosaveName: windowAutosaveName, focusRequest: nativeFocusRequest, onClose: { session.suspend(); Task { await session.flush() } }))
        .navigationTitle(title)
        .task { await startSession() }
        .onChange(of: appearance, initial: true) { session.shellAppearance = appearance }
        .onDisappear { session.suspend(); Task { await session.flush() } }
        .onExitCommand { if session.focusMode { session.focusMode = false } }
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewSelectionChanged)) { notification in
            if let view = notification.object as? PDFView, view === session.surfaceView { session.updateCompanionSelection() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window == session.surfaceView?.window {
                Task { await session.refreshBookmarks(); await session.refreshComfortPreferences(); await session.companion.refreshSettings() }
            } else if !hasBook { Task { await session.refreshLibrary() } }
        }
        .overlay { if session.busy { ProgressView("Opening document").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, UTType(filenameExtension: "epub")!]) { result in
            switch result {
            case .success(let url):
                let repair = repairBook; repairBook = nil
                Task { if let repair { await session.relinkURL(url, book: repair) } else { await session.importURL(url, asReference: importReference) } }
            case .failure(let error):
                repairBook = nil
                if (error as NSError).code != NSUserCancelledError { session.report(error) }
            }
        }
        .sheet(isPresented: Binding(get: { session.commandCenterVisible && !session.miniReaderActive }, set: { session.commandCenterVisible = $0 }), onDismiss: {
            if let command = pendingCommand { pendingCommand = nil; perform(command, width: session.surfaceView?.window?.contentView?.bounds.width ?? 1120) }
        }) {
            CommandCenterView(session: session, commands: WorkspaceCommand.mainCommands, perform: { command in pendingCommand = command; session.commandCenterVisible = false }, dismiss: { session.commandCenterVisible = false })
        }
        .sheet(isPresented: $readingToolsVisible) {
            VStack(spacing: 0) {
                ReadingToolsView(session: session)
                Divider()
                HStack { Spacer(); Button("Done") { readingToolsVisible = false }.keyboardShortcut(.cancelAction) }.padding(16)
            }
        }
        .sheet(isPresented: Binding(get: { session.companionVisible && !session.focusMode && (session.surfaceView?.window?.contentView?.bounds.width ?? 800) < Adaptive.Layout.inspectorThreshold }, set: {
            if !$0 { session.companionVisible = false; session.companion.cancel() }
        })) {
            CompanionView(session: session).frame(width: 380, height: 600)
        }
        .sheet(isPresented: $catalogVisible) {
            VStack(spacing: 0) {
                ComponentCatalog()
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { catalogVisible = false }.keyboardShortcut(.cancelAction)
                }.padding(Adaptive.Space.regular)
            }
        }
        .sheet(isPresented: $compactInspectorVisible, onDismiss: { restoreFocus(.inspector) }) {
            VStack(alignment: .trailing) {
                inspector.frame(width: 320, height: 400)
                Button("Done") { compactInspectorVisible = false }.keyboardShortcut(.cancelAction)
                    .padding(Adaptive.Space.regular)
            }
        }
        .alert("Unable to open document", isPresented: Binding(
            get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
    }

    private func startSession() async {
        #if DEBUG || FOUNDATION_BENCHMARK
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-designReader") || arguments.contains("-phase0Import") || arguments.contains("-libraryReview") else {
            if !arguments.contains("-designReview") { await session.restore() }
            return
        }
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
        for page in 0..<3 {
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)
        let chapter = page == 0 ? "Chapter One" : "Chapter \(page + 1)"
        let paragraph = NSAttributedString(string: "A quiet place to read.\n\n\(chapter)\n\nA book opens a space for thought.\nFollow the words, pause, and return to the page.", attributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black
        ])
        let path = CGPath(rect: CGRect(x: 64, y: 64, width: 484, height: 650), transform: nil)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(paragraph), CFRange(), path, nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
        }
        context.closePDF()
        do {
            if arguments.contains("-libraryReview") {
                for name in ["Designing for attention", "Глубокое чтение", "A field guide to the night sky", "Patterns of thought"] {
                    try await session.importData(data as Data, title: name)
                }
                await session.closeBook()
                if let book = session.books.first { await session.toggleFavorite(book) }
            } else if arguments.contains("-phase0Import") { try await session.importData(data as Data, title: "Phase 0 reader") }
            else { try session.openReview(data as Data) }
        } catch { session.report(error) }
        #else
        await session.restore()
        #endif
    }

    private func workspace(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if !session.focusMode && sidebarVisible && width >= Adaptive.Layout.sidebarThreshold {
                sidebar.frame(width: Adaptive.Layout.sidebar)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider().overlay(Adaptive.divider)
            }
            if searchVisible && hasBook && !session.focusMode {
                searchPanel.frame(width: 260)
                Divider()
            }
            Group {
                if session.miniReaderActive {
                    VStack(spacing: 16) {
                        Image(systemName: "pip").font(.system(size: 32, weight: .light)).foregroundStyle(Adaptive.secondary)
                        Text("Reading in Mini Reader").font(.title2)
                        Button("Return to Reader") { session.closeMiniReader() }
                    }
                }
                else if let engine = session.epubEngine {
                    NativeEPUBView(engine: engine, session: session).id(engine.bookID)
                        .safeAreaInset(edge: .bottom, spacing: 0) { if !session.focusMode { MagicSelectionBar(session: session) } }
                }
                else if let engine = session.pdfEngine {
                    HStack(spacing: 0) {
                        NativePDFView(engine: engine, session: session).id(engine.bookID)
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                if !session.focusMode { MagicSelectionBar(session: session) }
                            }
                        if session.companion.smartMargins && !session.focusMode && width >= Adaptive.Layout.inspectorThreshold { SmartMarginRail(session: session) }
                    }
                }
                else { library }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !session.focusMode && session.companionVisible && width >= Adaptive.Layout.inspectorThreshold {
                Divider(); CompanionView(session: session).frame(width: 340)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if !session.focusMode && inspectorVisible && width >= Adaptive.Layout.inspectorThreshold {
                Divider().overlay(Adaptive.divider)
                inspector.frame(width: Adaptive.Layout.inspector)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Adaptive.Motion.panel, value: sidebarVisible)
        .animation(reduceMotion ? nil : Adaptive.Motion.panel, value: inspectorVisible)
        .animation(reduceMotion ? nil : Adaptive.Motion.panel, value: session.focusMode)
        .animation(reduceMotion ? nil : Adaptive.Motion.panel, value: searchVisible)
        .animation(reduceMotion ? nil : Adaptive.Motion.panel, value: session.companionVisible)
    }

    private var filteredBooks: [BookRecord] {
        session.books.filter { book in
            (libraryQuery.isEmpty || book.title.localizedCaseInsensitiveContains(libraryQuery)) &&
            (section != .favorites || book.favorite) && (section != .reading || session.states[book.id] != nil)
        }
    }

    @ViewBuilder private var library: some View {
        if session.books.isEmpty {
            VStack(spacing: Adaptive.Space.small) {
                AdaptiveEmptyState(title: "Your next chapter", message: "Open a PDF or EPUB to begin reading.", symbol: "book.closed")
                Button("Open book", systemImage: "plus") { importReference = false; importing = true }
                    .buttonStyle(.borderedProminent).disabled(session.busy).accessibilityIdentifier("library.open")
                Button("Import linked book") { importReference = true; importing = true }.disabled(session.busy)
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(section.title).font(Adaptive.TypeStyle.title)
                    Spacer()
                    TextField("Search books", text: $libraryQuery).textFieldStyle(.roundedBorder).focused($librarySearchFocused).frame(maxWidth: 240)
                    Menu("Import book", systemImage: "plus") {
                        Button("Import a copy") { importReference = false; importing = true }
                        Button("Import linked book") { importReference = true; importing = true }
                    }.menuStyle(.borderlessButton).fixedSize().disabled(session.busy).accessibilityIdentifier("library.import")
                }
                if filteredBooks.isEmpty { Text("No books in this view").foregroundStyle(Adaptive.secondary) }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 460))], alignment: .leading, spacing: 16) {
                        ForEach(filteredBooks) { book in
                            VStack(alignment: .leading, spacing: 12) {
                                Button { Task { await session.openBook(book) } } label: {
                                    HStack(spacing: 16) {
                                        Image(systemName: "book.closed").font(.system(size: 28, weight: .light))
                                            .frame(width: 56, height: 80).background(Adaptive.background, in: RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(book.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                                .fixedSize(horizontal: false, vertical: true).help(book.title)
                                            Text(LocalizedStringKey(book.format == .epub ? (book.isReference ? "Linked EPUB" : "EPUB") : (book.isReference ? "Linked PDF" : "Managed PDF"))).font(.caption).foregroundStyle(Adaptive.secondary)
                                            if case .pdf(let point) = session.states[book.id]?.anchor?.position {
                                                Text("Page \(point.pageIndex + 1)").font(.caption).foregroundStyle(Adaptive.secondary)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityIdentifier("library.book.\(book.id)").disabled(session.busy)
                                HStack {
                                    if book.pageCount > 0 {
                                        let page = session.states[book.id]?.anchor.flatMap { anchor -> Int? in
                                            if case .pdf(let p) = anchor.position { return p.pageIndex + 1 }; return nil
                                        } ?? 0
                                        ProgressView(value: min(1, Double(page) / Double(book.pageCount))).accessibilityLabel(Text("Reading progress"))
                                    }
                                    Spacer()
                                    Button("Favorite", systemImage: book.favorite ? "star.fill" : "star") { Task { await session.toggleFavorite(book) } }
                                        .labelStyle(.iconOnly).buttonStyle(.plain).accessibilityValue(Text(LocalizedStringKey(book.favorite ? "On" : "Off")))
                                        .accessibilityIdentifier("library.favorite.\(book.id)")
                                }
                            }.padding(16).background(Adaptive.surface, in: RoundedRectangle(cornerRadius: Adaptive.corner))
                            .contextMenu {
                                Button("Open book") { Task { await session.openBook(book) } }
                                Button("Favorite") { Task { await session.toggleFavorite(book) } }
                                if book.isReference {
                                    Button("Locate linked book") { repairBook = book; importing = true }
                                }
                            }
                        }
                    }
                }
            }.padding(32)
        }
    }

    private var searchPanel: some View {
        AdaptivePanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Find in book").font(.headline)
                    Spacer()
                    Button("Close search", systemImage: "xmark") { searchVisible = false; session.search("") }.labelStyle(.iconOnly)
                }
                TextField("Find text", text: Binding(get: { session.searchQuery }, set: { session.search($0) }))
                    .textFieldStyle(.roundedBorder).focused($searchFieldFocused).accessibilityIdentifier("reader.search.query")
                if session.checkingText { ProgressView("Checking document text") }
                else if session.engine?.capabilities.contains(.search) != true { Text("This PDF has no searchable text.").foregroundStyle(Adaptive.secondary) }
                else if session.searching { ProgressView("Searching") }
                else if !session.searchQuery.isEmpty { Text("\(session.searchMatches.count) matches").font(.caption).foregroundStyle(Adaptive.secondary) }
                if session.searchLimitReached { Text("Showing the first 1,000 matches. Refine your search.").font(.caption) }
                List(session.searchMatches) { match in
                    Button { session.selectMatch(match) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if case .pdf(let point) = match.anchor.position { Text("Page \(point.pageIndex + 1)").font(.caption).foregroundStyle(Adaptive.secondary) }
                            Text(match.snippet).lineLimit(3)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityIdentifier("reader.search.match")
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }.padding(16)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("reader.search.panel")
    }

    private var sidebar: some View {
        AdaptivePanel {
            List {
                ForEach(LibrarySection.allCases) { item in
                    Button { section = item; if hasBook { Task { await session.closeBook() } } } label: {
                        Label(item.title, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Adaptive.text)
                    .listRowBackground(section == item ? Adaptive.accent.opacity(0.14) : Color.clear)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            .listStyle(.sidebar)
            .onMoveCommand { direction in
                let offset: Int
                switch direction {
                case .up: offset = -1
                case .down: offset = 1
                default: return
                }
                let items = LibrarySection.allCases
                let current = items.firstIndex(of: section) ?? 0
                section = items[min(max(current + offset, 0), items.count - 1)]
            }
            .scrollContentBackground(.hidden)
            .accessibilityLabel(Text("Library"))
            .accessibilityIdentifier("library.sidebar")
        }
    }

    private var inspector: some View {
        AdaptivePanel {
            VStack(alignment: .leading, spacing: Adaptive.Space.regular) {
                Text("Document").font(Adaptive.TypeStyle.section)
                if let document {
                    Text(title).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("Page \(session.pageNumber) of \(document.pageCount)").foregroundStyle(Adaptive.secondary)
                    Text("Zoom \(Int((session.scale * 100).rounded()))%").accessibilityIdentifier("reader.scale")
                    if !session.checkingText && session.engine?.capabilities.contains(.search) != true {
                        Text("This PDF has no searchable text.").font(.caption).foregroundStyle(Adaptive.secondary)
                    }
                    Text("Bookmarks").font(.headline)
                    if session.bookmarks.isEmpty { Text("No bookmarks yet").foregroundStyle(Adaptive.secondary) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(session.bookmarks) { mark in
                                HStack {
                                    Button { session.navigate(to: mark.anchor) } label: {
                                        if case .pdf(let point) = mark.anchor.position { Text("Page \(point.pageIndex + 1)") }
                                    }.accessibilityIdentifier("bookmark.\(mark.id)")
                                    Spacer()
                                    Button("Remove bookmark", systemImage: "minus.circle") { Task { await session.removeBookmark(mark) } }.labelStyle(.iconOnly)
                                }
                            }
                        }
                    }

                } else if let epub = session.epubEngine {
                    Text(title).font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(epub.publication.readingResources.enumerated()), id: \.offset) { index, chapter in
                                Button(chapter.title) { session.navigate(page: index + 1) }
                                    .accessibilityIdentifier("epub.chapter.\(index)")
                            }
                            Divider()
                            Text("Bookmarks").font(.headline)
                            ForEach(session.bookmarks) { mark in
                                HStack {
                                    Button(mark.title.isEmpty ? "Bookmark" : mark.title) { session.navigate(to: mark.anchor) }
                                    Button("Remove bookmark", systemImage: "minus.circle") { Task { await session.removeBookmark(mark) } }.labelStyle(.iconOnly)
                                }
                            }
                        }
                    }
                } else {
                    Text("Open a book to see document details.").foregroundStyle(Adaptive.secondary)
                }
                Spacer()
            }.padding(Adaptive.Space.large)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Document"))
        .accessibilityIdentifier("document.inspector")
    }

    private func restoreFocus(_ target: ToolbarFocus) {
        toolbarFocus = target
        nativeFocusRequest = NativeFocusRequest(identifier: "\(target).toggle")
    }

    private func perform(_ command: WorkspaceCommand, width: CGFloat) {
        if session.performReadingCommand(command) { return }
        switch command {
        case .commandCenter: session.setAutoScroll(false); session.commandCenterVisible.toggle()
        case .readingTools: readingToolsVisible = true
        case .back, .forward, .nextPassage, .previousPassage, .toggleSpotlight, .spotlightNext, .spotlightPrevious, .toggleAutoScroll, .toggleSession, .stopSession, .miniReader, .returnToReader: break
        case .openDocument: if !session.busy { session.setAutoScroll(false); importReference = false; importing = true }
        case .importReference: if !session.busy { session.setAutoScroll(false); importReference = true; importing = true }
        case .closeBook: searchVisible = false; Task { await session.closeBook() }
        case .search:
            if !hasBook { librarySearchFocused = true }
            else { session.focusMode = false; searchVisible = true; searchFieldFocused = true }
        case .toggleBookmark: Task { await session.toggleBookmark() }
        case .toggleFocus: session.focusMode.toggle()
        case .toggleAwake: session.setKeepAwake(!session.keepAwake)
        case .toggleSidebar: toggleSidebar(width: width)
        case .toggleAppearance: appearanceVisible.toggle()
        case .toggleInspector: toggleInspector(width: width)
        case .zoomIn: session.zoom(by: 1.1)
        case .zoomOut: session.zoom(by: 1 / 1.1)
        case .companion: _ = session.performReadingCommand(.companion)
        }
    }

    private func toggleSidebar(width: CGFloat) {
        if width < Adaptive.Layout.sidebarThreshold { compactSidebarVisible.toggle() }
        else { sidebarVisible.toggle() }
    }

    private func toggleInspector(width: CGFloat) {
        if width < Adaptive.Layout.inspectorThreshold { compactInspectorVisible = true }
        else { inspectorVisible.toggle() }
    }

    @ToolbarContentBuilder
    private func toolbar(width: CGFloat) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Sidebar", systemImage: "sidebar.left") {
                perform(.toggleSidebar, width: width)
            }
            .focusable()
            .focused($toolbarFocus, equals: .sidebar)
            .onKeyPress(.space) { perform(.toggleSidebar, width: width); return .handled }
            .accessibilityIdentifier("sidebar.toggle")
            .accessibilityValue(Text(sidebarVisible && width >= Adaptive.Layout.sidebarThreshold ? "Shown" : "Hidden"))
            .popover(isPresented: $compactSidebarVisible) { sidebar.frame(width: 240, height: 240).onExitCommand { compactSidebarVisible = false }.onDisappear { restoreFocus(.sidebar) } }
        }
        ToolbarItemGroup {
            if hasBook && width >= 1250 {
                Button("Back", systemImage: "arrow.uturn.backward") { perform(.back, width: width) }.disabled(session.commands?.canGoBack != true).accessibilityIdentifier("reader.back")
                Button("Forward", systemImage: "arrow.uturn.forward") { perform(.forward, width: width) }.disabled(session.commands?.canGoForward != true).accessibilityIdentifier("reader.forward")
            }
            if session.engine != nil {
                Button("Library", systemImage: "books.vertical") { perform(.closeBook, width: width) }
                    .accessibilityIdentifier("reader.close").disabled(session.busy)
                Button(LocalizedStringKey(session.epubEngine == nil ? "Previous page" : "Previous chapter"), systemImage: "chevron.left") { session.navigate(page: session.pageNumber - 1) }
                    .disabled(session.pageNumber <= 1).accessibilityIdentifier("page.previous")
                Text("\(session.pageNumber)/\(session.sectionCount)").monospacedDigit()
                    .accessibilityIdentifier("page.current")
                Button(LocalizedStringKey(session.epubEngine == nil ? "Next page" : "Next chapter"), systemImage: "chevron.right") { session.navigate(page: session.pageNumber + 1) }
                    .disabled(session.pageNumber >= session.sectionCount).accessibilityIdentifier("page.next")
            }
            if hasBook && width >= 1100 {
                Button("Find in book", systemImage: "magnifyingglass") { perform(.search, width: width) }
                    .disabled(session.engine?.capabilities.contains(.search) != true).accessibilityIdentifier("reader.find")
                Button("Bookmark page", systemImage: session.pageIsBookmarked ? "bookmark.fill" : "bookmark") { perform(.toggleBookmark, width: width) }
                    .accessibilityValue(Text(LocalizedStringKey(session.pageIsBookmarked ? "Bookmarked" : "Not bookmarked")))
                    .accessibilityIdentifier("reader.bookmark")
                Button("Focus", systemImage: session.focusMode ? "viewfinder.circle.fill" : "viewfinder") { perform(.toggleFocus, width: width) }
                    .accessibilityValue(Text(LocalizedStringKey(session.focusMode ? "On" : "Off"))).accessibilityIdentifier("reader.focus")
                Toggle("Keep Awake", systemImage: "sun.max", isOn: Binding(get: { session.keepAwake }, set: { session.setKeepAwake($0) }))
                    .toggleStyle(.button).labelStyle(.iconOnly).accessibilityIdentifier("reader.awake")
            }
            Button("Open book", systemImage: "doc.badge.plus") { perform(.openDocument, width: width) }.disabled(session.busy)
            Button("Appearance", systemImage: "paintpalette") { perform(.toggleAppearance, width: width) }
                .focusable()
                .focused($toolbarFocus, equals: .appearance)
                .onKeyPress(.space) { perform(.toggleAppearance, width: width); return .handled }
                .accessibilityIdentifier("appearance.toggle")
                 .popover(isPresented: $appearanceVisible) {
                    VStack(spacing: 0) {
                        AppearancePicker(appearance: $appearance)
                        if session.engine != nil {
                            Divider()
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Page palette", selection: Binding(get: { session.commands?.palette ?? .original }, set: { session.setPalette($0) })) {
                                    ForEach(PagePalette.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue.capitalized)).tag($0) }
                                }.accessibilityIdentifier("page.palette")
                                Text("Page \(session.pageNumber)").font(.caption).foregroundStyle(Adaptive.secondary)
                                if session.commands?.palette != .original && session.pdfEngine?.colorSupport != nil && session.pdfEngine?.colorSupport != .available {
                                    Text("Original preserves this page’s images or layout.").font(.caption).foregroundStyle(Adaptive.secondary)
                                        .accessibilityIdentifier("page.fallback")
                                }
                                if let epub = session.epubEngine { EPUBTypographyControls(session: session, engine: epub) }
                                Button("Undo palette") { session.undoPalette() }
                                    .disabled(!(session.commands?.canUndoPalette ?? false))
                            }.padding(24).frame(width: 280)
                        }
                    }.onExitCommand { appearanceVisible = false }.onDisappear { restoreFocus(.appearance) }
                }
            Button("Document inspector", systemImage: "sidebar.right") {
                perform(.toggleInspector, width: width)
            }
            .focusable()
            .focused($toolbarFocus, equals: .inspector)
            .onKeyPress(.space) { perform(.toggleInspector, width: width); return .handled }
            .accessibilityIdentifier("inspector.toggle")
            if hasBook && width >= Adaptive.Layout.inspectorThreshold {
                Button("AI Companion", systemImage: "sparkle") { perform(.companion, width: width) }
                    .accessibilityIdentifier("ai.toggle")
            }
            Menu {
                Button("Command Center") { perform(.commandCenter, width: width) }
                Button("AI Companion") { perform(.companion, width: width) }.disabled(!hasBook)
                Button("Reading tools") { perform(.readingTools, width: width) }
                if hasBook {
                    Button("Back") { perform(.back, width: width) }.disabled(session.commands?.canGoBack != true)
                    Button("Forward") { perform(.forward, width: width) }.disabled(session.commands?.canGoForward != true)
                    Button("Mini Reader") { perform(.miniReader, width: width) }
                    Button("Reading Spotlight") { perform(.toggleSpotlight, width: width) }
                    Button("Auto-scroll") { perform(.toggleAutoScroll, width: width) }
                }
                Divider()
                Button("Import linked book") { perform(.importReference, width: width) }
                Button("Appearance") { perform(.toggleAppearance, width: width) }
                Button("Sidebar") { perform(.toggleSidebar, width: width) }
                Button("Document inspector") { perform(.toggleInspector, width: width) }
                if hasBook {
                    Button("Find in book") { perform(.search, width: width) }.disabled(session.engine?.capabilities.contains(.search) != true)
                    Button("Bookmark page") { perform(.toggleBookmark, width: width) }
                    Button("Focus") { perform(.toggleFocus, width: width) }
                    Button("Keep Awake") { perform(.toggleAwake, width: width) }
                    Button("Close book") { perform(.closeBook, width: width) }
                }
                Divider()
                Button("Adaptive components") { catalogVisible = true }
            } label: { Label("More", systemImage: "ellipsis.circle") }
            .accessibilityLabel(Text("More actions"))
            .accessibilityIdentifier("workspace.more")
        }
    }
}

struct NativePDFView: NSViewRepresentable {
    let engine: PDFReaderEngine
    let session: ReaderSession
    final class Coordinator {
        weak var session: ReaderSession?
        weak var engine: PDFReaderEngine?
        init(_ session: ReaderSession, _ engine: PDFReaderEngine) { self.session = session; self.engine = engine }
    }
    func makeCoordinator() -> Coordinator { Coordinator(session, engine) }
    func makeNSView(context: Context) -> PDFSurfaceHost {
        PDFSurfaceHost(pdf: engine.view) { [weak session, weak engine] in
            guard let session, session.engine === engine else { return }
            session.mount()
        }
    }
    func updateNSView(_ view: PDFSurfaceHost, context: Context) {}
    static func dismantleNSView(_ host: PDFSurfaceHost, coordinator: Coordinator) {
        if host.pdf.superview === host { host.pdf.removeFromSuperview() }
        Task { @MainActor in
            guard let session = coordinator.session, session.engine === coordinator.engine else { return }
            await session.flush()
        }
    }
}

/// Each window owns a host; a detached reader lends the same PDFView to a new host.
final class PDFSurfaceHost: NSView {
    let pdf: PDFView
    private let mounted: () -> Void
    init(pdf: PDFView, mounted: @escaping () -> Void) {
        self.pdf = pdf; self.mounted = mounted
        super.init(frame: pdf.frame)
        setAccessibilityElement(false)
        pdf.removeFromSuperview(); addSubview(pdf); pdf.autoresizingMask = [.width, .height]; pdf.frame = bounds
    }
    required init?(coder: NSCoder) { fatalError("Programmatic PDF host") }
    override func layout() { super.layout(); if pdf.superview === self { pdf.frame = bounds } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.pdf.superview === self else { return }
            self.layoutSubtreeIfNeeded(); self.pdf.layoutDocumentView(); self.mounted()
        }
    }
}

struct NativeEPUBView: NSViewRepresentable {
    let engine: EPUBReaderEngine
    let session: ReaderSession
    func makeNSView(context: Context) -> WKWebView {
        Task { @MainActor [weak session, weak engine] in
            guard let session, session.engine === engine else { return }
            session.mount()
        }
        return engine.view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

struct EPUBTypographyControls: View {
    let session: ReaderSession
    let engine: EPUBReaderEngine
    private func binding<T>(_ keyPath: WritableKeyPath<EPUBTypography, T>) -> Binding<T> {
        Binding(get: { engine.typography[keyPath: keyPath] }, set: { value in
            var settings = engine.typography; settings[keyPath: keyPath] = value
            do { try session.commands?.perform(.setTypography(settings)); Task { await session.flush() } }
            catch { session.report(error) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Typeface", selection: binding(\.typeface)) {
                Text("Serif").tag(EPUBTypography.Typeface.serif)
                Text("System").tag(EPUBTypography.Typeface.system)
            }.accessibilityIdentifier("epub.typeface")
            Text("Text size")
            Slider(value: binding(\.fontSize), in: 12...36, step: 1).accessibilityLabel("Text size").accessibilityIdentifier("epub.fontSize")
            Text("Column width")
            Slider(value: binding(\.columnWidth), in: 320...960, step: 20).accessibilityLabel("Column width").accessibilityIdentifier("epub.columnWidth")
            Text("Line spacing")
            Slider(value: binding(\.lineHeight), in: 1.2...2.2, step: 0.1).accessibilityLabel("Line spacing").accessibilityIdentifier("epub.lineHeight")
        }
    }
}
