import XCTest
import UIKit
@testable import STV

/// 1.5 plugin runtime: sandbox isolation, host API, manifest validation, bundled comic plugins (offline fixtures),
/// JM stripe unscramble, 苹果 CMS parsing and the minors content filter.
final class PluginTests: XCTestCase {

    // MARK: helpers

    static func manifest(id: String = "com.test.sandbox", http: [String] = ["example.com", "*.example.com"], storage: Bool = false,
                         type: String = "comic", caps: [String] = ["detail", "pages"], extra: [String: Any] = [:]) -> PluginManifest {
        var o: [String: Any] = ["schema": 1, "id": id, "name": "T", "version": "1.0.0", "author": ["name": "t"], "type": type, "adult": false,
                                "minAppVersion": "1.5", "entry": "main.js", "permissions": ["http": http, "storage": storage], "capabilities": caps]
        for (k, v) in extra { o[k] = v }
        return try! PluginManifest.decode(try! JSONSerialization.data(withJSONObject: o))
    }

    static let stub = "export default { async detail(){ return {} }, async pages(){ return {images:[]} } };"

    func instance(_ src: String = PluginTests.stub, manifest m: PluginManifest = PluginTests.manifest()) throws -> PluginInstance {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try PluginInstance(manifest: m, source: src, dir: dir, settings: [:], extraDomains: [], learnedUA: nil)
    }

    func code(_ e: Error) -> String {
        if case let PluginError.runtime(code, _) = e { return code }
        return "\(e)"
    }

    func expectCode(_ want: String, _ body: () async throws -> Any, file: StaticString = #filePath, line: UInt = #line) async {
        do { let v = try await body(); XCTFail("expected \(want), got \(v)", file: file, line: line) }
        catch { XCTAssertEqual(code(error), want, "\(error)", file: file, line: line) }
    }

    static func fixture(_ path: String) -> Data {
        (try? Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Plugins/" + path))) ?? Data()
    }

    /// Longest-prefix URL → fixture file responder.
    static func responder(_ map: [String: String]) -> (URLRequest) -> PluginFixtures.Reply? {
        { req in
            let u = req.url?.absoluteString ?? ""
            guard let k = map.keys.filter({ u.hasPrefix($0) }).max(by: { $0.count < $1.count }) else { return PluginFixtures.Reply(status: 404, body: Data()) }
            return PluginFixtures.Reply(status: 200, headers: ["content-type": "text/html; charset=utf-8"], body: fixture(map[k]!))
        }
    }

    override func tearDown() {
        PluginFixtures.responder = nil
        PluginNet.testProtocolClasses = nil
        NetGuard.resolverOverride = nil
        super.tearDown()
    }

    // MARK: sandbox isolation

    func testEvalAndFunctionConstructorsAreBlocked() async throws {
        let p = try instance()
        defer { p.shutdown() }
        for src in ["eval('1+1')", "new Function('return 1')()", "Function('return 1')()",
                    "(async function(){}).constructor('return 1')()", "(function*(){}).constructor('yield 1')().next()"] {
            do { _ = try await p.evalForTest(src); XCTFail("\(src) should throw") }
            catch { XCTAssertTrue("\(error)".lowercased().contains("eval") || "\(error)".contains("not supported") || code(error) != "", "\(src): \(error)") }
        }
        let leaked = try await p.evalForTest("typeof __host + ',' + typeof require + ',' + typeof fetch + ',' + typeof XMLHttpRequest + ',' + typeof std + ',' + typeof os")
        XCTAssertEqual(leaked as? String, "undefined,undefined,undefined,undefined,undefined,undefined")
        let frozen = try await p.evalForTest("(() => { try { host.http.request = 1 } catch(e) {} ; return Object.isFrozen(host) && Object.isFrozen(host.http) })()")
        XCTAssertEqual(frozen as? Bool, true)
    }

    func testImportIsRejected() throws {
        XCTAssertThrowsError(try instance("import x from './lib.js'; export default { detail(){}, pages(){} };"))
        XCTAssertThrowsError(try instance("export default 42;"))
    }

    func testInfiniteLoopTimesOut() async throws {
        let p = try instance("export default { detail(){}, pages(){}, async home(){ for(;;){} } };")
        defer { p.shutdown() }
        let t = Date()
        await expectCode("E_TIMEOUT") { try await p.call("home", [:], timeout: 1) }
        XCTAssertLessThan(Date().timeIntervalSince(t), 5)
        // The instance stays usable after an interrupt.
        let ok = try await p.evalForTest("1+2")
        XCTAssertEqual(ok as? Int, 3)
    }

    func testMemoryCap() async throws {
        let p = try instance("export default { detail(){}, pages(){}, async home(){ const a=[]; for(;;) a.push('x'.repeat(1<<20) + a.length) } };")
        defer { p.shutdown() }
        await expectCode("E_MEMORY") { try await p.call("home", [:], timeout: 20) }
    }

    func testHttpAllowListAndAddressGuards() async throws {
        PluginFixtures.responder = { _ in PluginFixtures.Reply(body: Data("ok".utf8)) }
        let p = try instance()
        defer { p.shutdown() }
        let ok = try await p.evalForTest("(async () => (await host.http.get('https://www.example.com/a')).body)()")
        XCTAssertEqual(ok as? String, "ok")
        for u in ["https://evil.test/", "https://127.0.0.1/", "https://[::1]/", "http://example.com:8080/", "file:///etc/passwd", "ftp://example.com/"] {
            do { _ = try await p.evalForTest("(async () => (await host.http.get('\(u)')).status)()"); XCTFail("\(u) should be blocked") }
            catch { XCTAssertEqual(code(error), "E_PERMISSION", "\(u): \(error)") }
        }
        let allowed = try await p.evalForTest("[host.http.allowed('https://example.com/'), host.http.allowed('https://example.com.evil.test/'), host.http.allowed('https://10.0.0.1/')]")
        XCTAssertEqual(allowed as? [Bool], [true, false, false])
    }

    func testPrivateDNSAndLoopbackResolutionBlocked() async throws {
        NetGuard.resolverOverride = { h in h.hasPrefix("lan.") ? ["192.168.1.10"] : h.hasPrefix("lo.") ? ["127.0.0.1"] : h.hasPrefix("v6.") ? ["fd00::1"] : ["93.184.216.34"] }
        for ip in ["10.1.2.3", "172.16.0.1", "192.168.0.1", "127.0.0.1", "169.254.1.1", "100.64.0.1", "::1", "fe80::1", "fd12::1", "0.0.0.0"] {
            XCTAssertTrue(NetGuard.isBlockedIP(ip), ip)
        }
        XCTAssertFalse(NetGuard.isBlockedIP("93.184.216.34"))
        XCTAssertFalse(NetGuard.isBlockedIP("198.18.0.5"), "Clash fake-ip range must stay usable")
        let p = try instance()
        defer { p.shutdown() }
        for h in ["lan.example.com", "lo.example.com", "v6.example.com"] {
            do { _ = try await p.evalForTest("(async () => (await host.http.get('https://\(h)/')).status)()"); XCTFail(h) }
            catch { XCTAssertEqual(code(error), "E_PERMISSION", "\(h): \(error)") }
        }
    }

    final class RedirectStub: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let u = request.url!
            if u.host == "a.example.com" {
                let to = URL(string: u.path == "/ok" ? "https://b.example.com/final" : "https://evil.test/steal")!
                let r = HTTPURLResponse(url: u, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": to.absoluteString, "Set-Cookie": "sid=1; Path=/"])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: to), redirectResponse: r)
                return
            }
            let r = HTTPURLResponse(url: u, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("final".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testRedirectToUnlistedHostIsBlocked() async throws {
        PluginNet.testProtocolClasses = [RedirectStub.self]
        NetGuard.resolverOverride = { _ in ["93.184.216.34"] }
        let p = try instance()
        defer { p.shutdown() }
        let ok = try await p.evalForTest("(async () => { const r = await host.http.get('https://a.example.com/ok'); return r.body + '@' + r.url })()")
        XCTAssertEqual(ok as? String, "final@https://b.example.com/final")
        await expectCode("E_PERMISSION") { try await p.evalForTest("(async () => (await host.http.get('https://a.example.com/bad')).body)()") }
    }

    func testForbiddenHeadersAndPerPluginCookies() async throws {
        var seen: [URLRequest] = []
        PluginFixtures.responder = { r in seen.append(r); return PluginFixtures.Reply(body: Data("x".utf8)) }
        let a = try instance(manifest: Self.manifest(id: "com.test.a"))
        let b = try instance(manifest: Self.manifest(id: "com.test.b"))
        defer { a.shutdown(); b.shutdown() }
        a.host.net.jar.add([HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "sid", .value: "A", .secure: "TRUE"])!])
        _ = try await a.evalForTest("(async () => (await host.http.get('https://example.com/', { headers: { Cookie: 'sid=forged', Host: 'evil.test', Referer: 'https://example.com/' } })).status)()")
        _ = try await b.evalForTest("(async () => (await host.http.get('https://example.com/')).status)()")
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0].value(forHTTPHeaderField: "Cookie"), "sid=A", "own jar only, forged Cookie header dropped")
        XCTAssertNotEqual(seen[0].value(forHTTPHeaderField: "Host"), "evil.test")
        XCTAssertEqual(seen[0].value(forHTTPHeaderField: "Referer"), "https://example.com/")
        XCTAssertNil(seen[1].value(forHTTPHeaderField: "Cookie"), "plugin B must not see plugin A's cookies")
        XCTAssertFalse((HTTPCookieStorage.shared.cookies ?? []).contains { $0.name == "sid" && $0.value == "A" })
    }

