import AppKit
import WebKit
import Observation

public struct EPUBTypography: Codable, Equatable, Sendable {
    public enum Typeface: String, Codable, Sendable, CaseIterable { case system, serif }
    public var typeface: Typeface = .serif
    public var fontSize: Double = 20
    public var columnWidth: Double = 680
    public var lineHeight: Double = 1.6
    public init() {}
    public func validate() throws {
        guard fontSize.isFinite, columnWidth.isFinite, lineHeight.isFinite,
              (12...36).contains(fontSize), (320...960).contains(columnWidth), (1.2...2.2).contains(lineHeight) else { throw ReaderError.unsupportedCommand }
    }
}

@MainActor
private final class EPUBResourceHandler: NSObject, WKURLSchemeHandler {
    let publication: EPUBPublication
    init(_ publication: EPUBPublication) { self.publication = publication }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "book", let resource = publication.resources[String(url.path.dropFirst())] else {
            task.didFailWithError(ReaderError.unavailableSource); return
        }
        task.didReceive(URLResponse(url: url, mimeType: resource.mediaType, expectedContentLength: resource.data.count, textEncodingName: resource.mediaType == "application/xhtml+xml" ? "utf-8" : nil))
        task.didReceive(resource.data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// WebKit owns layout; the publication owns source text and locators. No page number
/// is persisted for EPUB. All book links use the same command path as native controls.
@MainActor @Observable
public final class EPUBReaderEngine: NSObject, ReaderEngine, WKNavigationDelegate, WKScriptMessageHandler {
    public let bookID: UUID
    public let sourceRevision: String
    public let publication: EPUBPublication
    public let view: WKWebView
    public let capabilities: Set<ReaderCapability>
    public private(set) var palette: PagePalette = .original
    public private(set) var typography = EPUBTypography()
    public private(set) var chapterIndex = 0
    public private(set) var selection: (anchor: SourceAnchor, text: String, displayText: String)?
    public private(set) var ready = false
    public var onPositionChanged: (() -> Void)?
    public var onSelectionChanged: (() -> Void)?
    public var onInternalNavigation: ((SourceAnchor) -> Void)?
    public var onManualInteraction: (() -> Void)?
    public var onError: ((Error) -> Void)?
    @ObservationIgnored private var locator = EPUBTextLocator(offset: 0)
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var pendingNavigation: WKNavigation?
    @ObservationIgnored private var canScrollDown = true
    @ObservationIgnored private var savedHighlights: [ReaderHighlight] = []
    @ObservationIgnored private var playback: ReaderPassage?

    public init(publication: EPUBPublication, bookID: UUID, revision: String) {
        self.publication = publication; self.bookID = bookID; sourceRevision = revision
        var capabilities: Set<ReaderCapability> = [.reflow, .pagePalette, .continuousScroll]
        if publication.readingResources.contains(where: { $0.text.contains(where: { !$0.isWhitespace }) }) {
            capabilities.formUnion([.textSelection, .search, .passageNavigation, .readAloud])
        }
        self.capabilities = capabilities
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(EPUBResourceHandler(publication), forURLScheme: "adaptive-epub")
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.setAccessibilityIdentifier("reader.epub")
        view.navigationDelegate = self
        // The weak bridge breaks the WKUserContentController -> engine -> view cycle.
        let bridge = EPUBMessageBridge(self)
        configuration.userContentController.add(bridge, contentWorld: .defaultClient, name: "reader")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
    }
    public func start() { if !loading && !ready { loadChapter() } }
    public func stop() { view.stopLoading(); cancelSearch(); view.configuration.userContentController.removeScriptMessageHandler(forName: "reader", contentWorld: .defaultClient); view.navigationDelegate = nil }
    public func currentAnchor() throws -> SourceAnchor {
        SourceAnchor(bookID: bookID, sourceRevision: sourceRevision, position: .epub(resource: publication.readingResources[chapterIndex].resource, locator: locator.encoded))
    }
    public func navigate(to anchor: SourceAnchor) throws {
        try anchor.validate(bookID: bookID, revision: sourceRevision)
        guard case .epub(let resource, let encoded) = anchor.position,
              let index = publication.readingResources.firstIndex(where: { $0.resource == resource }) else { throw ReaderError.invalidAnchor }
        let next = try EPUBTextLocator(encoded: encoded)
        try next.validate(in: publication.readingResources[index].text)
        let changed = index != chapterIndex
        chapterIndex = index; locator = next; selection = nil
        if changed || !ready { loadChapter() }
        else { evaluate("adaptive.go(\(next.offset))") }
        onPositionChanged?()
    }
    public func applyTypography(_ value: EPUBTypography) throws {
        try value.validate(); typography = value; applyStyle()
    }
    public func applyPagePalette(_ value: PagePalette) throws { palette = value; applyStyle() }
    public func adjacentPassage(_ direction: Int) throws -> SourceAnchor {
        guard direction == 1 || direction == -1 else { throw ReaderError.unsupportedCommand }
        let offsets = publication.readingResources[chapterIndex].passageOffsets
        let target = direction > 0 ? offsets.first(where: { $0 > locator.offset }) : offsets.last(where: { $0 < locator.offset })
        let index: Int, offset: Int
        if let target { index = chapterIndex; offset = target }
        else {
            index = min(publication.readingResources.count - 1, max(0, chapterIndex + direction))
            offset = index == chapterIndex ? locator.offset : (direction > 0 ? 0 : publication.readingResources[index].passageOffsets.last ?? 0)
        }
        return SourceAnchor(bookID: bookID, sourceRevision: sourceRevision, position: .epub(resource: publication.readingResources[index].resource, locator: EPUBTextLocator(offset: offset).encoded))
    }
    public func scroll(by points: Double) throws -> Bool {
        guard points.isFinite else { throw ReaderError.unsupportedCommand }
        guard ready else { return true }
        if points > 0 && !canScrollDown { return false }
        evaluate("window.scrollBy(0,\(points))"); return true
    }
    public func search(_ query: String) throws -> AsyncThrowingStream<ReaderSearchMatch, Error> {
        cancelSearch()
        let chapters = publication.readingResources, bookID = bookID, revision = sourceRevision
        return AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                var count = 0
                for chapter in chapters {
                    guard !Task.isCancelled else { continuation.finish(); return }
                    let text = chapter.text as NSString
                    var range = NSRange(location: 0, length: text.length)
                    while range.length > 0 && !query.isEmpty {
                        guard !Task.isCancelled else { continuation.finish(); return }
                        let hit = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                        if hit.location == NSNotFound { break }
                        let quote = text.substring(from: hit.location).prefix(80)
                        let anchor = SourceAnchor(bookID: bookID, sourceRevision: revision, position: .epub(resource: chapter.resource, locator: EPUBTextLocator(offset: hit.location, quote: String(quote)).encoded))
                        continuation.yield(ReaderSearchMatch(anchor: anchor, snippet: text.substring(with: NSRange(location: hit.location, length: min(180, text.length - hit.location)))))
                        count += 1
                        if count >= 1000 { continuation.finish(); return }
                        let end = hit.location + max(hit.length, 1)
                        range = NSRange(location: end, length: text.length - end)
                    }
                    await Task.yield()
                }
                continuation.finish()
            }
            searchTask = worker
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
    public func setHighlights(_ values: [ReaderHighlight]) throws {
        for item in values {
            try item.anchor.validate(bookID: bookID, revision: sourceRevision)
            guard case .epub(let resource, let encoded) = item.anchor.position,
                  let chapter = publication.readingResources.first(where: { $0.resource == resource }) else { throw ReaderError.invalidAnchor }
            let locator = try EPUBTextLocator(encoded: encoded); try locator.validate(in: chapter.text)
            let text = chapter.text as NSString
            guard item.quotation.utf16.count <= text.length - locator.offset,
                  text.substring(with: NSRange(location: locator.offset, length: item.quotation.utf16.count)) == item.quotation else { throw ReaderError.invalidAnchor }
        }
        savedHighlights = values; renderHighlights()
    }
    public func setPlayback(_ value: ReaderPassage?) throws {
        if let value { try value.anchor.validate(bookID: bookID, revision: sourceRevision) }
        playback = value; renderPlayback()
    }
    private func renderPlayback() {
        guard ready else { return }
        if let playback, case .epub(let path, let encoded) = playback.anchor.position,
           path == publication.readingResources[chapterIndex].resource, let locator = try? EPUBTextLocator(encoded: encoded) {
            evaluate("adaptive.playback({offset:\(locator.offset),length:\(playback.text.utf16.count)})")
        } else { evaluate("adaptive.playback(null)") }
    }
    private func renderHighlights() {
        guard ready else { return }
        let resource = publication.readingResources[chapterIndex].resource
        var values: [[String: Any]] = []
        for item in savedHighlights {
            if case .epub(let path, let encoded) = item.anchor.position, path == resource, let locator = try? EPUBTextLocator(encoded: encoded) {
                values.append(["offset": locator.offset, "length": item.quotation.utf16.count, "color": item.color.rawValue])
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: values), let json = String(data: data, encoding: .utf8) { evaluate("adaptive.highlights(\(json))") }
        renderPlayback()
    }
    public func cancelSearch() { searchTask?.cancel(); searchTask = nil }
    private func loadChapter() {
        ready = false; loading = true
        let resource = publication.readingResources[chapterIndex].resource
        var url = URLComponents(); url.scheme = "adaptive-epub"; url.host = "book"; url.path = "/" + resource
        if let url = url.url { pendingNavigation = view.load(URLRequest(url: url)) }
    }
    private func applyStyle() {
        guard ready else { return }
        let colors: (String, String)
        switch palette {
        case .original: colors = ("#ffffff", "#202020")
        case .paper: colors = ("#f6f0e2", "#302a22")
        case .dusk: colors = ("#302c2b", "#e5d9c9")
        case .midnight: colors = ("#191b20", "#d6d9df")
        case .forest: colors = ("#202e28", "#d9e4d6")
        }
        let family = typography.typeface == .serif ? "ui-serif, Georgia, serif" : "-apple-system, sans-serif"
        let css = "html{background:\(colors.0)!important;color:\(colors.1)!important;color-scheme:\(palette == .midnight || palette == .forest || palette == .dusk ? "dark" : "light")}body{box-sizing:border-box;margin:0 auto!important;padding:32px 28px 90px!important;max-width:\(typography.columnWidth)px!important;font-family:\(family)!important;font-size:\(typography.fontSize)px!important;line-height:\(typography.lineHeight)!important;overflow-wrap:anywhere}body p,body li{font:inherit!important}img,svg{max-width:100%;height:auto}a{color:LinkText}::selection{background:Highlight;color:HighlightText}"
        if let json = try? JSONSerialization.data(withJSONObject: [css]), let args = String(data: json, encoding: .utf8) {
            evaluate("adaptive.style(\(args)[0],\(locator.offset))")
        }
    }
    private func evaluate(_ script: String) {
        view.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            if case .failure(let error) = result { self?.onError?(error) }
        }
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigation === pendingNavigation else { return }
        loading = false; ready = true; applyStyle(); renderHighlights(); onPositionChanged?()
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === pendingNavigation else { return }
        loading = false
        if (error as NSError).code != NSURLErrorCancelled { onError?(error) }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .other, action.request.url?.scheme == "adaptive-epub", action.request.url?.host == "book", action.targetFrame?.isMainFrame == true else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any],
              let path = value["path"] as? String, path == "/" + publication.readingResources[chapterIndex].resource else { return }
        if value["manual"] as? Bool == true { onManualInteraction?(); return }
        if let end = value["end"] as? Bool { canScrollDown = !end }
        if let href = value["link"] as? String, let url = URL(string: href), url.scheme == "adaptive-epub", url.host == "book",
           let index = publication.readingResources.firstIndex(where: { $0.resource == String(url.path.dropFirst()) }) {
            let chapter = publication.readingResources[index]
            let offset: Int
            if let fragment = url.fragment, !fragment.isEmpty {
                guard let found = chapter.fragments[fragment] else { onError?(ReaderError.invalidAnchor); return }; offset = found
            } else { offset = 0 }
            onInternalNavigation?(SourceAnchor(bookID: bookID, sourceRevision: sourceRevision, position: .epub(resource: chapter.resource, locator: EPUBTextLocator(offset: offset).encoded)))
            return
        }
        guard let offset = value["offset"] as? Int, let quote = value["quote"] as? String else { return }
        let next = EPUBTextLocator(offset: offset, quote: quote)
        guard (try? next.validate(in: publication.readingResources[chapterIndex].text)) != nil else { onError?(ReaderError.invalidAnchor); return }
        if let text = value["selection"] as? String {
            selection = text.isEmpty ? nil : (SourceAnchor(bookID: bookID, sourceRevision: sourceRevision, position: .epub(resource: publication.readingResources[chapterIndex].resource, locator: next.encoded)), text, String(((value["displaySelection"] as? String) ?? text).prefix(8000)))
            onSelectionChanged?()
        } else { locator = next; onPositionChanged?() }
    }
    private static let script = #"""
    (() => {
      const nodes=[], starts=[]; let text='';
      const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,{acceptNode:n=>n.parentElement.closest('style,script')?NodeFilter.FILTER_REJECT:NodeFilter.FILTER_ACCEPT});
      while(walker.nextNode()){starts.push(text.length);nodes.push(walker.currentNode);text+=walker.currentNode.textContent;}
      function point(offset){let lo=0,hi=starts.length-1;while(lo<hi){const mid=Math.ceil((lo+hi)/2);if(starts[mid]<=offset)lo=mid;else hi=mid-1;}const i=lo;return nodes[i]?[nodes[i],Math.min(nodes[i].length,Math.max(0,offset-starts[i]))]:null;}
      function position(){const r=document.caretRangeFromPoint(Math.max(30,(innerWidth-document.body.clientWidth)/2+30),36);if(r){const i=nodes.indexOf(r.startContainer);if(i>=0)return starts[i]+r.startOffset;}for(let i=0;i<nodes.length;i++){const r=document.createRange();r.selectNodeContents(nodes[i]);if(r.getBoundingClientRect().bottom>32)return starts[i];}return 0;}
      let last={offset:0};let styled=false,programmaticY=null;
      function send(offset,extra={}){if(!('selection' in extra))last.offset=offset;window.webkit.messageHandlers.reader.postMessage({path:decodeURIComponent(location.pathname),offset,quote:Array.from(text.slice(offset)).slice(0,60).join(''),end:scrollY+innerHeight>=document.documentElement.scrollHeight-1,...extra});}
      let moving=false,timer;
      function go(offset){document.documentElement.style.setProperty('scroll-behavior','auto','important');moving=true;clearTimeout(timer);timer=null;last.offset=offset;const p=point(offset);if(p){const r=document.createRange();r.setStart(...p);r.setEnd(p[0],Math.min(p[0].length,p[1]+1));scrollTo(0,Math.max(0,r.getBoundingClientRect().top+scrollY-36));}programmaticY=scrollY;setTimeout(()=>{moving=false;send(offset);},0);}
      function highlights(items){for(const color of ['yellow','green','blue','purple'])CSS.highlights.delete('adaptive-'+color);const groups={};for(const item of items){const a=point(item.offset),b=point(item.offset+item.length);if(!a||!b)continue;const r=document.createRange();r.setStart(...a);r.setEnd(...b);(groups[item.color]??=[]).push(r);}for(const [color,ranges]of Object.entries(groups))CSS.highlights.set('adaptive-'+color,new Highlight(...ranges));let s=document.getElementById('adaptive-highlights');if(!s){s=document.createElement('style');s.id='adaptive-highlights';document.head.append(s);}s.textContent='::highlight(adaptive-yellow){background:#efcc65;color:#201b0c}::highlight(adaptive-green){background:#a2d9aa;color:#15251a}::highlight(adaptive-blue){background:#9ac9ed;color:#132532}::highlight(adaptive-purple){background:#d1b2e5;color:#24152e}::highlight(adaptive-speech){background:#bad8fc;color:#14283f}';}
      function playback(item){CSS.highlights.delete('adaptive-speech');if(!item)return;const a=point(item.offset),b=point(item.offset+item.length);if(!a||!b)return;const r=document.createRange();r.setStart(...a);r.setEnd(...b);CSS.highlights.set('adaptive-speech',new Highlight(r));}
      window.adaptive={go,highlights,playback,style:(css,offset)=>{let s=document.getElementById('adaptive-style');if(!s){s=document.createElement('style');s.id='adaptive-style';document.head.append(s);}s.textContent=css;styled=true;go(offset);}};
      addEventListener('scroll',()=>{if(!styled||moving||Math.abs(scrollY-programmaticY)<1)return;if(timer)return;timer=setTimeout(()=>{timer=null;if(Math.abs(scrollY-programmaticY)>=1)send(position());},120);},{passive:true});
      let selectionTimer;document.addEventListener('selectionchange',()=>{clearTimeout(selectionTimer);selectionTimer=setTimeout(()=>{const s=getSelection();if(!s||!s.rangeCount){send(position(),{selection:''});return;}const r=s.getRangeAt(0);function offset(n,o){const i=nodes.indexOf(n);if(i>=0)return starts[i]+o;const t=document.createRange();t.setStart(document.body,0);t.setEnd(n,o);let total=0;for(const node of nodes){if(t.comparePoint(node,node.length)===0)total+=node.length;}return total;}const start=offset(r.startContainer,r.startOffset);let end=Math.min(offset(r.endContainer,r.endOffset),start+8000);if(end>start&&/[\uD800-\uDBFF]/.test(text[end-1]))end--;send(start,{selection:text.slice(start,end),displaySelection:s.toString().slice(0,8000)});},100);});
      document.addEventListener('click',e=>{const a=e.target.closest('a');if(a){e.preventDefault();window.webkit.messageHandlers.reader.postMessage({path:decodeURIComponent(location.pathname),link:a.href});}},true);
      addEventListener('resize',()=>{if(styled)go(last.offset);});
      document.fonts.addEventListener('loadingdone',()=>{if(styled)go(last.offset);});
      function manual(){window.webkit.messageHandlers.reader.postMessage({path:decodeURIComponent(location.pathname),manual:true});}
      addEventListener('wheel',manual,{passive:true});addEventListener('pointerdown',manual,{passive:true});
      addEventListener('keydown',e=>{if(['ArrowDown','ArrowUp','PageDown','PageUp','Home','End',' '].includes(e.key))manual();});
    })();
    """#
}

@MainActor private final class EPUBMessageBridge: NSObject, WKScriptMessageHandler {
    weak var engine: EPUBReaderEngine?
    init(_ engine: EPUBReaderEngine) { self.engine = engine }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { engine?.userContentController(controller, didReceive: message) }
}
