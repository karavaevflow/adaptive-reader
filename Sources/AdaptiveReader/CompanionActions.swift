import Foundation
import AppKit
import PDFKit
import ReaderCore
import CryptoKit

extension ReaderSession {
    func updateCompanionSelection() {
        guard let engine, engine.capabilities.contains(.textSelection),
              let selection = engine.view.currentSelection, let page = selection.pages.first,
              let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            companion.selection = nil; companion.selectionLabel = ""; return
        }
        let lines = selection.selectionsByLine().filter { $0.pages.contains { $0 === page } }
        let value = String(lines.compactMap(\.string).joined(separator: "\n").prefix(1400))
        guard !value.isEmpty else { companion.selection = nil; return }
        let rect = selection.bounds(for: page), box = page.bounds(for: .cropBox)
        let anchor = SourceAnchor(bookID: engine.bookID, sourceRevision: engine.sourceRevision,
            position: .pdf(.init(pageIndex: engine.document.index(for: page), x: box.minX, y: min(box.maxY, rect.maxY + 10))))
        let id = SHA256.hash(data: Data("\(engine.sourceRevision):\(engine.document.index(for: page)):\(rect):\(value)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        companion.selection = EvidencePassage(id: id, anchor: anchor, text: value)
        companion.selectionLabel = String(value.prefix(80))
    }
    func askCompanion(_ question: String) {
        guard engine != nil else { return }
        if miniReaderActive { closeMiniReader() }
        focusMode = false; companionVisible = true; companion.query = question
        companion.ask(page: pageNumber, question: question)
    }
    func goToCompanionSource(_ source: EvidencePassage) {
        do {
            try companion.validate(source)
            try commands?.perform(.navigate(source.anchor))
            if case .pdf(let point) = source.anchor.position, let page = engine?.document.page(at: point.pageIndex),
               let text = page.string {
                let range = (text as NSString).range(of: source.text)
                if range.location != NSNotFound, let selection = page.selection(for: range) {
                    selection.color = NSColor.systemYellow.withAlphaComponent(0.3)
                    engine?.view.highlightedSelections = [selection]
                }
            }
        } catch { companion.errorMessage = error.localizedDescription }
    }
    func applyCompanionAction(_ action: CompanionAction) {
        do {
            guard let engine, companion.bookID == engine.bookID, companion.revision == engine.sourceRevision else { throw CompanionError.invalidEvidence }
            try action.validate(pageCount: engine.document.pageCount, sources: companion.evidence)
            switch action.kind {
            case .goToPage: if let page = action.page { navigate(page: page) }
            case .navigateToPassage: if let source = companion.evidence.first(where: { $0.id == action.sourceID }) { goToCompanionSource(source) }
            case .setTheme: if let palette = action.palette { setPalette(palette) }
            case .setFocus: if action.enabled != focusMode { _ = performReadingCommand(.toggleFocus) }
            case .setKeepAwake: if action.enabled != keepAwake { _ = performReadingCommand(.toggleAwake) }
            case .createBookmark: if !pageIsBookmarked { _ = performReadingCommand(.toggleBookmark) }
            case .createNote: if let source = companion.evidence.first(where: { $0.id == action.sourceID }) { companion.prepareNote(source, text: action.text ?? "") }
            }
        } catch { companion.errorMessage = error.localizedDescription }
    }
}
