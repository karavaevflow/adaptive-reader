import Foundation

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
    case textSelection, search, pageNavigation, reflow
}

@MainActor
public protocol ReaderEngine: AnyObject {
    var bookID: UUID { get }
    var sourceRevision: String { get }
    var capabilities: Set<ReaderCapability> { get }
    func currentAnchor() throws -> SourceAnchor
    func navigate(to anchor: SourceAnchor) throws
}

public enum PagePalette: String, Codable, CaseIterable, Sendable {
    case original, paper, dusk, midnight, forest
}

public enum ApplicationCommand: Sendable {
    case navigate(SourceAnchor)
    case setPalette(PagePalette)
}

@MainActor
public final class ReaderCommands {
    public let engine: any ReaderEngine
    public private(set) var palette: PagePalette = .original
    private var paletteHistory: [PagePalette] = []

    public init(engine: any ReaderEngine) { self.engine = engine }

    public func perform(_ command: ApplicationCommand) throws {
        switch command {
        case .navigate(let anchor):
            try anchor.validate(bookID: engine.bookID, revision: engine.sourceRevision)
            try engine.navigate(to: anchor)
        case .setPalette(let palette):
            paletteHistory.append(self.palette)
            self.palette = palette
        }
    }

    public func undoPalette() {
        if let previous = paletteHistory.popLast() { palette = previous }
    }
}
