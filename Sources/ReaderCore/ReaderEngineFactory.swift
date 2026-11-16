import Foundation

@MainActor public enum ReaderEngineFactory {
    public static func open(data: Data, format: BookFormat, bookID: UUID) async throws -> any ReaderEngine {
        if format == .epub {
            let worker = Task.detached(priority: .userInitiated) { (try EPUBPublication(data: data), PDFReaderEngine.revision(data)) }
            let (publication, revision) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            return EPUBReaderEngine(publication: publication, bookID: bookID, revision: revision)
        }
        let prepared = await Task.detached(priority: .userInitiated) { PreparedPDFSource(data: data) }.value
        try Task.checkCancellation()
        return try PDFReaderEngine(source: prepared, bookID: bookID)
    }
}
