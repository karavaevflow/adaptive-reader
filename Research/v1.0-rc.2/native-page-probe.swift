import AppKit
import PDFKit
import ReaderCore
import CryptoKit
import Darwin

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: input)
let began = ProcessInfo.processInfo.systemUptime
let engine = try PDFReaderEngine(data: data, bookID: UUID())
NSApp.setActivationPolicy(.prohibited)
let palette: PagePalette = CommandLine.arguments[2] == "original" ? .original : .midnight
try engine.applyPagePalette(palette)
let readyMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
func draw(_ page: PDFPage) -> (String, Double) {
    let began = ProcessInfo.processInfo.systemUptime
    let box = page.bounds(for: .cropBox)
    let context = CGContext(data: nil, width: 512, height: 664, bitsPerComponent: 8,
        bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 512, height: 664))
    context.scaleBy(x: 512 / box.width, y: 664 / box.height)
    context.translateBy(x: -box.minX, y: -box.minY)
    page.draw(with: .cropBox, to: context)
    let pixels = context.makeImage()!.dataProvider!.data! as Data
    let hash = SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
    return (hash, (ProcessInfo.processInfo.systemUptime - began) * 1000)
}
let pages = (0..<3).map { engine.document.page(at: $0)! }
let first = pages.map(draw), repeated = pages.map(draw)
precondition(Set(first.map(\.0)).count == 3, "Distinct source chapters must render differently")
precondition(first.map(\.0) == repeated.map(\.0), "Repeat draws must preserve each page")
var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
let value: [String: Any] = ["palette": palette.rawValue, "fixtureSHA256": PDFReaderEngine.revision(data),
    "readyMS": readyMS, "firstDrawMS": first.map(\.1), "repeatDrawMS": repeated.map(\.1),
    "pagePixelsSHA256": first.map(\.0), "distinctPages": 3, "peakClientRSSBytes": usage.ru_maxrss]
print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
