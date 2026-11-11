import SwiftUI
import ReaderCore

struct CompanionView: View {
    @Bindable var session: ReaderSession
    private var model: CompanionModel { session.companion }
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Label("AI Companion", systemImage: "sparkle").font(.headline)
                Spacer()
                Button("New topic", systemImage: "plus.bubble") { model.newTopic() }.labelStyle(.iconOnly).accessibilityIdentifier("ai.newTopic")
                Button("AI settings", systemImage: "gearshape") { model.settingsVisible = true }.labelStyle(.iconOnly).accessibilityIdentifier("ai.settings")
                Button("Close", systemImage: "xmark") { model.cancel(); session.companionVisible = false }.labelStyle(.iconOnly).accessibilityIdentifier("ai.close")
            }.buttonStyle(.borderless).padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.fixtureMode { Label("Test provider · no model request", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary) }
                    if model.settings.mode == .off && !model.fixtureMode {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Ask about this book").font(.title3.weight(.medium))
                            Text("Connect a local model or explicitly enable a cloud provider. Reading works without AI.").foregroundStyle(.secondary)
                            Button("Configure AI") { model.settingsVisible = true }
                        }.padding(.vertical, 12)
                    }
                    if let selected = model.selection {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Selected source").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Text(String(selected.text.prefix(240))).font(.callout).lineLimit(5)
                            Text("Selection context uses an excerpt from the first selected page.").font(.caption).foregroundStyle(.secondary)
                            Button("Use book context instead") { model.selection = nil }
                        }.padding(12).background(Adaptive.background, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if model.busy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(model.indexing ? "Preparing local text index" : "Receiving answer")
                            Spacer(); Button("Cancel") { model.cancel() }.accessibilityIdentifier("ai.cancel")
                        }
                        if model.indexing { ProgressView(value: model.progress) }
                    }
                    if let message = model.errorMessage { Text(NSLocalizedString(message, comment: "Companion error")).foregroundStyle(.secondary).accessibilityIdentifier("ai.error") }
                    if model.indexTruncated { Text("Index limit reached. Search covers the indexed portion.").font(.caption).foregroundStyle(.secondary) }
                    if let answer = model.answer {
                        Text(LocalizedStringKey(answer.kind == .book ? "From the book" : (answer.kind == .general ? "General model knowledge" : "Insufficient evidence")))
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text(answer.answer).textSelection(.enabled).accessibilityIdentifier("ai.answer")
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(answer.sourceIDs, id: \.self) { id in
                                if let source = model.evidence.first(where: { $0.id == id }) {
                                    Button { session.goToCompanionSource(source) } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Label(sourceLabel(source), systemImage: "text.book.closed")
                                            Text(String(source.text.prefix(180))).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    }.buttonStyle(.bordered).accessibilityIdentifier("ai.citation")
                                }
                            }
                        }
                        Menu("Explain Again") {
                            ForEach(["Simpler", "More detail", "With an example", "With an analogy", "Step by step", "As a text diagram"], id: \.self) { style in
                                Button(LocalizedStringKey(style)) { model.ask(page: session.pageNumber, question: model.query, refinement: style, chapter: session.companionChapterLabel) }
                            }
                        }.accessibilityIdentifier("ai.explainAgain")
                        if !answer.actions.isEmpty {
                            Text("Suggested actions · review before applying").font(.caption).foregroundStyle(.secondary)
                            ForEach(answer.actions) { action in
                                Button(actionLabel(action)) { session.applyCompanionAction(action) }.accessibilityIdentifier("ai.action.\(action.kind.rawValue)")
                            }
                            if session.commands?.canUndoPalette == true { Button("Undo palette") { session.undoPalette() } }
                        }
                    }
                    if model.draftSource != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Review note").font(.headline)
                            TextEditor(text: $model.draftNote).frame(minHeight: 80).accessibilityIdentifier("ai.noteDraft")
                            HStack {
                                Button("Save note") { Task { await model.saveNote() } }.disabled(model.draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canSaveNotes).accessibilityIdentifier("ai.saveNote")
                                Button("Cancel note") { model.draftSource = nil; model.draftNote = "" }
                            }
                        }
                    }
                    if model.undoNote != nil { Button("Undo saved note") { Task { await model.undoSavedNote() } }.accessibilityIdentifier("ai.undoNote") }
                    if !model.notes.isEmpty {
                        Divider(); Text("Reader notes").font(.headline)
                        ForEach(model.notes) { note in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(note.text).textSelection(.enabled)
                                Button("Open note source") { session.navigate(to: note.anchor) }
                            }.padding(.vertical, 6)
                        }
                    }
                    Toggle("Smart Margins", isOn: $model.smartMargins).accessibilityIdentifier("ai.margins")
                    Text("Source hints appear only when enabled; Focus hides them.").font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                TextField("Question about the book", text: $model.query, axis: .vertical).lineLimit(2...5)
                    .textFieldStyle(.plain).accessibilityIdentifier("ai.query")
                    .onSubmit { model.ask(page: session.pageNumber, chapter: session.companionChapterLabel) }
                HStack {
                    Text(model.settings.mode == .cloud ? "Cloud · selected excerpts will be sent" : "Local context · on this Mac").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Ask", systemImage: "arrow.up") { model.ask(page: session.pageNumber, chapter: session.companionChapterLabel) }
                        .disabled(model.busy || model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("ai.ask")
                }
            }.padding(16)
        }.background(Adaptive.surface).accessibilityElement(children: .contain).accessibilityIdentifier("ai.companion")
            .sheet(isPresented: $model.settingsVisible) { CompanionSettingsView(model: model) }
            .onAppear {
                #if DEBUG || FOUNDATION_BENCHMARK
                if model.fixtureMode && ProcessInfo.processInfo.arguments.contains("-companionReview") && !model.reviewStarted {
                    model.reviewStarted = true; model.query = "Explain this source"; model.ask(page: session.pageNumber, chapter: session.companionChapterLabel)
                }
                #endif
            }
    }
    private func sourceLabel(_ source: EvidencePassage) -> String {
        if case .pdf(let point) = source.anchor.position { return String(localized: "Page \(point.pageIndex + 1)") }
        return String(localized: "Source")
    }
    private func actionLabel(_ action: CompanionAction) -> String {
        switch action.kind {
        case .goToPage: String(localized: "Go to page \(action.page ?? 1)")
        case .navigateToPassage: String(localized: "Open source")
        case .setTheme: String(localized: "Apply palette") + ": " + NSLocalizedString((action.palette ?? .original).rawValue.capitalized, comment: "Palette")
        case .setFocus: String(localized: "Focus") + (action.enabled == true ? " ✓" : " —")
        case .setKeepAwake: String(localized: "Keep Awake") + (action.enabled == true ? " ✓" : " —")
        case .createBookmark: String(localized: "Bookmark page")
        case .createNote: String(localized: "Review suggested note")
        }
    }
}

