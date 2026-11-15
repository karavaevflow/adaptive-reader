import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

extension KnowledgeKind {
    var label: LocalizedStringKey {
        switch self { case .quotation: "Author quotation"; case .readerNote: "Reader note"; case .modelInference: "Model inference" }
    }
    var symbol: String {
        switch self { case .quotation: "quote.opening"; case .readerNote: "pencil"; case .modelInference: "sparkles" }
    }
}
struct KnowledgeView: View {
    @Bindable var model: KnowledgeModel
    @State private var exporting = false
    @State private var importing = false
    @State private var exportType = UTType.plainText
    @State private var exportName = "Knowledge.md"
    @State private var document = StudyTextDocument("")
    @State private var memoryQuery = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Knowledge workspace").font(.headline)
                Spacer()
                Button("Save current passage", systemImage: "plus") { model.capture() }.disabled(!model.canCapture).accessibilityIdentifier("knowledge.capture")
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Export Markdown") { document = StudyTextDocument(model.memory.markdown()); exportType = UTType(filenameExtension: "md") ?? .plainText; exportName = "Knowledge.md"; exporting = true }.accessibilityIdentifier("knowledge.export.markdown")
                    Button("Export knowledge (JSON)") {
                        do { document = StudyTextDocument(String(decoding: try model.memory.encoded(), as: UTF8.self)); exportType = .json; exportName = "Knowledge.json"; exporting = true }
                        catch { model.report(error) }
                    }
                    Button("Import knowledge (JSON)") { importing = true }
                    Button("Reset search index") { Task { await model.resetIndex() } }.disabled(model.busy)
                }.menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("knowledge.more")
                Button("Close", systemImage: "xmark") { model.close() }.labelStyle(.iconOnly).keyboardShortcut(.cancelAction).accessibilityIdentifier("knowledge.close")
            }.padding(16)
            Picker("Knowledge section", selection: $model.tab) {
                Text("Memory").tag("memory"); Text("Library search").tag("search"); Text("Canvas").tag("canvas"); Text("Timeline").tag("timeline"); Text("Reading paths").tag("paths")
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 12).accessibilityIdentifier("knowledge.tabs")
            Divider()
            if let error = model.errorMessage { HStack { Text(error).foregroundStyle(.red).textSelection(.enabled); Spacer(); Button("Dismiss") { model.errorMessage = nil } }.font(.callout).padding(12).accessibilityIdentifier("knowledge.error") }
            if let message = model.statusMessage { Text(message).font(.caption).foregroundStyle(Adaptive.secondary).padding(8) }
            if model.busy { HStack { ProgressView(); Text(LocalizedStringKey(model.operationLabel)).font(.callout); if model.operationLabel == "Searching library" { ProgressView(value: model.progress) }; Spacer(); Button("Cancel") { model.cancel() } }.padding(12) }
            Group {
                switch model.tab {
                case "search": search
                case "canvas": KnowledgeCanvas(model: model)
                case "timeline": timeline
                case "paths": paths
                default: memory
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Adaptive.background).accessibilityElement(children: .contain).accessibilityIdentifier("knowledge.workspace")
        .task { await model.reload() }
        .sheet(isPresented: $model.comparisonVisible) { KnowledgeComparison(model: model) }
        .sheet(item: $model.draft) { value in KnowledgeEditor(model: model, initial: value) }
        .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportName) { result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { model.report(error) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { model.report(error) }; return }
            Task {
                do {
                    let value = try await Task.detached {
                        let grant = url.startAccessingSecurityScopedResource(); defer { if grant { url.stopAccessingSecurityScopedResource() } }
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 48 * 1024 * 1024 else { throw CompanionError.limitExceeded }
                        let value = try JSONDecoder().decode(KnowledgeSnapshot.self, from: Data(contentsOf: url)); try value.validate(); return value
                    }.value
                    _ = await model.perform(.merge(value))
                } catch { model.report(error) }
            }
        }
    }
    private var memory: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search saved cards", text: $memoryQuery).textFieldStyle(.roundedBorder).accessibilityIdentifier("knowledge.memory.query")
                Button("New reader note") { model.capture(kind: .readerNote) }.disabled(!model.canCapture)
                if model.deleted != nil { Button("Undo deletion") { Task { await model.undoDeletion() } } }
            }
            Text("Your saved ideas and sources. Search indexes are separate and can be rebuilt.").font(.caption).foregroundStyle(Adaptive.secondary)
            if model.memory.cards.isEmpty { ContentUnavailableView("No saved knowledge", systemImage: "square.stack", description: Text("Save a passage, reader note or cited model answer.")) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.memory.cards.filter { memoryQuery.isEmpty || KnowledgeSearchIndex.matches(memoryQuery, $0.title + " " + $0.text + " " + $0.tags.joined(separator: " ")) }) { card in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Label(card.kind.label, systemImage: card.kind.symbol).font(.caption).foregroundStyle(Adaptive.secondary); Spacer(); Text(card.tags.joined(separator: " · ")).font(.caption) }
                            Text(card.title).font(.headline).accessibilityIdentifier("knowledge.card.title")
                            Text(card.text).textSelection(.enabled).lineLimit(5)
                            if !card.comment.isEmpty { Text("Your comment").font(.caption2).foregroundStyle(Adaptive.secondary); Text(card.comment).font(.callout).foregroundStyle(Adaptive.secondary) }
                            ForEach(Array(card.sources.enumerated()), id: \.offset) { _, source in sourceButton(source) }
                            HStack {
                                Button("Edit") { model.draft = card }.accessibilityIdentifier("knowledge.card.edit")
                                Button("Add to Canvas") { Task { await model.addToBoard(card) } }.accessibilityIdentifier("knowledge.card.canvas")
                                Spacer()
                                Button("Delete", role: .destructive) { Task { await model.removeCard(card.id) } }.accessibilityIdentifier("knowledge.card.delete")
                            }.controlSize(.small)
                        }.padding(16).background(Adaptive.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Adaptive.divider))
                    }
                }
            }
        }.padding(16)
    }
    private var search: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Ask or search the library", text: $model.query).textFieldStyle(.roundedBorder).onSubmit { model.search() }.accessibilityIdentifier("knowledge.search.query")
                Button("Search") { model.search() }.disabled(model.busy || model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("knowledge.search.run")
            }
            HStack {
                TextField("Title", text: $model.titleFilter)
                TextField("Author", text: $model.authorFilter)
                TextField("Collection", text: $model.collectionFilter)
                Menu("Books") {
                    ForEach(model.books) { book in Toggle(book.title, isOn: Binding(get: { model.selectedBooks.contains(book.id) }, set: { if $0 { model.selectedBooks.insert(book.id) } else { model.selectedBooks.remove(book.id) } })) }
                    Button("All books") { model.selectedBooks = [] }
                }
                Toggle("Saved only", isOn: $model.savedOnly)
            }.textFieldStyle(.roundedBorder).controlSize(.small)
            HStack {
                Button("Compare selected") { model.comparisonVisible = true }.disabled(model.busy || Set(model.hits.filter { model.selectedHits.contains($0.id) && $0.kind == .quotation }.map { $0.source.anchor.bookID }).count < 2).accessibilityIdentifier("knowledge.compare")
                Button("Ask selected sources") { model.ask(compare: false) }.disabled(model.busy || model.selectedHits.isEmpty || model.settings.mode == .off)
                Button("Suggest reading path") { Task { await model.suggestPath() } }.disabled(model.busy || model.hits.isEmpty).accessibilityIdentifier("knowledge.path.suggest")
            }
            Text(LocalizedStringKey(model.settings.mode == .off ? "AI is off. Search, comparisons of excerpts and reading paths work locally." : "AI receives only the selected excerpts, titles and your question when you ask.")).font(.caption).foregroundStyle(Adaptive.secondary)
            Text(LocalizedStringKey(model.semanticAvailable ? "Saved cards: installed local semantic model + text search" : "Text search · local semantic model unavailable for this query language")).font(.caption2).foregroundStyle(Adaptive.secondary)
            if model.truncated { Text("Results limited. Refine your query or book filters.").font(.caption) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let answer = model.answer {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Model inference", systemImage: "sparkles").font(.headline)
                            Text(answer.answer).textSelection(.enabled)
                            ForEach(model.answerSources.filter { answer.sourceIDs.contains($0.id) }) { sourceButton($0.source) }
                            Button("Save cited answer") { model.saveAnswer() }.disabled(answer.kind != .book)
                        }.padding(16).background(Adaptive.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if !model.busy && model.hits.isEmpty {
                        ContentUnavailableView(LocalizedStringKey(model.hasSearched ? "No matching excerpts" : "Search your library"), systemImage: "magnifyingglass", description: Text("Try a term or filter the books, authors and collections."))
                    }
                    ForEach(model.hits) { hit in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle(isOn: Binding(get: { model.selectedHits.contains(hit.id) }, set: { if $0 { model.selectedHits.insert(hit.id) } else { model.selectedHits.remove(hit.id) } })) { Label(hit.kind.label, systemImage: hit.kind.symbol).font(.caption) }.toggleStyle(.checkbox)
                                    .accessibilityLabel(Text(hit.kind.label) + Text(" · " + hit.source.bookTitle + " · " + hit.source.location))
                                    .accessibilityIdentifier("knowledge.hit.select." + hit.id)
                                Spacer(); Button("Save card") { model.saveHit(hit) }.accessibilityIdentifier("knowledge.hit.save")
                            }
                            Text(hit.text).textSelection(.enabled).lineLimit(6).accessibilityIdentifier("knowledge.hit.text")
                            sourceButton(hit.source)
                        }.padding(12).background(Adaptive.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Adaptive.secondary) }
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("knowledge.search.results")
        }.padding(16)
    }
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Book", selection: $model.timelineBook) { ForEach(model.books) { Text($0.title).tag(Optional($0.id)) } }.accessibilityIdentifier("knowledge.timeline.book")
                Button("Show timeline") { model.loadTimeline() }.disabled(model.busy).accessibilityIdentifier("knowledge.timeline.load")
            }
            Text("Actual source chapters and your saved events or ideas. No invented events.").font(.caption).foregroundStyle(Adaptive.secondary)
            if let id = model.timelineBook { KnowledgeMetadataEditor(model: model, bookID: id).id(id) }
            if !model.busy && model.timeline.isEmpty { Text("This book has no available outline or saved events yet.").font(.caption).foregroundStyle(Adaptive.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.timeline) { step in
                        VStack(alignment: .leading, spacing: 4) { Text(step.title).font(.headline); sourceButton(step.source) }.padding(.vertical, 4)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("knowledge.timeline")
        }.padding(16)
    }
    private var paths: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                Text("Suggested from available excerpts matching your goal. Edit freely; coverage is not exhaustive.").font(.caption).foregroundStyle(Adaptive.secondary)
                ForEach(model.memory.paths) { path in KnowledgePathView(model: model, initial: path).id(path.id) }
                if model.memory.paths.isEmpty { ContentUnavailableView("No reading paths", systemImage: "point.topleft.down.to.point.bottomright.curvepath", description: Text("Search for a goal, select useful excerpts and suggest a reading path.")) }
            }.padding(16)
        }
    }
    private func sourceButton(_ source: KnowledgeSource) -> some View {
        Button { Task { await model.open(source) } } label: { Label(source.bookTitle + " · " + source.location, systemImage: "arrow.up.right").font(.caption).lineLimit(2) }.buttonStyle(.link).accessibilityIdentifier("knowledge.source")
    }
}
private struct KnowledgeEditor: View {
    let model: KnowledgeModel
    @State var value: KnowledgeCard
    @State private var tags: String
    init(model: KnowledgeModel, initial: KnowledgeCard) { self.model = model; _value = State(initialValue: initial); _tags = State(initialValue: initial.tags.joined(separator: ", ")) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(value.kind.label, systemImage: value.kind.symbol).font(.headline)
            TextField("Card title", text: $value.title).textFieldStyle(.roundedBorder).accessibilityIdentifier("knowledge.editor.title")
            if value.kind == .quotation { Text(value.text).lineLimit(5).textSelection(.enabled) }
            else { TextEditor(text: $value.text).frame(height: 120).border(Adaptive.divider).accessibilityLabel("Card text") }
            Text("Your comment").font(.caption)
            TextEditor(text: $value.comment).frame(height: 80).border(Adaptive.divider).accessibilityLabel("Your comment").accessibilityIdentifier("knowledge.editor.comment")
            TextField("Tags, separated by commas", text: $tags).textFieldStyle(.roundedBorder)
            ScrollView { VStack(alignment: .leading) { ForEach(Array(value.sources.enumerated()), id: \.offset) { _, source in Text(source.bookTitle + " · " + source.location).font(.caption).foregroundStyle(Adaptive.secondary) } } }.frame(maxHeight: 60)
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel") { model.draft = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save card") {
                    value.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    Task { await model.saveDraft(value) }
                }.keyboardShortcut(.defaultAction).disabled(value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.title.count > 300 || value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.text.count > 8000 || value.comment.count > 8000).accessibilityIdentifier("knowledge.editor.save")
            }
        }.padding(24).frame(width: 480)
    }
}
private struct KnowledgeMetadataEditor: View {
    let model: KnowledgeModel
    let bookID: UUID
    @State private var author = ""
    @State private var collection = ""
    var body: some View {
        HStack {
            TextField("Author", text: $author); TextField("Collection", text: $collection)
            Button("Save metadata") { Task { _ = await model.perform(.metadata(.init(bookID: bookID, author: author, collection: collection))) } }
        }.textFieldStyle(.roundedBorder).controlSize(.small).task {
            author = model.memory.metadata.first { $0.bookID == bookID }?.author ?? ""
            collection = model.memory.metadata.first { $0.bookID == bookID }?.collection ?? ""
        }
    }
}
private struct KnowledgePathView: View {
    let model: KnowledgeModel
    @State var value: KnowledgeReadingPath
    init(model: KnowledgeModel, initial: KnowledgeReadingPath) { self.model = model; _value = State(initialValue: initial) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Reading goal", text: $value.goal).font(.headline).accessibilityIdentifier("knowledge.path.goal")
            ForEach(Array(value.steps.enumerated()), id: \.element.id) { index, step in
                HStack {
                    Toggle(isOn: Binding(get: { value.steps[index].completed }, set: { value.steps[index].completed = $0 })) { EmptyView() }.labelsHidden()
                    TextField("Step title", text: $value.steps[index].title)
                    Button("Open source") { Task { await model.open(step.source) } }
                    Button { value.steps.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).accessibilityLabel("Move step up")
                    Button { value.steps.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index == value.steps.count - 1).accessibilityLabel("Move step down")
                    Button { value.steps.remove(at: index) } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove step")
                }.controlSize(.small)
            }
            Button("Save reading path") { Task { _ = await model.perform(.savePath(value)) } }.disabled(value.steps.isEmpty).accessibilityIdentifier("knowledge.path.save")
        }.padding(16).background(Adaptive.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct KnowledgeCanvas: View {
    @Bindable var model: KnowledgeModel
    @State private var pan = CGSize(width: 40, height: 50)
    @State private var panStart = CGSize(width: 40, height: 50)
    @State private var zoom = 1.0
    @State private var zoomStart = 1.0
    @State private var query = ""
    @State private var relation = ""
    @State private var cluster = ""
    @State private var drag: [UUID: CGSize] = [:]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Board", selection: $model.boardID) { ForEach(model.memory.boards) { Text($0.title).tag(Optional($0.id)) } }.frame(maxWidth: 200)
                Button("New board") { Task { await model.newBoard() } }.accessibilityIdentifier("knowledge.board.new")
                TextField("Find cards", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    .onSubmit { revealFirstMatch() }.help("Press Return to reveal the first matching card.").accessibilityIdentifier("knowledge.canvas.query")
                Spacer()
                if let undo = model.undoMovement, undo.0 == model.boardID { Button("Undo move") { Task { if await model.perform(.placeNode(board: undo.0, node: undo.1)) { model.undoMovement = nil } } } }
                Button { zoom = max(0.25, zoom / 1.2); zoomStart = zoom } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Zoom out")
                Text(zoom, format: .percent.precision(.fractionLength(0))).monospacedDigit().font(.caption)
                Button { zoom = min(2, zoom * 1.2); zoomStart = zoom } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Zoom in")
                Button("Center") { pan = .init(width: 40, height: 50); panStart = pan; zoom = 1; zoomStart = 1 }
            }.padding(12).controlSize(.small)
            if let board = model.board {
                HStack {
                    TextField("Connection label", text: $relation).textFieldStyle(.roundedBorder).accessibilityIdentifier("knowledge.connection.label")
                    Button("Connect selected") { Task { await model.connect(label: relation) } }.disabled(model.selectedNodes.count != 2 || relation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || relation.count > 300).accessibilityIdentifier("knowledge.connect")
                    TextField("Cluster", text: $cluster).textFieldStyle(.roundedBorder).frame(maxWidth: 130)
                    Button("Group selected") { Task { for node in board.nodes where model.selectedNodes.contains(node.id) { var item = node; item.cluster = cluster; _ = await model.perform(.placeNode(board: board.id, node: item)) } } }.disabled(model.selectedNodes.isEmpty || cluster.count > 100)
                }.padding(.horizontal, 12).padding(.bottom, 10).controlSize(.small)
                GeometryReader { geometry in
                    let translations = drag.mapValues { CanvasPoint(x: $0.width, y: $0.height) }
                    let layout = KnowledgeCanvasLayout(board: board, cards: model.memory.cards, origin: .init(x: pan.width, y: pan.height), zoom: zoom, viewport: .init(x: geometry.size.width, y: geometry.size.height), query: query, translations: translations)
                    ZStack(alignment: .topLeading) {
                        Adaptive.surface.opacity(0.5).contentShape(Rectangle()).gesture(DragGesture().onChanged { pan = .init(width: panStart.width + $0.translation.width, height: panStart.height + $0.translation.height) }.onEnded { _ in panStart = pan })
                        Canvas { context, _ in
                            let groups = Dictionary(grouping: layout.visibleNodes.filter { !$0.cluster.isEmpty }, by: \.cluster)
                            for (name, nodes) in groups {
                                let points = nodes.compactMap { layout.centers[$0.id] }
                                if let x = points.map(\.x).min(), let y = points.map(\.y).min(), let maxX = points.map(\.x).max(), let maxY = points.map(\.y).max() {
                                    let rect = CGRect(x: x - 125 * zoom - 12, y: y - 75 * zoom - 24, width: maxX - x + 250 * zoom + 24, height: maxY - y + 150 * zoom + 36)
                                    context.fill(Path(roundedRect: rect, cornerRadius: 16), with: .color(Color.accentColor.opacity(0.04)))
                                    context.draw(Text(name).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: rect.minX + 12, y: rect.minY + 12), anchor: .leading)
                                }
                            }
                            for edge in layout.connections {
                                let a = CGPoint(x: edge.start.x, y: edge.start.y), b = CGPoint(x: edge.end.x, y: edge.end.y)
                                var line = Path(); line.move(to: a); line.addLine(to: b)
                                context.stroke(line, with: .color(.secondary.opacity(0.6)), lineWidth: 1.5)
                                context.draw(Text(edge.label).font(.caption).foregroundStyle(.secondary), at: .init(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                            }
                        }.allowsHitTesting(false)
                        ForEach(layout.visibleNodes) { node in
                            if let card = layout.cards[node.id], let center = layout.centers[node.id] {
                                let point = CGPoint(x: center.x, y: center.y)
                                Group {
                                    canvasCard(card, node: node).frame(width: 250, height: 150).scaleEffect(zoom).position(point)
                                        .gesture(DragGesture(minimumDistance: 4).onChanged { drag[node.id] = $0.translation }.onEnded {
                                            let target = CanvasPoint(x: node.point.x + $0.translation.width / zoom, y: node.point.y + $0.translation.height / zoom)
                                            drag[node.id] = nil; Task { await model.move(node, to: target) }
                                        })
                                }
                            }
                        }
                    }.clipped().gesture(MagnificationGesture().onChanged { zoom = min(2, max(0.25, zoomStart * $0)) }.onEnded { _ in zoomStart = zoom })
                }.accessibilityElement(children: .contain).accessibilityIdentifier("knowledge.canvas")
                if !board.edges.isEmpty {
                    ScrollView(.horizontal) { HStack { ForEach(board.edges) { edge in Button { Task { _ = await model.perform(.disconnect(board: board.id, edge: edge.id)) } } label: { Label(edge.label, systemImage: "xmark.circle") }.accessibilityLabel(Text("Remove connection") + Text(": " + edge.label)) } }.padding(8) }.frame(height: 42)
                }
            } else { ContentUnavailableView("No boards", systemImage: "square.grid.2x2", description: Text("Add saved cards to a board, then select two to connect them.")) }
        }
        .onChange(of: model.boardID) { model.selectedNodes = []; pan = .init(width: 40, height: 50); panStart = pan }
        .onChange(of: query) { model.selectedNodes = [] }
    }
    private func revealFirstMatch() {
        guard !query.isEmpty, let board = model.board else { return }
        let cards = Dictionary(model.memory.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let node = board.nodes.first(where: { node in
            guard let card = cards[node.id] else { return false }
            return KnowledgeSearchIndex.matches(query, card.title + " " + card.text + " " + node.cluster)
        }) {
            pan = .init(width: 40 - node.point.x * zoom, height: 50 - node.point.y * zoom); panStart = pan
        }
    }
    private func canvasCard(_ card: KnowledgeCard, node: CanvasNode) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button { if model.selectedNodes.contains(card.id) { model.selectedNodes.remove(card.id) } else { model.selectedNodes.insert(card.id) } } label: { Label(card.kind.label, systemImage: model.selectedNodes.contains(card.id) ? "checkmark.circle.fill" : card.kind.symbol).font(.caption) }.buttonStyle(.plain).accessibilityIdentifier("knowledge.node.select").accessibilityValue(Text(LocalizedStringKey(model.selectedNodes.contains(card.id) ? "Selected" : "Not selected")))
                Spacer()
            }
            Text(card.title).font(.headline).lineLimit(2)
            Text(card.text).font(.caption).foregroundStyle(Adaptive.secondary).lineLimit(2)
            HStack { Text(node.cluster).font(.caption2).foregroundStyle(.tint); Spacer(); Button("Source") { if let source = card.sources.first { Task { await model.open(source) } } }.font(.caption).buttonStyle(.link) }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Adaptive.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selectedNodes.contains(card.id) ? Color.accentColor : Adaptive.divider, lineWidth: model.selectedNodes.contains(card.id) ? 2 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 40.0 : -40.0
            Task { await model.move(node, to: .init(x: node.point.x + delta, y: node.point.y)) }
        }
        .contextMenu {
            Button("Edit") { model.draft = card }
            Button("Move left") { Task { await model.move(node, to: .init(x: node.point.x - 40, y: node.point.y)) } }
            Button("Move right") { Task { await model.move(node, to: .init(x: node.point.x + 40, y: node.point.y)) } }
            Button("Move up") { Task { await model.move(node, to: .init(x: node.point.x, y: node.point.y - 40)) } }
            Button("Move down") { Task { await model.move(node, to: .init(x: node.point.x, y: node.point.y + 40)) } }
        }
    }
}

