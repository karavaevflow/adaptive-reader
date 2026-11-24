import Foundation

/// Format-independent search evidence. Native selections stay inside the engine.
public struct ReaderSearchMatch: Identifiable, Sendable {
    public let id: UUID
    public let anchor: SourceAnchor
    public let snippet: String
    public init(anchor: SourceAnchor, snippet: String) { id = UUID(); self.anchor = anchor; self.snippet = snippet }
}
