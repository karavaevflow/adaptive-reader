import AppKit
import CoreGraphics

// Supplemental cold-process / fresh-library launch metric. Does not flush OS caches.
// Unique signed QA identities preserve the owner's production library/preferences.
enum LaunchFailure: Error { case arguments, existingOutput, process, window, identity, termination }
@MainActor func command(_ executable: String, _ arguments: [String]) throws -> Data {
    let process=Process(), pipe=Pipe(); process.executableURL=URL(fileURLWithPath:executable);process.arguments=arguments;process.standardOutput=pipe
    try process.run();let result=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
    guard process.terminationStatus==0 else { throw LaunchFailure.process };return result
}
@MainActor func hasWindow(_ pid: pid_t) -> Bool {
    guard let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return false }
    return windows.contains { row in
        guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid,
              (row[kCGWindowLayer as String] as? NSNumber)?.intValue==0,
              let bounds=row[kCGWindowBounds as String] as? [String:Any],let rect=CGRect(dictionaryRepresentation:bounds as CFDictionary) else { return false }
        return rect.width>=400 && rect.height>=200
    }
}
@MainActor func measure() async throws {
    guard CommandLine.arguments.count==5 else { throw LaunchFailure.arguments }
    let app=URL(fileURLWithPath:CommandLine.arguments[1]),repo=URL(fileURLWithPath:CommandLine.arguments[2]),output=URL(fileURLWithPath:CommandLine.arguments[4])
    guard !FileManager.default.fileExists(atPath:output.path) else { throw LaunchFailure.existingOutput }
    let sourceInfo=try PropertyListSerialization.propertyList(from:Data(contentsOf:app.appendingPathComponent("Contents/Info.plist")),format:nil) as! [String:Any]
    guard sourceInfo["CFBundleIdentifier"] as? String=="com.karavaevflow.AdaptiveReader" else { throw LaunchFailure.identity }
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    var rows=[[String:Any]]()
    let start=ISO8601DateFormatter().string(from:Date())
    for run in 1...5 {
        let id="com.karavaevflow.AdaptiveReader.ReleaseQA."+UUID().uuidString
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("Adaptive-Launch-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let copy=folder.appendingPathComponent("AdaptiveReader.app")
        _ = try command("/usr/bin/ditto",[app.path,copy.path])
        var info=sourceInfo;info["CFBundleIdentifier"]=id
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:copy.appendingPathComponent("Contents/Info.plist"),options:.atomic)
        _ = try command("/usr/bin/codesign",["--force","--sign","-","--entitlements",repo.appendingPathComponent("Sources/AdaptiveReader/AdaptiveReader.entitlements").path,copy.path])
        let configuration=NSWorkspace.OpenConfiguration();configuration.activates=false;configuration.createsNewApplicationInstance=true
        configuration.arguments=["-AppleLanguages","(en)","-AppleLocale","en"]
        let began=ProcessInfo.processInfo.systemUptime
        let process=try await NSWorkspace.shared.openApplication(at:copy,configuration:configuration)
        guard process.bundleIdentifier==id else { throw LaunchFailure.identity }
        defer { if !process.isTerminated { process.terminate() } }
        while !hasWindow(process.processIdentifier) && ProcessInfo.processInfo.systemUptime-began<15 {
            guard !process.isTerminated else { throw LaunchFailure.process };try await Task.sleep(for:.milliseconds(10))
        }
        guard hasWindow(process.processIdentifier) else { throw LaunchFailure.window }
        let elapsed=(ProcessInfo.processInfo.systemUptime-began)*1000
        let rss=String(decoding:try command("/bin/ps",["-o","rss=","-p",String(process.processIdentifier)]),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        guard let memory=UInt64(rss),memory>0 else { throw LaunchFailure.process }
        rows.append(["run":run,"firstWindowMS":elapsed,"firstWindowRSSBytes":memory*1024,"qaBundleIdentifier":id])
        guard process.terminate() else { throw LaunchFailure.termination }
        let stopping=ProcessInfo.processInfo.systemUptime
        while !process.isTerminated && ProcessInfo.processInfo.systemUptime-stopping<10 { try await Task.sleep(for:.milliseconds(20)) }
        guard process.isTerminated else { throw LaunchFailure.termination }
        try await Task.sleep(for:.milliseconds(500))
    }
    let result:[String:Any] = ["sourceCommit":CommandLine.arguments[3],"startedUTC":start,"finishedUTC":ISO8601DateFormatter().string(from:Date()),"method":"First layer-0 WindowServer window >=400x200 pt; fresh process/library, inactive QA identity; OS caches not flushed; one RSS sample after window","runs":rows]
    try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
    print("Completed five isolated launches")
}
try await measure()
