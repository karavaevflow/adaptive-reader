import SwiftUI
import ReaderCore
import PDFKit
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
    private var document: PDFDocument? { session.engine?.document }
    private var title: String { session.title }
    @State private var importing = false
    @State private var appearanceVisible = false
    @State private var catalogVisible = false
    @State private var compactSidebarVisible = false
    @State private var compactInspectorVisible = false
    @State private var section = LibrarySection.all
    @FocusState private var toolbarFocus: ToolbarFocus?
    private enum ToolbarFocus: Hashable { case sidebar, appearance, inspector }

    var body: some View {
        GeometryReader { geometry in
            workspace(width: geometry.size.width)
                .toolbar { toolbar(width: geometry.size.width) }
                .focusedSceneValue(\.workspaceActions, WorkspaceActions(
                    openDocument: { if !session.busy { importing = true } },
                    toggleSidebar: { toggleSidebar(width: geometry.size.width) },
                    toggleAppearance: { appearanceVisible.toggle() },
                    toggleInspector: { toggleInspector(width: geometry.size.width) },
                    zoomIn: { session.zoom(by: 1.1) }, zoomOut: { session.zoom(by: 1 / 1.1) }
                ))
        }
        .background(Adaptive.background)
        .background(WindowIntegration(autosaveName: windowAutosaveName))
        .navigationTitle(title)
        .task { await startSession() }
        .onDisappear { Task { await session.flush() } }
        .overlay { if session.busy { ProgressView("Opening document").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): Task { await session.importURL(url) }
            case .failure(let error): session.report(error)
            }
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
        .sheet(isPresented: $compactInspectorVisible, onDismiss: { toolbarFocus = .inspector }) {
            VStack(alignment: .trailing) {
                inspector.frame(width: 320, height: 240)
                Button("Done") { compactInspectorVisible = false }.keyboardShortcut(.cancelAction)
                    .padding(Adaptive.Space.regular)
            }
        }
        .alert("Unable to open document", isPresented: Binding(
            get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
        .onChange(of: appearanceVisible) { _, visible in
            if !visible { toolbarFocus = .appearance }
        }
        .onChange(of: compactSidebarVisible) { _, visible in
            if !visible { toolbarFocus = .sidebar }
        }
    }

    private func startSession() async {
        #if DEBUG || FOUNDATION_BENCHMARK
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-designReader") || arguments.contains("-phase0Import") else {
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
        let paragraph = NSAttributedString(string: "A quiet place to read.\n\nChapter One\n\nA book opens a space for thought.\nFollow the words, pause, and return to the page.", attributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black
        ])
        let path = CGPath(rect: CGRect(x: 64, y: 64, width: 484, height: 650), transform: nil)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(paragraph), CFRange(), path, nil)
        CTFrameDraw(frame, context)
        if page > 0 {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 60, y: 540, width: 490, height: 190))
            let label = NSAttributedString(string: "Chapter \(page + 1)", attributes: [.font: NSFont.systemFont(ofSize: 24)])
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(label), CFRange(), CGPath(rect: CGRect(x: 64, y: 560, width: 480, height: 160), transform: nil), nil), context)
        }
        context.endPDFPage()
        }
        context.closePDF()
        do {
            if arguments.contains("-phase0Import") { try await session.importData(data as Data, title: "Phase 0 reader") }
            else { try session.openReview(data as Data) }
        } catch { session.report(error) }
        #else
        await session.restore()
        #endif
    }

    private func workspace(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if sidebarVisible && width >= Adaptive.Layout.sidebarThreshold {
                sidebar.frame(width: Adaptive.Layout.sidebar)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider().overlay(Adaptive.divider)
            }
            Group {
                if let engine = session.engine { NativePDFView(engine: engine, session: session).id(engine.bookID) }
                else {
                    VStack(spacing: Adaptive.Space.small) {
                        AdaptiveEmptyState(title: "Your next chapter", message: "Open a PDF to begin reading.",
                                           symbol: "book.closed")
                        Button("Open PDF", systemImage: "plus") { importing = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(session.busy)
                            .accessibilityIdentifier("library.open")
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if inspectorVisible && width >= Adaptive.Layout.inspectorThreshold {
                Divider().overlay(Adaptive.divider)
                inspector.frame(width: Adaptive.Layout.inspector)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Adaptive.Motion.panel, value: sidebarVisible)
        .animation(reduceMotion ? nil : Adaptive.Motion.panel, value: inspectorVisible)
    }

    private var sidebar: some View {
        AdaptivePanel {
            List {
                ForEach(LibrarySection.allCases) { item in
                    Button { section = item } label: {
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
                toggleSidebar(width: width)
            }
            .focused($toolbarFocus, equals: .sidebar)
            .help("Show or hide the library")
            .accessibilityIdentifier("sidebar.toggle")
            .accessibilityValue(Text(sidebarVisible && width >= Adaptive.Layout.sidebarThreshold ? "Shown" : "Hidden"))
            .popover(isPresented: $compactSidebarVisible) { sidebar.frame(width: 240, height: 240) }
        }
        ToolbarItemGroup {
            if let engine = session.engine {
                Button("Previous page", systemImage: "chevron.left") { session.navigate(page: session.pageNumber - 1) }
                    .disabled(session.pageNumber <= 1).accessibilityIdentifier("page.previous")
                Text("\(session.pageNumber)/\(engine.document.pageCount)").monospacedDigit()
                    .accessibilityIdentifier("page.current")
                Button("Next page", systemImage: "chevron.right") { session.navigate(page: session.pageNumber + 1) }
                    .disabled(session.pageNumber >= engine.document.pageCount).accessibilityIdentifier("page.next")
            }
            Button("Open PDF", systemImage: "doc.badge.plus") { importing = true }.disabled(session.busy)
            Button("Appearance", systemImage: "paintpalette") { appearanceVisible.toggle() }
                .focused($toolbarFocus, equals: .appearance)
                .accessibilityIdentifier("appearance.toggle")
                 .popover(isPresented: $appearanceVisible) {
                    VStack(spacing: 0) {
                        AppearancePicker(appearance: $appearance)
                        if let engine = session.engine {
                            Divider()
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Page palette", selection: Binding(get: { session.commands?.palette ?? .original }, set: { session.setPalette($0) })) {
                                    ForEach(PagePalette.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue.capitalized)).tag($0) }
                                }.accessibilityIdentifier("page.palette")
                                Text("Page \(session.pageNumber)").font(.caption).foregroundStyle(Adaptive.secondary)
                                if session.commands?.palette != .original && engine.colorSupport != .available {
                                    Text("Original preserves this page’s images or layout.").font(.caption).foregroundStyle(Adaptive.secondary)
                                        .accessibilityIdentifier("page.fallback")
                                }
                                Button("Undo palette") { session.undoPalette() }
                                    .disabled(!(session.commands?.canUndoPalette ?? false))
                            }.padding(24).frame(width: 280)
                        }
                    }
                }
            Button("Document inspector", systemImage: "sidebar.right") {
                toggleInspector(width: width)
            }
            .focused($toolbarFocus, equals: .inspector)
            .accessibilityIdentifier("inspector.toggle")
            Menu {
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
        init(_ session: ReaderSession) { self.session = session }
    }
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeNSView(context: Context) -> PDFView {
        DispatchQueue.main.async { session.mount() }
        return engine.view
    }
    func updateNSView(_ view: PDFView, context: Context) {}
    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        Task { @MainActor in await coordinator.session?.flush() }
    }
}
