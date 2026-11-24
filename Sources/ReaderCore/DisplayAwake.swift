import Foundation
import IOKit.pwr_mgt

/// Each reading window owns one assertion; closing it releases that window's hold.
public final class DisplayAwake {
    private var assertion: IOPMAssertionID = 0
    public var isActive: Bool { assertion != 0 }
    public init() {}
    public func setEnabled(_ enabled: Bool) throws {
        if enabled, !isActive {
            var candidate: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Adaptive Reader reading session" as CFString, &candidate)
            guard result == kIOReturnSuccess else { throw ReaderError.unsupportedCommand }
            assertion = candidate
        } else if !enabled { release() }
    }
    public func release() { if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 } }
    deinit { release() }
}
