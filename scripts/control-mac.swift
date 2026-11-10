import AppKit
import Foundation
let screen = NSScreen.main!
let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())!
let data: [String: Any] = ["model": "MacBookAir10,1", "chip": "Apple M1", "memoryBytes": ProcessInfo.processInfo.physicalMemory,
 "os": ProcessInfo.processInfo.operatingSystemVersionString, "screenPoints": [screen.frame.width, screen.frame.height],
 "backingScaleFactor": screen.backingScaleFactor, "displayPixels": [mode.pixelWidth, mode.pixelHeight], "refreshHz": mode.refreshRate]
print(String(data: try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted,.sortedKeys]), encoding: .utf8)!)
