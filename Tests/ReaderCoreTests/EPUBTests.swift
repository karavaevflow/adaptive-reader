import Foundation
import Testing
import WebKit
@testable import ReaderCore

private func epub(_ name: String = "reflow") throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Research/Fixtures/EPUB/\(name).epub"))
}

@Test func epubContainerPreservesReadingOrderTextIllustrationsAndFootnotes() throws {
    let book = try EPUBPublication(data: epub())
    #expect(book.title == "Adaptive EPUB Specimen")
    #expect(book.chapters.map(\.resource) == ["EPUB/one.xhtml", "EPUB/two.xhtml"])
    #expect(book.chapters[0].text.contains("Понимание"))
    #expect(book.chapters[1].text.contains("Passage 1799"))
    #expect(book.chapters[1].title == "A long chapter")
    #expect(book.chapters[1].fragments["note"] != nil)
    #expect(book.resources["EPUB/diagram.svg"]?.mediaType == "image/svg+xml")
    #expect(book.resources["META-INF/container.xml"] == nil)
}

@Test @MainActor func nonSpineFootnotesUseTheSameNavigationAndBackHistory() throws {
    let data = try epub("linked-footnotes"), publication = try EPUBPublication(data: data)
    #expect(publication.chapters.count == 2 && publication.linkedChapters.count == 1)
    let chapter = try #require(publication.linkedChapters.first)
    let offset = try #require(chapter.fragments["footnote"])
    let engine = EPUBReaderEngine(publication: publication, bookID: UUID(), revision: PDFReaderEngine.revision(data))
    defer { engine.stop() }
    let commands = ReaderCommands(engine: engine), origin = try engine.currentAnchor()
    let target = SourceAnchor(bookID: engine.bookID, sourceRevision: engine.sourceRevision, position: .epub(resource: chapter.resource, locator: EPUBTextLocator(offset: offset).encoded))
    try commands.perform(.navigate(target))
    #expect(try engine.currentAnchor() == target)
    try commands.perform(.back)
    #expect(try engine.currentAnchor() == origin)
}

@Test func epubRejectsUnsafeUnsupportedSourcesAndSanitizesAuthoredScripts() throws {
    #expect(throws: EPUBError.unsafeResource) { try EPUBPublication(data: epub("traversal")) }
    #expect(throws: EPUBError.invalidContainer) { try EPUBPublication(data: epub("corrupt")) }
    #expect(throws: EPUBError.encrypted) { try EPUBPublication(data: epub("encrypted")) }
    #expect(throws: EPUBError.unsupportedLayout) { try EPUBPublication(data: epub("fixed-layout")) }
    let book = try EPUBPublication(data: epub("scripted"))
    let html = String(decoding: book.chapters[0].html, as: UTF8.self)
    #expect(!html.contains("onload="))
    #expect(!html.contains("<script"))
    #expect(!html.contains("<iframe"))
    #expect(html.contains("script-src 'none'"))
    #expect(html.contains("connect-src 'none'"))
    #expect(throws: EPUBError.unsafeResource) { try EPUBPublication.resolve("%2e%2e/%2e%2e/file", relativeTo: "EPUB") }
    #expect(throws: EPUBError.unsafeResource) { try EPUBPublication.resolve("https://example.com/book", relativeTo: "EPUB") }
    #expect(try EPUBPublication.resolve("../images/figure.svg", relativeTo: "EPUB/Text") == "EPUB/images/figure.svg")
}

