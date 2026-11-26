import UIKit
import WebKit

/// Hidden browser that loads a play page and reports the first media request. WebKit does not show a page's own requests to
/// the app, so a script in every frame reports them (XHR, fetch, media elements, resource timing); navigations are judged by
/// the delegate. The view has a throw-away data store and goes away on success, failure, timeout and cancellation alike. At
/// most two run at once.
final class WebSniffer: Sniffer {
    private let ownPort: () -> Int
    private let gate = Gate(2)

    init(ownPort: @escaping () -> Int) { self.ownPort = ownPort }

    func sniff(_ r: SniffRequest) async throws -> SniffResult {
        guard let url = TVBoxUrl.url(r.url), TVBoxUrl.isHttp(r.url) else { throw TVBoxError("解析地址无效：\(r.url.prefix(80))") }
        try await gate.enter()
        do {
            let out = try await SniffSession.run(r, url, ownPort: ownPort())
            await gate.leave()
            return out
        } catch {
            await gate.leave()
            throw error
        }
    }

    /// Counting semaphore for tasks; a cancelled task leaves the queue.
    private actor Gate {
        private var free: Int
        private var queue: [(id: UUID, c: CheckedContinuation<Void, Error>)] = []
        init(_ n: Int) { free = n }

        func enter() async throws {
            if free > 0 { free -= 1; return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { c.resume(throwing: CancellationError()) } else { queue.append((id, c)) }
                }
            } onCancel: { Task { await self.cancel(id) } }
        }

        private func cancel(_ id: UUID) {
            guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
            queue.remove(at: i).c.resume(throwing: CancellationError())
        }

        func leave() { if queue.isEmpty { free += 1 } else { queue.removeFirst().c.resume() } }
    }
}

