import Foundation

/// Hashing and file I/O run before the main-actor engine is constructed.
public struct PreparedPDFSource: Sendable {
    public let data: Data
    public let revision: String
    public init(data: Data) {
        self.data = data
        revision = PDFReaderEngine.revision(data)
    }
}
