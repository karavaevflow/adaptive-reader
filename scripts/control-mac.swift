import AppKit
import Foundation
import Darwin
func hardware(_ key: String) -> String {
    var count = 0
    guard sysctlbyname(key, nil, &count, nil, 0) == 0 else { return "unknown" }
    var bytes = [CChar](repeating: 0, count: count)
    guard sysctlbyname(key, &bytes, &count, nil, 0) == 0 else { return "unknown" }
    return String(cString: bytes)
}
let screen = NSScreen.main!
let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())!
let data: [String: Any] = ["model": hardware("hw.model"), "chip": hardware("machdep.cpu.brand_string"),
 "memoryBytes": ProcessInfo.processInfo.physicalMemory, "os": ProcessInfo.processInfo.operatingSystemVersionString,
 "screenPoints": [screen.frame.width, screen.frame.height], "backingScaleFactor": screen.backingScaleFactor,
 "displayPixels": [mode.pixelWidth, mode.pixelHeight], "refreshHz": mode.refreshRate]
print(String(data: try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted,.sortedKeys]), encoding: .utf8)!)
