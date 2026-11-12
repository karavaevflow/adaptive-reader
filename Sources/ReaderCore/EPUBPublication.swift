import Foundation
import ZIPFoundation

public enum EPUBError: Error, Equatable, LocalizedError {
    case invalidContainer, unsafeResource, oversized, encrypted, unsupportedLayout
    public var errorDescription: String? {
        switch self {
        case .invalidContainer: "This EPUB could not be read. Its container or reading order is invalid."
        case .unsafeResource: "This EPUB contains an unsafe or ambiguous resource path."
        case .oversized: "This EPUB exceeds the supported resource limits."
        case .encrypted: "Encrypted EPUB content is not supported. Use a DRM-free edition."
        case .unsupportedLayout: "Fixed-layout EPUB is not supported by the reflow reader."
        }
    }
}

/// Versioned UTF-16 offset in the sanitized chapter's text stream. Reflow does not
/// alter that stream. The quote detects corruption instead of silently drifting.
public struct EPUBTextLocator: Codable, Equatable, Sendable {
    public let version: Int
    public let offset: Int
    public let quote: String
    public init(offset: Int, quote: String = "") { version = 1; self.offset = offset; self.quote = String(quote.prefix(80)) }
    public var encoded: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self).base64EncodedString()) ?? ""
    }
    public init(encoded: String) throws {
        guard encoded.count <= 2048, let data = Data(base64Encoded: encoded),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1,
              value.offset >= 0, value.quote.count <= 80 else { throw ReaderError.invalidAnchor }
        self = value
    }
    public func validate(in text: String) throws {
        let value = text as NSString
        guard offset <= value.length, quote.isEmpty || (offset < value.length && value.substring(from: offset).hasPrefix(quote)) else {
            throw ReaderError.invalidAnchor
        }
    }
}

public struct EPUBChapter: Sendable, Identifiable {
    public var id: String { resource }
    public let resource: String
    public let title: String
    public let html: Data
    public let text: String
    public let fragments: [String: Int]
    public let passageOffsets: [Int]
}
public struct EPUBResource: Sendable {
    public let data: Data
    public let mediaType: String
}

/// Immutable, bounded, offline EPUB snapshot. No archive entry is written to disk.
public struct EPUBPublication: Sendable {
    public let title: String
    public let language: String?
    public let chapters: [EPUBChapter]
    public let linkedChapters: [EPUBChapter]
    public var readingResources: [EPUBChapter] { chapters + linkedChapters }
    public let resources: [String: EPUBResource]

