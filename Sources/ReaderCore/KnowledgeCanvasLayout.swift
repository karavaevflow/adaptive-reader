import Foundation

public struct KnowledgeCanvasConnection: Sendable, Identifiable {
    public let id: UUID
    public let start: CanvasPoint
    public let end: CanvasPoint
    public let label: String
}
/// Shared viewport calculation used by the SwiftUI canvas and Release harness.
/// Lookup and culling are linear, independent of the number of offscreen card views.
public struct KnowledgeCanvasLayout: Sendable {
    public let cards: [UUID: KnowledgeCard]
    public let visibleNodes: [CanvasNode]
    public let centers: [UUID: CanvasPoint]
    public let connections: [KnowledgeCanvasConnection]
    public init(board: KnowledgeBoard, cards: [KnowledgeCard], origin: CanvasPoint, zoom: Double,
                viewport: CanvasPoint, query: String = "", translations: [UUID: CanvasPoint] = [:]) {
        self.cards = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var centers: [UUID: CanvasPoint] = [:], visible: [CanvasNode] = [], connections: [KnowledgeCanvasConnection] = []
        let scale = zoom.isFinite ? min(2, max(0.25, zoom)) : 1
        let halfWidth = 125 * scale, halfHeight = 75 * scale
        for node in board.nodes {
            let translation = translations[node.id] ?? .init(x: 0, y: 0)
            let center = CanvasPoint(x: node.point.x * scale + origin.x + halfWidth + translation.x, y: node.point.y * scale + origin.y + halfHeight + translation.y)
            centers[node.id] = center
            guard let card = self.cards[node.id], query.isEmpty || KnowledgeSearchIndex.matches(query, card.title + " " + card.text + " " + node.cluster) else { continue }
            if center.x + halfWidth >= 0, center.y + halfHeight >= 0, center.x - halfWidth <= viewport.x, center.y - halfHeight <= viewport.y { visible.append(node) }
        }
        let visibleIDs = Set(visible.map(\.id))
        for edge in board.edges {
            guard let a = centers[edge.from], let b = centers[edge.to],
                  query.isEmpty || visibleIDs.contains(edge.from) && visibleIDs.contains(edge.to),
                  max(a.x, b.x) >= 0, max(a.y, b.y) >= 0, min(a.x, b.x) <= viewport.x, min(a.y, b.y) <= viewport.y else { continue }
            connections.append(.init(id: edge.id, start: a, end: b, label: edge.label))
        }
        self.visibleNodes = visible; self.centers = centers; self.connections = connections
    }
}
