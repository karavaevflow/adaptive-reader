import Foundation
import CryptoKit
@preconcurrency import PDFKit
import AppKit
import Observation
import Combine

@MainActor
@Observable
public final class PDFReaderEngine: ReaderEngine {
    public let bookID: UUID
    public let sourceRevision: String
    @ObservationIgnored public let document: PDFDocument
    @ObservationIgnored public let view: PDFView
    @ObservationIgnored private let documentDelegate: AdaptivePDFDelegate
    public private(set) var palette: PagePalette = .original

    public convenience init(data: Data, bookID: UUID, password: String? = nil) throws {
        try self.init(source: PreparedPDFSource(data: data), bookID: bookID, password: password)
    }

    public init(source: PreparedPDFSource, bookID: UUID, password: String? = nil) throws {
        let data = source.data
        _ = NSApplication.shared
        guard let document = PDFDocument(data: data) else { throw ReaderError.unavailableSource }
        if document.isLocked, let password { _ = document.unlock(withPassword: password) }
        guard !document.isLocked else { throw ReaderError.lockedDocument }
        guard document.pageCount > 0 else { throw ReaderError.unavailableSource }
        self.bookID = bookID
        self.sourceRevision = source.revision
        self.document = document
        documentDelegate = AdaptivePDFDelegate()
        document.delegate = documentDelegate
        self.hasText = document.page(at: 0)?.string?.isEmpty == false
        view = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 650))
        view.setAccessibilityIdentifier("reader.document")
        view.displayBox = .cropBox
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.document = document
    }

    public nonisolated static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public private(set) var hasText = false
    public func updateTextAvailability(_ available: Bool) { hasText = available }

    public var capabilities: Set<ReaderCapability> {
        var result: Set<ReaderCapability> = [.pageNavigation, .pagePalette, .zoom]
        if document.allowsCopying && hasText { result.formUnion([.search, .textSelection]) }
        return result
    }

    @ObservationIgnored private var searchObservers = Set<AnyCancellable>()
    @ObservationIgnored private var searchContinuation: AsyncThrowingStream<ReaderSearchMatch, Error>.Continuation?
    @ObservationIgnored private var searchSelections: [UUID: PDFSelection] = [:]
    @ObservationIgnored private var searchToken = UUID()

    public func search(_ query: String) throws -> AsyncThrowingStream<ReaderSearchMatch, Error> {
        guard capabilities.contains(.search) else { throw ReaderError.unsupportedCommand }
        cancelSearch()
        searchSelections.removeAll()
        let token = UUID(); searchToken = token
        let pair = AsyncThrowingStream<ReaderSearchMatch, Error>.makeStream()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pair.continuation.finish(); return pair.stream
        }
        searchContinuation = pair.continuation
        pair.continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason {
                Task { @MainActor in if self?.searchToken == token { self?.cancelSearch() } }
            }
        }
        let center = NotificationCenter.default
        center.publisher(for: .PDFDocumentDidFindMatch, object: document).receive(on: RunLoop.main).sink { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.searchToken == token, self.searchContinuation != nil, self.searchSelections.count < 1000,
                      let selection = notification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection,
                      let page = selection.pages.first else { return }
                let box = page.bounds(for: .cropBox), bounds = selection.bounds(for: page)
                guard bounds.minY.isFinite, bounds.maxY.isFinite else { return }
                let anchor = SourceAnchor(bookID: self.bookID, sourceRevision: self.sourceRevision,
                    position: .pdf(.init(pageIndex: self.document.index(for: page), x: box.minX, y: min(box.maxY, bounds.maxY + 20))))
                let context = selection.copy() as? PDFSelection
                context?.extend(atStart: 40); context?.extend(atEnd: 80)
                let snippet = String((context?.string ?? selection.string ?? query).prefix(180))
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let match = ReaderSearchMatch(anchor: anchor, snippet: snippet)
                self.searchSelections[match.id] = selection
                self.searchContinuation?.yield(match)
                if self.searchSelections.count >= 1000 {
                    self.searchContinuation?.finish(); self.searchContinuation = nil
                    self.document.cancelFindString()
                }
            }
        }.store(in: &searchObservers)
        center.publisher(for: .PDFDocumentDidEndFind, object: document).receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.searchToken == token else { return }
                self?.searchContinuation?.finish(); self?.searchContinuation = nil
            }
        }.store(in: &searchObservers)
        document.beginFindString(query, withOptions: .caseInsensitive)
        return pair.stream
    }
    public func cancelSearch() {
        searchToken = UUID()
        searchObservers.removeAll()
        searchSelections.removeAll()
        document.cancelFindString()
        searchContinuation?.finish(); searchContinuation = nil
    }
    public func showSearchMatch(_ match: ReaderSearchMatch) throws {
        try navigate(to: match.anchor)
        if let selection = searchSelections[match.id] {
            view.setCurrentSelection(selection, animate: false)
            view.scrollSelectionToVisible(nil)
        }
    }

    public var colorSupport: PDFColorSupport {
        ((view.currentDestination?.page ?? view.currentPage) as? AdaptivePDFPage)?.colorSupport ?? .missingText
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
        if palette != .original, let page = view.currentDestination?.page ?? view.currentPage, let ref = page.pageRef,
           (page as? AdaptivePDFPage)?.colorSupport == .available,
           PDFColorRenderer.shared.cached(page: ref, id: "preflight-\(sourceRevision)-\(document.index(for: page))", palette: palette) == nil {
            throw ReaderError.unavailableSource
        }
        let anchor = try? currentAnchor()
        let selection = view.currentSelection, highlights = view.highlightedSelections
        self.palette = palette
        let scale = view.scaleFactor, automatic = view.autoScales
        documentDelegate.setPalette(palette)
        view.document = nil
        view.document = document
        view.autoScales = automatic
        if !automatic { view.scaleFactor = scale }
        view.layoutDocumentView()
        if let anchor { try navigate(to: anchor) }
        view.setCurrentSelection(selection, animate: false)
        view.highlightedSelections = highlights
    }
}
