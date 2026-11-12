import Foundation
import Observation
import ReaderCore
import PDFKit

@MainActor @Observable
final class StudyModel {
    enum Deleted { case note(ReaderNote), card(StudyCard), highlight(ReaderHighlight) }
    var deleted: Deleted?
    var visible = false
    var tab = "notes"
    var notes: [ReaderNote] = []
    var cards: [StudyCard] = []
    var highlights: [ReaderHighlight] = []
    var savedListen: ListenPosition?
    var highlightColor = HighlightColor.yellow
    var showArchived = false
    var recallCard: StudyCard?
    var revealAnswer = false
    var draftCard: StudyCard?
    var draftNote: ReaderNote?
    var errorMessage: String?
    var busy = false
    var importSummary: String?
    var followSpeech = true
    let speech: SpeechPlayer = {
        #if DEBUG || FOUNDATION_BENCHMARK
        if ProcessInfo.processInfo.arguments.contains("-silentSpeechTest") { return SpeechPlayer(volume: 0) }
        #endif
        return SpeechPlayer()
    }()
    @ObservationIgnored private var store: LibraryStore?
    @ObservationIgnored private var record: BookRecord?
    @ObservationIgnored private weak var session: ReaderSession?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingListen: (BookRecord, ListenPosition)?
    var dueCards: [StudyCard] { cards.filter { !$0.archived && $0.dueAt <= Date() }.sorted { $0.dueAt < $1.dueAt } }
    var available: Bool { record != nil }

