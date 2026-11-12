import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

struct StudyTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json] }
    var text: String
    init(_ text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

struct StudyView: View {
    let session: ReaderSession
    @Bindable var model: StudyModel
    @State private var exporting = false
    @State private var importing = false
    @State private var exportType = UTType.plainText
    @State private var exportName = "Study.md"
    @State private var exportDocument = StudyTextDocument("")
    @FocusState private var editorReturn: String?
    @State private var filterColor: HighlightColor?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Study").font(.headline)
                Spacer()
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Export Markdown") {
                        do { exportDocument = StudyTextDocument(try model.markdown()); exportType = UTType(filenameExtension: "md") ?? .plainText; exportName = session.title + "-Study.md"; exporting = true }
                        catch { model.errorMessage = error.localizedDescription }
                    }.accessibilityIdentifier("study.export")
                    Button("Export cards (JSON)") {
                        do { exportDocument = StudyTextDocument(String(decoding: try model.cardArchive(), as: UTF8.self)); exportType = .json; exportName = session.title + "-Cards.json"; exporting = true }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                    Button("Import cards (JSON)") { importing = true }
                }.menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("study.actions")
                Button("Close Study", systemImage: "xmark") { model.visible = false }.labelStyle(.iconOnly).accessibilityIdentifier("study.close")
            }.padding(16)
            Picker("Study section", selection: $model.tab) {
                Text("Notes").tag("notes"); Text("Cards").tag("cards"); Text("Recall").tag("recall"); Text("Highlights").tag("highlights"); Text("Listen").tag("listen")
            }.pickerStyle(.menu).padding(.horizontal, 16).padding(.bottom, 12).accessibilityIdentifier("study.section")
            Divider()
            Group {
                switch model.tab {
                case "cards": cards
                case "recall": recall
                case "highlights": highlights
                case "listen": listen
                default: notes
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.deleted != nil {
                Divider()
                Button("Undo deletion") { Task { await model.undoDeletion() } }.padding(12).accessibilityIdentifier("study.undo")
            }
            if let error = model.errorMessage ?? (model.tab == "listen" ? model.speech.errorMessage : nil) {
                Divider()
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled).padding(16).accessibilityIdentifier("study.error")
            }
        }
        .background(Adaptive.background)
        .accessibilityElement(children: .contain).accessibilityIdentifier("study.panel")
        .task { await model.reload() }
        .onExitCommand { model.visible = false }
        .onChange(of: model.tab) { if model.tab == "recall" { model.beginRecall() } }
        .sheet(item: $model.draftCard, onDismiss: { editorReturn = "card" }) { card in CardEditor(model: model, initial: card) }
        .sheet(item: $model.draftNote, onDismiss: { editorReturn = "note" }) { note in NoteEditor(model: model, initial: note) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result { case .success(let url): Task { await model.importCards(url) }; case .failure(let error): model.errorMessage = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: exportName) { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
    }
    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("New note", systemImage: "square.and.pencil") { _ = session.performReadingCommand(.newNote) }.disabled(!WorkspaceCommand.newNote.isEnabled(in: session)).focusable().focused($editorReturn, equals: "note").accessibilityIdentifier("study.newNote")
            if model.notes.isEmpty { Text("Your notes stay with their source.").foregroundStyle(Adaptive.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.notes) { note in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(note.text).textSelection(.enabled).accessibilityIdentifier("study.note.text")
                            Text(note.quotation).font(.caption).foregroundStyle(Adaptive.secondary).lineLimit(3)
                            HStack {
                                Button("Source") { model.go(to: note.anchor) }.accessibilityIdentifier("study.note.source")
                                Button("Edit") { model.draftNote = note }.accessibilityIdentifier("study.note.edit")
                                Spacer()
                                Button("Delete note", systemImage: "trash") { Task { await model.deleteNote(note) } }.labelStyle(.iconOnly)
                            }.buttonStyle(.borderless)
                            Divider()
                        }
                    }
                }
            }
        }.padding(16)
    }
    private var cards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("New card", systemImage: "rectangle.stack.badge.plus") { _ = session.performReadingCommand(.newCard) }.disabled(!WorkspaceCommand.newCard.isEnabled(in: session)).focusable().focused($editorReturn, equals: "card").accessibilityIdentifier("study.newCard")
            Toggle("Show archived", isOn: $model.showArchived)
            if let summary = model.importSummary { Text(summary).font(.caption).foregroundStyle(Adaptive.secondary) }
            if model.cards.isEmpty { Text("Write a question and answer in your own words.").foregroundStyle(Adaptive.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.cards.filter { model.showArchived || !$0.archived }) { card in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(card.question).font(.headline).textSelection(.enabled).accessibilityIdentifier("study.card.question")
                            Text(card.answer).lineLimit(4).textSelection(.enabled).accessibilityIdentifier("study.card.answer")
                            Group {
                                if card.archived { Text("Archived") }
                                else { Text("Next review: \(card.dueAt.formatted(date: .abbreviated, time: .omitted))") }
                            }.font(.caption).foregroundStyle(Adaptive.secondary)
                            HStack {
                                Button("Source") { model.go(to: card.anchor) }.accessibilityIdentifier("study.card.source")
                                Button("Edit") { model.draftCard = card }.accessibilityIdentifier("study.card.edit")
                                Menu("More") {
                                    Button(LocalizedStringKey(card.archived ? "Unarchive" : "Archive")) { var value = card; value.archived.toggle(); Task { await model.saveCard(value) } }
                                    Button("Delete card", role: .destructive) { Task { await model.deleteCard(card) } }
                                }
                            }.buttonStyle(.borderless)
                            Divider()
                        }
                    }
                }
            }
        }.padding(16)
    }
    private var recall: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Recall").font(.title2)
                Text("Take a moment to answer before revealing the card. You can stop whenever you like.").foregroundStyle(Adaptive.secondary)
                if let card = model.recallCard {
                    Text(card.question).font(.title3).textSelection(.enabled).accessibilityIdentifier("recall.question")
                    if model.revealAnswer {
                        Divider(); Text(card.answer).textSelection(.enabled).accessibilityIdentifier("recall.answer")
                        HStack {
                            Button("Again") { Task { await model.review(remembered: false) } }.accessibilityIdentifier("recall.again")
                            Button("Remembered") { Task { await model.review(remembered: true) } }.accessibilityIdentifier("recall.remembered")
                        }.disabled(model.busy)
                    } else {
                        Button("Reveal answer") { model.revealAnswer = true }.accessibilityIdentifier("recall.reveal")
                    }
                    Button("Source") { model.go(to: card.anchor) }
                } else {
                    Text("No cards due. Read at your own pace.").foregroundStyle(Adaptive.secondary).accessibilityIdentifier("recall.empty")
                    Button("New card") { model.newCard() }.disabled(!model.available)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }
    private var highlights: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Highlight color", selection: $model.highlightColor) { ForEach(HighlightColor.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue.capitalized)).tag($0) } }
            Button("Highlight passage", systemImage: "highlighter") { _ = session.performReadingCommand(.highlightPassage) }.disabled(!WorkspaceCommand.highlightPassage.isEnabled(in: session)).accessibilityIdentifier("study.highlight")
            Picker("Filter colors", selection: $filterColor) {
                Text("All colors").tag(nil as HighlightColor?)
                ForEach(HighlightColor.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue.capitalized)).tag(Optional($0)) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.highlights.filter { filterColor == nil || $0.color == filterColor }) { highlight in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(highlight.displayQuotation ?? highlight.quotation).textSelection(.enabled).accessibilityIdentifier("study.highlight.text")
                            HStack {
                                Button("Source") { model.go(to: highlight.anchor) }.accessibilityIdentifier("study.highlight.source")
                                Menu(LocalizedStringKey(highlight.color.rawValue.capitalized)) {
                                    ForEach(HighlightColor.allCases, id: \.self) { color in Button(LocalizedStringKey(color.rawValue.capitalized)) { Task { await model.changeHighlight(highlight, color: color) } } }
                                }
                                Spacer()
                                Button("Delete highlight", systemImage: "trash") { Task { await model.deleteHighlight(highlight) } }.labelStyle(.iconOnly)
                            }.buttonStyle(.borderless)
                            Divider()
                        }
                    }
                }
            }
        }.padding(16)
    }
    private var listen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Listen & Read").font(.title2)
                Text("On-device macOS speech. No book text is sent to an AI service.").font(.callout).foregroundStyle(Adaptive.secondary)
                if session.pdfEngine != nil { Text("PDF text order follows the document and may differ in complex layouts.").font(.caption).foregroundStyle(Adaptive.secondary) }
                Picker("Voice", selection: Binding(get: { model.speech.voiceIdentifier }, set: { model.speech.voiceIdentifier = $0 })) {
                    Text("Automatic").tag("")
                    ForEach(model.speech.voices) { voice in Text("\(voice.name) · \(voice.language)").tag(voice.id) }
                }.disabled(model.speech.status != .stopped).accessibilityIdentifier("listen.voice")
                Text("Speed \(model.speech.rate, specifier: "%.1f")×")
                Slider(value: Binding(get: { model.speech.rate }, set: { model.speech.rate = $0 }), in: 0.5...2, step: 0.1).accessibilityLabel("Speech speed").accessibilityIdentifier("listen.rate")
                Text("Speed changes apply to the next passage.").font(.caption).foregroundStyle(Adaptive.secondary)
                Toggle("Follow text", isOn: $model.followSpeech)
                HStack {
                    switch model.speech.status {
                    case .stopped:
                        Button("Listen from here", systemImage: "play.fill") { _ = session.performReadingCommand(.listenFromHere) }.accessibilityIdentifier("listen.start")
                    case .playing:
                        Button("Pause", systemImage: "pause.fill") { _ = session.performReadingCommand(.toggleListening) }.accessibilityIdentifier("listen.pause")
                    case .paused:
                        Button("Continue", systemImage: "play.fill") { _ = session.performReadingCommand(.toggleListening) }.accessibilityIdentifier("listen.continue")
                    }
                    Button("Stop", systemImage: "stop.fill") { _ = session.performReadingCommand(.stopListening) }.disabled(model.speech.status == .stopped).accessibilityIdentifier("listen.stop")
                }.disabled(session.engine?.capabilities.contains(.readAloud) != true)
                if model.savedListen != nil && model.savedListen?.completed != true && model.speech.status == .stopped {
                    Button("Resume saved listening") { _ = session.performReadingCommand(.resumeListening) }.accessibilityIdentifier("listen.saved")
                }
                Text(LocalizedStringKey(model.speech.status == .playing ? "Speaking" : model.speech.status == .paused ? "Paused" : "Stopped")).font(.caption).accessibilityIdentifier("listen.status")
                if !model.speech.spokenText.isEmpty { Text(model.speech.spokenText).font(.callout).accessibilityLabel("Current spoken word").accessibilityIdentifier("listen.word") }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.task { await model.speech.loadVoices() }
    }
}

