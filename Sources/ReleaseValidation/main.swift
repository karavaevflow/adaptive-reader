import Foundation
import ReaderCore

// Release engineering only. Does not launch a model, speech player or reader window.
// The frozen upgrade fixture is artificial reader data, never a user's library.
enum ValidationFailure: Error { case arguments, destinationExists, missingPosition }

func seed(repository: URL, destination: URL) async throws {
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw ValidationFailure.destinationExists }
    let store = LibraryStore(root: destination)
    var sources: [KnowledgeSource] = []
    for (index, file) in ["text.pdf", "EPUB/reflow.epub"].enumerated() {
        let data = try Data(contentsOf: repository.appendingPathComponent("Research/Fixtures/" + file))
        let id = UUID(uuidString: index == 0 ? "B0000000-0000-4000-8000-000000000001" : "B0000000-0000-4000-8000-000000000002")!
        let book = try await store.importBook(data: data, id: id, title: index == 0 ? "Upgrade PDF" : "Upgrade EPUB", revision: PDFReaderEngine.revision(data), pageCount: index == 0 ? 3 : 2, format: index == 0 ? .pdf : .epub)
        let position: DocumentPosition
        if index == 0 { position = .pdf(.init(pageIndex: 1, x: 30, y: 600)) }
        else {
            let publication = try EPUBPublication(data: data)
            let chapter = publication.chapters[0]
            position = .epub(resource: chapter.resource, locator: EPUBTextLocator(offset: 0, quote: String(chapter.text.prefix(80))).encoded)
        }
        let anchor = SourceAnchor(bookID: id, sourceRevision: book.revision, position: position)
        try await store.save(ReadingState(anchor: anchor, palette: .forest, scale: 1.2), for: book)
        try await store.setFavorite(true, for: id)
        try await store.saveBookmarks([ReaderBookmark(anchor: anchor, title: "Keep this fragment")], for: book)
        try await store.saveNote(ReaderNote(anchor: anchor, text: "Сохранить мою заметку при обновлении", quotation: "Reading specimen"), for: book)
        try await store.saveCard(StudyCard(anchor: anchor, quotation: "Reading specimen", question: "What must survive an update?", answer: "My source and learning records"), for: book)
        try await store.saveHighlight(ReaderHighlight(anchor: anchor, quotation: "Reading specimen", color: .green), for: book)
        try await store.saveListenPosition(ListenPosition(anchor: anchor, rate: 0.9, voiceIdentifier: nil), for: book)
        sources.append(KnowledgeSource(anchor: anchor, bookTitle: book.title, location: index == 0 ? "Page 2" : "Chapter 1", quotation: "Reading specimen"))
        try await store.performKnowledge(.metadata(.init(bookID: id, author: "Reader", collection: "Upgrade check")))
    }
    let first = KnowledgeCard(title: "Keep quotation", kind: .quotation, text: "Reading specimen", sources: [sources[0]])
    let second = KnowledgeCard(title: "Keep reader idea", kind: .readerNote, text: "Моя связь между книгами", sources: [sources[1]])
    try await store.performKnowledge(.saveCard(first)); try await store.performKnowledge(.saveCard(second))
    let board = KnowledgeBoard(title: "Upgrade board", nodes: [.init(cardID: first.id, point: .init(x: 20, y: 20)), .init(cardID: second.id, point: .init(x: 380, y: 20))], edges: [.init(from: first.id, to: second.id, label: "Related idea")])
    try await store.performKnowledge(.saveBoard(board))
    try await store.performKnowledge(.savePath(.init(goal: "Keep my path", steps: sources.map { .init(title: "Return to source", source: $0) })))
    let fragment = BilingualFragment(source: sources[0], translation: "Учимся читать", language: "Русский", explanation: "A reader's translation")
    try await store.performExtended(.saveFragment(fragment))
    try await store.performExtended(.saveWord(.init(fragmentID: fragment.id, word: "read", meaning: "читать")))
    try await store.performExtended(.saveSplit(.init(anchor: sources[1].anchor, palette: .paper)))
    let tracking = try await store.performExtended(.setTracking(replay: true, insights: true))
    try await store.performExtended(.record(.init(kind: .chapterCompleted, anchor: sources[0].anchor), generation: tracking.generation))
    try await store.performExtended(.activeTime(book: sources[0].anchor.bookID, seconds: 42, generation: tracking.generation))
    try await store.setCurrentBook(sources[0].anchor.bookID)
}

func report(root: URL) async throws -> Data {
    let store = LibraryStore(root: root), books = try await store.books()
    var rows: [[String: Any]] = []
    for book in books.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
        let (_, data, state) = try await store.openBook(book.id)
        guard let anchor = state?.anchor else { throw ValidationFailure.missingPosition }
        try anchor.validate(bookID: book.id, revision: book.revision)
        let study = try await store.study(for: book)
        rows.append(["id": book.id.uuidString, "revision": PDFReaderEngine.revision(data), "format": book.format.rawValue,
                     "favorite": book.favorite, "bookmarks": try await store.bookmarks(for: book).count,
                     "notes": try await store.notes(for: book).count, "cards": study.cards.count,
                     "highlights": study.highlights.count, "listeningPosition": study.listen != nil])
    }
    let knowledge = try await store.knowledge(), extended = try await store.extendedReading()
    return try JSONSerialization.data(withJSONObject: ["books": rows, "knowledgeCards": knowledge.cards.count,
        "boards": knowledge.boards.count, "edges": knowledge.boards.reduce(0) { $0 + $1.edges.count },
        "paths": knowledge.paths.count, "translations": extended.fragments.count, "vocabulary": extended.vocabulary.count,
        "splitPosition": extended.splitPosition != nil, "replayEnabled": extended.replayEnabled, "insightsEnabled": extended.insightsEnabled,
        "events": extended.events.count, "metrics": extended.metrics.count, "aiMode": try await store.companionSettings().mode.rawValue], options: [.prettyPrinted, .sortedKeys])
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { throw ValidationFailure.arguments }
if arguments[1] == "seed", arguments.count == 4 {
    try await seed(repository: URL(fileURLWithPath: arguments[2]), destination: URL(fileURLWithPath: arguments[3]))
    FileHandle.standardOutput.write(try await report(root: URL(fileURLWithPath: arguments[3])))
} else if arguments[1] == "verify", arguments.count == 3 {
    FileHandle.standardOutput.write(try await report(root: URL(fileURLWithPath: arguments[2])))
} else { throw ValidationFailure.arguments }
FileHandle.standardOutput.write(Data("\n".utf8))