@Test @MainActor func epubCommandsReflowAndReopenPreserveSourceAnchorAndOriginalBytes() async throws {
    let data = try epub(), publication = try EPUBPublication(data: data), id = UUID(), revision = PDFReaderEngine.revision(data)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(root: root)
    let record = try await store.importBook(data: data, id: id, title: publication.title, revision: revision, format: .epub)
    let engine = EPUBReaderEngine(publication: publication, bookID: id, revision: revision), commands = ReaderCommands(engine: engine)
    defer { engine.stop() }
    let chapter = publication.chapters[1], text = chapter.text as NSString
    let offset = text.range(of: "Passage 853.").location
    let locator = EPUBTextLocator(offset: offset, quote: "Passage 853.")
    let anchor = SourceAnchor(bookID: id, sourceRevision: revision, position: .epub(resource: chapter.resource, locator: locator.encoded))
    try commands.perform(.navigate(anchor))
    var typography = EPUBTypography(); typography.fontSize = 29; typography.columnWidth = 420
    try commands.perform(.setTypography(typography)); try commands.perform(.setPalette(.midnight))
    #expect(try engine.currentAnchor() == anchor)
    try commands.perform(.advancePassage(1))
    if case .epub(let resource, let next) = try engine.currentAnchor().position {
        #expect(resource == chapter.resource)
        #expect(try EPUBTextLocator(encoded: next).offset > offset)
    } else { Issue.record("Passage navigation changed format") }
    try commands.perform(.back)
    #expect(try engine.currentAnchor() == anchor)
    try await store.save(ReadingState(anchor: engine.currentAnchor(), palette: engine.palette, scale: 1, epubTypography: typography), for: record)
    let mark = ReaderBookmark(anchor: anchor, title: "Passage 853")
    try await store.saveBookmarks([mark], for: record)
    let reopened = LibraryStore(root: root)
    let (book, bytes, state) = try await reopened.openBook(id)
    #expect(book.format == .epub && book.schemaVersion == 3)
    #expect(bytes == data && book.assetName.hasSuffix(".epub"))
    #expect(state?.anchor == anchor && state?.epubTypography == typography)
    #expect(try await reopened.bookmarks(for: book) == [mark])
    #expect(throws: ReaderError.unsupportedCommand) { try commands.perform(.setScale(2)) }
    let wrong = SourceAnchor(bookID: id, sourceRevision: revision, position: .epub(resource: chapter.resource, locator: EPUBTextLocator(offset: offset, quote: "Wrong quote").encoded))
    #expect(throws: ReaderError.invalidAnchor) { try commands.perform(.navigate(wrong)) }
    #expect(try engine.currentAnchor() == anchor)
    var matches: [ReaderSearchMatch] = []
    for try await result in try commands.search("Passage 853.") { matches.append(result) }
    #expect(matches.count == 1)
    if let match = matches.first { try commands.perform(.showSearchMatch(match)); #expect(try engine.currentAnchor() == match.anchor) }
}

@Test func schemaTwoPDFMigratesToExplicitFormatWithoutChangingSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("unchanged legacy source".utf8), id = UUID(), store = LibraryStore(root: root)
    let record = try await store.importBook(data: data, id: id, title: "Legacy", revision: PDFReaderEngine.revision(data))
    let url = root.appendingPathComponent("Books/\(id.uuidString).json")
    var old = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    old["schemaVersion"] = 2; old.removeValue(forKey: "format")
    try JSONSerialization.data(withJSONObject: old).write(to: url)
    let (migrated, bytes, _) = try await LibraryStore(root: root).openBook(id)
    #expect(migrated.format == .pdf && migrated.schemaVersion == 3)
    #expect(bytes == data && migrated.assetName == record.assetName)
}

@MainActor private func epubJavaScript(_ engine: EPUBReaderEngine, _ script: String, world: WKContentWorld = .defaultClient) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        engine.view.evaluateJavaScript(script, in: nil, in: world) { result in
            switch result {
            case .success(let value): continuation.resume(returning: String(describing: value))
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }
}

