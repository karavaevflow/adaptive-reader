import Foundation
import ReaderCore
import Observation
import Security
import CryptoKit

enum CompanionSecrets {
    private static func query(_ destination: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "AdaptiveReader.Development") + ".AI",
         kSecAttrAccount as String: SHA256.hash(data: Data(destination.utf8)).map { String(format: "%02x", $0) }.joined()]
    }
    static func read(_ destination: String) throws -> String {
        var value = query(destination); value[kSecReturnData as String] = true
        var item: CFTypeRef?
        let result = SecItemCopyMatching(value as CFDictionary, &item)
        if result == errSecItemNotFound { return "" }
        guard result == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) else { throw CompanionError.configuration }
        return text
    }
    static func save(_ key: String, destination: String) throws {
        let value = query(destination), data = Data(key.utf8)
        let result = SecItemUpdate(value as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = value; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CompanionError.configuration }
        } else if result != errSecSuccess { throw CompanionError.configuration }
    }
    static func remove(_ destination: String) throws {
        let result = SecItemDelete(query(destination) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CompanionError.configuration }
    }
}

/// Security IPC may wait for the user; keep it away from the reader's main actor.
actor CompanionKeyVault {
    static let shared = CompanionKeyVault()
    func read(_ destination: String) throws -> String { try CompanionSecrets.read(destination) }
    func save(_ key: String, destination: String) throws { try CompanionSecrets.save(key, destination: destination) }
    func remove(_ destination: String) throws { try CompanionSecrets.remove(destination) }
}

