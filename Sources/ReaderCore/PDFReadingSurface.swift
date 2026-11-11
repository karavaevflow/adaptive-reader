import AppKit
import PDFKit
import Combine

/// Native PDFKit owns selection and links; the overlay never consumes input or text accessibility.
@MainActor
final class PDFReadingView: PDFView {
    var internalNavigation: ((PDFDestination) -> Void)?
    var manualInteraction: (() -> Void)?
    var focusPoint: ((NSPoint) -> Void)?
    var focusStep: ((Int) -> Void)?
    private var monitor: AnyCancellable?
    private var spotlightTracking: NSTrackingArea?
    let spotlight = ReadingSpotlightOverlay(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        spotlight.autoresizingMask = [.width, .height]
        spotlight.frame = bounds; spotlight.isHidden = true
        addSubview(spotlight)
        let token = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .keyDown, .mouseMoved]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, event.window === window else { return false }
                let point = self.convert(event.locationInWindow, from: nil)
                let inside = self.bounds.contains(point)
                if (event.type == .mouseMoved || event.type == .leftMouseDown), inside, !self.spotlight.isHidden { self.focusPoint?(point) }
                if inside && [.scrollWheel, .leftMouseDown, .leftMouseDragged].contains(event.type) { self.manualInteraction?() }
                if event.type == .keyDown, let responder = window.firstResponder as? NSView,
                   responder === self || responder.isDescendant(of: self) {
                    self.manualInteraction?()
                    if event.modifierFlags.intersection([.option, .command, .control, .shift]) == .option, [125, 126].contains(event.keyCode), !self.spotlight.isHidden {
                        self.focusStep?(event.keyCode == 125 ? 1 : -1); return true
                    }
                }
                return false
            }
            return consumed ? nil : event
        }
        if let token { monitor = AnyCancellable { NSEvent.removeMonitor(token) } }
    }
    required init?(coder: NSCoder) { fatalError("Programmatic PDF surface") }
    override func perform(_ action: PDFAction) {
        if let go = action as? PDFActionGoTo, let internalNavigation { internalNavigation(go.destination) }
        else { super.perform(action) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let spotlightTracking { removeTrackingArea(spotlightTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved], owner: self)
        spotlightTracking = area; addTrackingArea(area)
    }
    override func layout() {
        super.layout(); spotlight.frame = bounds
        if subviews.last !== spotlight { spotlight.removeFromSuperview(); addSubview(spotlight, positioned: .above, relativeTo: nil) }
    }
}

@MainActor
final class ReadingSpotlightOverlay: NSView {
    override var isFlipped: Bool { superview?.isFlipped ?? false }
    var focusRect = NSRect.zero { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        if !focusRect.isEmpty { path.append(NSBezierPath(roundedRect: focusRect, xRadius: 5, yRadius: 5)) }
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.18).setFill(); path.fill()
    }
}
