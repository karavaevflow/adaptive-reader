import CoreGraphics
import Foundation

// The visual matrix needs a logical desktop large enough for a 1440 pt window.
let display = CGMainDisplayID()
let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode],
      let mode = modes.filter({ $0.width >= 1440 && $0.height >= 900 })
        .min(by: { $0.width * $0.height < $1.width * $1.height }) else {
    fputs("The CI display has no mode large enough for the 1440 pt visual matrix.\n", stderr)
    exit(1)
}
let result = CGDisplaySetDisplayMode(display, mode, nil)
guard result == .success else {
    fputs("Could not configure the CI display: \(result.rawValue)\n", stderr)
    exit(1)
}
print("CI desktop configured to \(mode.width) × \(mode.height) logical pixels.")
