import SwiftUI
import ReaderCore
import PDFKit

struct ExtendedReadingView: View {
    @Bindable var model: ExtendedReadingModel
    let session: ReaderSession
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Extended reading").font(.title2.bold())
                Spacer()
                Button("Done") { model.visible = false }.keyboardShortcut(.cancelAction).accessibilityIdentifier("extended.done")
            }.padding(20)
            Picker("Tools", selection: $model.tab) {
                Text("Split").tag("split"); Text("Bilingual").tag("bilingual"); Text("OCR").tag("ocr")
                Text("Replay").tag("replay"); Text("Insights").tag("insights")
            }.pickerStyle(.segmented).padding(.horizontal, 20).accessibilityIdentifier("extended.tabs")
            if let error = model.errorMessage {
                HStack { Image(systemName: "exclamationmark.triangle"); Text(error); Button("Dismiss") { model.errorMessage = nil } }
                    .foregroundStyle(.secondary).padding().accessibilityIdentifier("extended.error")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.tab {
                    case "split": split
                    case "bilingual": bilingual
                    case "ocr": ocr
                    case "replay": replay
                    default: insights
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("extended.content").id(model.tab)
        }.background(.background).accessibilityElement(children: .contain).accessibilityIdentifier("extended.workspace")
            .task { await model.reload() }
    }
    private var split: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Two independent readers").font(.headline)
            Text("Open another book or a second position in this book. Each pane has its own scroll, palette and navigation. Application menus control the primary pane.").foregroundStyle(.secondary)
            if session.engine == nil { Text("Open a book first.") }
            ForEach(model.books) { book in
                Button { model.startSplit(book) } label: {
                    HStack { Image(systemName: book.format == .pdf ? "doc" : "book"); Text(book.title); Spacer(); Image(systemName: "rectangle.split.2x1") }
                }.disabled(session.engine == nil || model.busy).accessibilityIdentifier("split.open." + book.id.uuidString)
            }
            if model.busy { ProgressView("Opening second pane") }
            if model.secondary != nil { Button("Close second pane") { model.closeSplit() }.accessibilityIdentifier("split.close") }
        }
    }
    private var bilingual: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Text("Aligned fragments").font(.headline)
            Text("Capture a source fragment and add your translation and context explanation. Alignment belongs to this fragment; arbitrary editions are not automatically aligned. No model is contacted.").foregroundStyle(.secondary)
            Button("Capture current passage") { model.capture() }.disabled(session.engine == nil).accessibilityIdentifier("bilingual.capture")
            if let source = model.capturedSource {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading) { Text("Original").font(.caption); Text(source.quotation).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading) {
                        TextField("Translation language", text: $model.language)
                        TextField("Your translation", text: $model.translation, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("bilingual.translation")
                        TextField("Idiom or context explanation", text: $model.explanation, axis: .vertical).lineLimit(2...4)
                    }.frame(maxWidth: .infinity)
                }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Button("Save aligned fragment") { Task { await model.saveTranslation() } }.disabled(model.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("bilingual.save")
                Button("Explain in AI Companion") { model.explain(source) }.accessibilityIdentifier("bilingual.explain")
                Text("AI uses your configured provider only after you press Ask. Review the answer before saving your translation.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.snapshot.fragments.filter { $0.source.anchor.bookID == session.record?.id }) { fragment in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(fragment.source.bookTitle).font(.caption); Spacer(); (Text(fragment.language + " · ") + Text("Reader translation")).font(.caption).foregroundStyle(.secondary) }
                    HStack(alignment: .top, spacing: 20) {
                        Text(fragment.source.quotation).frame(maxWidth: .infinity, alignment: .leading)
                        Text(fragment.translation).frame(maxWidth: .infinity, alignment: .leading)
                    }.textSelection(.enabled)
                    if !fragment.explanation.isEmpty { Text(fragment.explanation).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack {
                        Button("Show original") { model.reveal(fragment.source.anchor) }.buttonStyle(.link)
                        Button("Save a word from this fragment") { model.selectedFragment = fragment.id }
                    }
                    if model.selectedFragment == fragment.id {
                        HStack { TextField("Word or idiom", text: $model.word).accessibilityIdentifier("bilingual.word"); TextField("Meaning in this context", text: $model.meaning); Button("Save word") { Task { await model.saveWord() } }.disabled(model.word.isEmpty || model.meaning.isEmpty) }
                    }
                    ForEach(model.snapshot.vocabulary.filter { $0.fragmentID == fragment.id }) { word in Text(word.word + " — " + word.meaning).font(.callout) }
                }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private var ocr: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recognize this PDF page").font(.headline)
            Text("Local Vision OCR. One page at a time, with no upload or change to the PDF. Tables, formulas and reading order may need review; confidence is a model score, not a guarantee.").foregroundStyle(.secondary)
            HStack {
                Button("Recognize current page") { model.recognizePage() }.disabled(session.pdfEngine == nil || model.ocrRunning).accessibilityIdentifier("ocr.start")
                if model.ocrRunning { ProgressView().controlSize(.small); Button("Cancel recognition") { model.cancelOCR() }.accessibilityIdentifier("ocr.cancel") }
            }
            if let page = model.ocrPage {
                Text("Page \(page.pageIndex + 1) · \(page.lines.count) recognized lines").font(.caption).accessibilityIdentifier("ocr.result")
                TextField("Find in recognized text", text: $model.ocrQuery).textFieldStyle(.roundedBorder).accessibilityIdentifier("ocr.search")
                if page.lines.isEmpty { Text("No text found. Try a clearer scan or use Original.") }
                ForEach(page.lines.filter { model.ocrQuery.isEmpty || $0.text.localizedCaseInsensitiveContains(model.ocrQuery) }) { line in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.text).textSelection(.enabled)
                            if line.needsReview { Label("Check recognition · \(Int(line.confidence * 100))%", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button("Show scan") { model.reveal(line.anchor) }.buttonStyle(.link).accessibilityIdentifier("ocr.source")
                    }.padding(.vertical, 6)
                }
            }
        }
    }
    private var replay: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Toggle("Record Reading Replay", isOn: Binding(get: { model.snapshot.replayEnabled }, set: { enabled in Task { await model.perform(.setTracking(replay: enabled, insights: model.snapshot.insightsEnabled)) } })).accessibilityIdentifier("replay.enabled")
            Text("Only Adaptive reading actions are stored locally: source locations, notes and question events. No screen recording, question text or activity outside Adaptive. Disabling stops new records; clearing removes saved events.").foregroundStyle(.secondary)
            Button("Clear Replay") { Task { await model.perform(.clearReplay) } }.accessibilityIdentifier("replay.clear")
            Text("\(model.snapshot.events.count) events").accessibilityIdentifier("replay.count")
            ForEach(model.snapshot.events.reversed()) { event in
                HStack { Text(LocalizedStringKey(event.kind.rawValue)); Text(event.date, style: .time).foregroundStyle(.secondary); Spacer(); Button("Return to fragment") { model.reveal(event.anchor) }.buttonStyle(.link) }
            }
        }
    }
    private var insights: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Toggle("Track Reading Insights", isOn: Binding(get: { model.snapshot.insightsEnabled }, set: { enabled in Task { await model.perform(.setTracking(replay: model.snapshot.replayEnabled, insights: enabled)) } })).accessibilityIdentifier("insights.enabled")
            Text("Time counts only while this reading window is visible and active, for up to 60 seconds after interaction. Time is an estimate, not a measure of comprehension. Chapter completion is marked by you. Data stays on this Mac.").foregroundStyle(.secondary)
            HStack {
                Button("Mark chapter or page completed") { model.record(.chapterCompleted, anchor: model.activeAnchor) }.disabled(session.engine == nil || !model.snapshot.insightsEnabled).accessibilityIdentifier("insights.complete")
                Button("Clear Insights") { Task { await model.perform(.clearInsights) } }.accessibilityIdentifier("insights.clear")
            }
            ForEach(model.snapshot.metrics) { metric in
                HStack {
                    Text(model.books.first { $0.id == metric.bookID }?.title ?? NSLocalizedString("Unavailable book", comment: "Unavailable metric source")).font(.headline)
                    Spacer()
                    Text("\(Int(metric.activeSeconds / 60)) min · \(metric.notes) notes · \(metric.completedChapters.count) completed")
                }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct SplitReadingView<Primary: View>: View {
    @Bindable var model: ExtendedReadingModel
    let session: ReaderSession
    @ViewBuilder let primary: () -> Primary
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header(session.title, primary: true)
                primary()
            }.frame(minWidth: 280).overlay(alignment: .top) { if model.activePane == "primary" { Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false) } }
            if let pane = model.secondary {
                VStack(spacing: 0) {
                    header(pane.record.title, primary: false)
                    HStack {
                        Button("Next page or chapter", systemImage: "arrow.right") { model.activePane = "secondary"; pane.nextSection() }.labelStyle(.iconOnly).disabled(!pane.canStepSection(1)).accessibilityIdentifier("split.next")
                        Picker("Second pane palette", selection: Binding(get: { pane.engine.palette }, set: { pane.perform(.setPalette($0)) })) { ForEach(PagePalette.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue.capitalized)).tag($0) } }.labelsHidden()
                        Menu("Second pane tools", systemImage: "ellipsis.circle") {
                            Button("Previous page or chapter") { model.activePane = "secondary"; pane.stepSection(-1) }.disabled(!pane.canStepSection(-1))
                            Button("Back") { model.activePane = "secondary"; pane.perform(.back) }.disabled(!pane.commands.canGoBack)
                            Button("Previous text block") { model.activePane = "secondary"; pane.perform(.advancePassage(-1)) }.disabled(!pane.engine.capabilities.contains(.passageNavigation))
                            Button("Next text block") { model.activePane = "secondary"; pane.perform(.advancePassage(1)) }.disabled(!pane.engine.capabilities.contains(.passageNavigation))
                        }.menuStyle(.borderlessButton).labelStyle(.iconOnly).fixedSize().accessibilityIdentifier("split.more")
                        Spacer()
                        Button("Swap panes", systemImage: "arrow.left.arrow.right") { model.swap() }.labelStyle(.iconOnly).accessibilityIdentifier("split.swap")
                        Button("Close second pane", systemImage: "xmark") { model.closeSplit() }.labelStyle(.iconOnly).accessibilityIdentifier("split.close")
                    }.padding(8).controlSize(.small)
                    if let error = pane.errorMessage { Text(error).foregroundStyle(.secondary).padding() }
                    SplitNativeView(pane: pane).id(pane.id)
                }.frame(minWidth: 280).overlay(alignment: .top) { if model.activePane == "secondary" { Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false) } }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("split.readers")
    }
    private func header(_ title: String, primary: Bool) -> some View {
        HStack {
            Button { model.activePane = primary ? "primary" : "secondary"; model.interaction() } label: {
                Label(title, systemImage: model.activePane == (primary ? "primary" : "secondary") ? "circle.inset.filled" : "circle").lineLimit(1)
            }.buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(primary ? "Primary pane" : "Secondary pane")) + Text(": " + title))
                .accessibilityValue(Text(LocalizedStringKey(model.activePane == (primary ? "primary" : "secondary") ? "Active" : "Inactive")))
                .accessibilityIdentifier(primary ? "split.primary" : "split.secondary")
            Spacer()
            Text("\(primary ? session.pageNumber : model.secondary?.section ?? 1)").monospacedDigit().accessibilityIdentifier(primary ? "split.primary.section" : "split.secondary.section")
            if primary && model.secondary?.record.id == session.record?.id {
                Toggle("Sync positions", isOn: $model.syncPositions).toggleStyle(.checkbox).accessibilityIdentifier("split.sync")
            }
        }.font(.caption).padding(10).background(.bar)
    }
}
private struct SplitNativeView: NSViewRepresentable {
    let pane: SplitPane
    func makeNSView(context: Context) -> NSView {
        if let pdf = pane.engine as? PDFReaderEngine {
            pdf.view.setAccessibilityIdentifier("reader.secondary.pdf")
            return PDFSurfaceHost(pdf: pdf.view) { [weak pane] in pane?.mount() }
        }
        if let epub = pane.engine as? EPUBReaderEngine {
            epub.view.setAccessibilityIdentifier("reader.secondary.epub")
            Task { @MainActor in pane.mount() }; return epub.view
        }
        return NSView()
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