@Test @MainActor func webKitReflowResolvesTextAndNeverExecutesBookScripts() async throws {
    let data = try epub("scripted"), publication = try EPUBPublication(data: data)
    let engine = EPUBReaderEngine(publication: publication, bookID: UUID(), revision: PDFReaderEngine.revision(data))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = engine.view
    defer { engine.stop(); window.contentView = nil }
    var failure: Error?
    engine.onError = { failure = $0 }
    engine.start()
    for _ in 0..<100 { if engine.ready || failure != nil { break }; try await Task.sleep(for: .milliseconds(100)) }
    #expect(engine.ready)
    if let failure { throw failure }
    #expect(try await epubJavaScript(engine, "typeof window.authoredScriptRan", world: .page) == "undefined")
    #expect(try await epubJavaScript(engine, "document.querySelectorAll('script,iframe,[onload],[contenteditable]').length") == "0")
    _ = try await epubJavaScript(engine, "document.documentElement.style.scrollBehavior='smooth'; 'ready'")
    let imageMetrics = "JSON.stringify((()=>{const i=document.querySelector('img'),r=i.getBoundingClientRect();return {natural:i.naturalWidth,ratio:r.width/r.height};})())"
    let originalImage = try #require(JSONSerialization.jsonObject(with: Data(try await epubJavaScript(engine, imageMetrics).utf8)) as? [String: Double])
    #expect(originalImage["natural"] == 360)
    var imageTypography = EPUBTypography(); imageTypography.columnWidth = 360; imageTypography.fontSize = 28
    try engine.applyTypography(imageTypography); try engine.applyPagePalette(.midnight)
    let reflowedImage = try #require(JSONSerialization.jsonObject(with: Data(try await epubJavaScript(engine, imageMetrics).utf8)) as? [String: Double])
    #expect(abs((originalImage["ratio"] ?? 0) - (reflowedImage["ratio"] ?? 1)) < 0.01)
    #expect(try await epubJavaScript(engine, "getComputedStyle(document.querySelector('img')).filter") == "none")
    let chapter = publication.chapters[1]
    let offset = (chapter.text as NSString).range(of: "Passage 853.").location
    let anchor = SourceAnchor(bookID: engine.bookID, sourceRevision: engine.sourceRevision, position: .epub(resource: chapter.resource, locator: EPUBTextLocator(offset: offset, quote: "Passage 853.").encoded))
    try engine.navigate(to: anchor)
    for _ in 0..<100 { if engine.ready || failure != nil { break }; try await Task.sleep(for: .milliseconds(100)) }
    try await Task.sleep(for: .milliseconds(150))
    if let failure { throw failure }
    let measure = "JSON.stringify((()=>{const p=document.getElementById('p853'),r=p.getBoundingClientRect();return {top:r.top,bottom:r.bottom,font:parseFloat(getComputedStyle(p).fontSize),width:document.body.getBoundingClientRect().width};})())"
    let before = try #require(JSONSerialization.jsonObject(with: Data(try await epubJavaScript(engine, measure).utf8)) as? [String: Double])
    let persistent = ReaderHighlight(anchor: anchor, quotation: "Passage 853.", color: .green)
    try ReaderCommands(engine: engine).perform(.setHighlights([persistent]))
    try engine.setPlayback(ReaderPassage(anchor: anchor, text: "Passage", next: nil))
    #expect(try await epubJavaScript(engine, "Array.from(CSS.highlights.get('adaptive-green'))[0].toString()") == "Passage 853.")
    #expect((before["top"] ?? -100) >= -5 && (before["top"] ?? 1000) < 100, "Before reflow: \(before)")
    var typography = EPUBTypography(); typography.fontSize = 30; typography.columnWidth = 420
    try engine.applyTypography(typography)
    try await Task.sleep(for: .milliseconds(150))
    let after = try #require(JSONSerialization.jsonObject(with: Data(try await epubJavaScript(engine, measure).utf8)) as? [String: Double])
    #expect(after["font"] == 30 && after["width"] == 420)
    #expect(try await epubJavaScript(engine, "Array.from(CSS.highlights.get('adaptive-green'))[0].toString()") == "Passage 853.")
    try engine.setPlayback(nil)
    #expect(try await epubJavaScript(engine, "String(CSS.highlights.has('adaptive-green'))") == "true")
    #expect((after["top"] ?? -100) >= -5 && (after["top"] ?? 1000) < 100, "After reflow: \(after)")
    try await Task.sleep(for: .milliseconds(250))
    if case .epub(_, let encoded) = try engine.currentAnchor().position {
        let restoredOffset = try EPUBTextLocator(encoded: encoded).offset
        #expect(restoredOffset == offset)
    }
    else { Issue.record("EPUB position changed format") }
    for iteration in 0..<4 {
        typography.fontSize = iteration % 2 == 0 ? 18 : 30
        typography.columnWidth = iteration % 2 == 0 ? 680 : 420
        try engine.applyTypography(typography)
        try await Task.sleep(for: .milliseconds(250))
        if case .epub(_, let encoded) = try engine.currentAnchor().position {
            let restoredOffset = try EPUBTextLocator(encoded: encoded).offset
            #expect(restoredOffset == offset)
        }
    }
    // Cancelling a stale chapter load must not report a failed current document.
    let first = SourceAnchor(bookID: engine.bookID, sourceRevision: engine.sourceRevision, position: .epub(resource: publication.chapters[0].resource, locator: EPUBTextLocator(offset: 0).encoded))
    try engine.navigate(to: first); try engine.navigate(to: anchor)
    for _ in 0..<100 { if engine.ready || failure != nil { break }; try await Task.sleep(for: .milliseconds(100)) }
    try await Task.sleep(for: .milliseconds(250))
    #expect(engine.chapterIndex == 1 && engine.ready)
    #expect(try await epubJavaScript(engine, "Array.from(CSS.highlights.get('adaptive-green'))[0].toString()") == "Passage 853.")
    // Continuous movement must publish intermediate anchors, rather than waiting
    // for the scroll stream to go quiet (which starves auto-scroll checkpoints).
    for _ in 0..<10 {
        _ = try engine.scroll(by: 80)
        try await Task.sleep(for: .milliseconds(40))
    }
    if case .epub(_, let encoded) = try engine.currentAnchor().position {
        let moved = try EPUBTextLocator(encoded: encoded).offset
        #expect(moved > offset)
    }
    if let failure { throw failure }
}

@Test func epubEvidenceUsesResolvableLocatorsAcrossUnicodeAndReflow() throws {
    let data = try epub(), publication = try EPUBPublication(data: data), id = UUID(), revision = PDFReaderEngine.revision(data)
    let index = try EPUBEvidenceIndex(publication: publication, bookID: id, revision: revision)
    #expect(!index.truncated && !index.passages.isEmpty)
    for source in index.passages {
        try source.anchor.validate(bookID: id, revision: revision)
        guard case .epub(let resource, let encoded) = source.anchor.position,
              let chapter = publication.chapters.first(where: { $0.resource == resource }) else { Issue.record("Missing EPUB resource"); continue }
        try EPUBTextLocator(encoded: encoded).validate(in: chapter.text)
    }
    let result = try index.retrieve("attention", visibleResource: publication.chapters[0].resource)
    #expect(result.first?.text.localizedCaseInsensitiveContains("attention") == true)
}
