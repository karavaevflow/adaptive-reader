import Foundation
import PDFKit
import CryptoKit

/// Disposable, bounded lexical evidence. Native PDF objects never leave the build worker.
public struct PDFEvidenceIndex: Codable, Sendable {
    public let schemaVersion: Int
    public let bookID: UUID
    public let revision: String
    public let pageCount: Int
    public let passages: [EvidencePassage]
    public let truncated: Bool
    public static func build(data: Data, bookID: UUID, revision: String,
                             progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> Self {
        guard PDFReaderEngine.revision(data) == revision else { throw ReaderError.sourceChanged }
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.allowsCopying else { throw CompanionError.noText }
        var passages: [EvidencePassage] = [], bytes = 0, truncated = false
        for pageIndex in 0..<pdf.pageCount {
            try Task.checkCancellation()
            if passages.count >= 32000 || bytes >= 24 * 1024 * 1024 { truncated = true; break }
            autoreleasepool {
                guard let page = pdf.page(at: pageIndex) else { return }
                let box = page.bounds(for: .cropBox)
                let lines = page.selection(for: box)?.selectionsByLine() ?? []
                var text = "", region = CGRect.null, ordinal = 0, previous = CGRect.null
                func flush() {
                    guard !text.isEmpty, passages.count < 32000, bytes < 24 * 1024 * 1024 else { return }
                    let key = "\(revision):\(pageIndex):\(ordinal):\(text)"
                    let id = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
                    let anchor = SourceAnchor(bookID: bookID, sourceRevision: revision, position: .pdf(.init(pageIndex: pageIndex, x: box.minX, y: min(box.maxY, region.maxY + 10))))
                    passages.append(EvidencePassage(id: id, anchor: anchor, text: text)); bytes += text.utf8.count
                    text = ""; region = .null; ordinal += 1
                }
                for line in lines.prefix(5000) {
                    if Task.isCancelled { break }
                    let value = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let rect = line.bounds(for: page)
                    guard !value.isEmpty, !rect.isEmpty, rect.minX.isFinite, rect.maxY.isFinite else { continue }
                    if !previous.isNull && (previous.minY - rect.maxY > max(8, previous.height * 0.8) || abs(previous.minX - rect.minX) > 40) { flush() }
                    if text.count + value.count + (text.isEmpty ? 0 : 1) > 1400 { flush() }
                    text += (text.isEmpty ? "" : "\n") + String(value.prefix(1400)); region = region.union(rect); previous = rect
                }
                flush()
                if lines.count > 5000 { truncated = true }
            }
            if pageIndex % 8 == 0 { await progress(pageIndex + 1, pdf.pageCount); await Task.yield() }
        }
        try Task.checkCancellation()
        guard !passages.isEmpty else { throw CompanionError.noText }
        await progress(pdf.pageCount, pdf.pageCount)
        return Self(schemaVersion: 1, bookID: bookID, revision: revision, pageCount: pdf.pageCount, passages: passages, truncated: truncated)
    }
    public func validate(bookID: UUID, revision: String) throws {
        guard schemaVersion == 1, self.bookID == bookID, self.revision == revision,
              passages.count <= 32000, pageCount > 0,
              Set(passages.map(\.id)).count == passages.count,
              passages.reduce(0, { $0 + $1.text.utf8.count }) <= 25 * 1024 * 1024 else { throw CompanionError.invalidEvidence }
        for item in passages {
            try item.anchor.validate(bookID: bookID, revision: revision)
            guard !item.text.isEmpty, item.text.count <= 1400, item.id.count == 24,
                  case .pdf(let point) = item.anchor.position, point.pageIndex < pageCount else { throw CompanionError.invalidEvidence }
        }
    }
    public func retrieve(_ query: String, visiblePage: Int, limit: Int = 6) throws -> [EvidencePassage] {
        let ignored: Set<String> = ["the", "and", "for", "this", "that", "what", "why", "how", "please", "explain", "это", "как", "что", "для", "или", "его", "она", "они", "объясни", "пожалуйста"]
        let terms = Set(Self.terms(query).filter { !ignored.contains($0) }.prefix(64))
        var candidates: [(index: Int, length: Int, matches: [String: Int], visible: Bool)] = []
        var frequency: [String: Int] = [:], totalLength = 0
        for (index, passage) in passages.enumerated() {
            if index % 64 == 0 { try Task.checkCancellation() }
            let words = Self.terms(passage.text); totalLength += words.count
            var matches: [String: Int] = [:]
            for word in words where terms.contains(word) { matches[word, default: 0] += 1 }
            for word in matches.keys { frequency[word, default: 0] += 1 }
            let onPage: Bool = { if case .pdf(let point) = passage.anchor.position { point.pageIndex == visiblePage } else { false } }()
            if !matches.isEmpty || onPage { candidates.append((index, words.count, matches, onPage)) }
        }
        let count = Double(max(1, passages.count)), average = Double(max(1, totalLength)) / count
        var scored: [(Int, Double)] = []
        for candidate in candidates {
            try Task.checkCancellation()
            var score = candidate.visible ? 0.25 : 0
            for word in candidate.matches.keys.sorted() {
                let hits = candidate.matches[word] ?? 0
                let df = Double(frequency[word] ?? 0), tf = Double(hits)
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                score += idf * (tf * 2.2) / (tf + 1.2 * (0.25 + 0.75 * Double(candidate.length) / average))
            }
            scored.append((candidate.index, score))
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(min(8, max(0, limit))).map { passages[$0.0] }
    }
    private static func terms(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
    }
}