    func testStorageNeedsPermissionAndIsPerPlugin() async throws {
        let none = try instance()
        defer { none.shutdown() }
        await expectCode("E_PERMISSION") { try await none.evalForTest("host.storage.set('k', 1)") }
        let a = try instance(manifest: Self.manifest(id: "com.test.sa", storage: true))
        let b = try instance(manifest: Self.manifest(id: "com.test.sb", storage: true))
        defer { a.shutdown(); b.shutdown() }
        _ = try await a.evalForTest("host.storage.set('k', {v: 1})")
        let mine = try await a.evalForTest("host.storage.get('k').v")
        let other = try await b.evalForTest("host.storage.get('k')")
        XCTAssertEqual(mine as? Int, 1)
        XCTAssertTrue(other is NSNull)
        await expectCode("E_STORAGE_FULL") { try await a.evalForTest("host.storage.set('big', 'x'.repeat(1100000))") }
    }

    func testErrorsCarryCodes() async throws {
        let p = try instance("export default { detail(){ throw host.error('E_NOT_FOUND', 'gone') }, pages(){ return null.x } };")
        defer { p.shutdown() }
        await expectCode("E_NOT_FOUND") { try await p.call("detail", [:]) }
        await expectCode("E_INTERNAL") { try await p.call("pages", [:]) }
    }

    // MARK: host API

    func testCSSSelectorsAndHTML() async throws {
        let p = try instance()
        defer { p.shutdown() }
        let html = #"<div id='m'><ul class='l x'><li class='a'><a href='/p/1' data-x='1'>One</a></li><li><a href='/p/2' title='T2'>Two</a></li><li class='a b'><a href='https://cdn.example.com/3.jpg'>Three</a></li></ul><p>t <b>bold</b></p><img data-original='/media/photos/1/00001.webp'></div>"#
        let js = """
        (() => { const d = host.html.parse(\(String(decoding: try JSONSerialization.data(withJSONObject: [html], options: [.fragmentsAllowed]), as: UTF8.self))[0]);
          return [ d.select('li').length, d.select('ul.l.x > li.a a').map(a => a.text()).join('|'), d.select('a[href^="/p/"]').length,
                   d.select('a[href$=".jpg"]').length, d.select('a[href*="/p/2"]')[0].attr('title'), d.select('li:first-child a')[0].text(),
                   d.select('li:last-child a')[0].text(), d.select('li:nth-child(2) a')[0].text(), d.select('li:not(.a)').length,
                   d.selectFirst('#m p').text(), d.selectFirst('p').html(), d.select('a[data-x], img[data-original*="/media/photos/"]').length,
                   d.selectFirst('.nope') === null, d.select('li').map(li => li.select('a').length).join('') ] })()
        """
        let r = try await p.evalForTest(js) as? [Any]
        XCTAssertEqual(r?[0] as? Int, 3)
        XCTAssertEqual(r?[1] as? String, "One|Three")
        XCTAssertEqual(r?[2] as? Int, 2)
        XCTAssertEqual(r?[3] as? Int, 1)
        XCTAssertEqual(r?[4] as? String, "T2")
        XCTAssertEqual(r?[5] as? String, "One")
        XCTAssertEqual(r?[6] as? String, "Three")
        XCTAssertEqual(r?[7] as? String, "Two")
        XCTAssertEqual(r?[8] as? Int, 1)
        XCTAssertEqual(r?[9] as? String, "t bold")
        XCTAssertEqual(r?[10] as? String, "t <b>bold</b>")
        XCTAssertEqual(r?[11] as? Int, 2)
        XCTAssertEqual(r?[12] as? Bool, true)
        XCTAssertEqual(r?[13] as? String, "111")
    }

    func testMediaTransformDeclarationValidation() throws {
        let aes: [String: Any] = [
            "type": "aes", "key": "f5d965df75336270", "iv": "97b60394abc2fbe1",
            "keyEncoding": "utf8", "mode": "cbc", "padding": "pkcs7"
        ]
        let accepted = try XCTUnwrap(PluginOut.mediaTransform(aes))
        XCTAssertEqual(accepted["type"] as? String, "aes")
        XCTAssertEqual(accepted["key"] as? String, "f5d965df75336270")
        XCTAssertEqual(accepted["iv"] as? String, "97b60394abc2fbe1")
        XCTAssertEqual(PluginOut.mediaTransform(["type": "stripes", "segments": 10])?["segments"] as? Int, 10)
        XCTAssertNil(PluginOut.mediaTransform(["type": "unknown"]))
        XCTAssertNil(PluginOut.mediaTransform("aes"))
    }

