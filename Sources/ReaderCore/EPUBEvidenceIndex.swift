import Foundation
import CryptoKit

/// Bounded, recreatable evidence with the same anchors used by bookmarks and notes.
public struct EPUBEvidenceIndex: Sendable {
    public let passages: [EvidencePassage]
    public let truncated: Bool
    public init(publication: EPUBPublication, bookID: UUID, revision: String) throws {
        var passages: [EvidencePassage] = [], bytes = 0, truncated = false
        outer: for chapter in publication.readingResources {
            let source = chapter.text as NSString
            let boundaries = Set([0, source.length] + chapter.passageOffsets).sorted()
            for block in 0..<max(0, boundaries.count - 1) {
                var offset = boundaries[block]
                let value = source.substring(with: NSRange(location: offset, length: boundaries[block + 1] - offset))
                var rest = value[...]
                while !rest.isEmpty {
                    try Task.checkCancellation()
                    if passages.count >= 32_000 || bytes >= 24 * 1024 * 1024 { truncated = true; break outer }
                    let chunk = String(rest.prefix(1200))
                    let leading = chunk.prefix(while: { $0.isWhitespace })
                    let text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let start = offset + leading.utf16.count
                        let locator = EPUBTextLocator(offset: start, quote: String(text.prefix(60)))
                        let anchor = SourceAnchor(bookID: bookID, sourceRevision: revision, position: .epub(resource: chapter.resource, locator: locator.encoded))
                        let key = "\(revision):\(chapter.resource):\(start):\(text)"
                        let id = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
                        passages.append(EvidencePassage(id: id, anchor: anchor, text: text)); bytes += text.utf8.count
                    }
                    offset += chunk.utf16.count; rest = rest.dropFirst(chunk.count)
                }
            }
        }
        self.passages = passages; self.truncated = truncated
    }
    public func retrieve(_ query: String, visibleResource: String) throws -> [EvidencePassage] {
        try EvidenceRanking.retrieve(query, passages: passages) { anchor in
            if case .epub(let resource, _) = anchor.position { resource == visibleResource } else { false }
        }
    }
}
