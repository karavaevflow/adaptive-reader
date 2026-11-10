import Foundation
import AppKit
import PDFKit
import CoreText
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import ReaderCore
import Darwin

func text(_ value: String, rect: CGRect, color: NSColor = .black, size: Double = 16, context: CGContext) {
    let string = NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
    CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string), CFRange(), CGPath(rect: rect, transform: nil), nil), context)
}
func png(_ image: CGImage, at url: URL) {
    let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, image, nil)
    precondition(CGImageDestinationFinalize(output))
}
func makePDF(_ url: URL, pages: Int = 1, draw: (CGContext, Int) -> Void) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    for index in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(box)
        draw(context, index)
        context.endPDFPage()
    }
    context.closePDF()
}
func generate(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let body = "Reading specimen. A stable anchor connects the reader to the original source.\n\nSelection, search and links belong to PDFKit. A page palette changes drawing without changing the document.\n\nThe engine can return to the same passage after closing the application."
    makePDF(directory.appendingPathComponent("text.pdf"), pages: 3) { context, page in
        text("Chapter \(page + 1)\n\n" + body, rect: CGRect(x: 64, y: 180, width: 484, height: 540), context: context)
        context.setURL(URL(string: "https://example.com/reading")! as CFURL, for: CGRect(x: 64, y: 160, width: 170, height: 20))
        text("Source link", rect: CGRect(x: 64, y: 150, width: 200, height: 25), color: .systemBlue, context: context)
    }
    makePDF(directory.appendingPathComponent("columns-table.pdf")) { context, _ in
        text("Two columns and a table", rect: CGRect(x: 48, y: 700, width: 510, height: 40), size: 24, context: context)
        for x in [48.0, 320.0] { text(body, rect: CGRect(x: x, y: 330, width: 240, height: 340), size: 13, context: context) }
        for row in 0...4 {
            let y = 100 + row * 45
            context.setStrokeColor(NSColor.darkGray.cgColor)
            context.stroke(CGRect(x: 48, y: y, width: 510, height: 45))
            text("Row \(row + 1)        Source        Position", rect: CGRect(x: 60, y: y + 8, width: 480, height: 28), size: 13, context: context)
        }
    }
    makePDF(directory.appendingPathComponent("chart.pdf")) { context, _ in
        text("Color chart\n\nNeutral text should adapt. Colored bars should retain their hue.", rect: CGRect(x: 64, y: 550, width: 480, height: 180), context: context)
        for (index, color) in [NSColor.red, .green, .blue].enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 80 + index * 160, y: 160, width: 100, height: 160 + index * 55))
        }
    }
    makePDF(directory.appendingPathComponent("dark.pdf")) { context, _ in
        context.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
        text("An originally dark page\n\n" + body, rect: CGRect(x: 64, y: 100, width: 484, height: 620), color: .white, context: context)
    }
    let source = CGPDFDocument(directory.appendingPathComponent("text.pdf") as CFURL)!
    let scan = PDFColorRenderer.shared.original(page: source.page(at: 1)!)!
    makePDF(directory.appendingPathComponent("scan.pdf")) { context, _ in context.draw(scan, in: CGRect(x: 0, y: 0, width: 612, height: 792)) }
    let nasa = CGPDFDocument(directory.appendingPathComponent("nasa-apollo-earth.pdf") as CFURL)!
    let photo = PDFColorRenderer.shared.original(page: nasa.page(at: 1)!)!
    makePDF(directory.appendingPathComponent("photo-caption.pdf")) { context, _ in
        context.draw(photo, in: CGRect(x: 64, y: 230, width: 484, height: 440))
        text("Apollo 17 Earth photograph. Credit NASA.\nColor-preservation fixture, derived from the NASA lithograph.", rect: CGRect(x: 64, y: 100, width: 484, height: 90), context: context)
    }
    let protected = PDFDocument(url: directory.appendingPathComponent("text.pdf"))!
    precondition(protected.write(to: directory.appendingPathComponent("protected.pdf"), withOptions: [
        .userPasswordOption: "phase0", .ownerPasswordOption: "phase0-owner"
    ]))
}