    func testDynamicImageDomainsAreLearnedPerPluginFromAuthorizedSourceResponses() async throws {
        let pluginID = "com.test.sandbox"
        PluginMediaDomainCache.clear(pluginID: pluginID)
        PluginMediaDomainCache.clear(pluginID: "com.test.other")

        // Nuxt payloads can serialize image URLs in indexed tables, so the
        // image key is not adjacent to the URL in the raw response. The
        // provider's typed cover reference is the authoritative image signal.
        let nuxtID = "com.test.nuxt-image"
        PluginMediaDomainCache.clear(pluginID: nuxtID)
        PluginMediaDomainCache.learn(pluginID: nuxtID,
                                     sourceURL: URL(string: "https://yeguodj.com/_payload.json")!,
                                     sourcePolicy: DomainPolicy(["yeguodj.com"]),
                                     contentType: "application/json",
                                     body: Data(#"{"table":["cover","https://pic.vojggi.cn/no-extension"]}"#.utf8))
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: nuxtID).isEmpty,
                      "observing a CDN in a trusted response alone must not grant image access")
        _ = PluginMedia.ref(plugin: nuxtID, url: "https://pic.vojggi.cn/no-extension")
        XCTAssertEqual(PluginMediaDomainCache.domains(pluginID: nuxtID), ["pic.vojggi.cn"])
        XCTAssertTrue(PluginMedia.allows(URL(string: "https://pic.vojggi.cn/no-extension")!,
                                         explicitPolicy: DomainPolicy(["yeguodj.com"]),
                                         learnedHosts: Set(PluginMediaDomainCache.domains(pluginID: nuxtID))))
        _ = PluginMedia.ref(plugin: nuxtID, url: "https://unobserved-cdn.example.net/no-extension")
        XCTAssertEqual(PluginMediaDomainCache.domains(pluginID: nuxtID), ["pic.vojggi.cn"],
                       "provider output cannot authorize a host absent from a trusted response")
        PluginMediaDomainCache.clear(pluginID: nuxtID)

        let insecureImageID = "com.test.insecure-image"
        PluginMediaDomainCache.clear(pluginID: insecureImageID)
        _ = PluginMedia.ref(plugin: insecureImageID, url: "http://pic.vojggi.cn/no-extension")
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: insecureImageID).isEmpty,
                      "dynamic image learning must remain HTTPS-only")
        PluginMediaDomainCache.clear(pluginID: insecureImageID)
        let payload = #"{"cover":"https:\/\/img-cdn.example.net/posters/cover","stream":"https://video-cdn.example.net/index.m3u8","api":"https://api-cdn.example.net/data","legacy":"http://old-image.example.net/cover.jpg"}"#
        PluginFixtures.responder = { _ in
            PluginFixtures.Reply(status: 200, headers: ["content-type": "application/json"], body: Data(payload.utf8))
        }
        let p = try instance()
        defer {
            p.shutdown()
            PluginFixtures.responder = nil
            PluginMediaDomainCache.clear(pluginID: pluginID)
        }

        let status = try await p.evalForTest("(async () => (await host.http.get('https://example.com/payload')).status)()")
        XCTAssertEqual(status as? Int, 200)
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: pluginID).isEmpty,
                      "a trusted response creates candidates, not permissions")
        _ = PluginMedia.ref(plugin: pluginID, url: "https://img-cdn.example.net/posters/cover")
        XCTAssertEqual(PluginMediaDomainCache.domains(pluginID: pluginID), ["img-cdn.example.net"])
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: "com.test.other").isEmpty,
                      "learned image hosts must not cross plugin boundaries")

        // A familiar file suffix in an unrelated field must not grant image access.
        let unrelatedID = "com.test.unrelated-url"
        PluginMediaDomainCache.learn(pluginID: unrelatedID,
                                     sourceURL: URL(string: "https://example.com/page")!,
                                     sourcePolicy: DomainPolicy(["example.com"]),
                                     contentType: "application/json",
                                     body: Data(#"{"analytics":"https://tracking-cdn.example.net/pixel.jpg","video":"https://video-cdn.example.net/poster.mp4"}"#.utf8))
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: unrelatedID).isEmpty)
        PluginMediaDomainCache.clear(pluginID: unrelatedID)

        // Generic JSON src and HTML video/script src are ambiguous, not image evidence.
        let ambiguousID = "com.test.ambiguous-src"
        PluginMediaDomainCache.learn(pluginID: ambiguousID,
                                     sourceURL: URL(string: "https://example.com/page")!,
                                     sourcePolicy: DomainPolicy(["example.com"]),
                                     contentType: "application/json",
                                     body: Data(#"{"src":"https://json-src-cdn.example.net/file","poster":"https://json-poster-cdn.example.net/poster"}"#.utf8))
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: ambiguousID).isEmpty,
                      "even explicit image-looking fields require native image classification")
        PluginMediaDomainCache.clear(pluginID: ambiguousID)

        let htmlID = "com.test.html-image-src"
        PluginMediaDomainCache.learn(pluginID: htmlID,
                                     sourceURL: URL(string: "https://example.com/page")!,
                                     sourcePolicy: DomainPolicy(["example.com"]),
                                     contentType: "text/html",
                                     body: Data(#"<img class="cover" src="https://img-tag-cdn.example.net/no-extension"><video src="https://video-src-cdn.example.net/movie"><script src="https://script-src-cdn.example.net/app.js"></script><video poster="https://video-poster-cdn.example.net/poster">"#.utf8))
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: htmlID).isEmpty,
                      "HTML image tags are candidates, not direct permissions")
        _ = PluginMedia.ref(plugin: htmlID, url: "https://img-tag-cdn.example.net/no-extension")
        XCTAssertEqual(PluginMediaDomainCache.domains(pluginID: htmlID), ["img-tag-cdn.example.net"])
        PluginMediaDomainCache.clear(pluginID: htmlID)

        // IMAGE CDN declarations may contain a bare origin URL with no path.
        let imageListID = "com.test.image-list"
        PluginMediaDomainCache.clear(pluginID: imageListID)
        PluginMediaDomainCache.learn(pluginID: imageListID,
                                     sourceURL: URL(string: "https://example.com/ping")!,
                                     sourcePolicy: DomainPolicy(["example.com"]),
                                     contentType: "application/json",
                                     body: Data(#"{"sourceList":[{"type":"IMAGE","domain":[{"url":"https://bare-image-cdn.example.net","status":0},{"url":"bare-host-image-cdn.example.net","status":0}]}]}"#.utf8))
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: imageListID).isEmpty)
        _ = PluginMedia.ref(plugin: imageListID, url: "https://bare-image-cdn.example.net/poster")
        _ = PluginMedia.ref(plugin: imageListID, url: "https://bare-host-image-cdn.example.net/poster")
        XCTAssertEqual(PluginMediaDomainCache.domains(pluginID: imageListID).sorted(),
                       ["bare-host-image-cdn.example.net", "bare-image-cdn.example.net"])
        PluginMediaDomainCache.clear(pluginID: imageListID)

        // Redirects may use a newly observed CDN only in the context of an image request.
        let redirectID = "com.test.image-redirect"
        PluginMediaDomainCache.clear(pluginID: redirectID)
        PluginMediaDomainCache.learn(pluginID: redirectID,
                                     sourceURL: URL(string: "https://example.com/ping")!,
                                     sourcePolicy: DomainPolicy(["example.com"]),
                                     contentType: "application/json",
                                     body: Data(#"{"cdn":"https://redirect-image-cdn.example.net"}"#.utf8))
        NetGuard.resolverOverride = { _ in ["93.184.216.34"] }
        XCTAssertTrue(PluginMedia.allowsRedirect(pluginID: redirectID,
                                                 url: URL(string: "https://redirect-image-cdn.example.net/final.webp")!,
                                                 explicitPolicy: DomainPolicy(["example.com"]),
                                                 learnedHosts: []))
        XCTAssertEqual(PluginMediaDomainCache.domains(pluginID: redirectID), ["redirect-image-cdn.example.net"])
        XCTAssertFalse(PluginMedia.allowsRedirect(pluginID: redirectID,
                                                  url: URL(string: "https://unobserved-redirect.example.net/steal")!,
                                                  explicitPolicy: DomainPolicy(["example.com"]),
                                                  learnedHosts: []),
                       "an arbitrary public redirect target is still blocked")
        NetGuard.resolverOverride = nil
        PluginMediaDomainCache.clear(pluginID: redirectID)

        // Dynamic image permission is deliberately separate from host.http permission.
        await expectCode("E_PERMISSION") {
            try await p.evalForTest("(async () => (await host.http.get('https://img-cdn.example.net/cover.webp')).status)()")
        }

        let explicitMedia = DomainPolicy(["static-cdn.example.net"])
        let learned = Set(["img-cdn.example.net"])
        XCTAssertTrue(PluginMedia.allows(URL(string: "https://img-cdn.example.net/cover.webp")!,
                                         explicitPolicy: explicitMedia, learnedHosts: learned))
        XCTAssertFalse(PluginMedia.allows(URL(string: "http://img-cdn.example.net/cover.webp")!,
                                          explicitPolicy: explicitMedia, learnedHosts: learned),
                       "dynamically learned CDN hosts are HTTPS-only")
        XCTAssertFalse(PluginMedia.allows(URL(string: "https://evil.img-cdn.example.net/cover.webp")!,
                                          explicitPolicy: explicitMedia, learnedHosts: learned),
                       "learned permissions are exact hosts, not wildcard suffixes")
        XCTAssertFalse(PluginMedia.allows(URL(string: "https://user@img-cdn.example.net/cover.webp")!,
                                          explicitPolicy: explicitMedia, learnedHosts: learned),
                       "dynamic image URLs cannot carry credentials")
        XCTAssertFalse(PluginMedia.allows(URL(string: "https://img-cdn.example.net:8443/cover.webp")!,
                                          explicitPolicy: explicitMedia, learnedHosts: learned),
                       "dynamic image URLs use standard HTTPS only")
        XCTAssertTrue(PluginMedia.allows(URL(string: "http://static-cdn.example.net/cover.webp")!,
                                         explicitPolicy: explicitMedia, learnedHosts: learned),
                      "explicit manifest media permissions retain existing HTTP compatibility")

        // A response from a host outside this plugin's HTTP manifest cannot teach new image domains.
        PluginMediaDomainCache.learn(pluginID: pluginID, sourceURL: URL(string: "https://evil.example.net/page")!,
                                     sourcePolicy: DomainPolicy(["example.com"]), contentType: "application/json",
                                     body: Data(#"{"cover":"https://evil-cdn.example.net/cover.jpg"}"#.utf8))
        XCTAssertEqual(PluginMediaDomainCache.domains(pluginID: pluginID), ["img-cdn.example.net"])

        // Learning requires HTTPS at the trusted source as well as HTTPS at the CDN.
        let httpSourceID = "com.test.http-source"
        PluginMediaDomainCache.learn(pluginID: httpSourceID, sourceURL: URL(string: "http://example.com/page")!,
                                     sourcePolicy: DomainPolicy(["example.com"]), contentType: "text/html",
                                     body: Data(#"<img src="https://http-source-cdn.example.net/cover.jpg">"#.utf8))
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: httpSourceID).isEmpty)
        PluginMediaDomainCache.clear(pluginID: httpSourceID)

        // Cached permissions expire after 24 hours.
        let expiryID = "com.test.expiry"
        let old = Date(timeIntervalSince1970: 1_000)
        PluginMediaDomainCache.learn(pluginID: expiryID, sourceURL: URL(string: "https://example.com/page")!,
                                     sourcePolicy: DomainPolicy(["example.com"]), contentType: "application/json",
                                     body: Data(#"{"cover":"https://expiry-cdn.example.net/cover.jpg"}"#.utf8), now: old)
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: expiryID, now: old).isEmpty)
        PluginMediaDomainCache.learnImageURL(pluginID: expiryID, url: "https://expiry-cdn.example.net/cover.jpg", now: old)
        XCTAssertEqual(PluginMediaDomainCache.domains(pluginID: expiryID, now: old), ["expiry-cdn.example.net"])
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: expiryID, now: Date(timeIntervalSince1970: 1_000 + 24 * 60 * 60 + 1)).isEmpty)
        PluginMediaDomainCache.clear(pluginID: expiryID)

        // An in-flight response from before Clear Data/update must not repopulate the cache.
        let staleID = "com.test.stale-response"
        let oldGeneration = PluginMediaDomainCache.generation(pluginID: staleID)
        PluginMediaDomainCache.clear(pluginID: staleID)
        PluginMediaDomainCache.learn(pluginID: staleID,
                                     sourceURL: URL(string: "https://example.com/page")!,
                                     sourcePolicy: DomainPolicy(["example.com"]),
                                     contentType: "application/json",
                                     body: Data(#"{"cover":"https://stale-cdn.example.net/cover"}"#.utf8),
                                     expectedGeneration: oldGeneration)
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: staleID).isEmpty)
        PluginMediaDomainCache.clear(pluginID: staleID)
    }

    func testEncryptedAuthorizedResponseCanTeachImageCDNOnlyAfterNativeImageClassification() async throws {
        let pluginID = "com.test.encrypted-cdn"
        PluginMediaDomainCache.clear(pluginID: pluginID)
        let key = Data("0123456789abcdef".utf8)
        let iv = Data("fedcba9876543210".utf8)
        let plaintext = Data(#"{"sourceList":[{"type":"IMAGE","domain":[{"url":"https://encrypted-image-cdn.example.net","status":0}]}]}"#.utf8)
        let ciphertext = try PluginCrypto.aes(encrypt: true, mode: "cbc", key: key, iv: iv,
                                              data: plaintext, padding: true)
        let envelope = try JSONSerialization.data(withJSONObject: ["data": ciphertext.base64EncodedString()])
        PluginFixtures.responder = { _ in
            PluginFixtures.Reply(status: 200, headers: ["content-type": "application/json"], body: envelope)
        }
        let p = try instance(manifest: Self.manifest(id: pluginID))
        defer {
            p.shutdown()
            PluginFixtures.responder = nil
            PluginMediaDomainCache.clear(pluginID: pluginID)
        }

        let decoded = try await p.evalForTest("""
        (async () => {
          const response = await host.http.get('https://example.com/encrypted');
          const envelope = JSON.parse(response.body);
          return host.crypto.aes({ op: 'decrypt', mode: 'cbc', padding: 'pkcs7',
            key: '0123456789abcdef', iv: 'fedcba9876543210',
            data: envelope.data, in: 'base64', out: 'utf8' });
        })()
        """)
        XCTAssertTrue((decoded as? String)?.contains("encrypted-image-cdn.example.net") == true)
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: pluginID).isEmpty,
                      "decrypting a trusted response still creates only a candidate")
        _ = PluginMedia.ref(plugin: pluginID, url: "https://encrypted-image-cdn.example.net/poster")
        XCTAssertEqual(PluginMediaDomainCache.domains(pluginID: pluginID), ["encrypted-image-cdn.example.net"])

        let forgedID = "com.test.forged-decrypt"
        PluginMediaDomainCache.clear(pluginID: forgedID)
        PluginMediaDomainCache.learnDecryptedPayload(pluginID: forgedID, ciphertext: Data(repeating: 7, count: 32),
                                                      plaintext: Data(#"{"cover":"https://forged-cdn.example.net/a"}"#.utf8))
        XCTAssertTrue(PluginMediaDomainCache.domains(pluginID: forgedID).isEmpty,
                      "plugin-created ciphertext without response provenance must not teach a CDN")
        PluginMediaDomainCache.clear(pluginID: forgedID)
    }

    func testCryptoAndCodec() async throws {
        let p = try instance()
        defer { p.shutdown() }
        let r = try await p.evalForTest("""
        (() => { const k = '0123456789abcdef', iv = 'fedcba9876543210';
          const enc = host.crypto.aes({ mode: 'cbc', op: 'encrypt', key: k, iv: iv, data: 'hello 世界', out: 'base64' });
          const dec = host.crypto.aes({ mode: 'cbc', op: 'decrypt', key: k, iv: iv, data: enc, in: 'base64' });
          return [ host.crypto.md5('abc'), host.crypto.sha256('abc').slice(0, 16), host.crypto.hmac('sha256', 'key', 'The quick brown fox jumps over the lazy dog').slice(0, 16),
                   dec, host.codec.base64Encode('hi'), host.codec.base64Decode('aGk='), host.url.resolve('https://example.com/a/b', '../c?x=1'),
                   host.url.encodeForm({ a: '1 2', b: '&' }) ] })()
        """) as? [String]
        XCTAssertEqual(r?[0], "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(r?[1], "ba7816bf8f01cfea")
        XCTAssertEqual(r?[2], "f7bc83f430538424")
        XCTAssertEqual(r?[3], "hello 世界")
        XCTAssertEqual(r?[4], "aGk=")
        XCTAssertEqual(r?[5], "hi")
        XCTAssertEqual(r?[6], "https://example.com/c?x=1")
        XCTAssertEqual(r?[7], "a=1%202&b=%26")
    }

    // MARK: manifest

    func testManifestValidation() throws {
        let base: [String: Any] = ["schema": 1, "id": "com.test.m", "name": "M", "version": "1.0.0", "author": ["name": "a"], "type": "comic", "adult": true,
                                   "minAppVersion": "1.5", "entry": "main.js", "permissions": ["http": ["example.com"]], "capabilities": ["detail", "pages"]]
        func m(_ patch: [String: Any]) throws -> PluginManifest {
            var o = base; for (k, v) in patch { o[k] = v }
            return try PluginManifest.decode(try JSONSerialization.data(withJSONObject: o))
        }
        XCTAssertEqual(try m([:]).problems(appVersion: "1.5"), [])
        XCTAssertThrowsError(try m(["compat": "catvod"]), "CatVod compat mode is not supported")
        XCTAssertFalse(try m(["id": "Bad Id"]).problems(appVersion: "1.5").isEmpty)
        XCTAssertFalse(try m(["permissions": ["http": ["*"]]]).problems(appVersion: "1.5").isEmpty)
        XCTAssertFalse(try m(["permissions": ["http": ["127.0.0.1"]]]).problems(appVersion: "1.5").isEmpty)
        XCTAssertFalse(try m(["capabilities": ["detail"]]).problems(appVersion: "1.5").isEmpty)
        XCTAssertFalse(try m(["minAppVersion": "9.0"]).problems(appVersion: "1.5").isEmpty)
        XCTAssertFalse(try m(["entry": "../x.js"]).problems(appVersion: "1.5").isEmpty)
        XCTAssertEqual(try m(["capabilities": ["detail", "pages", "home"], "homeFeatures": ["featured", "categoryShelves", "numbered"]]).problems(appVersion: "1.5"), [])
        XCTAssertFalse(try m(["homeFeatures": ["featured"]]).problems(appVersion: "1.5").isEmpty, "homeFeatures requires the home capability")
        XCTAssertFalse(try m(["capabilities": ["detail", "pages", "home"], "homeFeatures": ["featured", "featured"]]).problems(appVersion: "1.5").isEmpty, "homeFeatures must be unique")
        XCTAssertFalse(try m(["capabilities": ["detail", "pages", "home"], "homeFeatures": ["unknown"]]).problems(appVersion: "1.5").isEmpty, "unknown homeFeatures are rejected")
        // Integrity mismatch
        let bad = try m(["integrity": ["files": ["main.js": "sha256-AAAA"]]])
        XCTAssertThrowsError(try PluginInstaller.validate(manifest: bad, source: Data(Self.stub.utf8), origin: "test"))

        // Shorthand flat-string integrity form used by some third-party plugin packs.
        let goodHash = PluginManifest.fileHash(Data(Self.stub.utf8))
        let flatGood = try m(["integrity": goodHash])
        XCTAssertEqual(flatGood.integrity?.hash, goodHash)
        XCTAssertNoThrow(try PluginInstaller.validate(manifest: flatGood, source: Data(Self.stub.utf8), origin: "test"))
        let flatBad = try m(["integrity": "sha256-AAAA"])
        XCTAssertThrowsError(try PluginInstaller.validate(manifest: flatBad, source: Data(Self.stub.utf8), origin: "test"))
        XCTAssertFalse(PluginNet.forbiddenHeaders.contains("authorization"))
        // Permission diff
        let v2 = try m(["version": "1.1.0", "permissions": ["http": ["example.com", "new.example.net"], "cloudflare": true]])
        let diff = PermissionDiff(old: try m([:]), new: v2)
        XCTAssertTrue(diff.needsConsent)
    }

    func testBundledPluginsValidate() throws {
        let b = PluginInstaller.bundled()
        let comics: Set = ["com.idj.bundled.manga18fx", "com.idj.bundled.komikindo", "com.idj.bundled.jm18comic"]
        XCTAssertTrue(Set(b.map(\.manifest.id)).isSuperset(of: comics))
        for x in b {
            XCTAssertTrue(x.manifest.adult, "\(x.name) must sit behind the adult switch")
            let p = try PluginInstaller.prepare(bundle: x.data, origin: "test")
            // Comics export `pages`, videos export `play`.
            let last = comics.contains(x.manifest.id) ? "pages" : "play"
            XCTAssertTrue(Set(p.exported).isSuperset(of: ["home", "category", "search", "detail", last]), "\(x.name): \(p.exported)")
        }
    }

    func testInstallerRejectsUnsafeRedirectsAndHeaders() async throws {
        for url in ["http://example.org/x","https://u:p@example.org/x","https://127.0.0.1/x","https://example.org:8443/x"] {
            XCTAssertThrowsError(try PluginInstaller.checkedDownloadURL(url))
        }
        var calls=0
        PluginFixtures.responder={ request in calls+=1;return .init(status:302,headers:["Location":"http://127.0.0.1/private"],body:Data()) }
        defer {PluginFixtures.responder=nil}
        do { _=try await PluginInstaller.download("https://example.org/start",limit:1024);XCTFail("unsafe redirect accepted") } catch {}
        XCTAssertEqual(calls,1,"must reject redirected target before any fetch")
        let headers=PluginOut.headers(["Referer":"safe\r\nInjected: yes","User-Agent":"safe","Authorization":"not allowed"])
        XCTAssertNil(headers["Referer"]);XCTAssertNil(headers["Authorization"]);XCTAssertEqual(headers["User-Agent"],"safe")
    }

    func testAIMirrorRequiresCatalogNotLandingPage() {
        XCTAssertFalse(HuangguoClient.isAICatalogResponse(status:200,data:Data("<title>最新地址入口</title><div class='hg-drama-card'>".utf8)))
        XCTAssertFalse(HuangguoClient.isAICatalogResponse(status:404,data:Data(#"{"data":{"items":[]}}"#.utf8)))
        XCTAssertFalse(HuangguoClient.isAICatalogResponse(status:200,data:Data(#"{"data":{}}"#.utf8)))
        XCTAssertTrue(HuangguoClient.isAICatalogResponse(status:200,data:Data(#"{"data":{"items":[]}}"#.utf8)))
    }

    func testOptInHuangguoAIReadOnlyPipeline() async throws {
        guard ProcessInfo.processInfo.environment["STV_COMPAT_AI"] == "1" else { throw XCTSkip("set STV_COMPAT_AI") }
        let channel = try XCTUnwrap(HuangguoClient.aiChannels.first { $0.slug == "ai-duanju" })
        let list = try await HuangguoClient.shared.list(channel,page:1)
        let first = try XCTUnwrap(list.items.first)
        let detail = try await HuangguoClient.shared.detail(first)
        let ep = try XCTUnwrap(detail.episodes.first)
        let result = try await HuangguoClient.shared.resolve(seriesId:first.seriesId,episode:ep)
        let stream = try XCTUnwrap(result.streams.first)
        let url = try XCTUnwrap(URL(string:stream.url))
        var request = URLRequest(url:url)
        for (k,v) in stream.headers { request.setValue(v,forHTTPHeaderField:k) }
        let (data,response) = try await URLSession.shared.data(for:request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let report:[String:Any] = ["list":list.items.count,"id":first.seriesId,"chapters":detail.episodes.count,"mediaHost":url.host ?? "","mediaPath":url.path,"status":status,"isHLS":String(decoding:data.prefix(16),as:UTF8.self).hasPrefix("#EXTM3U"),"bytes":data.count]
        if let dir=ProcessInfo.processInfo.environment["STV_SHOT_DIR"] { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:dir).appendingPathComponent("ios-ai-native-metadata.json")) }
        XCTAssertEqual(status,200)
        XCTAssertTrue(String(decoding:data,as:UTF8.self).hasPrefix("#EXTM3U"))
    }

    @MainActor func testOptInM3UBundleThroughNativeRuntime() async throws {
        guard let path = ProcessInfo.processInfo.environment["STV_COMPAT_BUNDLE"] else { throw XCTSkip("set STV_COMPAT_BUNDLE for reviewed M3U sample") }
        let pending = try PluginInstaller.prepare(bundle: Data(contentsOf: URL(fileURLWithPath: path)), origin: "compatibility-test")
        try PluginStore.shared.commit(pending)
        let p = JSVideoProvider(source: .plugin(pending.manifest.id))
        let list = try await p.list(SiteCategory(id: JSVideoProvider.homeID, title: "", path: ""), page: 1)
        XCTAssertEqual(list.items.count, 1)
        let first = try XCTUnwrap(list.items.first)
        XCTAssertTrue(first.title.contains("Big Buck Bunny"))
        let search = try await p.search("Bunny", page: 1)
        XCTAssertEqual(search.items.count, 1)
        let detail = try await p.detail(first)
        let video = try await p.resolve(first, XCTUnwrap(detail.episodes.first))
        let streamURL = try XCTUnwrap(video.url)
        XCTAssertEqual(URL(string: streamURL)?.host, "test-streams.mux.dev")
        let (data, response) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: streamURL)))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("#EXTM3U"))
        PluginRuntime.unload(pending.manifest.id)
        XCTAssertNotNil(PluginStore.snapshot(pending.manifest.id), "installation persists after engine unload")
        let again = try await p.search("Bunny", page: 1)
        XCTAssertEqual(again.items.count, 1)
    }

    @MainActor func testSubscriptionRefreshPersistsAndRejectsForeignUpdate() async throws {
        let url="https://compat.example.org/sub/list.json"
        var body=Data(#"{"name":"v1","plugins":[{"id":"com.example.catalog","manifest":"plugins/manifest.json","version":"1.0.0"}]}"#.utf8)
        PluginFixtures.responder={request in request.url?.absoluteString==url ? .init(body:body) : nil}
        let store=PluginStore.shared
        defer{store.removeSubscription(url);PluginFixtures.responder=nil}
        try await store.addSubscription(url)
        var current=try XCTUnwrap(store.subscriptions.first{$0.url==url})
        XCTAssertEqual(current.plugins.first?.manifest,"https://compat.example.org/sub/plugins/manifest.json")
        body=Data(#"{"name":"v2","plugins":[{"id":"com.example.catalog","manifest":"plugins/manifest.json","version":"1.1.0"}]}"#.utf8)
        await store.refreshSubscriptions()
        current=try XCTUnwrap(store.subscriptions.first{$0.url==url})
        XCTAssertEqual(current.name,"v2");XCTAssertEqual(current.plugins.first?.version,"1.1.0")
        body=Data(#"{"sites":[],"spider":"https://example.org/spider.jar"}"#.utf8)
        await store.refreshSubscriptions()
        current=try XCTUnwrap(store.subscriptions.first{$0.url==url})
        XCTAssertEqual(current.name,"v2");XCTAssertEqual(current.plugins.count,1)
        XCTAssertTrue(current.error?.contains("TVBox")==true)
        let persisted=try JSONDecoder().decode([PluginSubscription].self,from:XCTUnwrap(UserDefaults.standard.data(forKey:PluginStore.subsKey)))
        XCTAssertEqual(persisted.first{$0.url==url}?.plugins.first?.version,"1.1.0")
        XCTAssertNil(PluginStore.snapshot("com.example.catalog"),"a subscription refresh must not auto-install executable plugins")
    }

    func testSubscriptionRejectsForeignWithoutClobberingCache() throws {
        var sub = PluginSubscription(url: "https://example.org/sub.json")
        try PluginInstaller.applySubscription(Data(#"{"name":"good","plugins":[],"cms":[{"name":"Demo","api":"https://example.org/api"}]}"#.utf8), to: &sub)
        for text in [#"{}"#, #"{"sites":[],"spider":"https://example.org/a.jar"}"#,
                     #"{"sourceUrl":"https://example.org/rss","ruleArticles":"item"}"#,
                     #"{"plugins":{},"cms":[]}"#, #"{"plugins":[],"cms":null}"#] {
            XCTAssertThrowsError(try PluginInstaller.applySubscription(Data(text.utf8), to: &sub))
            XCTAssertEqual(sub.name, "good")
            XCTAssertEqual(sub.cms.count, 1)
        }
        try PluginInstaller.applySubscription(Data(#"{"plugins":[],"cms":[]}"#.utf8), to: &sub)
        XCTAssertTrue(sub.cms.isEmpty, "an explicitly empty idj1 subscription is still valid")
    }

    // MARK: bundled comic plugins against saved pages (offline)

    @MainActor func install(_ name: String) throws -> MangaSourceID {
        let b = try XCTUnwrap(PluginInstaller.bundled().first { $0.name == name })
        PluginRuntime.unload(b.manifest.id)
        try PluginStore.shared.commit(try PluginInstaller.prepare(bundle: b.data, origin: "test"))
        PluginStore.shared.setEnabled(b.manifest.id, true)
        return .plugin(b.manifest.id)
    }

    @MainActor func testManga18fxPlugin() async throws {
        PluginFixtures.responder = Self.responder([
            "https://manga18fx.com/manga/secret-class-01/chapter": "manga18fx/chapter.html", "https://manga18fx.com/manga/": "manga18fx/detail.html",
            "https://manga18fx.com/search": "manga18fx/search.html", "https://manga18fx.com/page/": "manga18fx/page2.html", "https://manga18fx.com/": "manga18fx/home.html"])
        let src = try install("manga18fx")
        let p = JSComicProvider(source: src)
        let home = try await p.list(MangaCategory(id: JSComicProvider.homeID, title: ""), page: 1)
        XCTAssertGreaterThan(home.items.count, 10)
        XCTAssertTrue(home.items.allSatisfy { $0.cover.hasPrefix(PluginMedia.scheme) })
        XCTAssertGreaterThan(p.categories.count, 5, "categories cached from home()")
        let page2 = try await p.list(MangaCategory(id: "latest", title: ""), page: 2)
        XCTAssertFalse(page2.items.isEmpty)
        let s = try await p.search("love", page: 1)
        XCTAssertFalse(s.items.isEmpty)
        let d = try await p.detail(MangaItem(source: src, mangaId: "secret-class-01", title: "x", cover: ""))
        XCTAssertEqual(d.item.title, "Secret Class")
        XCTAssertGreaterThan(d.chapters.count, 10)
        XCTAssertEqual(d.chapters.first?.chapterId, "secret-class-01/chapter-1", "old → new order")
        let pages = try await p.pages(d.item, d.chapters[0])
        XCTAssertGreaterThan(pages.count, 5)
        let ref = try XCTUnwrap(PluginMedia.parse(pages[0]))
        XCTAssertEqual(ref.url.host, "img01.manga18fx.com")
        XCTAssertEqual(ref.headers["Referer"], "https://manga18fx.com/")
        XCTAssertNil(ref.transform)
    }

    @MainActor func testKomikindoPlugin() async throws {
        PluginFixtures.responder = Self.responder([
            "https://komikindo.click/manga/?": "komikindo/list.html", "https://komikindo.click/manga/": "komikindo/detail.html",
            "https://komikindo.click/?s=": "komikindo/search.html", "https://komikindo.click/ane-haha": "komikindo/chapter.html"])
        let src = try install("komikindo")
        let p = JSComicProvider(source: src)
        let home = try await p.list(MangaCategory(id: JSComicProvider.homeID, title: ""), page: 1)
        XCTAssertGreaterThan(home.items.count, 10)
        XCTAssertTrue(home.hasMore)
        let s = try await p.search("love", page: 1)
        XCTAssertFalse(s.items.isEmpty)
        let d = try await p.detail(MangaItem(source: src, mangaId: "ane-haha-kankei-kai-hiroyuki", title: "x", cover: ""))
        XCTAssertEqual(d.chapters.count, 4)
        XCTAssertEqual(d.chapters.first?.chapterId, "ane-haha-kankei-kai-hiroyuki-chapter-1")
        XCTAssertEqual(d.status, "连载中")
        let pages = try await p.pages(d.item, d.chapters[3])
        XCTAssertGreaterThan(pages.count, 3)
        let ref = try XCTUnwrap(PluginMedia.parse(pages[0]))
        XCTAssertEqual(ref.url.scheme, "https", "http image URLs are upgraded")
        XCTAssertEqual(ref.url.host, "linksaya.com")
        XCTAssertEqual(ref.headers["Referer"], "https://komikindo.click/")
    }

    @MainActor func testJM18comicPluginWithScrambleDescriptor() async throws {
        PluginFixtures.responder = Self.responder([
            "https://18comic.ink/albums": "jm/albums.html", "https://18comic.ink/album/": "jm/album.html", "https://18comic.ink/photo/": "jm/photo.html",
            "https://18comic.ink/search/": "jm/search.html", "https://jmcomicgo.org/": "jm/publish.html"])
        let src = try install("jm18comic")
        let p = JSComicProvider(source: src)
        let home = try await p.list(MangaCategory(id: JSComicProvider.homeID, title: ""), page: 1)
        XCTAssertGreaterThan(home.items.count, 20)
        XCTAssertTrue(home.hasMore)
        let d = try await p.detail(MangaItem(source: src, mangaId: "1254979", title: "x", cover: ""))
        XCTAssertFalse(d.item.title.isEmpty)
        XCTAssertGreaterThan(d.chapters.count, 5)
        XCTAssertEqual(d.chapters.first?.chapterId, "1254979")
        let pages = try await p.pages(d.item, d.chapters[0])
        XCTAssertGreaterThan(pages.count, 10)
        // Published algorithm (JMComic-Crawler-Python get_num): aid 1254979 ≥ 421926 → x = 8;
        // md5("1254979" + "00001") ends in "9" → (57 % 8) * 2 + 2 = 4; "00002" ends in "b" → (98 % 8) * 2 + 2 = 6.
        let segs = pages.prefix(3).map { (PluginMedia.parse($0)?.transform?["segments"] as? Int) ?? -1 }
        XCTAssertEqual(segs, [4, 6, 4])
        XCTAssertEqual(PluginMedia.parse(pages[0])?.transform?["type"] as? String, "stripes")
        XCTAssertTrue(PluginMedia.parse(pages[0])?.url.host?.hasSuffix("18comic.ink") ?? false)
    }

    // MARK: JM stripes (native)

    func testStripePlanMatchesReferenceAlgorithm() {
        // Reference (Python decode_and_save) for h = 1003, num = 8: over = 3, move = 125.
        let plan = ImageStripes.plan(height: 1003, segments: 8)
        XCTAssertEqual(plan.count, 8)
        XCTAssertEqual(plan[0].src, 875); XCTAssertEqual(plan[0].dst, 0); XCTAssertEqual(plan[0].h, 128)
        XCTAssertEqual(plan[1].src, 750); XCTAssertEqual(plan[1].dst, 128); XCTAssertEqual(plan[1].h, 125)
        XCTAssertEqual(plan[7].src, 0); XCTAssertEqual(plan[7].dst, 878); XCTAssertEqual(plan[7].h, 125)
        XCTAssertEqual(plan.map(\.h).reduce(0, +), 1003)
        XCTAssertTrue(ImageStripes.plan(height: 100, segments: 0).isEmpty)
    }

    func testStripeUnscrambleRoundTrip() throws {
        // Synthetic image: every row has a distinct color, so any misplaced band shows up.
        let w = 7, h = 1003
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            for y in 0..<h {
                UIColor(red: CGFloat(y % 256) / 255, green: CGFloat((y / 256) * 60) / 255, blue: 0.5, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: y, width: w, height: 1))
            }
        }.cgImage!
        for n in [2, 4, 6, 8, 10, 16] {
            let scrambled = try XCTUnwrap(ImageStripes.scramble(img, segments: n))
            let restored = try XCTUnwrap(ImageStripes.unscramble(scrambled, segments: n))
            XCTAssertEqual(rows(restored), rows(img), "segments=\(n)")
            XCTAssertNotEqual(rows(scrambled), rows(img))
        }
        // Through the PluginMedia transform path (encoded → decoded image data).
        let png = UIImage(cgImage: try XCTUnwrap(ImageStripes.scramble(img, segments: 6))).pngData()!
        let out = try PluginMedia.apply(["type": "stripes", "segments": 6], png)
        let back = try XCTUnwrap(UIImage(data: out)?.cgImage)
        XCTAssertEqual(back.height, h)
        let a = rows(back), b = rows(img)
        let close = zip(a, b).filter { abs(Int($0.0) - Int($0.1)) <= 3 }.count   // JPEG re-encode tolerance
        XCTAssertGreaterThan(Double(close) / Double(h), 0.97)
    }

    /// Red channel of the middle pixel in each row.
    private func rows(_ img: CGImage) -> [UInt8] {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (0..<h).map { buf[($0 * w + w / 2) * 4] }
    }

    func testMediaRefRoundTripDropsUnsafeHeaders() {
        let r = PluginMedia.ref(plugin: "com.a.b", url: "https://img.example.com/1.jpg?x=1", headers: ["Referer": "https://example.com/", "Cookie": "x", "Authorization": "y"],
                                transform: ["type": "stripes", "segments": 4])
        let p = PluginMedia.parse(r)
        XCTAssertEqual(p?.plugin, "com.a.b")
        XCTAssertEqual(p?.url.absoluteString, "https://img.example.com/1.jpg?x=1")
        XCTAssertEqual(p?.headers, ["Referer": "https://example.com/"])
        XCTAssertEqual(p?.transform?["segments"] as? Int, 4)
    }

    // MARK: 苹果 CMS

    private func tvboxConfig(_ text: String) throws -> TVBoxConfig {
        guard case .config(let c) = try TVBoxConfig.parse(text, "") else { throw TVBoxError("not a config") }
        return c
    }

    /// Every site of a pasted TVBox config is kept for the TVBox page: nothing is dropped or sent to 采集站 any more.
    func testTVBoxConfigKeepsEverySiteKind() throws {
        let config = try tvboxConfig(#"{"name":"demo","sites":[{"name":"CMS","type":1,"api":"http://cms.example/api.php/provide/vod/"},{"name":"jar","type":3,"api":"csp_demo"},{"name":"dup","type":1,"api":"https://cms.example/api.php/provide/vod/"}],"spider":"https://example.org/a.jar"}"#)
        XCTAssertEqual(config.name, "demo")
        XCTAssertEqual(config.sites.map(\.name), ["CMS", "jar", "dup"])
        XCTAssertEqual(config.sites.map(\.kind), [.cmsJson, .jar, .cmsJson])
        XCTAssertEqual(config.sites[0].api, "http://cms.example/api.php/provide/vod/")
        XCTAssertTrue(config.hasCode)
    }

    func testTVBoxLargeCatalogAndStandaloneLiveLists() throws {
        let scripts = (0..<600).map { ["type": 3, "api": "csp_\($0)"] as [String: Any] }
        let xml = ["type": 0, "api": "https://cms.example/vod/xml"] as [String: Any]
        let live = ["name": "直播", "url": "https://cms.example/channels.m3u"]
        let bytes = try JSONSerialization.data(withJSONObject: ["sites": scripts + [xml], "lives": [live, live]])
        let catalog = try tvboxConfig(String(decoding: bytes, as: UTF8.self))
        XCTAssertEqual(catalog.sites.count, 601)
        XCTAssertEqual(catalog.sites.filter { $0.kind == .cmsXml }.map(\.api), ["https://cms.example/vod/xml"])
        XCTAssertEqual(catalog.lives.map(\.url), ["https://cms.example/channels.m3u"])
    }

    /// Code-only configs import too, but ask for trust before anything runs.
    func testPastedTVBoxConfigsAreRecognised() async throws {
        let text = #"{"sites":[{"name":"jar","type":3,"api":"csp_demo"}],"spider":"x.jar"}"#
        XCTAssertTrue(try tvboxConfig(text).hasCode)
        guard case .tvbox(let pasted) = try await PluginInstaller.interpret("  " + text + "\n") else { return XCTFail("not recognised") }
        XCTAssertEqual(pasted, text)
        let repo = TVBoxRepo(RepoRecord(id: "r", name: "n", url: ""), try tvboxConfig(text))
        XCTAssertTrue(repo.needsTrust)
        XCTAssertFalse(repo.trusted)
    }

    @MainActor func testCMSCategoryRequestsKeepFullCategoryList() async throws {
        NetGuard.resolverOverride = { _ in ["93.184.216.34"] }
        var queries: [[String: String]] = []
        PluginFixtures.responder = { request in
            let pairs = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value ?? "") })
            queries.append(query)
            let payload: [String: Any] = query["t"] == "6"
                ? ["code": 1, "pagecount": 2, "class": [["type_id": 6, "type_name": "动作片"]], "list": [["vod_id": 42, "vod_name": "测试影片"]]]
                : ["code": 1, "class": [["type_id": 1, "type_name": "电影"], ["type_id": 6, "type_name": "动作片"]], "list": []]
            return PluginFixtures.Reply(status: 200, body: try! JSONSerialization.data(withJSONObject: payload))
        }
        let site = try await CMSStore.shared.add(name: "Fixture", api: "https://cms-regression.example.com/api", adult: false)
        defer { CMSStore.shared.remove(site.key) }
        let provider = MacCMSProvider(source: site.source, site: site)
        let page = try await provider.list(SiteCategory(id: "6", title: "动作片", path: "6"), page: 2)
        XCTAssertEqual(page.items.first?.seriesId, "42")
        XCTAssertEqual(queries.last?["t"], "6")
        XCTAssertEqual(queries.last?["pg"], "2")
        XCTAssertEqual(CMSStore.site(site.key)?.categories.count, 2)
    }

    static let cmsList: [String: Any] = [
        "code": 1, "page": 1, "pagecount": 3, "total": 60,
        "class": [["type_id": 1, "type_name": "电影"], ["type_id": 2, "type_name": "连续剧"], ["type_id": 9, "type_name": "萝莉"]],
        "list": [
            ["vod_id": 101, "vod_name": "示例电影", "vod_pic": "http://img.example.com/a.jpg", "vod_remarks": "HD", "type_name": "电影", "vod_actor": "甲,乙"],
            ["vod_id": 102, "vod_name": "不该出现", "vod_pic": "", "type_name": "萝莉", "vod_remarks": ""]
        ]
    ]

    func testMacCMSParsing() throws {
        let src = DramaSource.cms("abc")
        let cats = MacCMSProvider.parseCategories(Self.cmsList)
        XCTAssertEqual(cats.map(\.name), ["电影", "连续剧"], "minors categories are dropped")
        let page = MacCMSProvider.page(Self.cmsList, source: src, page: 1)
        XCTAssertEqual(page.items.map(\.seriesId), ["101"])
        XCTAssertEqual(page.items.first?.cover, "https://img.example.com/a.jpg")
        XCTAssertTrue(page.hasMore)
        let detail: [String: Any] = ["list": [[
            "vod_id": 7, "vod_name": "剧", "vod_pic": "https://x/a.jpg", "type_name": "连续剧", "vod_content": "<p>简介&nbsp;</p>",
            "vod_play_from": "share$$$m3u8a$$$mp4b",
            "vod_play_url": "第1集$https://share.example.com/p/1#第2集$https://share.example.com/p/2$$$第1集$https://cdn.example.com/1/index.m3u8#第2集$https://cdn.example.com/2/index.m3u8$$$第1集$http://v.example.com/1.mp4"
        ]]]
        let d = try MacCMSProvider.parseDetail(detail, series: HGSeries(source: src, seriesId: "7", title: "", cover: ""), source: src)
        XCTAssertEqual(d.episodes.count, 2, "longest direct line wins")
        XCTAssertEqual(d.episodes.first?.page, "m3u8a")
        let st = MacCMSProvider.streams(for: d.episodes[0])
        XCTAssertEqual(st.map(\.url), ["https://cdn.example.com/1/index.m3u8", "http://v.example.com/1.mp4"], "alt lines keep the source scheme")
        XCTAssertEqual(st.first?.kind, .hls)
        let lines = MacCMSProvider.lines(from: "a$$$b", urls: "x$u1#y$u2$$$z$u3")
        XCTAssertEqual(lines.map(\.name), ["a", "b"])
        XCTAssertEqual(lines[0].eps.map(\.1), ["u1", "u2"])
        XCTAssertThrowsError(try CMSStore.normalize("http://127.0.0.1/api.php"))
        XCTAssertEqual(try CMSStore.normalize("http://cms.example.com/api.php/provide/vod/?ac=list"), "https://cms.example.com/api.php/provide/vod/")
    }

    // MARK: Plugin homepage capabilities and response parsing

    func testPluginHomeFeatureRoutingAndPresentation() {
        XCTAssertTrue(PluginHomeFeatures.usesCategoryShelves(["categoryShelves"]))
        XCTAssertFalse(PluginHomeFeatures.usesCategoryShelves(["featured"]))
        XCTAssertFalse(PluginHomeFeatures.usesCategoryShelves(nil))
        XCTAssertTrue(PluginHomeFeatures.showsFeaturedCarousel(["featured"], itemCount: 1))
        XCTAssertFalse(PluginHomeFeatures.showsFeaturedCarousel(["featured"], itemCount: 0))
        XCTAssertFalse(PluginHomeFeatures.showsFeaturedCarousel(["categoryShelves"], itemCount: 3))
        XCTAssertFalse(PluginHomeFeatures.usesNumbering(nil))
        XCTAssertFalse(PluginHomeFeatures.usesNumbering(["categoryShelves"]))
        XCTAssertTrue(PluginHomeFeatures.usesNumbering(["numbered"]))

        let noCategories = JSVideoProvider.visibleCategories(cached: [], features: ["categoryShelves"])
        XCTAssertTrue(noCategories.isEmpty, "category-shelf plugins must not receive a fabricated 推荐 category")
        let legacyFallback = JSVideoProvider.visibleCategories(cached: [], features: nil)
        XCTAssertEqual(legacyFallback.map(\.id), [JSVideoProvider.homeID], "legacy plugins keep the historical home feed")
    }

    func testFallbackHeroChoosesFirstCategoryWithContentInSiteOrder() async {
        let categories = ["empty-first", "has-content", "also-has-content"]
        let selected = await PluginHomeFeatures.firstPopulated(categories) { category in
            category != "empty-first"
        }
        XCTAssertEqual(selected, "has-content")
    }

    func testJSVideoHomeResponseParsingAndCategoryCacheSemantics() {
        let provider = JSVideoProvider(source: .plugin("com.test.video"))
        let response: [String: Any] = [
            "categories": [
                ["id": "movie", "name": "电影"],
                ["id": "movie", "name": "重复分类"],
                ["id": "", "name": "无效分类"]
            ],
            "items": [
                ["id": "featured-1", "title": "精选剧集", "cover": "https://img.example.com/1.jpg"],
                ["id": "", "title": "缺少 ID", "cover": "https://img.example.com/2.jpg"]
            ]
        ]

        // Without an installed manifest opting in, categories are still parsed but featured items stay disabled.
        let legacy = provider.parseHomeResponse(response, features: [])
        XCTAssertEqual(legacy.categories?.map(\.id), ["movie"])
        XCTAssertTrue(legacy.featured.isEmpty)

        let featured = provider.parseHomeResponse(response, features: ["featured"])
        XCTAssertEqual(featured.featured.map(\.seriesId), ["featured-1"], "only valid items become featured entries")

        // A missing categories key means "not supplied" (preserve cached values), not "clear cache".
        let omitted = provider.parseHomeResponse(["items": []], features: ["featured"])
        XCTAssertNil(omitted.categories)
        let malformed = provider.parseHomeResponse(["categories": "not-an-array"], features: ["categoryShelves"])
        XCTAssertNil(malformed.categories, "malformed category payloads must not clear the last valid cache")

        // An explicitly empty categories array means the site currently has no real categories.
        let empty = provider.parseHomeResponse(["categories": []], features: ["categoryShelves"])
        XCTAssertEqual(empty.categories?.count, 0)

        // Numbering is carried by the same BoardSpec that renders the full category list.
        let site = DramaSource.plugin("com.test.video")
        let category = SiteCategory(id: "movie", title: "电影", path: "movie")
        let ordinaryBoard = BoardSpec(kind: .site(site, category), numbered: PluginHomeFeatures.usesNumbering(nil))
        let rankedBoard = BoardSpec(kind: .site(site, category), numbered: PluginHomeFeatures.usesNumbering(["numbered"]))
        XCTAssertFalse(ordinaryBoard.numbered)
        XCTAssertTrue(rankedBoard.numbered)
    }

    // MARK: content filter

    func testMinorsFilter() {
        for blocked in [["Loli Collection"], ["x", "lolicon"], ["正太"], ["萝莉"], ["蘿莉"], ["Schoolgirl"], ["school-girl"], ["age_regression"],
                        ["未成年"], ["女子高生"], ["JK"], ["ロリ"], ["Hasunosora Jogakuin"], ["little girl"]] {
            XCTAssertTrue(ContentFilter.isBlocked(blocked), "\(blocked)")
        }
        for ok in [["Secret Class"], ["MILF"], ["Childhood Friend Romance"].map { _ in "Mature" }, ["Kids Return".replacingOccurrences(of: "Kids", with: "Adults")],
                   ["Minority Report".replacingOccurrences(of: "Minority", with: "Majority")], ["Jake"], ["Japanese"], ["school life"], ["女大學生"]] {
            XCTAssertFalse(ContentFilter.isBlocked(ok), "\(ok)")
        }
    }
    func testPluginMediaRejectsCredentialsAndNonStandardPortsForExplicitAndLearnedHosts() {
        let explicit = DomainPolicy(["example.com"])
        let learned: Set<String> = ["cdn.example.net"]
        for raw in [
            "https://user:pass@example.com/image.jpg",
            "https://example.com:8443/image.jpg",
            "http://example.com:8080/image.jpg",
            "https://user:pass@cdn.example.net/image.jpg",
            "https://cdn.example.net:9443/image.jpg",
            "http://cdn.example.net/image.jpg"
        ] {
            XCTAssertFalse(PluginMedia.allows(URL(string: raw)!, explicitPolicy: explicit, learnedHosts: learned), raw)
        }
        XCTAssertTrue(PluginMedia.allows(URL(string: "https://example.com/image.jpg")!, explicitPolicy: explicit, learnedHosts: learned))
        XCTAssertTrue(PluginMedia.allows(URL(string: "http://example.com/image.jpg")!, explicitPolicy: explicit, learnedHosts: learned),
                      "explicit legacy HTTP on port 80 remains supported")
        XCTAssertTrue(PluginMedia.allows(URL(string: "https://cdn.example.net/image.jpg")!, explicitPolicy: explicit, learnedHosts: learned))
    }

    func testNetGuardCanBypassPositiveDNSCacheAndFailsClosedOnEmptyResolution() {
        var count = 0
        let host = "dns-cache-bypass-\(UUID().uuidString).example.net"
        NetGuard.resolverOverride = { _ in
            count += 1
            return count == 1 ? ["93.184.216.34"] : ["192.168.1.20"]
        }
        XCTAssertFalse(NetGuard.resolvesToBlocked(host),
                        "the first public resolution may populate the normal positive cache")
        XCTAssertTrue(NetGuard.resolvesToBlocked(host, useCache: false),
                      "media requests must bypass a previous positive DNS cache entry")
        NetGuard.resolverOverride = { _ in [] }
        XCTAssertTrue(NetGuard.resolvesToBlocked("unresolved.example.net", useCache: false),
                      "DNS failure must fail closed")
    }

}
