import SwiftUI
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
    @State private var document: PDFDocument?
    @State private var title = "Adaptive Reader"
    @State private var importing = false
    @State private var appearanceVisible = false
    @State private var catalogVisible = false
    @State private var compactSidebarVisible = false
    @State private var compactInspectorVisible = false
    @State private var section = LibrarySection.all
    @State private var errorMessage: String?
    @FocusState private var toolbarFocus: ToolbarFocus?
    private enum ToolbarFocus: Hashable { case sidebar, appearance, inspector }

    var body: some View {
        GeometryReader { geometry in
            workspace(width: geometry.size.width)
                .toolbar { toolbar(width: geometry.size.width) }
                .focusedSceneValue(\.workspaceActions, WorkspaceActions(
                    openDocument: { importing = true },
                    toggleSidebar: { toggleSidebar(width: geometry.size.width) },
                    toggleAppearance: { appearanceVisible.toggle() },
                    toggleInspector: { toggleInspector(width: geometry.size.width) }
                ))
        }
        .background(Adaptive.background)
        .navigationTitle(title)
        #if DEBUG
        .task { loadReviewDocument() }
        #endif
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard let opened = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                document = opened
                title = url.deletingPathExtension().lastPathComponent
            } catch { errorMessage = error.localizedDescription }
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
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: appearanceVisible) { _, visible in
            if !visible { toolbarFocus = .appearance }
        }
        .onChange(of: compactSidebarVisible) { _, visible in
            if !visible { toolbarFocus = .sidebar }
        }
    }

    #if DEBUG
    private func loadReviewDocument() {
        guard ProcessInfo.processInfo.arguments.contains("-designReader") else { return }
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)
        let paragraph = NSAttributedString(string: "A quiet place to read.\n\nChapter One\n\nA book opens a space for thought.\nFollow the words, pause, and return to the page.", attributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black
        ])
        let path = CGPath(rect: CGRect(x: 64, y: 64, width: 484, height: 650), transform: nil)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(paragraph), CFRange(), path, nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()
        document = PDFDocument(data: data as Data)
        title = "Reading specimen"
    }
    #endif

    private func workspace(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if sidebarVisible && width >= Adaptive.Layout.sidebarThreshold {
                sidebar.frame(width: Adaptive.Layout.sidebar)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider().overlay(Adaptive.divider)
            }
            Group {
                if let document { NativePDFView(document: document) }
                else {
                    VStack(spacing: Adaptive.Space.small) {
                        AdaptiveEmptyState(title: "Your next chapter", message: "Open a PDF to begin reading.",
                                           symbol: "book.closed")
                        Button("Open PDF", systemImage: "plus") { importing = true }
                            .buttonStyle(.borderedProminent)
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
                    Text("\(document.pageCount) pages").foregroundStyle(Adaptive.secondary)
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
            Button("Open PDF", systemImage: "doc.badge.plus") { importing = true }
            Button("Appearance", systemImage: "paintpalette") { appearanceVisible.toggle() }
                .focused($toolbarFocus, equals: .appearance)
                .accessibilityIdentifier("appearance.toggle")
                .popover(isPresented: $appearanceVisible) { AppearancePicker(appearance: $appearance) }
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
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