private struct CardEditor: View {
    let model: StudyModel
    @State private var value: StudyCard
    init(model: StudyModel, initial: StudyCard) { self.model = model; _value = State(initialValue: initial) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Card").font(.title2)
            Text(value.quotation).lineLimit(3).foregroundStyle(Adaptive.secondary).font(.callout)
            Text("Question").font(.headline)
            TextField("Question", text: $value.question, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4).accessibilityIdentifier("card.question")
            Text("Answer").font(.headline)
            TextEditor(text: $value.answer).font(.body).frame(minHeight: 140).border(Adaptive.divider).accessibilityLabel("Answer").accessibilityIdentifier("card.answer")
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { model.draftCard = nil }.keyboardShortcut(.cancelAction).accessibilityIdentifier("card.cancel")
                Spacer()
                Button("Save card") { Task { await model.saveCard(value) } }.keyboardShortcut(.defaultAction)
                    .disabled(model.busy || value.question.count > 2000 || value.answer.count > 8000 || value.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("card.save")
            }
        }.padding(24).frame(width: 460, height: 440)
    }
}

private struct NoteEditor: View {
    let model: StudyModel
    @State private var value: ReaderNote
    init(model: StudyModel, initial: ReaderNote) { self.model = model; _value = State(initialValue: initial) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Note").font(.title2)
            Text(value.quotation).lineLimit(4).foregroundStyle(Adaptive.secondary)
            TextEditor(text: $value.text).font(.body).frame(minHeight: 180).border(Adaptive.divider).accessibilityLabel("Note text").accessibilityIdentifier("study.note.editor")
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { model.draftNote = nil }.keyboardShortcut(.cancelAction).accessibilityIdentifier("study.note.cancel")
                Spacer()
                Button("Save note") { Task { await model.saveNote(value) } }.keyboardShortcut(.defaultAction)
                    .disabled(model.busy || value.text.count > 8000 || value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("study.note.save")
            }
        }.padding(24).frame(width: 460, height: 380)
    }
}
