import Foundation
import PDFKit
import AppKit

public struct ReaderPassage: Sendable {
    public let anchor: SourceAnchor
    public let text: String
    public let next: SourceAnchor?
    public init(anchor: SourceAnchor, text: String, next: SourceAnchor?) { self.anchor = anchor; self.text = text; self.next = next }
}

extension EPUBReaderEngine {
    public func textPassage(at anchor: SourceAnchor) throws -> ReaderPassage {
        try anchor.validate(bookID: bookID, revision: sourceRevision)
        guard case .epub(let resource, let encoded) = anchor.position,
              let index = publication.readingResources.firstIndex(where: { $0.resource == resource }) else { throw ReaderError.invalidAnchor }
        let chapter = publication.readingResources[index], locator = try EPUBTextLocator(encoded: encoded)
        try locator.validate(in: chapter.text)
        let text = chapter.text as NSString
        var start = locator.offset
        let nonspace = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: [], range: NSRange(location: start, length: text.length - start))
        start = nonspace.location == NSNotFound ? text.length : nonspace.location
        if start >= text.length {
            guard index + 1 < publication.chapters.count else { return ReaderPassage(anchor: anchor, text: "", next: nil) }
            return try textPassage(at: SourceAnchor(bookID: bookID, sourceRevision: sourceRevision, position: .epub(resource: publication.chapters[index + 1].resource, locator: EPUBTextLocator(offset: 0).encoded)))
        }
        let blockEnd = chapter.passageOffsets.first(where: { $0 > start }) ?? text.length
        var length = min(1600, blockEnd - start)
        if start + length < text.length, (0xD800...0xDBFF).contains(text.character(at: start + length - 1)) { length -= 1 }
        let rest = text.substring(with: NSRange(location: start, length: length))
        // Bounded utterances preserve exact source offsets, including Unicode.
        var value = String(rest.prefix(500))
        if value.count == 500 {
            if let breakPoint = value.lastIndex(where: { ".!?\n".contains($0) }), value.distance(from: value.startIndex, to: breakPoint) > 150 { value = String(value[...breakPoint]) }
            else if let space = value.lastIndex(where: { $0.isWhitespace }) { value = String(value[...space]) }
        }
        let end = start + value.utf16.count
        let next: SourceAnchor?
        if end < text.length { next = SourceAnchor(bookID: bookID, sourceRevision: sourceRevision, position: .epub(resource: resource, locator: EPUBTextLocator(offset: end).encoded)) }
        else if index + 1 < publication.chapters.count { next = SourceAnchor(bookID: bookID, sourceRevision: sourceRevision, position: .epub(resource: publication.chapters[index + 1].resource, locator: EPUBTextLocator(offset: 0).encoded)) }
        else { next = nil }
        let precise = SourceAnchor(bookID: bookID, sourceRevision: sourceRevision, position: .epub(resource: resource, locator: EPUBTextLocator(offset: start, quote: String(value.prefix(60))).encoded))
        return ReaderPassage(anchor: precise, text: value, next: next)
    }
}

extension PDFReaderEngine {
    public func textPassage(at anchor: SourceAnchor) throws -> ReaderPassage {
        try anchor.validate(bookID: bookID, revision: sourceRevision)
        guard document.allowsCopying, case .pdf(let point) = anchor.position, (0..<document.pageCount).contains(point.pageIndex) else { throw ReaderError.unsupportedCommand }
        for index in point.pageIndex..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            let lines = page.selection(for: box)?.selectionsByLine() ?? []
            let eligible = lines.filter { index != point.pageIndex || $0.bounds(for: page).maxY <= point.y + 12 }
            guard let first = eligible.first(where: { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else { continue }
            var text = "", last = first
            for line in eligible {
                let value = line.string ?? ""
                if !text.isEmpty && text.count + value.count > 500 { break }
                text += (text.isEmpty ? "" : "\n") + value; last = line
            }
            let bounds = first.bounds(for: page), end = last.bounds(for: page)
            let start = SourceAnchor(bookID: bookID, sourceRevision: sourceRevision, position: .pdf(.init(pageIndex: index, x: bounds.minX, y: bounds.maxY)))
            let next = SourceAnchor(bookID: bookID, sourceRevision: sourceRevision, position: .pdf(.init(pageIndex: index, x: end.minX, y: end.minY - 13)))
            return ReaderPassage(anchor: start, text: text, next: next)
        }
        return ReaderPassage(anchor: anchor, text: "", next: nil)
    }
}

extension PDFReaderEngine {
    private func selection(quotation: String, anchor: SourceAnchor) throws -> PDFSelection {
        try anchor.validate(bookID: bookID, revision: sourceRevision)
        guard case .pdf(let point) = anchor.position, let page = document.page(at: point.pageIndex), let text = page.string as NSString?, !quotation.isEmpty else { throw ReaderError.invalidAnchor }
        var range = NSRange(location: 0, length: text.length), best: PDFSelection?, distance = Double.infinity
        while range.length > 0 {
            let hit = text.range(of: quotation, range: range)
            if hit.location == NSNotFound { break }
            if let selection = page.selection(for: hit) {
                let bounds = selection.bounds(for: page)
                let value = hypot(bounds.minX - point.x, bounds.maxY - point.y)
                if value < distance { distance = value; best = selection }
            }
            let end = hit.location + max(1, hit.length); range = NSRange(location: end, length: text.length - end)
        }
        guard let best else { throw ReaderError.invalidAnchor }; return best
    }
    public func setHighlights(_ highlights: [ReaderHighlight]) throws {
        var pending: [(PDFPage, PDFAnnotation)] = []
        for item in highlights {
            let selected = try selection(quotation: item.quotation, anchor: item.anchor)
            for line in selected.selectionsByLine() {
                guard let page = line.pages.first else { continue }
                let annotation = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                annotation.color = item.color.native.withAlphaComponent(0.35)
                annotation.userName = "Adaptive:" + item.id.uuidString
                pending.append((page, annotation))
            }
        }
        for (page, annotation) in adaptiveHighlights { page.removeAnnotation(annotation) }
        for (page, annotation) in pending { page.addAnnotation(annotation) }
        adaptiveHighlights = pending
    }
    public func setPlayback(_ passage: ReaderPassage?) throws {
        guard let passage else { view.highlightedSelections = nil; return }
        let quote = passage.text.components(separatedBy: .newlines).first ?? passage.text
        let selected = try selection(quotation: quote, anchor: passage.anchor)
        selected.color = NSColor.systemBlue.withAlphaComponent(0.25); view.highlightedSelections = [selected]
    }
}

extension HighlightColor {
    var native: NSColor {
        switch self { case .yellow: .systemYellow; case .green: .systemGreen; case .blue: .systemBlue; case .purple: .systemPurple }
    }
}
