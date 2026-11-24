import AppKit
import PDFKit
import ReaderCore
import Darwin

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

/// Real PDFKit/WebKit surfaces and Vision work. This executable never initializes speech or an AI provider.
@main struct ExtendedResearch {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 4 else { throw ReaderError.unsupportedCommand }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), mode = CommandLine.arguments[2], pair = CommandLine.arguments[3]
        guard ["idle", "ocr", "cancel"].contains(mode), ["pdf-pdf", "pdf-epub"].contains(pair) else { throw ReaderError.unsupportedCommand }
        NSApplication.shared.setActivationPolicy(.accessory)
        let largeURL = root.appendingPathComponent("Research/Large/large-text.pdf")
        let leftData = try Data(contentsOf: largeURL), scanData = try Data(contentsOf: root.appendingPathComponent("Research/Fixtures/scan.pdf"))
        let rightURL = root.appendingPathComponent(pair == "pdf-pdf" ? "Research/Fixtures/scan.pdf" : "Research/Fixtures/EPUB/reflow.epub")
        let rightData = try Data(contentsOf: rightURL)
        let started = CFAbsoluteTimeGetCurrent()
        let left = try await ReaderEngineFactory.open(data: leftData, format: .pdf, bookID: UUID()) as! PDFReaderEngine
        let right = try await ReaderEngineFactory.open(data: rightData, format: pair == "pdf-pdf" ? .pdf : .epub, bookID: UUID())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 40, width: 1100, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1100, height: 680))
        left.view.frame = CGRect(x: 0, y: 0, width: 550, height: 680); container.addSubview(left.view)
        let rightView = (right as? PDFReaderEngine)?.view ?? (right as! EPUBReaderEngine).view
        rightView.frame = CGRect(x: 550, y: 0, width: 550, height: 680); container.addSubview(rightView)
        window.contentView = container; window.orderFrontRegardless()
        left.view.layoutDocumentView(); left.view.autoScales = true
        if let pdf = right as? PDFReaderEngine { pdf.view.layoutDocumentView(); pdf.view.autoScales = true }
        if let epub = right as? EPUBReaderEngine {
            epub.start()
            let deadline = Date().addingTimeInterval(10)
            while !epub.ready && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard epub.ready else { throw ReaderError.unavailableSource }
        }
        window.displayIfNeeded()
        let openMS = (CFAbsoluteTimeGetCurrent() - started) * 1000, initialRSS = residentBytes()
        var worker: DocumentOCR? = mode == "idle" ? nil : DocumentOCR()
        weak var workerProbe = worker
        var completed = mode == "idle", status = mode == "idle" ? "not-requested" : "running", ocrMS = 0.0, lineCount = 0
        let ocrStarted = CFAbsoluteTimeGetCurrent()
        var task: Task<Void, Never>?
        if let request = worker {
            task = Task { @MainActor in
                do {
                    let result = try await request.recognize(data: scanData, bookID: UUID(), revision: PDFReaderEngine.revision(scanData), pageIndex: 0)
                    lineCount = result.lines.count; status = "completed"
                } catch is CancellationError { status = "cancelled" }
                catch { status = "error: " + error.localizedDescription }
                ocrMS = (CFAbsoluteTimeGetCurrent() - ocrStarted) * 1000; completed = true
            }
        }
        var frames: [Double] = [], intervals: [Double] = [], overlapFrames = 0, last = CFAbsoluteTimeGetCurrent(), cancelStart: Double?
        guard let clip = left.view.documentView?.enclosingScrollView?.contentView else { throw ReaderError.unavailableSource }
        for index in 0..<120 {
            let begin = CFAbsoluteTimeGetCurrent(); intervals.append((begin - last) * 1000); last = begin
            if !completed { overlapFrames += 1 }
            if mode == "cancel", index == 6 { cancelStart = CFAbsoluteTimeGetCurrent(); worker?.cancel(); task?.cancel() }
            autoreleasepool {
                let maxY = max(1, left.view.documentView!.bounds.height - clip.bounds.height)
                clip.scroll(to: NSPoint(x: 0, y: maxY * Double(index) / 119)); clip.enclosingScrollView?.reflectScrolledClipView(clip)
                window.displayIfNeeded()
            }
            frames.append((CFAbsoluteTimeGetCurrent() - begin) * 1000)
            try await Task.sleep(for: .milliseconds(16))
        }
        await task?.value
        let cancelMS = cancelStart.map { max(0, ocrStarted + ocrMS / 1000 - $0) * 1000 } ?? 0
        worker = nil; task = nil
        try await Task.sleep(for: .milliseconds(100))
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = ["mode": mode, "pair": pair, "openMS": openMS, "initialRSSBytes": initialRSS,
            "finalRSSBytes": residentBytes(), "peakRSSBytes": usage.ru_maxrss, "cpuFrameMS": frames, "frameIntervalMS": intervals,
            "ocrMS": ocrMS, "ocrStatus": status, "recognizedLines": lineCount, "overlapFrames": overlapFrames,
            "cancellationMS": cancelMS, "workerReleased": workerProbe == nil,
            "leftRevision": left.sourceRevision, "rightRevision": right.sourceRevision, "ocrRevision": PDFReaderEngine.revision(scanData)]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        left.cancelSearch(); right.cancelSearch(); (right as? EPUBReaderEngine)?.stop(); window.close()
    }
}
