import Foundation
import Testing
@testable import ReaderCore

@Test func sessionPauseAndCompletionUseMonotonicTime() throws {
    var timer = ReadingSessionTimer()
    let anchor = SourceAnchor(bookID: UUID(), sourceRevision: "v1", position: .epub(resource: "chapter", locator: "paragraph"))
    try timer.start(duration: 25 * 60, now: 10, anchor: anchor)
    timer.pause(now: 70, anchor: anchor)
    #expect(timer.elapsed == 60)
    timer.tick(now: 700, anchor: anchor)
    #expect(timer.elapsed == 60)
    timer.resume(now: 900)
    timer.tick(now: 2340, anchor: anchor)
    #expect(timer.elapsed == 1500)
    #expect(timer.status == .completed)
    #expect(timer.endAnchor == anchor)
    timer.stop(now: 3000, anchor: nil)
    #expect(timer.endAnchor == anchor)
    timer.resume(now: 4000)
    #expect(timer.status == .completed)
    #expect(throws: ReaderError.unsupportedCommand) { try timer.start(duration: .nan, now: 0, anchor: nil) }
}

@Test func freeSessionStopsWithoutCollectingFurtherTime() throws {
    var timer = ReadingSessionTimer()
    try timer.start(duration: nil, now: 50, anchor: nil)
    timer.stop(now: 170, anchor: nil)
    timer.tick(now: 9999, anchor: nil)
    #expect(timer.elapsed == 120)
    #expect(timer.remaining == nil)
    #expect(timer.status == .completed)
}

@Test func ambientScheduleHandlesMidnightDSTAndManualOverride() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    var settings = AmbientReadingSettings(); settings.strategy = .schedule
    let evening = date("2026-03-28T21:00:00Z")
    #expect(settings.palette(at: evening, systemDark: false, calendar: calendar) == .midnight)
    #expect(settings.nextTransition(after: evening, calendar: calendar) == date("2026-03-29T05:00:00Z"))
    settings.dayMinute = 2 * 60 + 30
    #expect(settings.nextTransition(after: evening, calendar: calendar) == date("2026-03-29T01:00:00Z"))
    settings.dayMinute = 20 * 60; settings.nightMinute = 7 * 60
    #expect(settings.isNight(at: date("2026-04-01T10:00:00Z"), systemDark: false, calendar: calendar))
    settings.dayMinute = 7 * 60; settings.nightMinute = 2 * 60 + 30
    #expect(settings.isNight(at: date("2026-10-25T01:10:00Z"), systemDark: false, calendar: calendar))
    settings.nightMinute = settings.dayMinute
    #expect(throws: ReaderError.unsupportedCommand) { try settings.validate() }
    var preferences = ReadingComfortPreferences()
    preferences.manualOverrideUntil = evening.addingTimeInterval(100)
    #expect(preferences.overridesAutomation(at: evening, systemDark: false, strategy: .schedule))
    #expect(!preferences.overridesAutomation(at: evening.addingTimeInterval(101), systemDark: false, strategy: .schedule))
    preferences.manualOverrideSystemDark = false
    #expect(preferences.overridesAutomation(at: evening.addingTimeInterval(101), systemDark: false, strategy: .system))
    #expect(!preferences.overridesAutomation(at: evening.addingTimeInterval(101), systemDark: true, strategy: .system))
}

@Test func comfortSettingsRoundTripWithoutChangingReadingState() async throws {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Research/Fixtures")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(root: root), data = try Data(contentsOf: fixtures.appendingPathComponent("text.pdf"))
    let record = try await store.importBook(data: data, id: UUID(), title: "Book", revision: PDFReaderEngine.revision(data))
    let anchor = SourceAnchor(bookID: record.id, sourceRevision: record.revision, position: .pdf(.init(pageIndex: 1, x: 0, y: 500)))
    try await store.save(ReadingState(anchor: anchor, palette: .forest, scale: 1), for: record)
    #expect(try await store.comfortPreferences(for: record) == ReadingComfortPreferences())
    var preferences = ReadingComfortPreferences(); preferences.autoScrollSpeed = 52; preferences.miniAlwaysOnTop = true
    var ambient = AmbientReadingSettings(); ambient.strategy = .schedule
    preferences.ambient = ambient
    try await store.saveComfort(preferences, for: record)
    try await store.saveAmbientDefaults(ambient)
    let reopened = LibraryStore(root: root)
    #expect(try await reopened.comfortPreferences(for: record) == preferences)
    #expect(try await reopened.ambientDefaults() == ambient)
    #expect(try await reopened.readingState(for: record)?.anchor == anchor)
    #expect(try Data(contentsOf: root.appendingPathComponent("Assets/\(record.assetName)")) == data)
}
