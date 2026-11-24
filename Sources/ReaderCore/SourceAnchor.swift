import Foundation
import Observation

/// Coordinates use the PDF page's unrotated crop-box coordinate system.
public struct PDFPosition: Codable, Equatable, Sendable {
    public let pageIndex: Int
    public let x: Double
    public let y: Double

    public init(pageIndex: Int, x: Double, y: Double) {
        self.pageIndex = pageIndex
        self.x = x
        self.y = y
    }
}

public enum DocumentPosition: Codable, Equatable, Sendable {
    case pdf(PDFPosition)
    case epub(resource: String, locator: String)
}

public struct SourceAnchor: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let bookID: UUID
    public let sourceRevision: String
    public let position: DocumentPosition

    public init(bookID: UUID, sourceRevision: String, position: DocumentPosition) {
        schemaVersion = 1
        self.bookID = bookID
        self.sourceRevision = sourceRevision
        self.position = position
    }

    public func validate(bookID: UUID, revision: String) throws {
        guard schemaVersion == 1 else { throw ReaderError.unsupportedAnchorVersion }
        guard self.bookID == bookID, sourceRevision == revision else {
            throw ReaderError.sourceChanged
        }
        switch position {
        case .pdf(let point):
            guard point.pageIndex >= 0, point.x.isFinite, point.y.isFinite else {
                throw ReaderError.invalidAnchor
            }
        case .epub(let resource, let locator):
            guard !resource.isEmpty, !locator.isEmpty else { throw ReaderError.invalidAnchor }
        }
    }
}

public enum ReaderError: Error, Equatable {
    case unavailableSource, sourceChanged, invalidAnchor, unsupportedAnchorVersion
    case unsupportedCommand, lockedDocument
}

public enum ReaderCapability: String, Codable, Sendable {
    case textSelection, search, pageNavigation, reflow, pagePalette, zoom, readingFocus, continuousScroll, passageNavigation
}

@MainActor
public protocol ReaderEngine: AnyObject {
    var bookID: UUID { get }
    var sourceRevision: String { get }
    var capabilities: Set<ReaderCapability> { get }
    var palette: PagePalette { get }
    func currentAnchor() throws -> SourceAnchor
    func navigate(to anchor: SourceAnchor) throws
    func search(_ query: String) throws -> AsyncThrowingStream<ReaderSearchMatch, Error>
    func cancelSearch()
    func showSearchMatch(_ match: ReaderSearchMatch) throws
    func setScale(_ scale: Double) throws
    func applyPagePalette(_ palette: PagePalette) throws
    func setSpotlight(_ enabled: Bool) throws
    func stepSpotlight(_ direction: Int) throws
    func scroll(by points: Double) throws -> Bool
    func adjacentPassage(_ direction: Int) throws -> SourceAnchor
}

public extension ReaderEngine {
    var palette: PagePalette { .original }
    func setSpotlight(_ enabled: Bool) throws { throw ReaderError.unsupportedCommand }
    func stepSpotlight(_ direction: Int) throws { throw ReaderError.unsupportedCommand }
    func scroll(by points: Double) throws -> Bool { throw ReaderError.unsupportedCommand }
    func adjacentPassage(_ direction: Int) throws -> SourceAnchor { throw ReaderError.unsupportedCommand }
    func search(_ query: String) throws -> AsyncThrowingStream<ReaderSearchMatch, Error> { throw ReaderError.unsupportedCommand }
    func cancelSearch() {}
    func showSearchMatch(_ match: ReaderSearchMatch) throws { try navigate(to: match.anchor) }
    func setScale(_ scale: Double) throws { throw ReaderError.unsupportedCommand }
    func applyPagePalette(_ palette: PagePalette) throws { throw ReaderError.unsupportedCommand }
}

public enum PagePalette: String, Codable, CaseIterable, Sendable {
    case original, paper, dusk, midnight, forest
}