let args = CommandLine.arguments
if args.count > 1 && args[1] == "scroll" {
    let url = URL(fileURLWithPath: args[2])
    let data = try Data(contentsOf: url)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let start = CFAbsoluteTimeGetCurrent()
    let engine = try PDFReaderEngine(data: data, bookID: UUID(), password: url.lastPathComponent == "protected.pdf" ? "phase0" : nil)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 40, width: 800, height: 650),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = engine.view
    window.orderFrontRegardless()
    engine.view.layoutDocumentView()
    try engine.applyPagePalette(args[3] == "selected" ? .midnight : .original)
    window.displayIfNeeded()
    let openMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
    let clip = engine.view.documentView!.enclosingScrollView!.contentView
    var frames = [Double](), intervals = [Double](), last = CFAbsoluteTimeGetCurrent()
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
        MainActor.assumeIsolated {
            let begin = CFAbsoluteTimeGetCurrent()
            intervals.append((begin - last) * 1000)
            last = begin
            let maxY = max(1, engine.view.documentView!.bounds.height - clip.bounds.height)
            let phase = Double(frames.count % 120) / 119
            clip.scroll(to: NSPoint(x: 0, y: maxY * phase))
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
            window.displayIfNeeded()
            frames.append((CFAbsoluteTimeGetCurrent() - begin) * 1000)
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    while frames.count < 120 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    timer.invalidate()
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    let result: [String: Any] = ["fixture": url.lastPathComponent, "mode": args[3],
        "openMS": openMS, "cpuFrameMS": frames, "frameIntervalMS": intervals,
        "peakRSSBytes": usage.ru_maxrss]
    print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    window.close()
} else if args.count > 1 && args[1] == "measure" {
    let url = URL(fileURLWithPath: args[2]), mode = args[3]
    let document = CGPDFDocument(url as CFURL)!
    if !document.isUnlocked { precondition(document.unlockWithPassword("phase0")) }
    let page = document.page(at: 1)!
    let renderer = PDFColorRenderer()
    let support = renderer.support(for: page)
    func draw() -> CGImage {
        if mode == "original" || (mode == "selected" && support != .available) { return renderer.original(page: page)! }
        return renderer.render(page: page, palette: .midnight, selective: mode == "selected")!
    }
    let first = CFAbsoluteTimeGetCurrent()
    let image = draw()
    let firstMS = (CFAbsoluteTimeGetCurrent() - first) * 1000
    let repeatStart = CFAbsoluteTimeGetCurrent()
    _ = draw()
    let repeatMS = (CFAbsoluteTimeGetCurrent() - repeatStart) * 1000
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    if args.count > 4 { png(image, at: URL(fileURLWithPath: args[4])) }
    let bytes = image.dataProvider!.data! as Data
    let result: [String: Any] = ["fixture": url.lastPathComponent, "mode": mode, "support": support.rawValue,
        "firstMS": firstMS, "repeatMS": repeatMS, "peakRSSBytes": usage.ru_maxrss,
        "pixelSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
    print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
} else {
    let root = URL(fileURLWithPath: args.count > 1 ? args[1] : "Research", isDirectory: true)
    let fixtures = root.appendingPathComponent("Fixtures"), results = root.appendingPathComponent("Results")
    if !FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("text.pdf").path) { try generate(fixtures) }
    try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
    let files = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil).filter { $0.pathExtension == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    var rows = [[String: Any]]()
    var manifest = [String: String]()
    for file in files {
        manifest[file.lastPathComponent] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        for mode in ["original", "invert", "selected"] {
            for run in 1...5 {
                let child = Process(), output = Pipe()
                child.executableURL = URL(fileURLWithPath: args[0])
                child.arguments = ["measure", file.path, mode]
                if run == 1 { child.arguments!.append(results.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent)-\(mode).png").path) }
                child.standardOutput = output
                try child.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                child.waitUntilExit()
                precondition(child.terminationStatus == 0)
                var row = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                row["run"] = run
                rows.append(row)
            }
        }
        print("Measured \(file.lastPathComponent)")
    }
    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: results.appendingPathComponent("measurements.json"))
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checksums.json"))
}
