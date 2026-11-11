import Foundation
import PDFKit

extension PDFReaderEngine {
    /// PDF has fixed geometry: nearby lines form reading blocks, without claiming semantic EPUB paragraphs.
    public func adjacentPassage(_ direction: Int) throws -> SourceAnchor {
        guard direction == 1 || direction == -1, capabilities.contains(.passageNavigation),
              case .pdf(let current) = try currentAnchor().position,
              let page = document.page(at: current.pageIndex) else { throw ReaderError.unsupportedCommand }
        let blocks = readingBlocks(on: page)
        let nearest = blocks.indices.min { abs(Double(blocks[$0].maxY) + 16 - current.y) < abs(Double(blocks[$1].maxY) + 16 - current.y) }
        let next = (nearest ?? (direction > 0 ? -1 : 0)) + direction
        let targetPage: PDFPage, target: CGRect
        if blocks.indices.contains(next) { targetPage = page; target = blocks[next] }
        else {
            let index = current.pageIndex + direction
            guard (0..<document.pageCount).contains(index), let adjacent = document.page(at: index) else { return try currentAnchor() }
            targetPage = adjacent
            let adjacentBlocks = readingBlocks(on: adjacent)
            target = (direction > 0 ? adjacentBlocks.first : adjacentBlocks.last) ?? adjacent.bounds(for: .cropBox)
        }
        let box = targetPage.bounds(for: .cropBox)
        return SourceAnchor(bookID: bookID, sourceRevision: sourceRevision, position: .pdf(.init(
            pageIndex: document.index(for: targetPage), x: box.minX, y: min(box.maxY, target.maxY + 16))))
    }
    private func readingBlocks(on page: PDFPage) -> [CGRect] {
        let lines = page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []
        var blocks: [CGRect] = [], previous = CGRect.zero
        for line in lines {
            let rect = line.bounds(for: page)
            guard !rect.isEmpty, rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { continue }
            let gap = previous.minY - rect.maxY
            if let last = blocks.last, abs(previous.minX - rect.minX) <= max(18, previous.height),
               gap >= -previous.height * 0.2, gap <= max(6, previous.height * 0.65) {
                blocks[blocks.count - 1] = last.union(rect)
            } else { blocks.append(rect) }
            previous = rect
        }
        return blocks
    }
}