private struct KnowledgeComparison: View {
    @Bindable var model: KnowledgeModel
    @State private var relation = ""
    private var sources: [KnowledgeSearchHit] { Array(model.hits.filter { model.selectedHits.contains($0.id) && $0.kind == .quotation }.prefix(8)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Compare selected").font(.title2)
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .topLeading)], alignment: .leading, spacing: 16) {
                ForEach(sources) { hit in VStack(alignment: .leading, spacing: 8) {
                    Label("Author quotation", systemImage: "quote.opening").font(.caption).foregroundStyle(Adaptive.secondary)
                    Text(hit.source.bookTitle).font(.headline)
                    Text(hit.source.quotation).textSelection(.enabled)
                    Text(hit.source.location).font(.caption).foregroundStyle(Adaptive.secondary)
                    Button("Verify source") { model.comparisonVisible = false; Task { await model.open(hit.source) } }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Adaptive.surface, in: RoundedRectangle(cornerRadius: 12)) }
            } }
            TextField("Your connection between these excerpts", text: $relation, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4).accessibilityIdentifier("knowledge.relation.text")
            HStack {
                Button("Back") { model.comparisonVisible = false }.keyboardShortcut(.cancelAction)
                Button("Ask AI to compare") { model.comparisonVisible = false; model.ask(compare: true) }.disabled(model.settings.mode == .off)
                Spacer()
                Button("Save connection") { Task {
                    let card = KnowledgeCard(title: String(model.query.prefix(120)), kind: .readerNote, text: relation, sources: sources.map(\.source))
                    if await model.perform(.saveCard(card)) { model.comparisonVisible = false; model.tab = "memory" }
                } }.disabled(relation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("knowledge.relation.save")
            }
        }.padding(24).frame(width: 680, height: 510).accessibilityElement(children: .contain).accessibilityIdentifier("knowledge.comparison")
    }
}
