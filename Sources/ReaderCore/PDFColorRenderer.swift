import Foundation
import CoreGraphics
import CoreImage
@preconcurrency import PDFKit

public enum PDFColorSupport: String, Codable, Sendable {
    case available, complexGraphics, missingText, unsupportedGeometry, darkBackground
}

/// Original PDF geometry remains the authority for selection, links and anchors.
/// The color pipeline replaces only the page's drawing output.
public final class PDFColorRenderer: @unchecked Sendable {
    public static let shared = PDFColorRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    private let cache = NSCache<NSString, CGImage>()

    public init() {
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 8
    }

    public func support(for page: CGPDFPage) -> PDFColorSupport {
        let box = page.getBoxRect(.cropBox)
        guard page.rotationAngle == 0, box.origin == .zero, box.width > 0, box.height > 0,
              box.width <= 2000, box.height <= 2000 else { return .unsupportedGeometry }
        var resources: CGPDFDictionaryRef?
        guard let dictionary = page.dictionary, CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return .missingText }
        var annotations: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations {
            for index in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                var subtype: UnsafePointer<CChar>?
                guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation,
                      CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype,
                      String(cString: subtype) == "Link" else { return .complexGraphics }
                var appearance: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(annotation, "AP", &appearance) { return .complexGraphics }
            }
        }
        var objects: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects,
           CGPDFDictionaryGetCount(objects) > 0 { return .complexGraphics }
        var fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts,
              CGPDFDictionaryGetCount(fonts) > 0 else { return .missingText }
        // Sample the actual page background, including vector-filled dark pages.
        guard let image = original(page: page, scale: 0.1), let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return .darkBackground }
        for (x, y) in [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)] {
            let offset = y * image.bytesPerRow + x * 4
            if bytes[offset] < 240 || bytes[offset + 1] < 240 || bytes[offset + 2] < 240 { return .darkBackground }
        }
        return .available
    }

    public func original(page: CGPDFPage, scale: Double = 2) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let width = Int(ceil(box.width * scale)), height = Int(ceil(box.height * scale))
        guard width > 0, height > 0, width <= 8000, height <= 8000,
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.translateBy(x: -box.minX, y: -box.minY)
        bitmap.drawPDFPage(page)
        return bitmap.makeImage()
    }

    public func render(page: CGPDFPage, palette: PagePalette, selective: Bool = true, scale: Double = 2) -> CGImage? {
        guard let original = original(page: page, scale: scale) else { return nil }
        guard palette != .original else { return original }
        let input = CIImage(cgImage: original)
        let output: CIImage?
        if selective {
            let colors = Self.colors(palette)
            let size = 32
            var cube = [Float]()
            cube.reserveCapacity(size * size * size * 4)
            for blue in 0..<size {
                for green in 0..<size {
                    for red in 0..<size {
                        let r = Float(red) / Float(size - 1), g = Float(green) / Float(size - 1), b = Float(blue) / Float(size - 1)
                        // Replace the achromatic white/black components while
                        // retaining the chromatic residual, including antialiased edges.
                        let white = min(r, g, b), black = 1 - max(r, g, b)
                        for (index, channel) in [r, g, b].enumerated() {
                            cube.append(white * colors.1[index] + black * colors.0[index] + channel - white)
                        }
                        cube.append(1)
                    }
                }
            }
            let data = cube.withUnsafeBytes { Data($0) }
            output = CIFilter(name: "CIColorCube", parameters: [kCIInputImageKey: input,
                "inputCubeDimension": size, "inputCubeData": data])?.outputImage
        } else {
            output = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: input])?.outputImage
        }
        guard let output else { return nil }
        return context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    public func cached(page: CGPDFPage, id: String, palette: PagePalette) -> CGImage? {
        let key = "\(id)-\(palette.rawValue)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let image = render(page: page, palette: palette) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    private static func colors(_ palette: PagePalette) -> ([Float], [Float]) {
        switch palette {
        case .original: ([0, 0, 0], [1, 1, 1])
        case .paper: ([0.18, 0.16, 0.12], [0.96, 0.93, 0.85])
        case .dusk: ([0.85, 0.81, 0.74], [0.17, 0.16, 0.20])
        case .midnight: ([0.87, 0.88, 0.90], [0.07, 0.08, 0.10])
        case .forest: ([0.83, 0.88, 0.80], [0.08, 0.14, 0.11])
        }
    }
}

final class AdaptivePDFPage: PDFPage, @unchecked Sendable {
    private let lock = NSLock()
    private var eligibility: PDFColorSupport?
    private let renderID = UUID().uuidString

    var colorSupport: PDFColorSupport {
        lock.withLock {
            if let eligibility { return eligibility }
            let result = pageRef.map { PDFColorRenderer.shared.support(for: $0) } ?? .missingText
            eligibility = result
            return result
        }
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        let palette = (document?.delegate as? AdaptivePDFDelegate)?.palette ?? .original
        guard palette != .original, box == .cropBox, colorSupport == .available,
              let pageRef, let image = PDFColorRenderer.shared.cached(page: pageRef, id: renderID, palette: palette) else {
            super.draw(with: box, to: context)
            return
        }
        context.saveGState()
        context.draw(image, in: bounds(for: box))
        context.restoreGState()
    }
}

final class AdaptivePDFDelegate: NSObject, PDFDocumentDelegate {
    private let lock = NSLock()
    private var appearance: PagePalette = .original
    var palette: PagePalette { lock.withLock { appearance } }
    func setPalette(_ palette: PagePalette) { lock.withLock { appearance = palette } }
    func classForPage() -> AnyClass { AdaptivePDFPage.self }
}
