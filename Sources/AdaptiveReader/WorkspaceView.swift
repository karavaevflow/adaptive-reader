import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("inspectorVisible") private var inspectorVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var document: PDFDocument?
    @State private var title = "Adaptive Reader"
    @State private var importing = false
    @State private var appearanceVisible = false
    @State private var catalogVisible = false
    @State private var errorMessage: String?
    @AppStorage("shellAppearance") private var appearance = ShellAppearance.system

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if sidebarVisible && geometry.size.width >= 1000 {
                    List {
                        Label("All Books", systemImage: "books.vertical")
                        Label("Reading", systemImage: "book")
                        Label("Favorites", systemImage: "star")
                    }
                    .listStyle(.sidebar)
                    .frame(width: 220)
                    Divider()
                }
                Group {
                    if let document {
                        NativePDFView(document: document)
                    } else {
                        VStack(spacing: Adaptive.Space.large) {
                            AdaptiveEmptyState(
                                title: "Your next chapter",
                                message: "Open a PDF to begin reading.",
                                symbol: "book.closed"
                            )
                            Button("Open PDF", systemImage: "plus") { importing = true }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut("o")
                        }
                        .padding(Adaptive.Space.extraLarge)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if inspectorVisible && geometry.size.width >= 1200 {
                    Divider()
                    VStack(alignment: .leading, spacing: Adaptive.Space.regular) {
                        Text("Document").font(.headline)
                        Text(title).textSelection(.enabled)
                        if let document { Text("\(document.pageCount) pages").foregroundStyle(.secondary) }
                        Spacer()
                    }
                    .padding(Adaptive.Space.large)
                    .frame(width: 240)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: sidebarVisible)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: inspectorVisible)
        }
        .background(Adaptive.background)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Sidebar", systemImage: "sidebar.left") { sidebarVisible.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .accessibilityValue(sidebarVisible ? "Shown" : "Hidden")
            }
            ToolbarItemGroup {
                Button("Open PDF", systemImage: "doc.badge.plus") { importing = true }
                Button("Appearance", systemImage: "paintpalette") { appearanceVisible.toggle() }
                    .popover(isPresented: $appearanceVisible) {
                        Picker("Appearance", selection: $appearance) {
                            ForEach(ShellAppearance.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                        .padding(Adaptive.Space.large)
                        .frame(width: 220)
                    }
                Menu {
                    Button("Document inspector", systemImage: "sidebar.right") { inspectorVisible.toggle() }
                    Button("Adaptive components") { catalogVisible = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                // Own the bytes before relinquishing the file-picker access grant.
                let data = try Data(contentsOf: url)
                guard let opened = PDFDocument(data: data) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                document = opened
                title = url.deletingPathExtension().lastPathComponent
            } catch { errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: $catalogVisible) {
            VStack {
                ComponentCatalog()
                Button("Done") { catalogVisible = false }.keyboardShortcut(.cancelAction)
            }.padding()
        }
        .alert("Unable to open document", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
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
