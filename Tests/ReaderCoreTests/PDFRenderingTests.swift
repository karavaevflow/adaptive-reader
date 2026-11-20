import Testing
import AppKit
import PDFKit
import CryptoKit
@testable import ReaderCore

private var renderingFixtures: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Research/Fixtures")
}

@MainActor
private func pagePixels(_ page: PDFPage) throws -> Data {
    let bounds = page.bounds(for: .cropBox)
    let context = try #require(CGContext(data: nil, width: 256, height: 332,
        bitsPerComponent: 8, bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 256, height: 332))
    context.scaleBy(x: 256 / bounds.width, y: 332 / bounds.height)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)
    // Exercise PDFKit's actual subclass construction and drawing, not just
    // the standalone Core Image renderer or the navigation counter.
    page.draw(with: .cropBox, to: context)
    let image = try #require(context.makeImage())
    return try #require(image.dataProvider?.data) as Data
}

@Test @MainActor
func pdfKitCreatedPagesKeepDistinctImagesAcrossPagesAndDocuments() throws {
    let engine = try PDFReaderEngine(data: Data(contentsOf: renderingFixtures.appendingPathComponent("text.pdf")), bookID: UUID())
    let other = try PDFReaderEngine(data: Data(contentsOf: renderingFixtures.appendingPathComponent("columns-table.pdf")), bookID: UUID())
    let pages = try (0..<3).map { try #require(engine.document.page(at: $0)) }
    for palette in [PagePalette.original, .midnight, .forest, .midnight] {
        try engine.applyPagePalette(palette)
        let signatures = try pages.map { SHA256.hash(data: try pagePixels($0)).description }
        #expect(Set(signatures).count == 3, "Every chapter must draw its own page in \(palette.rawValue)")
        try other.applyPagePalette(palette)
        let otherPage = try #require(other.document.page(at: 0))
        #expect(SHA256.hash(data: try pagePixels(otherPage)).description != signatures[0],
                "Different documents must not share a page-image cache entry")
    }
}

@Test @MainActor
func pdfKitCreatedPagesUseActualFallbackPolicy() throws {
    let renderer = PDFColorRenderer()
    for name in ["text.pdf", "chart.pdf", "scan.pdf", "photo-caption.pdf", "dark.pdf"] {
        let engine = try PDFReaderEngine(data: Data(contentsOf: renderingFixtures.appendingPathComponent(name)), bookID: UUID())
        let page = try #require(engine.document.page(at: 0) as? AdaptivePDFPage)
        let reference = try #require(page.pageRef)
        let expected = renderer.support(for: reference)
        #expect(page.colorSupport == expected, "PDFKit-created page must evaluate the actual source: \(name)")
        if expected != .available {
            let original = try pagePixels(page)
            try engine.applyPagePalette(.midnight)
            #expect(try pagePixels(page) == original, "Ineligible pages must preserve Original: \(name)")
        }
    }
}

@Test(arguments: [1, 2, 3, 4, 5], [300.0, 900.0]) @MainActor
func pdfRelativeNavigationAdvancesEverySpreadAndStopsAtEdges(pageCount: Int, viewportHeight: Double) throws {
    let source = try #require(PDFDocument(data: Data(contentsOf: renderingFixtures.appendingPathComponent("text.pdf"))))
    let fixture = PDFDocument()
    for index in 0..<pageCount {
        let page = try #require(source.page(at: index % source.pageCount)?.copy() as? PDFPage)
        fixture.insert(page, at: index)
    }
    let engine = try PDFReaderEngine(data: #require(fixture.dataRepresentation()), bookID: UUID())
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: viewportHeight),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = engine.view
    defer { window.close() }
    engine.view.autoScales = false
    engine.view.scaleFactor = 0.6
    for mode in [PDFDisplayMode.singlePage, .singlePageContinuous, .twoUp, .twoUpContinuous] {
        for bookStyle in [false, true] {
            engine.view.displayMode = mode
            engine.view.displaysAsBook = bookStyle
            engine.view.layoutDocumentView()
            let first = try #require(engine.document.page(at: 0))
            try engine.navigate(to: SourceAnchor(bookID: engine.bookID, sourceRevision: engine.sourceRevision,
                position: .pdf(.init(pageIndex: 0, x: 0, y: first.bounds(for: .cropBox).maxY))))
            let spread = mode == .twoUp || mode == .twoUpContinuous
            let sequence = spread ? (bookStyle ? [0] + Array(stride(from: 1, to: pageCount, by: 2)) : Array(stride(from: 0, to: pageCount, by: 2))) : Array(0..<pageCount)
            #expect(try engine.adjacentPage(-1) == nil)
            for expected in sequence.dropFirst() {
                let next = try #require(try engine.adjacentPage(1))
                guard case .pdf(let point) = next.position else { Issue.record("Expected PDF page"); return }
                #expect(point.pageIndex == expected)
                try engine.navigate(to: next)
            }
            #expect(try engine.adjacentPage(1) == nil)
            for expected in sequence.dropLast().reversed() {
                let previous = try #require(try engine.adjacentPage(-1))
                guard case .pdf(let point) = previous.position else { Issue.record("Expected PDF page"); return }
                #expect(point.pageIndex == expected)
                try engine.navigate(to: previous)
            }
            #expect(try engine.adjacentPage(-1) == nil)
        }
    }
}
