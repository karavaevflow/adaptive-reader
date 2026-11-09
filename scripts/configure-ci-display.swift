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
var configuration: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
    fputs("Could not begin CI display configuration.\n", stderr)
    exit(1)
}
guard CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil) == .success else {
    CGCancelDisplayConfiguration(configuration)
    fputs("Could not select CI display mode.\n", stderr)
    exit(1)
}
let result = CGCompleteDisplayConfiguration(configuration, .forSession)
guard result == .success else {
    fputs("Could not retain the CI display mode for the session: \(result.rawValue)\n", stderr)
    exit(1)
}
let bounds = CGDisplayBounds(display)
print("CI display bounds: \(bounds.width) × \(bounds.height).")
guard bounds.width >= 1440, bounds.height >= 900 else {
    fputs("CI display bounds remain too small for the visual matrix.\n", stderr)
    exit(1)
}