private struct CompanionSettingsView: View {
    @Bindable var model: CompanionModel
    @State private var draft = CompanionSettings()
    @State private var key = ""
    @State private var cloudConsent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI settings").font(.title2.weight(.semibold))
            Picker("Provider mode", selection: $draft.mode) {
                Text("Off").tag(CompanionMode.off); Text("Local Ollama").tag(CompanionMode.local); Text("Cloud API").tag(CompanionMode.cloud)
            }.pickerStyle(.menu).accessibilityLabel(Text("Provider mode")).accessibilityIdentifier("ai.providerMode")
            TextField("Endpoint URL", text: $draft.endpoint).textFieldStyle(.roundedBorder).accessibilityIdentifier("ai.endpoint")
            TextField("Model identifier", text: $draft.model).textFieldStyle(.roundedBorder).accessibilityIdentifier("ai.model")
            if draft.mode == .cloud {
                SecureField("API key · stored in Keychain", text: $key).textFieldStyle(.roundedBorder)
                Text("When you ask, the question, book title, visible page and up to eight retrieved or selected excerpts are sent to this endpoint. The provider may retain them under its own policy. The whole book is not uploaded.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Allow sending these excerpts to this endpoint and model", isOn: $cloudConsent).accessibilityIdentifier("ai.cloudConsent")
                Button("Remove saved API key") {
                    Task { do { try await CompanionKeyVault.shared.remove(draft.destination) } catch { model.errorMessage = error.localizedDescription } }
                }
            } else if draft.mode == .local { Text("Local mode accepts only localhost. Install and choose your own Ollama model.").font(.callout).foregroundStyle(.secondary) }
            Button("Clear this book's AI index") { Task { await model.clearIndex() } }
            if let message = model.errorMessage { Text(NSLocalizedString(message, comment: "Companion error")).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { model.settingsVisible = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    draft.consentDestination = draft.mode == .cloud && cloudConsent ? draft.destination : nil
                    Task { await model.saveSettings(draft, key: key); key = "" }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 410)
            .onAppear { draft = model.settings; cloudConsent = draft.consentDestination == draft.destination }
            .onChange(of: draft.destination) { if draft.destination != model.settings.destination { cloudConsent = false } }
    }
}

