import Foundation
import AppKit
import WebKit
import ReaderCore
import Darwin

enum MeasurementError: Error { case timeout(String), wrongPosition, noSpeechProgress }
@MainActor func waitFor(_ label: String, timeout: Double = 20, _ condition: () -> Bool) throws {
    let start = ProcessInfo.processInfo.systemUptime
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime - start < timeout else { throw MeasurementError.timeout(label) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }
}
@MainActor func js(_ engine: EPUBReaderEngine, _ script: String) throws -> String {
    var result: Result<String, Error>?
    engine.view.evaluateJavaScript(script, in: nil, in: .defaultClient) { value in result = value.map { String(describing: $0) } }
    try waitFor("JavaScript completion") { result != nil }
    return try result!.get()
}
func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
func quantile(_ values: [Double], _ q: Double) -> Double { let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }

@MainActor func measure(_ path: String, speechEnabled: Bool, probeControls: Bool = false) throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let begin = uptime(), data = try Data(contentsOf: URL(fileURLWithPath: path)), publication = try EPUBPublication(data: data)
    let parsed = uptime(), revision = PDFReaderEngine.revision(data)
    let engine = EPUBReaderEngine(publication: publication, bookID: UUID(), revision: revision)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = engine.view
    defer { engine.stop(); window.contentView = nil }
    var error: Error?
    engine.onError = { error = $0 }
    let chapter = publication.chapters[1]
    let anchor = SourceAnchor(bookID: engine.bookID, sourceRevision: revision, position: .epub(resource: chapter.resource, locator: EPUBTextLocator(offset: 0).encoded))
    try engine.navigate(to: anchor)
    try waitFor("long chapter ready") { engine.ready || error != nil }
    if let error { throw error }
    _ = try js(engine, "document.body.getBoundingClientRect().height")
    let firstLayout = uptime()
    let commands = ReaderCommands(engine: engine)
    var typography = EPUBTypography(); typography.fontSize = 29; typography.columnWidth = 420
    let reflowStart = uptime(); try commands.perform(.setTypography(typography))
    _ = try js(engine, "document.body.getBoundingClientRect().height")
    let reflowEnd = uptime()
    let offset = (chapter.text as NSString).range(of: "Passage 853.").location
    let target = SourceAnchor(bookID: engine.bookID, sourceRevision: revision, position: .epub(resource: chapter.resource, locator: EPUBTextLocator(offset: offset, quote: "Passage 853.").encoded))
    let locatorStart = uptime(); try commands.perform(.navigate(target))
    let top = try js(engine, "document.getElementById('p853').getBoundingClientRect().top")
    guard let y = Double(top), y >= -5, y < 100 else { throw MeasurementError.wrongPosition }
    let locatorEnd = uptime()
    let player = SpeechPlayer(volume: 0)
    var wordCount = 0, firstWord: Double?
    player.onPassage = { passage in try? commands.perform(.followPlayback(passage.anchor)); try? commands.perform(.showPlayback(passage)) }
    player.onWord = { passage in wordCount += 1; if firstWord == nil { firstWord = uptime() }; try? commands.perform(.showPlayback(passage)) }
    player.onStop = { try? commands.perform(.showPlayback(nil)) }
    let speechStart = uptime()
    if speechEnabled {
        player.start(engine: engine, anchor: target)
        if probeControls {
            player.pause()
            guard player.status == .paused else { throw MeasurementError.noSpeechProgress }
            player.resume()
            guard player.status == .playing else { throw MeasurementError.noSpeechProgress }
        }
        try waitFor("native speech first word", timeout: 30) { wordCount > 0 || player.errorMessage != nil }
        if player.errorMessage != nil { throw MeasurementError.noSpeechProgress }
    }
    var roundTrips: [Double] = [], intervals: [Double] = [], previous = uptime(), done = false
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
        MainActor.assumeIsolated {
            let now = uptime(); intervals.append((now - previous) * 1000); previous = now
            _ = try? engine.scroll(by: 1)
            if intervals.count >= 120 { done = true }
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    try waitFor("reading interaction", timeout: 10) { done }; timer.invalidate()
    for _ in 0..<5 {
        let begin = uptime(); _ = try js(engine, "document.body.getBoundingClientRect().width"); roundTrips.append((uptime() - begin) * 1000)
    }
    let stopStart = uptime(); player.stop(); let stopElapsed = uptime() - stopStart, countAtStop = wordCount
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    guard wordCount == countAtStop else { throw MeasurementError.noSpeechProgress }
    if let error { throw error }
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    let row: [String: Any] = [
        "sourceSHA256": revision, "speech": speechEnabled, "parseMs": (parsed - begin) * 1000,
        "longChapterFirstLayoutMs": (firstLayout - begin) * 1000, "reflowMs": (reflowEnd - reflowStart) * 1000,
        "locatorMs": (locatorEnd - locatorStart) * 1000, "speechFirstWordMs": firstWord.map { ($0 - speechStart) * 1000 } ?? 0,
        "nativeWordCallbacks": wordCount, "inputRoundTripMedianMs": quantile(roundTrips, 0.5),
        "runLoopIntervalP95Ms": quantile(intervals, 0.95), "runLoopIntervalMaxMs": intervals.max() ?? 0,
        "speechStopMs": stopElapsed * 1000, "lateWordCallbacksAfterStop": wordCount - countAtStop,
        "peakClientBytes": usage.ru_maxrss, "windowVisible": false, "immediatePauseResumeProbe": probeControls
    ]
    print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
}

let arguments = ProcessInfo.processInfo.arguments
guard arguments.count >= 2 else { fatalError("Usage: EPUBResearch fixture.epub [--speech]") }
try measure(arguments[1], speechEnabled: arguments.contains("--speech"), probeControls: arguments.contains("--probe-controls"))