    public init(data: Data) throws {
        guard data.count <= 128 * 1024 * 1024 else { throw EPUBError.oversized }
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) } catch { throw EPUBError.invalidContainer }
        var files: [String: Data] = [:], total: UInt64 = 0, count = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            guard count <= 10_000, entry.uncompressedSize <= 32 * 1024 * 1024 else { throw EPUBError.oversized }
            total += entry.uncompressedSize
            guard total <= 256 * 1024 * 1024 else { throw EPUBError.oversized }
            guard entry.type != .symlink else { throw EPUBError.unsafeResource }
            if entry.type == .directory { continue }
            let path = try Self.path(entry.path)
            guard files[path] == nil else { throw EPUBError.unsafeResource }
            var bytes = Data()
            let checksum = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard bytes.count + chunk.count <= 32 * 1024 * 1024 else { throw EPUBError.oversized }
                bytes.append(chunk)
            }
            guard checksum == entry.checksum, bytes.count == entry.uncompressedSize else { throw EPUBError.invalidContainer }
            files[path] = bytes
        }
        guard files["mimetype"] == Data("application/epub+zip".utf8), let containerData = files["META-INF/container.xml"] else { throw EPUBError.invalidContainer }
        // Font obfuscation is also excluded until it has its own tested decoder.
        if files["META-INF/encryption.xml"] != nil { throw EPUBError.encrypted }
        let container = try Self.xml(containerData)
        guard let rootfile = try container.nodes(forXPath: "//*[local-name()='rootfile']").first as? XMLElement,
              let fullPath = rootfile.attribute(forName: "full-path")?.stringValue else { throw EPUBError.invalidContainer }
        let packagePath = try Self.path(fullPath)
        guard let packageData = files[packagePath] else { throw EPUBError.invalidContainer }
        let package = try Self.xml(packageData)
        title = try package.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='title']").first?.stringValue ?? "EPUB"
        language = try package.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='language']").first?.stringValue
        if try package.nodes(forXPath: "//*[local-name()='meta' and @property='rendition:layout']").contains(where: { $0.stringValue == "pre-paginated" }) {
            throw EPUBError.unsupportedLayout
        }
        let base = (packagePath as NSString).deletingLastPathComponent
        var navigationPaths = Set<String>()
        var manifest: [String: (String, String)] = [:], resources: [String: EPUBResource] = [:]
        for case let item as XMLElement in try package.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let id = item.attribute(forName: "id")?.stringValue,
                  let href = item.attribute(forName: "href")?.stringValue,
                  let mime = item.attribute(forName: "media-type")?.stringValue else { throw EPUBError.invalidContainer }
            let path = try Self.resolve(href, relativeTo: base)
            guard manifest[id] == nil, let bytes = files[path] else { throw EPUBError.invalidContainer }
            manifest[id] = (path, mime)
            if item.attribute(forName: "properties")?.stringValue?.split(separator: " ").contains("nav") == true { navigationPaths.insert(path) }
            // Only manifest resources are exposed to WebKit. Package metadata is private.
            resources[path] = EPUBResource(data: bytes, mediaType: mime)
        }
        var chapters: [EPUBChapter] = []
        for case let item as XMLElement in try package.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']") {
            guard let id = item.attribute(forName: "idref")?.stringValue, let (path, mime) = manifest[id],
                  mime == "application/xhtml+xml", let bytes = files[path] else { throw EPUBError.invalidContainer }
            guard chapters.count < 2000 else { throw EPUBError.oversized }
            chapters.append(try Self.chapter(bytes, resource: path, ordinal: chapters.count))
        }
        guard !chapters.isEmpty else { throw EPUBError.invalidContainer }
        let linked = try resources.keys.sorted().filter { path in
            resources[path]?.mediaType == "application/xhtml+xml" && !navigationPaths.contains(path) && !chapters.contains(where: { $0.resource == path })
        }.enumerated().map { index, path in try Self.chapter(resources[path]!.data, resource: path, ordinal: chapters.count + index) }
        // XHTML is always served sanitized, including non-linear linked footnotes.
        for (path, resource) in resources where resource.mediaType == "application/xhtml+xml" {
            let chapter = try chapters.first(where: { $0.resource == path }) ?? Self.chapter(resource.data, resource: path, ordinal: 0)
            resources[path] = EPUBResource(data: chapter.html, mediaType: "application/xhtml+xml")
        }
        self.chapters = chapters; linkedChapters = linked; self.resources = resources
    }

    public static func path(_ value: String) throws -> String {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains(":"), !value.contains("\0"),
              !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { throw EPUBError.unsafeResource }
        return value
    }
    public static func resolve(_ href: String, relativeTo directory: String) throws -> String {
        guard let components = URLComponents(string: href), components.scheme == nil, components.host == nil,
              components.query == nil, !href.hasPrefix("//"), let decoded = components.percentEncodedPath.removingPercentEncoding,
              !decoded.hasPrefix("/"), !decoded.contains("\\"), !decoded.contains(":"), !decoded.contains("\0") else { throw EPUBError.unsafeResource }
        var parts = directory.isEmpty ? [] : directory.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/") {
            if part == ".." { guard !parts.isEmpty else { throw EPUBError.unsafeResource }; parts.removeLast() }
            else if part != "." { parts.append(String(part)) }
        }
        return try path(parts.joined(separator: "/"))
    }
    private static func xml(_ data: Data) throws -> XMLDocument {
        let decoded = String(data: data, encoding: .utf8) ?? ((data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])) ? String(data: data, encoding: .utf16) : nil)
        guard data.count <= 8 * 1024 * 1024, var string = decoded,
              !string.localizedCaseInsensitiveContains("<!ENTITY") else { throw EPUBError.invalidContainer }
        string = string.replacingOccurrences(of: "<!DOCTYPE[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        do { return try XMLDocument(xmlString: string, options: [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace]) }
        catch { throw EPUBError.invalidContainer }
    }
    private static func chapter(_ data: Data, resource: String, ordinal: Int) throws -> EPUBChapter {
        let doc = try xml(data)
        let forbidden: Set<String> = ["script", "iframe", "object", "embed", "form", "base", "meta"]
        for node in try doc.nodes(forXPath: "//*").reversed() {
            guard let element = node as? XMLElement else { continue }
            if forbidden.contains(element.localName?.lowercased() ?? "") { element.detach(); continue }
            for attribute in element.attributes ?? [] {
                let name = attribute.name?.lowercased() ?? ""
                if name.hasPrefix("on") || name == "srcdoc" || name == "formaction" { element.removeAttribute(forName: attribute.name!) }
            }
        }
        guard let body = try doc.nodes(forXPath: "//*[local-name()='body']").first as? XMLElement else { throw EPUBError.invalidContainer }
        var text = "", fragments: [String: Int] = [:], passages: [Int] = []
        func collect(_ node: XMLNode) {
            if let element = node as? XMLElement {
                if ["style", "script"].contains(element.localName?.lowercased() ?? "") { return }
                if ["p", "h1", "h2", "h3", "h4", "li", "blockquote", "figcaption", "pre"].contains(element.localName?.lowercased() ?? "") {
                    passages.append((text as NSString).length)
                }
                if let id = element.attribute(forName: "id")?.stringValue { fragments[id] = (text as NSString).length }
            }
            if node.kind == .text { text += node.stringValue ?? "" }
            for child in node.children ?? [] { collect(child) }
        }
        collect(body)
        let heading = try doc.nodes(forXPath: "//*[local-name()='h1' or local-name()='h2']").first?.stringValue ?? doc.nodes(forXPath: "//*[local-name()='title']").first?.stringValue
        // Authored scripts never run. Reader scripts execute in an isolated WKContentWorld.
        let csp = "default-src 'none'; img-src adaptive-epub: data:; style-src adaptive-epub: 'unsafe-inline'; font-src adaptive-epub:; script-src 'none'; connect-src 'none'; media-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"
        let head = try doc.nodes(forXPath: "//*[local-name()='head']/*[local-name()='style' or local-name()='link']").map(\.xmlString).joined()
        var namespaces = doc.rootElement()?.namespaces?.map(\.xmlString) ?? []
        if doc.rootElement()?.namespace(forPrefix: "") == nil { namespaces.append("xmlns=\"http://www.w3.org/1999/xhtml\"") }
        let html = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html \(namespaces.joined(separator: " "))><head><meta charset=\"utf-8\"/><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\"/>\(head)</head>\(body.xmlString)</html>"
        return EPUBChapter(resource: resource, title: heading?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? heading! : "Chapter \(ordinal + 1)", html: Data(html.utf8), text: text, fragments: fragments, passageOffsets: Set(passages).sorted())
    }
}
