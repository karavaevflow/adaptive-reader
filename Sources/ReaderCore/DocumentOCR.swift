import Foundation
import CoreGraphics
import Vision
import CoreML

public struct OCRLine: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(anchor.bookID):\(anchor.position):\(bounds)" }
    public let anchor: SourceAnchor
    public let text: String
    public let confidence: Float
    public let bounds: CGRect
    public var needsReview: Bool { confidence < 0.85 }
    public init(anchor: SourceAnchor, text: String, confidence: Float, bounds: CGRect) {
        self.anchor = anchor; self.text = text; self.confidence = confidence; self.bounds = bounds
    }
}

public struct OCRPage: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let bookID: UUID
    public let revision: String
    public let pageIndex: Int
    public let lines: [OCRLine]
    public init(bookID: UUID, revision: String, pageIndex: Int, lines: [OCRLine]) {
        schemaVersion = 1; self.bookID = bookID; self.revision = revision; self.pageIndex = pageIndex; self.lines = lines
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ReaderError.unsupportedAnchorVersion }
        guard pageIndex >= 0, revision.count == 64, revision.allSatisfy(\.isHexDigit), lines.count <= 10000,
              lines.reduce(0, { $0 + $1.text.utf16.count }) <= 100000 else { throw ReaderError.invalidAnchor }
        for line in lines {
            try line.anchor.validate(bookID: bookID, revision: revision)
            guard case .pdf(let point) = line.anchor.position, point.pageIndex == pageIndex,
                  !line.text.isEmpty, line.text.utf16.count <= 16000, line.confidence.isFinite,
                  (0...1).contains(line.confidence), !line.bounds.isEmpty,
                  abs(point.x - line.bounds.minX) < 0.01, abs(point.y - line.bounds.maxY) < 0.01,
                  [line.bounds.minX, line.bounds.minY, line.bounds.maxX, line.bounds.maxY].allSatisfy(\.isFinite) else { throw ReaderError.invalidAnchor }
        }
    }
}

/// One cancellable Vision request and one bounded raster at a time. No network or source mutation.
public final class DocumentOCR: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let current = request; lock.unlock()
        current?.cancel()
    }
    public func recognize(data: Data, bookID: UUID, revision: String, pageIndex: Int, languages: [String] = ["en-US", "ru-RU"]) async throws -> OCRPage {
        let worker = Task.detached(priority: .utility) { [self] in
            try Task.checkCancellation()
            return try autoreleasepool {
                try self.checkCancellation()
                Self.trace("rendering page")
                guard PDFReaderEngine.revision(data) == revision else { throw ReaderError.sourceChanged }
                guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider),
                      !pdf.isEncrypted, pdf.allowsCopying else { throw ReaderError.lockedDocument }
                guard pageIndex >= 0, pageIndex < pdf.numberOfPages, let page = pdf.page(at: pageIndex + 1) else { throw ReaderError.invalidAnchor }
                let crop = page.getBoxRect(.cropBox)
                guard !crop.isEmpty, [crop.minX, crop.minY, crop.maxX, crop.maxY].allSatisfy(\.isFinite) else { throw ReaderError.invalidAnchor }
                // Render upright, including intrinsic rotation. Invert the exact same transform for anchors.
                let rotated = abs(page.rotationAngle % 180) == 90
                let size = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
                let scale = min(3, 2400 / max(size.width, size.height))
                let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ReaderError.unavailableSource }
                let target = CGRect(x: 0, y: 0, width: width, height: height)
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(target)
                let transform = page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true)
                context.concatenate(transform); context.clip(to: crop); context.drawPDFPage(page)
                try self.checkCancellation()
                guard let image = context.makeImage() else { throw ReaderError.unavailableSource }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
                request.preferBackgroundProcessing = true
                Self.trace("configuring recognizer")
                let supported = try request.supportedRecognitionLanguages()
                let selected = languages.filter { supported.contains($0) }
                guard !selected.isEmpty else { throw ReaderError.unsupportedCommand }
                request.recognitionLanguages = selected
                // A bounded page is processed on a supported CPU device. This keeps
                // recognition independent of a virtual/absent GPU and reader drawing.
                let stages = try request.supportedComputeStageDevices
                guard !stages.isEmpty else { throw ReaderError.unsupportedCommand }
                for (stage, devices) in stages {
                    guard let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) else { throw ReaderError.unsupportedCommand }
                    request.setComputeDevice(cpu, for: stage)
                }
                lock.lock(); let stopped = cancelled; if !stopped { self.request = request }; lock.unlock()
                guard !stopped else { throw CancellationError() }
                defer { lock.lock(); self.request = nil; lock.unlock() }
                Self.trace("recognizing text on CPU")
                do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
                catch { try self.checkCancellation(); throw error }
                try self.checkCancellation()
                Self.trace("recognition completed")
                let inverse = transform.inverted()
                let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                    guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
                    let pixels = VNImageRectForNormalizedRect(observation.boundingBox, width, height)
                    let bounds = pixels.applying(inverse).intersection(crop)
                    guard !bounds.isEmpty else { return nil }
                    return OCRLine(anchor: SourceAnchor(bookID: bookID, sourceRevision: revision,
                        position: .pdf(.init(pageIndex: pageIndex, x: bounds.minX, y: bounds.maxY))),
                        text: candidate.string, confidence: candidate.confidence, bounds: bounds)
                }
                let result = OCRPage(bookID: bookID, revision: revision, pageIndex: pageIndex, lines: lines)
                try result.validate(); return result
            }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { self.cancel(); worker.cancel() })
    }
    private func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        try Task.checkCancellation()
    }
    private static func trace(_ stage: String) {
        #if DEBUG
        NSLog("Adaptive OCR: %@", stage)
        #endif
    }
}

extension LibraryStore {
    public func cachedOCR(for book: BookRecord, pageIndex: Int) throws -> OCRPage? {
        try verifyRecord(book)
        let url = ocrURL(book, pageIndex)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let result = try JSONDecoder().decode(OCRPage.self, from: Data(contentsOf: url))
        try result.validate()
        guard result.bookID == book.id, result.revision == book.revision, result.pageIndex == pageIndex else { throw ReaderError.sourceChanged }
        return result
    }
    public func cacheOCR(_ page: OCRPage, for book: BookRecord) throws {
        try verifyRecord(book); try page.validate()
        guard page.bookID == book.id, page.revision == book.revision else { throw ReaderError.sourceChanged }
        let url = ocrURL(book, page.pageIndex)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(page).write(to: url, options: .atomic)
    }
    private func ocrURL(_ book: BookRecord, _ page: Int) -> URL {
        root.appendingPathComponent("Cache/OCR/\(book.id.uuidString)/\(book.revision)/\(page).json")
    }
}
