import AppKit
import Combine
import Observation

/// One scoped timer drives scrolling, sessions and ambient changes for a reader.
@MainActor @Observable
final class ReadingActivityDriver {
    private var interval: TimeInterval?
    @ObservationIgnored private var registration: AnyCancellable?
    @ObservationIgnored private var lastTick = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored var onTick: ((TimeInterval, TimeInterval, Date) -> Void)?
    var isRunning: Bool { interval != nil }
    func update(interval requested: TimeInterval?) {
        guard requested != interval else { return }
        registration?.cancel(); registration = nil; interval = requested
        guard let requested else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: requested, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let delta = min(0.1, max(0, now - self.lastTick)); self.lastTick = now
                self.onTick?(now, delta, Date())
            }
        }
        timer.tolerance = requested < 0.1 ? 0.002 : 0.1
        RunLoop.main.add(timer, forMode: .common)
        registration = AnyCancellable { timer.invalidate() }
    }
}