struct MagicSelectionBar: View {
    @Bindable var session: ReaderSession
    var body: some View {
        if let selection = session.companion.selection {
            HStack(spacing: 12) {
                Image(systemName: "text.cursor").foregroundStyle(.secondary)
                Text("Selected text").font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                Button("Copy") {
                    let text = session.engine?.view.currentSelection?.string ?? selection.text
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                }.accessibilityIdentifier("ai.copySelection")
                Button("Explain") { session.askCompanion(String(localized: "Explain the selected source.")) }.accessibilityIdentifier("ai.explainSelection")
                Menu("More") {
                    Button("Translate") { session.askCompanion(String(localized: "Translate the selected source into my question language.")) }
                    Button("Find Sources") {
                        session.companion.selection = nil
                        session.askCompanion(String(localized: "Find related passages in this book for this excerpt:") + "\n" + selection.text)
                    }
                    Button("Question") { session.companion.newTopic(); session.askCompanion("") }
                    Button("Note") { session.companionVisible = true; session.companion.prepareNote(selection) }
                }
            }.buttonStyle(.borderless).padding(12).background(Adaptive.surface).accessibilityElement(children: .contain).accessibilityIdentifier("ai.magicSelection")
        }
    }
}

struct SmartMarginRail: View {
    @Bindable var session: ReaderSession
    @State private var expanded = false
    var body: some View {
        GeometryReader { geometry in
            if let answer = session.companion.answer, let id = answer.sourceIDs.first,
               let source = session.companion.evidence.first(where: { $0.id == id }),
               case .pdf(let point) = source.anchor.position,
               let engine = session.engine, let page = engine.document.page(at: point.pageIndex), point.pageIndex == session.pageNumber - 1 {
                let native = engine.view.convert(NSPoint(x: point.x, y: point.y), from: page)
                let y = engine.view.isFlipped ? native.y : engine.view.bounds.height - native.y
                Button { expanded.toggle() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Source hint", systemImage: "text.bubble").font(.caption.weight(.medium))
                        Text(String(answer.answer.prefix(72))).font(.caption).lineLimit(4)
                    }.padding(8)
                }.buttonStyle(.plain).frame(width: 126).position(x: 66, y: min(max(50, y), max(50, geometry.size.height - 60)))
                    .popover(isPresented: $expanded) { Text(answer.answer).padding(16).frame(width: 280) }
            }
        }.frame(width: 132).background(Adaptive.background).accessibilityElement(children: .contain).accessibilityIdentifier("ai.marginRail")
            .id(session.companionViewportRevision)
    }
}
