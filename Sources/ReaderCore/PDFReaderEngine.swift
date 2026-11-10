import Foundation
import CryptoKit
@preconcurrency import PDFKit
import AppKit

@MainActor
public final class PDFReaderEngine: ReaderEngine {
    public let bookID: UUID
    public let sourceRevision: String
    public let document: PDFDocument
    public let view: PDFView
    private let documentDelegate: AdaptivePDFDelegate
    public private(set) var palette: PagePalette = .original

    public init(data: Data, bookID: UUID, password: String? = nil) throws {
        _ = NSApplication.shared
        guard let document = PDFDocument(data: data) else { throw ReaderError.unavailableSource }
        if document.isLocked, let password { _ = document.unlock(withPassword: password) }
        guard !document.isLocked else { throw ReaderError.lockedDocument }
        guard document.pageCount > 0 else { throw ReaderError.unavailableSource }
        self.bookID = bookID
        self.sourceRevision = Self.revision(data)
        self.document = document
        documentDelegate = AdaptivePDFDelegate()
        document.delegate = documentDelegate
        view = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 650))
        view.displayBox = .cropBox
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.document = document
    }

    public nonisolated static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var capabilities: Set<ReaderCapability> {
        var result: Set<ReaderCapability> = [.pageNavigation, .pagePalette, .zoom]
        if document.allowsCopying && (document.string?.isEmpty == false) { result.formUnion([.search, .textSelection]) }
        return result
    }

    public var colorSupport: PDFColorSupport {
        (view.currentPage as? AdaptivePDFPage)?.colorSupport ?? .missingText
    }

    public func currentAnchor() throws -> SourceAnchor {
        guard let destination = view.currentDestination, let page = destination.page else { throw ReaderError.invalidAnchor }
        let index = document.index(for: page)
        guard index != NSNotFound else { throw ReaderError.invalidAnchor }
        return SourceAnchor(bookID: bookID, sourceRevision: sourceRevision,
                            position: .pdf(PDFPosition(pageIndex: index,
                                x: min(max(destination.point.x, page.bounds(for: .cropBox).minX), page.bounds(for: .cropBox).maxX),
                                y: min(max(destination.point.y, page.bounds(for: .cropBox).minY), page.bounds(for: .cropBox).maxY))))
    }

    public func navigate(to anchor: SourceAnchor) throws {
        try anchor.validate(bookID: bookID, revision: sourceRevision)
        guard case .pdf(let position) = anchor.position else { throw ReaderError.unsupportedCommand }
        guard let page = document.page(at: position.pageIndex) else { throw ReaderError.invalidAnchor }
        let bounds = page.bounds(for: .cropBox)
        guard position.x >= bounds.minX, position.x <= bounds.maxX,
              position.y >= bounds.minY, position.y <= bounds.maxY else { throw ReaderError.invalidAnchor }
        view.go(to: PDFDestination(page: page, at: NSPoint(x: position.x, y: position.y)))
    }

    public func setScale(_ scale: Double) throws {
        guard scale.isFinite, scale >= view.minScaleFactor, scale <= view.maxScaleFactor else { throw ReaderError.unsupportedCommand }
        view.autoScales = false
        view.scaleFactor = scale
    }

    public func applyPagePalette(_ palette: PagePalette) throws {
        if palette != .original, let page = view.currentPage, let ref = page.pageRef,
           (page as? AdaptivePDFPage)?.colorSupport == .available,
           PDFColorRenderer.shared.cached(page: ref, id: "preflight-\(sourceRevision)-\(document.index(for: page))", palette: palette) == nil {
            throw ReaderError.unavailableSource
        }
        let anchor = try? currentAnchor()
        self.palette = palette
        let scale = view.scaleFactor, automatic = view.autoScales
        documentDelegate.setPalette(palette)
        view.document = nil
        view.document = document
        view.autoScales = automatic
        if !automatic { view.scaleFactor = scale }
        view.layoutDocumentView()
        if let anchor { try navigate(to: anchor) }
    }
}