@MainActor @Observable
final class CompanionModel {
    var settings = CompanionSettings()
    var query = ""
    var answer: CompanionAnswer?
    var evidence: [EvidencePassage] = []
    var selection: EvidencePassage?
    var selectionLabel = ""
    var busy = false
    var indexing = false
    var progress = 0.0
    var receivedCharacters = 0
    var errorMessage: String?
    var settingsVisible = false
    var smartMargins = false
    var notes: [ReaderNote] = []
    var draftNote = ""
    var draftSource: EvidencePassage?
    var undoNote: ReaderNote?
    var indexTruncated = false
    var reviewStarted = false
    var canSaveNotes: Bool { record != nil }
    private(set) var bookID: UUID?
    private(set) var revision = ""
    private var title = ""
    private var pageCount = 0
    @ObservationIgnored private var data: Data?
    @ObservationIgnored private var record: BookRecord?
    @ObservationIgnored private var store: LibraryStore?
    @ObservationIgnored private var index: PDFEvidenceIndex?
    @ObservationIgnored private var epubPublication: EPUBPublication?
    @ObservationIgnored private var epubIndex: EPUBEvidenceIndex?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lastRequest: CompanionRequest?
    @ObservationIgnored var onSettingsChanged: (@MainActor () -> Void)?
    var fixtureMode: Bool {
        #if DEBUG || FOUNDATION_BENCHMARK
        ProcessInfo.processInfo.arguments.contains("-companionFixture")
        #else
        false
        #endif
    }
    func configure(data: Data, bookID: UUID, revision: String, title: String, pageCount: Int, record: BookRecord?, store: LibraryStore, epub: EPUBPublication? = nil) {
        reset(); self.data = data; self.bookID = bookID; self.revision = revision; self.title = title
        self.epubPublication = epub; self.pageCount = pageCount; self.record = record; self.store = store
        setupTask = Task { [weak self] in
            do {
                let settings = try await store.companionSettings()
                let notes: [ReaderNote]
                if let record { notes = try await store.notes(for: record) } else { notes = [] }
                guard let self, !Task.isCancelled, self.bookID == bookID else { return }
                self.settings = settings; self.notes = notes
            } catch { if !Task.isCancelled { self?.errorMessage = error.localizedDescription } }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false; indexing = false }
    func newTopic() { cancel(); query = ""; answer = nil; evidence = []; lastRequest = nil; errorMessage = nil }
    func reset() {
        newTopic(); setupTask?.cancel(); setupTask = nil; selection = nil; selectionLabel = ""; smartMargins = false
        data = nil; index = nil; epubPublication = nil; epubIndex = nil; notes = []; draftSource = nil; draftNote = ""; undoNote = nil; bookID = nil; record = nil
        reviewStarted = false; settingsVisible = false; indexTruncated = false; progress = 0; receivedCharacters = 0
    }
    func saveSettings(_ value: CompanionSettings, key: String) async {
        cancel()
        do {
            if value.mode != .off { _ = try value.validatedURL() }
            if value.mode == .cloud && !key.isEmpty { try await CompanionKeyVault.shared.save(key, destination: value.destination) }
            try await store?.saveCompanionSettings(value); settings = value; settingsVisible = false; onSettingsChanged?()
        } catch { errorMessage = error.localizedDescription }
    }
    func refreshSettings() async {
        guard let bookID, let store else { return }
        do {
            let value = try await store.companionSettings()
            guard self.bookID == bookID, !Task.isCancelled else { return }
            if settings != value { cancel(); settings = value }
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
    func clearIndex() async {
        cancel(); index = nil; epubIndex = nil
        do { if let bookID { try await store?.clearEvidence(bookID: bookID, revision: revision) } }
        catch { errorMessage = error.localizedDescription }
    }
    func ask(page: Int, question: String? = nil, refinement: String? = nil, chapter: String? = nil) {
        let question = refinement != nil ? (lastRequest?.question ?? "") : (question ?? query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !question.isEmpty, let data, let bookID, let store else { return }
        cancel(); answer = nil; errorMessage = nil; receivedCharacters = 0; busy = true
        let token = generation, revision = revision, title = title
        let selected = selection, previous = lastRequest, isFixture = fixtureMode, pageCount = pageCount
        task = Task { [weak self] in
            do {
                guard let self else { return }
                let settings = try await store.companionSettings()
                try Task.checkCancellation(); guard self.generation == token else { return }
                self.settings = settings
                if !isFixture { _ = try settings.validatedURL() }
                let sources: [EvidencePassage]
                let finalQuestion: String
                if let refinement, let previous {
                    sources = previous.sources; finalQuestion = previous.question + "\nExplain again: " + refinement
                } else if let selected {
                    sources = [selected]; finalQuestion = question
                } else if let publication = self.epubPublication {
                    self.indexing = true
                    if self.epubIndex == nil {
                        let worker = Task.detached(priority: .utility) { try EPUBEvidenceIndex(publication: publication, bookID: bookID, revision: revision) }
                        let built = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                        try Task.checkCancellation()
                        guard self.generation == token, self.bookID == bookID else { return }
                        self.epubIndex = built
                    }
                    try Task.checkCancellation()
                    guard let index = self.epubIndex else { throw CompanionError.noText }
                    self.indexTruncated = index.truncated
                    let resource = publication.readingResources[min(max(0, page - 1), publication.readingResources.count - 1)].resource
                    let worker = Task.detached(priority: .userInitiated) { try index.retrieve(question, visibleResource: resource) }
                    sources = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    finalQuestion = question
                } else {
                    self.indexing = true
                    if self.index == nil { self.index = try await store.cachedEvidence(bookID: bookID, revision: revision) }
                    if self.index == nil {
                        let worker = Task.detached(priority: .utility) {
                            try await PDFEvidenceIndex.build(data: data, bookID: bookID, revision: revision) { [weak self] count, total in
                                await self?.indexProgress(Double(count) / Double(max(1, total)), token: token)
                            }
                        }
                        let built = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                        try Task.checkCancellation()
                        self.index = built; try await store.cacheEvidence(built)
                    }
                    try Task.checkCancellation()
                    guard let index = self.index else { throw CompanionError.noText }
                    self.indexTruncated = index.truncated
                    let worker = Task.detached(priority: .userInitiated) { try index.retrieve(question, visiblePage: max(0, page - 1)) }
                    sources = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    finalQuestion = question
                }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                guard !sources.isEmpty else { throw CompanionError.noText }
                self.indexing = false; self.evidence = sources
                let request = CompanionRequest(question: finalQuestion, title: title,
                    page: refinement == nil ? (self.epubPublication == nil ? page : nil) : previous?.page, sources: sources,
                    chapter: refinement == nil ? chapter : previous?.chapter)
                self.lastRequest = request
                let provider: any CompanionProvider
                if !isFixture { try await store.authorizeCompanion(settings) }
                let apiKey: String
                if !isFixture && settings.mode == .cloud { apiKey = try await CompanionKeyVault.shared.read(settings.destination) }
                else { apiKey = "" }
                try Task.checkCancellation()
                if !isFixture { try await store.authorizeCompanion(settings) }
                #if DEBUG || FOUNDATION_BENCHMARK
                if isFixture { provider = FixtureCompanionProvider(delayMilliseconds: ProcessInfo.processInfo.arguments.contains("-companionSlowFixture") ? 10000 : 300) }
                else { provider = CompanionHTTPProvider(settings: settings, apiKey: apiKey) }
                #else
                provider = CompanionHTTPProvider(settings: settings, apiKey: apiKey)
                #endif
                var response = ""
                for try await chunk in provider.response(to: request) {
                    try Task.checkCancellation(); guard self.generation == token else { return }
                    response += chunk; self.receivedCharacters = response.count
                    guard response.count <= 64000 else { throw CompanionError.limitExceeded }
                }
                try Task.checkCancellation()
                let answer = try JSONDecoder().decode(CompanionAnswer.self, from: Data(response.utf8))
                try answer.validate(sources: sources, pageCount: pageCount)
                try Task.checkCancellation(); guard self.generation == token else { return }
                self.answer = answer; self.busy = false; self.task = nil
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.busy = false; self.indexing = false; self.task = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }
    private func indexProgress(_ value: Double, token: UUID) { if generation == token { progress = value } }
    func validate(_ passage: EvidencePassage) throws {
        guard let bookID else { throw CompanionError.invalidEvidence }
        try passage.anchor.validate(bookID: bookID, revision: revision)
    }
    func prepareNote(_ passage: EvidencePassage, text: String = "") {
        do { try validate(passage); draftSource = passage; draftNote = text }
        catch { errorMessage = error.localizedDescription }
    }
    func saveNote() async {
        guard let draftSource, let record, let store else { return }
        do {
            try validate(draftSource)
            let note = ReaderNote(anchor: draftSource.anchor, text: draftNote, quotation: draftSource.text)
            try await store.saveNote(note, for: record)
            guard self.bookID == record.id else { return }
            notes = try await store.notes(for: record); undoNote = note; self.draftSource = nil; draftNote = ""
        } catch { errorMessage = error.localizedDescription }
    }
    func undoSavedNote() async {
        guard let note = undoNote, let record, let store else { return }
        do { try await store.removeNote(note.id, for: record); notes = try await store.notes(for: record); undoNote = nil }
        catch { errorMessage = error.localizedDescription }
    }
}

#if DEBUG || FOUNDATION_BENCHMARK
private struct FixtureCompanionProvider: CompanionProvider {
    let delayMilliseconds: Int
    func response(to request: CompanionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                    let source = request.sources[0]
                    let answer = CompanionAnswer(kind: .book, answer: "Test response — " + source.text,
                        sourceIDs: [source.id], actions: [.init(kind: .setTheme, palette: .forest), .init(kind: .createNote, sourceID: source.id, text: "Test note from the selected source")])
                    let text = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
                    continuation.yield(text); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
#endif
