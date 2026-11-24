import Foundation

public enum AmbientStrategy: String, Codable, CaseIterable, Sendable { case manual, system, schedule }
public enum ManualPaletteBehavior: String, Codable, CaseIterable, Sendable { case untilNextChange, disableAutomation }

public struct AmbientReadingSettings: Codable, Equatable, Sendable {
    public var strategy: AmbientStrategy = .manual
    public var dayMinute: Int = 7 * 60
    public var nightMinute: Int = 20 * 60
    public var dayPalette: PagePalette = .paper
    public var nightPalette: PagePalette = .midnight
    public var manualBehavior: ManualPaletteBehavior = .untilNextChange
    public init() {}
    public func validate() throws {
        guard (0..<1440).contains(dayMinute), (0..<1440).contains(nightMinute), dayMinute != nightMinute else { throw ReaderError.unsupportedCommand }
    }
    public func isNight(at date: Date, systemDark: Bool, calendar: Calendar = .current) -> Bool {
        if strategy == .system { return systemDark }
        func previousBoundary(_ minute: Int) -> Date {
            let today = calendar.startOfDay(for: date)
            func boundary(on day: Date) -> Date {
                calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day,
                              matchingPolicy: .nextTime, repeatedTimePolicy: .first) ?? day
            }
            let candidate = boundary(on: today)
            return candidate <= date ? candidate : boundary(on: calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        }
        return previousBoundary(nightMinute) > previousBoundary(dayMinute)
    }
    public func nextTransition(after date: Date, calendar: Calendar = .current) -> Date? {
        guard strategy == .schedule else { return nil }
        return [dayMinute, nightMinute].compactMap { minute in
            calendar.nextDate(after: date, matching: DateComponents(hour: minute / 60, minute: minute % 60), matchingPolicy: .nextTime, repeatedTimePolicy: .first)
        }.min()
    }
    public func palette(at date: Date, systemDark: Bool, calendar: Calendar = .current) -> PagePalette? {
        guard strategy != .manual else { return nil }
        return isNight(at: date, systemDark: systemDark, calendar: calendar) ? nightPalette : dayPalette
    }
}

/// Active timers/scrolling are deliberately not restored on application launch.
public struct ReadingComfortPreferences: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var ambient: AmbientReadingSettings?
    public var manualOverrideUntil: Date?
    public var manualOverrideSystemDark: Bool?
    public var autoScrollSpeed: Double
    public var miniAlwaysOnTop: Bool
    public init() {
        schemaVersion = 1; ambient = nil; manualOverrideUntil = nil
        manualOverrideSystemDark = nil; autoScrollSpeed = 32; miniAlwaysOnTop = false
    }
    public func validate() throws {
        guard schemaVersion == 1, autoScrollSpeed.isFinite, (8...160).contains(autoScrollSpeed) else { throw ReaderError.unsupportedCommand }
        try ambient?.validate()
        if let until = manualOverrideUntil, !until.timeIntervalSince1970.isFinite { throw ReaderError.unsupportedCommand }
    }
    public func overridesAutomation(at date: Date, systemDark: Bool, strategy: AmbientStrategy) -> Bool {
        switch strategy {
        case .manual: false
        case .schedule: manualOverrideUntil.map { date < $0 } ?? false
        case .system: manualOverrideSystemDark == systemDark
        }
    }
}

public enum ReadingSessionStatus: String, Sendable { case idle, running, paused, completed }

/// A monotonic clock supplies elapsed reading time. Wall-clock changes cannot add time.
public struct ReadingSessionTimer: Sendable {
    public private(set) var status: ReadingSessionStatus = .idle
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var duration: TimeInterval?
    public private(set) var startAnchor: SourceAnchor?
    public private(set) var endAnchor: SourceAnchor?
    private var accumulated: TimeInterval = 0
    private var resumedAt: TimeInterval?
    public init() {}
    public mutating func start(duration: TimeInterval?, now: TimeInterval, anchor: SourceAnchor?) throws {
        guard now.isFinite, duration.map({ $0.isFinite && $0 > 0 && $0 <= 24 * 3600 }) ?? true else { throw ReaderError.unsupportedCommand }
        self.duration = duration; startAnchor = anchor; endAnchor = nil
        elapsed = 0; accumulated = 0; resumedAt = now; status = .running
    }
    public mutating func tick(now: TimeInterval, anchor: SourceAnchor?) {
        guard status == .running, let resumedAt, now.isFinite else { return }
        elapsed = accumulated + max(0, now - resumedAt)
        if let duration, elapsed >= duration { elapsed = duration; finish(anchor: anchor) }
    }
    public mutating func pause(now: TimeInterval, anchor: SourceAnchor?) {
        tick(now: now, anchor: anchor)
        guard status == .running else { return }
        accumulated = elapsed; resumedAt = nil; status = .paused
    }
    public mutating func resume(now: TimeInterval) {
        guard status == .paused, now.isFinite else { return }
        resumedAt = now; status = .running
    }
    public mutating func stop(now: TimeInterval, anchor: SourceAnchor?) {
        guard status == .running || status == .paused else { return }
        tick(now: now, anchor: anchor)
        guard status != .completed else { return }
        finish(anchor: anchor)
    }
    private mutating func finish(anchor: SourceAnchor?) {
        accumulated = elapsed; resumedAt = nil; endAnchor = anchor; status = .completed
    }
    public var remaining: TimeInterval? { duration.map { max(0, $0 - elapsed) } }
}