    func configure(record: BookRecord?, store: LibraryStore, session: ReaderSession) {
        reset(); self.record = record; self.store = store; self.session = session
        speech.onPassage = { [weak self] passage in
            guard let self, let session = self.session else { return }
            do {
                if self.followSpeech { try session.commands?.perform(.followPlayback(passage.anchor)) }
                try session.commands?.perform(.showPlayback(passage))
            } catch { self.errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error"); self.speech.stop() }
        }
        speech.onWord = { [weak self] passage in
            guard let self, self.session?.epubEngine != nil else { return }
            do { try self.session?.commands?.perform(.showPlayback(passage)) } catch { self.errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
        }
        speech.onPosition = { [weak self] in self?.checkpoint($0) }
        speech.onStop = { [weak self] in
            guard let self else { return }
            try? self.session?.commands?.perform(.showPlayback(nil))
            if let anchor = self.speech.position { self.checkpoint(anchor) }
        }
        loadTask = Task { [weak self] in await self?.reload() }
    }
    func reset() {
        speech.stop(); loadTask?.cancel(); loadTask = nil
        notes = []; cards = []; highlights = []; savedListen = nil; recallCard = nil; revealAnswer = false
        draftCard = nil; draftNote = nil; visible = false; record = nil; session = nil; errorMessage = nil; deleted = nil; importSummary = nil
    }
    func reload() async {
        guard let record, let store else { return }
        do {
            let state = try await store.study(for: record), notes = try await store.notes(for: record)
            guard !Task.isCancelled, self.record?.id == record.id else { return }
            cards = state.cards; highlights = state.highlights; self.notes = notes; if speech.status == .stopped { savedListen = state.listen }
            if speech.status == .stopped, let position = state.listen { speech.rate = position.rate; speech.voiceIdentifier = position.voiceIdentifier ?? "" }
            if session?.engine?.capabilities.contains(.textSelection) == true { try session?.commands?.perform(.setHighlights(highlights)) }
        } catch { if !Task.isCancelled { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") } }
    }
    func source() throws -> (SourceAnchor, String) {
        guard let session, let engine = session.engine else { throw ReaderError.unavailableSource }
        if let selection = session.epubEngine?.selection { return (selection.anchor, selection.displayText) }
        if let selection = session.companion.selection { return (selection.anchor, selection.text) }
        let passage = try engine.textPassage(at: engine.currentAnchor())
        guard !passage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReaderError.unsupportedCommand }
        return (passage.anchor, passage.text)
    }
    func newCard() {
        visible = true; tab = "cards"; errorMessage = nil
        do {
            let (anchor, text) = try source()
            draftCard = StudyCard(anchor: anchor, quotation: text, question: "", answer: "")
            visible = true; tab = "cards"
        } catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
    }
    func newNote() {
        visible = true; tab = "notes"; errorMessage = nil
        do {
            let (anchor, text) = try source()
            draftNote = ReaderNote(anchor: anchor, text: "", quotation: String(text.prefix(1600)))
            visible = true; tab = "notes"
        } catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
    }
    func saveCard(_ value: StudyCard) async {
        guard !busy, let record, let store else { return }; busy = true; defer { busy = false }
        do { try await store.saveCard(value, for: record); errorMessage = nil; draftCard = nil; await reload() }
        catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
    }
    func saveNote(_ value: ReaderNote) async {
        guard !busy, let record, let store else { return }; busy = true; defer { busy = false }
        do { try await store.saveNote(value, for: record); errorMessage = nil; draftNote = nil; await reload(); session?.companion.notes = notes }
        catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
    }
    func deleteNote(_ value: ReaderNote) async {
        guard let record, let store else { return }
        do { try await store.removeNote(value.id, for: record); deleted = .note(value); await reload(); session?.companion.notes = notes }
        catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
    }
    func deleteCard(_ value: StudyCard) async {
        guard let record, let store else { return }
        do { try await store.removeCard(value.id, for: record); deleted = .card(value); await reload() }
        catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
    }
    func addHighlight() async {
        guard !busy, let record, let store else { return }; busy = true; defer { busy = false }
        visible = true; tab = "highlights"; errorMessage = nil
        do {
            var additions: [ReaderHighlight] = []
            if let pdf = session?.pdfEngine, let selection = pdf.view.currentSelection {
                for line in selection.selectionsByLine() {
                    guard let page = line.pages.first, let text = line.string, !text.isEmpty else { continue }
                    let bounds = line.bounds(for: page)
                    let anchor = SourceAnchor(bookID: pdf.bookID, sourceRevision: pdf.sourceRevision, position: .pdf(.init(pageIndex: pdf.document.index(for: page), x: bounds.minX, y: bounds.maxY)))
                    additions.append(ReaderHighlight(anchor: anchor, quotation: text, color: highlightColor))
                }
            } else if let selection = session?.epubEngine?.selection {
                additions.append(ReaderHighlight(anchor: selection.anchor, quotation: selection.text, color: highlightColor, displayQuotation: selection.displayText))
            } else {
                let (anchor, text) = try source()
                additions.append(ReaderHighlight(anchor: anchor, quotation: text, color: highlightColor))
            }
            try session?.commands?.perform(.setHighlights(highlights + additions))
            do { try await store.saveHighlights(additions, for: record) }
            catch { try? session?.commands?.perform(.setHighlights(highlights)); throw error }
            await reload(); visible = true; tab = "highlights"
        } catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
    }
    func changeHighlight(_ value: ReaderHighlight, color: HighlightColor) async {
        guard let record, let store else { return }; var changed = value; changed.color = color
        do { try await store.saveHighlight(changed, for: record); await reload() } catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
    }
    func deleteHighlight(_ value: ReaderHighlight) async {
        guard let record, let store else { return }
        do { try await store.removeHighlight(value.id, for: record); deleted = .highlight(value); await reload() } catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
    }
    func undoDeletion() async {
        guard let deleted, let record, let store else { return }
        do {
            switch deleted {
            case .card(let value): try await store.saveCard(value, for: record)
            case .note(let value): try await store.saveNote(value, for: record)
            case .highlight(let value): try await store.saveHighlight(value, for: record)
            }
            self.deleted = nil; await reload(); session?.companion.notes = notes
        } catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
    }
    func beginRecall() { tab = "recall"; revealAnswer = false; recallCard = dueCards.first }
    func review(remembered: Bool) async {
        guard var card = recallCard else { return }
        card.review(remembered: remembered); await saveCard(card); beginRecall()
    }
    func go(to anchor: SourceAnchor) { speech.pause(); session?.navigate(to: anchor); visible = false }
    func listen(resumeSaved: Bool) {
        guard let engine = session?.engine else { return }
        do {
            let anchor: SourceAnchor
            if resumeSaved, let savedListen { anchor = savedListen.anchor } else { anchor = try engine.currentAnchor() }
            speech.start(engine: engine, anchor: anchor)
        }
        catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
    }
    func checkpoint(_ anchor: SourceAnchor) {
        guard let record else { return }
        let value = ListenPosition(anchor: anchor, rate: speech.rate, voiceIdentifier: speech.voiceIdentifier.isEmpty ? nil : speech.voiceIdentifier, completed: speech.completed)
        pendingListen = (record, value); savedListen = value
        if saveTask == nil {
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300)); guard !Task.isCancelled else { return }
                await self?.flush(); self?.saveTask = nil
            }
        }
    }
    func flush() async {
        guard let pending = pendingListen, let store else { return }
        do {
            try await store.saveListenPosition(pending.1, for: pending.0)
            if pendingListen?.0.id == pending.0.id && pendingListen?.1 == pending.1 { pendingListen = nil }
        } catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
    }
    func markdown() throws -> String {
        let titles = Dictionary((session?.epubEngine?.publication.readingResources ?? []).map { ($0.resource, $0.title) }, uniquingKeysWith: { first, _ in first })
        return try StudyMarkdown.export(title: session?.title ?? "Adaptive Reader", notes: notes, cards: cards, highlights: highlights, chapterTitles: titles)
    }
    func cardArchive() throws -> Data {
        guard let record else { throw ReaderError.unavailableSource }
        return try StudyCardArchive(revision: record.revision, cards: cards).encoded()
    }
    func importCards(_ url: URL) async {
        guard !busy, let record, let store else { return }; busy = true; defer { busy = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let grant = url.startAccessingSecurityScopedResource(); defer { if grant { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 16 * 1024 * 1024 else { throw ReaderError.unsupportedCommand }
                return try Data(contentsOf: url)
            }.value
            guard self.record?.id == record.id else { return }
            let archive = try JSONDecoder().decode(StudyCardArchive.self, from: data)
            guard archive.schemaVersion == 1, archive.cards.count <= 10000 else { throw ReaderError.unsupportedAnchorVersion }
            // Ask the current document engine to resolve every imported locator
            // before committing the atomic merge; navigation is never performed.
            for card in archive.cards { _ = try session?.engine?.textPassage(at: card.rebased(for: record).anchor) }
            let count = try await store.importCards(data, for: record)
            await reload(); importSummary = String(localized: "Imported cards: \(count). Existing cards were kept.")
        } catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Study error") }
    }
}