public enum ApplicationCommand: Sendable {
    case navigate(SourceAnchor)
    case setPalette(PagePalette)
    case setScale(Double)
    case showSearchMatch(ReaderSearchMatch)
    case back, forward
    case setSpotlight(Bool), stepSpotlight(Int), advancePassage(Int)
}

@MainActor
@Observable
public final class ReaderCommands {
    public let engine: any ReaderEngine
    public private(set) var palette: PagePalette = .original
    private var paletteHistory: [PagePalette] = []
    private var backStack: [SourceAnchor] = []
    private var forwardStack: [SourceAnchor] = []
    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }
    private func remember(_ origin: SourceAnchor?) {
        if let origin { backStack.append(origin); if backStack.count > 100 { backStack.removeFirst() } }
        forwardStack.removeAll()
    }

    public init(engine: any ReaderEngine) { self.engine = engine; palette = engine.palette }

    public func perform(_ command: ApplicationCommand) throws {
        switch command {
        case .navigate(let anchor):
            guard engine.capabilities.contains(.pageNavigation) || engine.capabilities.contains(.reflow) else { throw ReaderError.unsupportedCommand }
            try anchor.validate(bookID: engine.bookID, revision: engine.sourceRevision)
            let origin = try? engine.currentAnchor()
            try engine.navigate(to: anchor)
            remember(origin)
        case .showSearchMatch(let match):
            guard engine.capabilities.contains(.pageNavigation) || engine.capabilities.contains(.reflow) else { throw ReaderError.unsupportedCommand }
            try match.anchor.validate(bookID: engine.bookID, revision: engine.sourceRevision)
            let origin = try? engine.currentAnchor()
            try engine.showSearchMatch(match)
            remember(origin)
        case .advancePassage(let direction):
            guard engine.capabilities.contains(.passageNavigation), direction == 1 || direction == -1 else { throw ReaderError.unsupportedCommand }
            let next = try engine.adjacentPassage(direction)
            if next != (try? engine.currentAnchor()) { try perform(.navigate(next)) }
        case .setSpotlight(let enabled):
            guard engine.capabilities.contains(.readingFocus) else { throw ReaderError.unsupportedCommand }
            try engine.setSpotlight(enabled)
        case .stepSpotlight(let direction):
            guard engine.capabilities.contains(.readingFocus), (direction == 1 || direction == -1) else { throw ReaderError.unsupportedCommand }
            try engine.stepSpotlight(direction)
        case .back:
            guard let target = backStack.last else { return }
            let current = try engine.currentAnchor()
            try engine.navigate(to: target)
            backStack.removeLast(); forwardStack.append(current)
        case .forward:
            guard let target = forwardStack.last else { return }
            let current = try engine.currentAnchor()
            try engine.navigate(to: target)
            forwardStack.removeLast(); backStack.append(current)
        case .setScale(let scale):
            guard engine.capabilities.contains(.zoom) else { throw ReaderError.unsupportedCommand }
            try engine.setScale(scale)
        case .setPalette(let palette):
            guard engine.capabilities.contains(.pagePalette) else { throw ReaderError.unsupportedCommand }
            try engine.applyPagePalette(palette)
            paletteHistory.append(self.palette)
            self.palette = palette
        }
    }

    public func search(_ query: String) throws -> AsyncThrowingStream<ReaderSearchMatch, Error> {
        guard engine.capabilities.contains(.search) else { throw ReaderError.unsupportedCommand }
        return try engine.search(query)
    }

    public var canUndoPalette: Bool { !paletteHistory.isEmpty }

    public func undoPalette() throws {
        guard let previous = paletteHistory.last else { return }
        try engine.applyPagePalette(previous)
        palette = previous
        paletteHistory.removeLast()
    }
}

extension ReaderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailableSource: "The document is unavailable or could not be opened."
        case .sourceChanged: "The source changed. Import the document again to create a new revision."
        case .invalidAnchor: "This reading position is unavailable."
        case .unsupportedAnchorVersion: "This record was created by an unsupported version."
        case .unsupportedCommand: "This document does not support that action."
        case .lockedDocument: "Unlock this PDF before importing it."
        }
    }
}