/// One page.
@MainActor
private final class SniffSession: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let r: SniffRequest
    private let ownPort: Int
    private let userAgent: String
    private var view: WKWebView?
    private var page: String
    private var seen = Set<String>()
    private var adHosts: [String: Bool] = [:]
    private var checks: [Task<Void, Never>] = []
    private var continuation: CheckedContinuation<SniffResult, Error>?
    private var outcome: Result<SniffResult, Error>?

    static func run(_ r: SniffRequest, _ url: URL, ownPort: Int) async throws -> SniffResult {
        try Task.checkCancellation()
        let s = SniffSession(r, ownPort: ownPort)
        defer { s.close() }
        return try await withTaskCancellationHandler {
            try await s.open(url)
            let timeout = Task { [weak s] in
                try? await Task.sleep(nanoseconds: UInt64(max(r.timeoutMs, 100)) * 1_000_000)
                if !Task.isCancelled { s?.finish(.failure(TVBoxError("解析超时，没有嗅探到播放地址"))) }
            }
            defer { timeout.cancel() }
            return try await s.result()
        } onCancel: { Task { @MainActor in s.finish(.failure(CancellationError())) } }
    }

    private init(_ r: SniffRequest, ownPort: Int) {
        self.r = r
        self.ownPort = ownPort
        page = r.url
        userAgent = r.headers.first { $0.key.caseInsensitiveCompare("user-agent") == .orderedSame }?.value ?? Self.phone
    }

    private static let phone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    // MARK: Life cycle

    private func open(_ url: URL) async throws {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = false
        cfg.allowsPictureInPictureMediaPlayback = false
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.userContentController.addUserScript(WKUserScript(source: Self.hooks, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController.add(Weak(self), name: "idjSniff")
        for list in await BlockLists.lists(ads: r.ads, allowPrivate: r.allowPrivate, ownPort: ownPort) { cfg.userContentController.add(list) }
        if outcome != nil { return }

        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let v = WKWebView(frame: window?.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844), configuration: cfg)
        v.customUserAgent = userAgent
        v.navigationDelegate = self
        v.uiDelegate = self
        v.isUserInteractionEnabled = false
        v.accessibilityElementsHidden = true
        // in the window, or WebKit throttles its timers and media; behind everything and practically transparent
        v.alpha = 0.01
        window?.insertSubview(v, at: 0)
        view = v

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        for (k, value) in r.headers {
            switch k.lowercased() {
            case "user-agent": break
            case "cookie":
                for pair in value.split(separator: ";") {
                    guard let i = pair.firstIndex(of: "="), let host = url.host,
                          let c = HTTPCookie(properties: [.name: pair[..<i].trimmingCharacters(in: .whitespaces), .value: String(pair[pair.index(after: i)...]), .domain: host, .path: "/"]) else { continue }
                    await cfg.websiteDataStore.httpCookieStore.setCookie(c)
                }
            default: req.setValue(value, forHTTPHeaderField: k)
            }
        }
        if outcome == nil { v.load(req) }
    }

    private func result() async throws -> SniffResult {
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { c in
            if let outcome { c.resume(with: outcome) } else { continuation = c }
        }
    }

    fileprivate func finish(_ r: Result<SniffResult, Error>) {
        guard outcome == nil else { return }
        outcome = r
        continuation?.resume(with: r)
        continuation = nil
    }

    private func close() {
        checks.forEach { $0.cancel() }
        guard let v = view else { return }
        view = nil
        v.navigationDelegate = nil
        v.uiDelegate = nil
        v.stopLoading()
        v.configuration.userContentController.removeScriptMessageHandler(forName: "idjSniff")
        v.configuration.userContentController.removeAllUserScripts()
        v.configuration.userContentController.removeAllContentRuleLists()
        v.load(URLRequest(url: URL(string: "about:blank")!))   // ends media that is still playing
        v.removeFromSuperview()
    }

    // MARK: Judging addresses

    /// `referrer`: address of the frame that asked; `cors`: the request carried an `Origin`.
    private func consider(_ url: String, referrer: String, cors: Bool) {
        guard outcome == nil, TVBoxUrl.isHttp(url), seen.count < 3000, seen.insert(url).inserted else { return }
        let host = TVBoxUrl.host(url)
        if isAd(host) || !literalAllowed(url, host) { return }
        if let manual = r.isVideo {
            checks.append(Task { [weak self] in
                if await manual(url), !Task.isCancelled { await self?.found(url, referrer, cors) }
            })
        } else if SniffCheck.isVideo(url, page: page, rules: r.rules) {
            checks.append(Task { [weak self] in await self?.found(url, referrer, cors) })
        }
    }

    private func found(_ url: String, _ referrer: String, _ cors: Bool) async {
        guard outcome == nil else { return }
        var h = ["User-Agent": userAgent]
        if let from = URL(string: referrer), let scheme = from.scheme, let host = from.host, scheme.hasPrefix("http") {
            let origin = "\(scheme)://\(host)" + (from.port.map { ":\($0)" } ?? "")
            let same = url.hasPrefix(origin + "/")
            // browsers only tell other origins where the request came from, not which page
            if !(scheme == "https" && url.hasPrefixIgnoringCase("http://")) { h["Referer"] = same ? referrer.substringBefore("#") : origin + "/" }
            if cors, !same { h["Origin"] = origin }
        }
        if let store = view?.configuration.websiteDataStore.httpCookieStore, let target = TVBoxUrl.url(url), let host = target.host?.lowercased() {
            let mine = await store.allCookies().filter { c in
                let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return (host == d || host.hasSuffix("." + d)) && (target.path.isEmpty ? "/" : target.path).hasPrefix(c.path) && (!c.isSecure || target.scheme == "https")
            }
            if !mine.isEmpty { h["Cookie"] = mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }
        }
        finish(.success(SniffResult(url: url, headers: h)))
    }

    /// A page asks few hosts many times; a config's list may be long.
    private func isAd(_ host: String) -> Bool {
        if let known = adHosts[host] { return known }
        let ad = SniffCheck.isAd(host, r.ads)
        adHosts[host] = ad
        return ad
    }

    /// Address policy for literal hosts; names are resolved before a navigation.
    private func literalAllowed(_ url: String, _ host: String) -> Bool {
        if host == "localhost" || host.hasPrefix("127.") || host == "::1" { return ownPort > 0 && URL(string: url)?.port == ownPort }
        return r.allowPrivate || !NetGuard.isIPLiteral(host) || !NetGuard.isBlockedIP(host)
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let o = m.body as? [String: Any], let raw = o["u"] as? String, raw.utf8.count < 16_000 else { return }
        let from = (o["p"] as? String) ?? m.frameInfo.request.url?.absoluteString ?? page
        consider(raw.trimmed, referrer: from, cors: J.bool(o["c"]))
    }

    // MARK: Navigation

    func webView(_ v: WKWebView, decidePolicyFor a: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = a.request.url?.absoluteString, outcome == nil else { return .cancel }
        if url.hasPrefix("about:") || url.hasPrefix("blob:") || url.hasPrefix("data:") { return .allow }
        // app links never leave the sniffer
        guard TVBoxUrl.isHttp(url) else { return .cancel }
        let host = TVBoxUrl.host(url), main = a.targetFrame?.isMainFrame == true
        guard literalAllowed(url, host) else {
            if main { finish(.failure(TVBoxError("\(host) 是本机或内网地址，已拦截"))) }
            return .cancel
        }
        if isAd(host) { return .cancel }
        let referrer = a.request.value(forHTTPHeaderField: "Referer") ?? page
        if main { page = url }
        if r.isVideo != nil { consider(url, referrer: referrer, cors: false) } else if SniffCheck.isVideo(url, page: page, rules: r.rules) {
            consider(url, referrer: referrer, cors: false)
            return .cancel
        }
        if r.allowPrivate || NetGuard.isIPLiteral(host) { return .allow }
        // a blocking lookup has no place on the cooperative pool
        let blocked = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in TVBoxWorkers.run { c.resume(returning: NetGuard.resolvesToBlocked(host)) } }
        if !blocked { return .allow }
        if main { finish(.failure(TVBoxError("\(host) 指向本机或内网地址，已拦截"))) }
        return .cancel
    }

    func webView(_ v: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let type = (response.response.mimeType ?? "").lowercased()
        let media = type.hasPrefix("video/") || type.hasPrefix("audio/") || type.contains("mpegurl") || type == "application/dash+xml"
        if media, r.isVideo == nil, let url = response.response.url?.absoluteString, !SniffCheck.excluded(url, page: page, rules: r.rules) {
            await found(url, page, false)
            return .cancel
        }
        return response.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ v: WKWebView, didFinish navigation: WKNavigation!) {
        guard outcome == nil, v.url?.absoluteString != "about:blank" else { return }
        for (i, s) in r.scripts.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i)) { [weak self] in
                guard let self, self.outcome == nil else { return }
                self.view?.evaluateJavaScript(s) { _, _ in }
            }
        }
    }

    func webView(_ v: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let e = error as NSError
        // policy cancellations (a media address, an ad) are not failures of the page
        if (e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled) || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }
        if v.url == nil || v.url?.absoluteString == r.url { finish(.failure(TVBoxError("解析页面打不开：" + SpiderErrors.text(error)))) }
    }

    func webViewWebContentProcessDidTerminate(_ v: WKWebView) { finish(.failure(TVBoxError("解析页面崩溃"))) }

    // MARK: Dialogs

    func webView(_ v: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo) async {}
    func webView(_ v: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo) async -> Bool { false }
    func webView(_ v: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText: String?, initiatedByFrame f: WKFrameInfo) async -> String? { nil }
    func webView(_ v: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    /// The content controller keeps its handlers alive.
    private final class Weak: NSObject, WKScriptMessageHandler {
        private weak var target: WKScriptMessageHandler?
        init(_ t: WKScriptMessageHandler) { target = t }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
    }

    /// Runs before the page's own scripts, in every frame. Media is muted: nobody is watching.
    private static let hooks = #"""
    (function () {
      'use strict';
      if (window.__idjSniff) return;
      try { Object.defineProperty(window, '__idjSniff', { value: true }); } catch (e) { return; }
      var port = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.idjSniff;
      if (!port) return;
      var sent = {}, count = 0;
      function say(u, cors) {
        try {
          if (!u) return;
          u = new URL(String(u && u.url || u), document.baseURI || location.href).href;
          if (u.slice(0, 4) !== 'http' || sent[u] || count > 4000) return;
          sent[u] = 1; count++;
          port.postMessage({ u: u, p: location.href, c: !!cors });
        } catch (e) { /* not an address */ }
      }
      var xhrOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u) { say(u, true); return xhrOpen.apply(this, arguments); };
      if (window.fetch) {
        var realFetch = window.fetch;
        window.fetch = function (u) { say(u, true); return realFetch.apply(this, arguments); };
      }
      function quiet(el) { try { el.muted = true; el.volume = 0; } catch (e) { /* not media */ } }
      var MediaEl = window.HTMLMediaElement && HTMLMediaElement.prototype;
      if (MediaEl) {
        var src = Object.getOwnPropertyDescriptor(MediaEl, 'src');
        if (src && src.set) Object.defineProperty(MediaEl, 'src', { configurable: true, enumerable: src.enumerable, get: src.get, set: function (v) { quiet(this); say(v, false); return src.set.call(this, v); } });
        var play = MediaEl.play;
        MediaEl.play = function () { quiet(this); say(this.currentSrc || this.getAttribute('src'), false); return play.apply(this, arguments); };
        var load = MediaEl.load;
        MediaEl.load = function () { quiet(this); look(this); return load.apply(this, arguments); };
      }
      var SourceEl = window.HTMLSourceElement && HTMLSourceElement.prototype;
      if (SourceEl) {
        var ssrc = Object.getOwnPropertyDescriptor(SourceEl, 'src');
        if (ssrc && ssrc.set) Object.defineProperty(SourceEl, 'src', { configurable: true, enumerable: ssrc.enumerable, get: ssrc.get, set: function (v) { say(v, false); return ssrc.set.call(this, v); } });
      }
      var setAttr = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (k, v) {
        if (String(k).toLowerCase() === 'src' && /^(video|audio|source)$/i.test(this.tagName)) say(v, false);
        return setAttr.apply(this, arguments);
      };
      var create = URL.createObjectURL;
      if (create) URL.createObjectURL = function (o) {
        // media source: its parts come by XHR / fetch, which are watched already
        try { if (window.MediaSource && o instanceof MediaSource) o.addEventListener('sourceopen', scan); } catch (e) { /* ignored */ }
        return create.apply(this, arguments);
      };
      function look(el) {
        if (!el || !el.tagName) return;
        if (/^(video|audio)$/i.test(el.tagName)) { quiet(el); say(el.currentSrc || el.getAttribute('src'), false); }
        else if (/^source$/i.test(el.tagName)) say(el.getAttribute('src'), false);
      }
      function scan() { try { document.querySelectorAll('video,audio,source').forEach(look); } catch (e) { /* ignored */ } }
      try {
        new MutationObserver(function (list) {
          list.forEach(function (m) {
            if (m.type === 'attributes') look(m.target);
            else m.addedNodes.forEach(function (n) { if (n.nodeType === 1) { look(n); if (n.querySelectorAll && n.childElementCount) n.querySelectorAll('video,audio,source').forEach(look); } });
          });
        }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
      } catch (e) { /* ignored */ }
      try {
        new PerformanceObserver(function (list) {
          list.getEntries().forEach(function (e) { say(e.name, e.initiatorType === 'xmlhttprequest' || e.initiatorType === 'fetch'); });
        }).observe({ type: 'resource', buffered: true });
      } catch (e) { /* ignored */ }
      ['loadstart', 'loadedmetadata', 'play', 'error'].forEach(function (n) { document.addEventListener(n, function (e) { look(e.target); }, true); });
      document.addEventListener('DOMContentLoaded', scan);
      window.addEventListener('load', scan);
    })();
    """#
}

/// Compiled content rules: what a hidden page has no business loading.
@MainActor
private enum BlockLists {
    private static let prefix = "idj-sniff-"

    static func lists(ads: [String], allowPrivate: Bool, ownPort: Int) async -> [WKContentRuleList] {
        func rule(_ filter: String, _ types: [String]? = nil, action: String = "block") -> [String: Any] {
            var trigger: [String: Any] = ["url-filter": filter]
            if let types { trigger["resource-type"] = types }
            return ["trigger": trigger, "action": ["type": action]]
        }
        var rules = [rule(".*", ["image", "font"])]
        // rule regexes know neither alternatives nor look-ahead: plain host names only, the rest is judged in `consider`
        for a in Set(ads.map { $0.lowercased() }).sorted().prefix(2000) where !a.isEmpty && a.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d || $0 == 0x2e }) && a.contains(".") {
            rules.append(rule("^[a-z]+://([^/:]*\\.)?" + a.replacingOccurrences(of: ".", with: "\\.") + "[/:]"))
        }
        if !allowPrivate {
            for f in ["10\\.", "192\\.168\\.", "169\\.254\\.", "172\\.1[6-9]\\.", "172\\.2[0-9]\\.", "172\\.3[01]\\.", "0\\.", "\\[f[cde]"] { rules.append(rule("^[a-z]+://" + f)) }
        }
        for f in ["127\\.", "localhost[/:]", "\\[::1\\]"] { rules.append(rule("^[a-z]+://" + f)) }
        if ownPort > 0 { rules.append(rule("^http://127\\.0\\.0\\.1:\(ownPort)/", action: "ignore-previous-rules")) }
        guard let store = WKContentRuleListStore.default() else { return [] }
        let json = RT.json(rules), id = prefix + Bytes.hex(Bytes.md5(json))
        if let hit = await withCheckedContinuation({ c in store.lookUpContentRuleList(forIdentifier: id) { list, _ in c.resume(returning: list) } }) { return [hit] }
        guard let made = await withCheckedContinuation({ c in store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, _ in c.resume(returning: list) } }) else { return [] }
        // one config rarely has more than a couple of variants
        store.getAvailableContentRuleListIdentifiers { ids in
            let old = (ids ?? []).filter { $0.hasPrefix(prefix) && $0 != id }
            if old.count > 12 { for x in old { store.removeContentRuleList(forIdentifier: x) { _ in } } }
        }
        return [made]
    }
}

/// Which addresses count. The page decides which of the config's rules apply; `SniffRules` keeps the compiled patterns.
enum SniffCheck {
    static func excluded(_ u: String, page: String, rules: [TVBoxRule]) -> Bool { SniffRules.excluded(u, page, rules) }
    static func isVideo(_ u: String, page: String, rules: [TVBoxRule]) -> Bool { SniffRules.isVideo(u, page, rules) }
    static func isAd(_ host: String, _ ads: [String]) -> Bool { SniffRules.isAd(host, ads) }
}
