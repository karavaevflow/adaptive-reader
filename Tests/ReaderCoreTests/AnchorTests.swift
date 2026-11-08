import Foundation
import Testing
@testable import ReaderCore

@Test func anchorsRoundTripAndRejectChangedSources() throws {
    let book = UUID()
    let positions: [DocumentPosition] = [
        .pdf(.init(pageIndex: 3, x: 24, y: 640)),
        .epub(resource: "chapter2.xhtml", locator: "epubcfi(/6/4!/4/2/1:12)")
    ]
    for position in positions {
        let anchor = SourceAnchor(bookID: book, sourceRevision: "revision-1", position: position)
        let decoded = try JSONDecoder().decode(SourceAnchor.self, from: JSONEncoder().encode(anchor))
        #expect(decoded == anchor)
        #expect(throws: ReaderError.sourceChanged) {
            try decoded.validate(bookID: book, revision: "revision-2")
        }
    }
}

@Test func positionSurvivesStoreRecreation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let anchor = SourceAnchor(bookID: UUID(), sourceRevision: "v1", position: .pdf(.init(pageIndex: 0, x: 0, y: 100)))
    try await PositionStore(directory: directory).save(anchor)
    let restored = try await PositionStore(directory: directory).load(bookID: anchor.bookID, revision: "v1")
    #expect(restored == anchor)
}
