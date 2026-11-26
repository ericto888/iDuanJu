import CommonCrypto
import XCTest
@testable import STV

/// shared/tvbox/cases.json (the behaviour both platforms agree on) and ports of the Kotlin engine tests.
final class TVBoxEngineTests: XCTestCase {
    // MARK: Fixtures

    private var tmp = URL(fileURLWithPath: "/")
    private var net: TVBoxNet!
    private var engine: TVBoxEngine!
    private var jar = FakeJar()
    private var sniffer = FakeSniffer()

    override func setUpWithError() throws {
        try super.setUpWithError()
        NetGuard.resolverOverride = { _ in ["93.184.216.34"] }
        TVBoxStub.reset()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tvbox-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("local"), withIntermediateDirectories: true)
        jar = FakeJar()
        sniffer = FakeSniffer()
        net = TVBoxNet(tmp.appendingPathComponent("local"), protocolClasses: [TVBoxStub.self], ownPort: { 9978 })
        engine = makeEngine()
    }

    override func tearDown() {
        engine.shutdown()
        net.close()
        NetGuard.resolverOverride = nil
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func makeEngine() -> TVBoxEngine {
        let jar = jar, sniffer = sniffer
        return TVBoxEngine(net, platform: { TVBoxPlatform(js: nil, python: nil, jar: jar, sniffer: sniffer, jsAsset: { _ in nil }, makeHost: { _, _, _ in NoHost() }) },
                           cache: TVBoxCache(tmp.appendingPathComponent("cache")), scripts: tmp.appendingPathComponent("scripts"), epgDir: tmp.appendingPathComponent("epg"), startProxy: { _ in 9978 })
    }

    private func config(_ text: String, _ base: String = "https://h.example/dir/cfg.json") throws -> TVBoxConfig {
        guard case .config(let c) = try TVBoxConfig.parse(text, base) else { throw TVBoxError("not a config") }
        return c
    }

    /// Site key → uid.
    @discardableResult
    private func use(_ text: String, trusted: Bool = true, id: String = "r") throws -> [String: String] {
        let c = try config(text, "https://h.example/c.json")
        engine.setRepos([RepoRuntime(id, "仓", c, trusted: trusted, allowPrivate: false)], active: id)
        return Dictionary(uniqueKeysWithValues: c.sites.map { ($0.key, TVBoxConfig.siteUid(id, $0.key)) })
    }

    private func collect<T>(_ s: AsyncThrowingStream<Snapshot<T>, Error>) async throws -> [Snapshot<T>] {
        var out: [Snapshot<T>] = []
        for try await x in s { out.append(x) }
        return out
    }

    private func failure(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> String {
        do { try await body(); XCTFail("no error", file: file, line: line); return "" } catch { return error.localizedDescription }
    }

    private func at(_ path: String) -> String { "http://site.example" + path }

    // MARK: cases.json

    private func same(_ expect: Any, _ actual: Any?, _ what: String) {
        switch expect {
        case let e as [String: Any]:
            guard let a = actual as? JSONObject else { XCTFail("\(what): not an object"); return }
            XCTAssertEqual(Set(e.keys), Set(a.keys), what)
            for (k, v) in e { same(v, a[k], what + "." + k) }
        case let e as [Any]:
            guard let a = actual as? [Any] else { XCTFail("\(what): not an array"); return }
            XCTAssertEqual(e.count, a.count, what)
            for (i, v) in e.enumerated() where i < a.count { same(v, a[i], what + "[\(i)]") }
        case let e as String: XCTAssertEqual(e, actual as? String, what)
        case let e as NSNumber: XCTAssertEqual(e, actual as? NSNumber, what)
        default: XCTFail("\(what): unexpected \(expect)")
        }
    }

    func testSharedCases() throws {
        let url = try XCTUnwrap(Bundle(for: TVBoxEngineTests.self).url(forResource: "cases", withExtension: "json", subdirectory: "tvbox"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var covered = Set<String>()
        func each(_ section: String, _ run: ([String: Any], String) throws -> Void) throws {
            covered.insert(section)
            let list = try XCTUnwrap(cases[section] as? [[String: Any]], section)
            XCTAssertFalse(list.isEmpty, section)
            for (i, c) in list.enumerated() { try run(c, "\(section)[\(i)] \(c["name"] as? String ?? "")") }
        }
        func s(_ c: [String: Any], _ k: String) -> String { c[k] as? String ?? "" }
        try each("lenientJson") { c, n in same(c["expect"] ?? "", try LenientJson.parse(s(c, "input")), n) }
        try each("resolve") { c, n in XCTAssertEqual(s(c, "expect"), TVBoxUrl.resolve(s(c, "base"), s(c, "ref")), n) }
        try each("decode") { c, n in
            XCTAssertEqual(s(c, "expect"), try TVBoxDecoder.decode(s(c, "input"), s(c, "key")), n)
            XCTAssertEqual(s(c, "expect"), try TVBoxDecoder.decode(Data(s(c, "input").utf8), s(c, "key")), n)
        }
        try each("spiderRef") { c, n in
            let e = c["expect"] as? [String: Any] ?? [:]
            XCTAssertEqual(SpiderRef(url: s(e, "url"), md5: s(e, "md5"), image: e["image"] as? Bool ?? false), SpiderRef.parse(s(c, "input")), n)
        }
        try each("siteKind") { c, n in XCTAssertEqual(s(c, "expect"), SiteKind.of(type: c["type"] as? Int ?? -1, api: s(c, "api")).rawValue, n + s(c, "api")) }
        try each("picture") { c, n in
            let p = TVBoxUrl.picture(s(c, "input")), e = c["expect"] as? [String: Any] ?? [:]
            XCTAssertEqual(s(e, "url"), p.url, n)
            XCTAssertEqual(e["headers"] as? [String: String], p.headers, n)
        }
        try each("playLines") { c, n in
            let e = c["expect"] as? [[String: Any]] ?? []
            let lines = VodMapper.lines(s(c, "from"), s(c, "url"))
            XCTAssertEqual(e.map { s($0, "name") }, lines.map(\.flag), n)
            XCTAssertEqual(e.map { $0["eps"] as? [[String]] ?? [] }, lines.map { $0.eps.map { [$0.name, $0.play] } }, n)
        }
        try each("streamUrl") { c, n in
            let x = TVBoxUrl.stream(s(c, "input")), e = c["expect"] as? [String: Any] ?? [:]
            XCTAssertEqual(s(e, "url"), x.url, n)
            XCTAssertEqual(e["headers"] as? [String: String], x.headers, n)
            XCTAssertEqual(s(e, "label"), x.label, n)
        }
        try each("playerResult") { c, n in
            let r = PlayerResult.fromJSON(JSONObject(c["input"] as? [String: Any] ?? [:])), e = c["expect"] as? [String: Any] ?? [:]
            XCTAssertEqual(e["parse"] as? Int, r.parse, n)
            XCTAssertEqual(e["jx"] as? Int, r.jx, n)
            XCTAssertEqual(s(e, "playUrl"), r.playUrl, n)
            XCTAssertEqual(s(e, "danmaku"), r.danmaku, n)
            XCTAssertEqual(e["headers"] as? [String: String], r.headers, n)
            XCTAssertEqual(e["urls"] as? [[String]], r.urls.map { [$0.name, $0.url] }, n)
            XCTAssertEqual(e["subs"] as? [[String]], r.subs.map { [$0.name, $0.url, $0.language ?? "", $0.format ?? ""] }, n)
        }
        try each("isVideoUrl") { c, n in XCTAssertEqual(c["expect"] as? Bool, SniffRules.isVideo(s(c, "url"), "", []), n + s(c, "url")) }
        try each("liveText") { c, n in
            let input = s(c, "input"), e = c["expect"] as? [[String: Any]] ?? []
            let groups = LiveParser.parse(input).groups
            XCTAssertTrue(LiveParser.looksLikeList(input) || input.hasPrefix("["), n)
            XCTAssertEqual(e.count, groups.count, n)
            for (x, g) in zip(e, groups) {
                XCTAssertEqual(s(x, "name"), g.name, n)
                XCTAssertEqual(s(x, "pass"), g.pass, n)
                let channels = x["channels"] as? [[String: Any]] ?? []
                XCTAssertEqual(channels.count, g.channels.count, n)
                for (y, ch) in zip(channels, g.channels) {
                    XCTAssertEqual(s(y, "name"), ch.name, n)
                    XCTAssertEqual(y["urls"] as? [String], ch.urls, n)
                    if y["logo"] != nil { XCTAssertEqual(s(y, "logo"), ch.logo, n) }
                    if y["tvgId"] != nil { XCTAssertEqual(s(y, "tvgId"), ch.tvgId, n) }
                    if y["tvgName"] != nil { XCTAssertEqual(s(y, "tvgName"), ch.tvgName, n) }
                    if let h = y["headers"] as? [String: String] { XCTAssertEqual(h, ch.headers, n) }
                }
            }
        }
        try each("epgUrl") { c, n in XCTAssertEqual(s(c, "expect"), EpgParser.url(s(c, "template"), s(c, "name"), s(c, "date")), n) }
        try each("siteUid") { c, n in XCTAssertEqual(s(c, "expect"), TVBoxConfig.siteUid(s(c, "repo"), s(c, "key")), n) }
        XCTAssertEqual(Set(cases.keys).subtracting(covered), [], "cases.json sections without a test")
    }

    // MARK: Text

    func testLooseNumbersAndStringsAreRead() throws {
        let o = try XCTUnwrap(LenientJson.parse(#"{type: '3', n: 1.5, big: 12345678901, hex: 0x1F, plus: +2, bare: csp_Demo, re: "a\.b\d", u: "中😀", empty:, t: true, v: 1.2.3}"#) as? JSONObject)
        XCTAssertEqual(J.int(o["type"]), 3)
        XCTAssertEqual(o["n"] as? Double, 1.5)
        XCTAssertEqual(J.int64(o["big"]), 12_345_678_901)
        XCTAssertEqual(J.int(o["hex"]), 31)
        XCTAssertEqual(J.int(o["plus"]), 2)
        XCTAssertEqual(o["bare"] as? String, "csp_Demo")
        XCTAssertEqual(o["re"] as? String, #"a\.b\d"#)
        XCTAssertEqual(o["u"] as? String, "中😀")
        XCTAssertTrue(o.isNull("empty") && o.has("empty"))
        XCTAssertTrue(J.bool(o["t"]))
        XCTAssertEqual(o["v"] as? String, "1.2.3")
        XCTAssertEqual(o.keys.prefix(3).joined(separator: ","), "type,n,big")
        XCTAssertEqual(try config(#"{"sites":[{"key":"k","api":"csp_A","type":3,"ext":{"z":1,"a":["x",true,null,1.5],"引":"\"\n"}}]}"#).sites[0].ext, #"{"z":1,"a":["x",true,null,1.5],"引":"\"\n"}"#)
        XCTAssertThrowsError(try LenientJson.parse("{\"a\":\n[1,")) { XCTAssertTrue($0.localizedDescription.contains("第 2 行")) }
    }

    func testAbsurdNumbersDoNotTrap() throws {
        for s in ["NaN", "nan", "Infinity", "-Infinity", "inf", "1e400", "-1e400", "1e19", ""] { XCTAssertEqual(J.int(s), 0, s) }
        XCTAssertEqual(J.int("3.9"), 3)
        XCTAssertEqual(J.int("-2.5"), -2)
        // what `json.dumps(float("inf"))` sends
        let o = try XCTUnwrap(LenientJson.objectOrNull(#"{"list":[{"vod_id":"1","vod_name":"a"}],"page":1,"pagecount":Infinity}"#))
        XCTAssertTrue(VodMapper.page(o, "u", 1) { $0 }.hasMore)
        let big = #"{"epg_data":[{"title":"t","start":"9223372036854775807","end":"9223372036854775807"},{"title":"a","start":"08:00","end":"09:00"},{"title":"a","start":"08:00","end":"09:00"}]}"#
        XCTAssertEqual(EpgParser.json(big, "2026-11-25").map(\.title), ["a"])
        XCTAssertTrue(EpgService.isGuide(Data("<?xml version=\"1.0\"?><tv>".utf8)))
        XCTAssertTrue(EpgService.isGuide(Data([0x1F, 0x8B, 8])))
        XCTAssertFalse(EpgService.isGuide(Data("<!DOCTYPE html><html>busy".utf8)))
        XCTAssertThrowsError(try TVBoxGzip.decompress(Gzip.compress(Data(count: 4096)), max: 1024))
    }

    func testPlayAddressesKeepTheirMarks() {
        XCTAssertEqual(TVBoxUrl.vod(" https://h.example/a.m3u8?sig=a$b|c "), .init(url: "https://h.example/a.m3u8?sig=a$b|c", headers: [:], label: ""))
        XCTAssertEqual(TVBoxUrl.vod("https://h.example/a|b.mp4|User-Agent=X|Y&Referer=https%3A%2F%2Fr.example%2F"), .init(url: "https://h.example/a|b.mp4", headers: ["User-Agent": "X|Y", "Referer": "https://r.example/"], label: ""))
        XCTAssertEqual(TVBoxUrl.vod("https://h.example/a|"), .init(url: "https://h.example/a|", headers: [:], label: ""))
        XCTAssertEqual(TVBoxUrl.stream("http://h.example/1|ua=U$线"), .init(url: "http://h.example/1", headers: ["User-Agent": "U"], label: "线"))
    }

    func testAddressesBecomeRequestURLs() {
        XCTAssertEqual(TVBoxUrl.url("http://www.饭太硬.com/tv")?.absoluteString, "http://www.xn--sss604efuw.com/tv")
        XCTAssertEqual(TVBoxUrl.url(" https://h.example:8443/a b/中?x={1}&y=%E4#f ")?.absoluteString, "https://h.example:8443/a%20b/%E4%B8%AD?x=%7B1%7D&y=%E4")
        let t = TVBoxUrl.target("http://u:p%40@h.example?x=1")
        XCTAssertEqual(t?.url.absoluteString, "http://h.example/?x=1")
        XCTAssertEqual(t?.user, "u")
        XCTAssertEqual(t?.password, "p@")
        XCTAssertEqual(TVBoxUrl.target("http://[fe80::1]:80/")?.host, "fe80::1")
        XCTAssertNil(TVBoxUrl.url("http://"))
        XCTAssertNil(TVBoxUrl.url("ftp://h.example/"))
        XCTAssertEqual(TVBoxUrl.join("https://h.example/a/b/c.js?x", "../d.js?y=1"), "https://h.example/a/d.js?y=1")
        XCTAssertEqual(TVBoxUrl.join("https://h.example/a/b", "/x"), "https://h.example/x")
        XCTAssertEqual(TVBoxUrl.join("https://h.example/a/b", "//o.example/x"), "https://o.example/x")
        XCTAssertEqual(TVBoxUrl.withQuery("https://h.example/api?ac=list&k=1#f", [("ac", "detail"), ("wd", "关 键")]), "https://h.example/api?k=1&ac=detail&wd=%E5%85%B3%20%E9%94%AE")
        XCTAssertEqual(TVBoxNet.Exchange.splitCookies("a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/, b=2"), ["a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/", "b=2"])
    }

    private let plain = #"{"sites":[{"key":"a","name":"站点","type":1,"api":"http://1.2.3.4:8080/api"}]}"#
    private func pad(_ s: String) -> String { String((s + "0000000000000000").prefix(16)) }

    private func aes(_ text: String, key: String, iv: String?) -> [UInt8] {
        let d = Array(text.utf8), k = Array(key.utf8), v = Array((iv ?? "0000000000000000").utf8)
        var out = [UInt8](repeating: 0, count: d.count + 16)
        var moved = 0
        let options = kCCOptionPKCS7Padding | (iv == nil ? kCCOptionECBMode : 0)
        XCTAssertEqual(CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(options), k, k.count, v, d, d.count, &out, out.count, &moved), CCCryptorStatus(kCCSuccess))
        return Array(out.prefix(moved))
    }

    func testEncryptedConfigs() throws {
        let key = "abc123", iv = "1700000000000" // the last 13 characters
        let hex = Bytes.hex(Array("$#\(key)#$".utf8)) + Bytes.hex(aes(plain, key: pad(key), iv: pad(iv))) + Bytes.hex(Array(iv.utf8))
        XCTAssertTrue(hex.hasPrefix("2423"))
        XCTAssertEqual(try TVBoxDecoder.decode(hex), plain)
        // the same text hidden behind the Base64 marker of a picture
        let carried = Data([0xFF, 0xD8, 1, 2, 3]) + Data(("xyzAbCd1234**" + Data(hex.utf8).base64EncodedString()).utf8)
        XCTAssertEqual(try TVBoxDecoder.decode(carried), plain)
        XCTAssertThrowsError(try TVBoxDecoder.decode(String(hex.dropLast(40))))

        let (url, secret) = TVBoxDecoder.splitKey("https://h.example/c.json;pk;secret")
        XCTAssertEqual(url, "https://h.example/c.json")
        let ecb = Bytes.hex(aes(plain, key: pad(secret), iv: nil))
        XCTAssertEqual(try TVBoxDecoder.decode(ecb, secret), plain)
        XCTAssertThrowsError(try TVBoxDecoder.decode(ecb, "wrong"))

        let payload = Data([0x50, 0x4B, 3, 4]) + Data((0..<300).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let picture = Data([0xFF, 0xD8, 0, 1]) + Data((0..<200).map { UInt8(truncatingIfNeeded: $0 * 31) }) + Data(("\nqwerTY12**" + payload.base64EncodedString() + "\n").utf8)
        XCTAssertEqual(TVBoxDecoder.carried(picture), payload)
        XCTAssertNil(TVBoxDecoder.carried(Data([1, 2, 3])))
        XCTAssertEqual(SpiderRef.parse("https://h.example/a.jar;md5;https://h.example/Md5.txt").md5, "https://h.example/Md5.txt")
        XCTAssertEqual(try TVBoxDecoder.decode(Gzip.compress(Data(plain.utf8))), plain)
        let gbk = try XCTUnwrap("{\"a\":\"中文\"}".data(using: TextDecode.gb18030))
        XCTAssertEqual(try TVBoxDecoder.decode(gbk), "{\"a\":\"中文\"}")
        XCTAssertEqual(TextDecode.decode(gbk, "text/html; charset=GBK"), "{\"a\":\"中文\"}")
        XCTAssertEqual(TextDecode.decode(Data("<meta charset=\"gbk\">".utf8) + gbk), "<meta charset=\"gbk\">{\"a\":\"中文\"}")
    }

    // MARK: Config

    func testReadsTheFullFieldModelAndTolerantTypes() throws {
        let c = try config("""
            // 配置
            {"spider":"./jar/a.jar;md5;0cc175b9c0f1b6a831c399e269772661","logo":"./l.png","wallpaper":"https://w.example","warningText":"提示","unknown":{"x":[1]},
             "sites":[
               {"key":"js","name":"脚本","type":"3","api":"./js/drpy2.min.js","ext":"./js/rule.js","searchable":0,"filterable":"1","timeout":30,"categories":["电影","剧集"]},
               {"key":"jar","name":"包","type":3,"api":"csp_Demo","ext":{"site":"../x.json","list":["./y.txt"]},"jar":"./b.jar","header":{"ua":"U1"},"changeable":0},
               {"key":"py","name":"蟒","type":3,"api":"py_demo","ext":"./py/demo.py"},
               {"key":"t4","name":"远程","type":4,"api":"https://t4.example/api","ext":"https://t4.example/ext.json"},
               {"key":"t4","name":"重复","type":4,"api":"https://t4.example/api2"},
               {"key":"x","name":"🔞 站","type":1,"api":"http://cms.example/api.php/provide/vod/?ac=list"},
               {"name":"无 key","type":0,"api":"http://10.0.0.2/api.php"}, 5, null ],
             "parses":[{"name":"聚合","type":3,"url":"Demo"},{"name":"json","type":1,"url":"https://p.example/?url=","ext":{"flag":["qq","qiyi"],"header":{"User-Agent":"P"}}},{"name":"web","type":0,"url":"https://w.example/?url="},{"name":"坏","type":1}],
             "flags":["qq","youku"],"ads":["ad.example"],"hosts":["a.example=1.2.3.4"],"headers":[{"host":"v.example","header":{"Referer":"https://r.example"}}],
             "doh":[{"name":"阿里","url":"https://dns.alidns.com/dns-query","ips":["223.5.5.5"]},{"name":"x","url":"ftp://x"}],
             "rules":[{"name":"新","hosts":["v.example"],"regex":["master,m3u8"],"exclude":["ad"],"script":["1"]},{"host":"www.old.example","rule":["\\\\.php\\\\?x="]},{"host":"*","filter":["/ads/"]},{"name":"空"}]}
            """)
        XCTAssertEqual(SpiderRef.parse(c.spider).url, "https://h.example/dir/jar/a.jar")
        XCTAssertEqual(c.logo, "https://h.example/dir/l.png")
        XCTAssertEqual(c.notice, "提示")
        XCTAssertEqual(c.sites.map(\.key), ["js", "jar", "py", "t4", "x", "无 key"])
        let (js, jar, py, t4) = (c.sites[0], c.sites[1], c.sites[2], c.sites[3])
        XCTAssertEqual(js.kind, .js)
        XCTAssertEqual(js.ext, "https://h.example/dir/js/rule.js")
        XCTAssertFalse(js.searchable)
        XCTAssertTrue(js.filterable)
        XCTAssertEqual(js.timeoutMs, 30_000)
        XCTAssertEqual(js.categories, ["电影", "剧集"])
        let ext = try XCTUnwrap(LenientJson.objectOrNull(jar.ext))
        XCTAssertEqual(ext.string("site"), "https://h.example/x.json")
        XCTAssertEqual(ext.optJSONArray("list")?.first as? String, "https://h.example/dir/y.txt")
        XCTAssertEqual(c.jarOf(jar), "https://h.example/dir/b.jar")
        XCTAssertEqual(jar.headers, ["User-Agent": "U1"])
        XCTAssertEqual(c.jarOf(js), c.spider)
        XCTAssertFalse(jar.changeable)
        let script = try PySpider.script(py.api, py.ext)
        XCTAssertEqual(script.url, "https://h.example/dir/py/demo.py")
        XCTAssertEqual(script.ext, "")
        XCTAssertEqual(t4.api, "https://t4.example/api")
        XCTAssertTrue(c.sites[4].adult)
        XCTAssertEqual(c.sites[5].kind, .cmsXml)
        XCTAssertTrue(c.hasCode)
        XCTAssertEqual(c.parses.map(\.name), ["聚合", "json", "web"])
        XCTAssertEqual(c.parses[1].flags, ["qq", "qiyi"])
        XCTAssertEqual(c.parses[1].headers["User-Agent"], "P")
        XCTAssertEqual(c.hosts, ["a.example": "1.2.3.4"])
        XCTAssertEqual(c.headers.map(\.host), ["v.example"])
        XCTAssertEqual(c.doh.map(\.name), ["阿里"])
        XCTAssertEqual(c.rules.count, 3)
        XCTAssertTrue(c.rules[1].matches("www.old.example"))
        XCTAssertTrue(c.rules[2].matches("any.example"))
        XCTAssertEqual(c.rules[0].regex, ["master,m3u8"])
    }

    func testDepotsAreListedAndMayNestOnce() throws {
        guard case .depot(let a) = try TVBoxConfig.parse(#"{"storeHouse":[{"sourceName":"仓一","sourceUrl":"./one.json"},{"sourceName":"坏","sourceUrl":""}]}"#, "https://h.example/d/x.json") else { return XCTFail("depot") }
        XCTAssertEqual(a, [TVBoxDepotEntry(name: "仓一", url: "https://h.example/d/one.json")])
        guard case .depot(let b) = try TVBoxConfig.parse(#"{"urls":[{"url":"http://a.example/1","name":"线路1"},{"url":"http://a.example/1","name":"重复"},{"url":"http://b.example/2"}]}"#, "https://h.example/x.json") else { return XCTFail("depot") }
        XCTAssertEqual(b.map(\.name), ["线路1", "b.example"])
        // a single config with sites is never mistaken for a depot
        XCTAssertEqual(try config(#"{"urls":[{"url":"x","name":"y"}],"sites":[{"key":"k","api":"https://a.example","type":1}]}"#).sites.count, 1)
    }

    func testMessagesAndForeignContentAreReadableErrors() throws {
        func message(_ text: String) -> String {
            do { _ = try TVBoxConfig.parse(text, ""); return "" } catch { return error.localizedDescription }
        }
        XCTAssertEqual(message(#"{"code":500,"msg":"账号已过期"}"#), "账号已过期")
        XCTAssertTrue(message("<!DOCTYPE html><html></html>").contains("网页"))
        XCTAssertTrue(message(#"{"sites":[],"spider":""}"#).contains("没有点播站点"))
        XCTAssertFalse(message("hello").isEmpty)
        func isLive(_ text: String) throws -> Bool { if case .live = try TVBoxConfig.parse(text, "") { return true } else { return false } }
        XCTAssertTrue(try isLive("#EXTM3U\n#EXTINF:-1,A\nhttp://a.example/1.m3u8"))
        XCTAssertTrue(try isLive("央视,#genre#\nCCTV1,http://a.example/1"))
        XCTAssertFalse(try isLive("# 注释\n{\"lives\":[{\"name\":\"a\",\"url\":\"http://a.example/l.txt\"}]}"))
        XCTAssertTrue(try isLive(#"[{"group":"g","channel":[{"name":"n","urls":["http://a.example/1"]}]}]"#))
        XCTAssertTrue(TVBoxConfig.isConfig("// x\n{sites:[]}"))
        XCTAssertTrue(TVBoxConfig.isConfig(#"{"urls":[{"url":"x"}]}"#))
        XCTAssertFalse(TVBoxConfig.isConfig(#"{"plugins":[],"urls":[]}"#))
    }

    // MARK: Live

    func testLiveVariants() throws {
        let b64 = Data("https://l.example/list.txt".utf8).base64EncodedString()
        let c = try config("""
            {"lives":[
            {"group":"redirect","channels":[{"name":"轮播","urls":["proxy://do=live&type=txt&ext=\(b64)"]}]},
            {"name":"新版","type":0,"url":"./tv.m3u","epg":"https://e.example/?ch={name}&date={date}","ua":"U","referer":"https://r.example","timeout":20},
            {"name":"包","type":3,"api":"csp_Live","ext":"x"},
            {"name":"内嵌","groups":[{"name":"g","pass":"1","channel":[{"name":"n","urls":["http://a.example/1"],"ua":"C"}]}]},
            {"group":"央视","channels":[{"name":"CCTV1","urls":["http://a.example/cctv1"]}]}]}
            """)
        XCTAssertEqual(c.lives.map(\.name), ["配置直播", "轮播", "新版", "包", "内嵌"])
        XCTAssertEqual(c.lives[1].url, "https://l.example/list.txt")
        XCTAssertEqual(c.lives[2].url, "https://h.example/dir/tv.m3u")
        XCTAssertEqual(c.lives[2].requestHeaders, ["User-Agent": "U", "Referer": "https://r.example"])
        XCTAssertEqual(c.lives[2].timeoutMs, 20_000)
        XCTAssertEqual(c.lives[3].kind, .jar)
        XCTAssertTrue(c.hasCode)
        XCTAssertEqual(c.lives[4].groups.first?.pass, "1")
        XCTAssertEqual(c.lives[4].groups.first?.channels.first?.headers["User-Agent"], "C")
        XCTAssertEqual(c.lives[0].groups.first?.channels.first?.name, "CCTV1")
        XCTAssertEqual(TVBoxConfig.proxyLive("proxy://do=live&ext=https%3A%2F%2Fp.example%2Fl%3Fa%3D1"), "https://p.example/l?a=1")
        XCTAssertEqual(TVBoxConfig.liveUid("r", c.lives[3].identity), TVBoxConfig.liveUid("r", "csp_Live x"))
    }

    func testTextListDirectivesPasswordsAndMergedLines() throws {
        let l = LiveParser.parse("ua=UA 1\r\nA,http://a.example/1\r\n分组_pw,#genre#\r\nheader={\"Referer\":\"https://r.example/\"}\r\nparse=1\r\nB,https://b.example/page#frag#https://b.example/2$备用\r\n")
        XCTAssertEqual(l.groups.map(\.name), ["默认分组", "分组"])
        XCTAssertEqual(l.groups[0].channels[0].headers, ["User-Agent": "UA 1"])
        let b = l.groups[1].channels[0]
        XCTAssertEqual(l.groups[1].pass, "pw")
        XCTAssertEqual(b.urls, ["https://b.example/page#frag", "https://b.example/2$备用"])
        XCTAssertTrue(b.parse)
        XCTAssertEqual(b.headers["Referer"], "https://r.example/")
        XCTAssertEqual(LiveParser.parse("分组_pw,#genre#\nB,https://b.example/1", skipPass: true).groups[0].pass, "")
        let m = LiveParser.parse("""
            #EXTM3U url-tvg="https://e.example/a.xml.gz"
            #EXTINF:-1 group-title="G;H" tvg-logo="l",名称, 带逗号
            #KODIPROP:inputstream.adaptive.manifest_type=mpd
            #KODIPROP:inputstream.adaptive.license_type=clearkey
            #KODIPROP:inputstream.adaptive.license_key=k1:k2
            #EXTHTTP:{"Cookie":"a=1"}
            https://a.example/x
            #EXTINF:-1,无分组
            #EXTGRP:组
            rtp://239.1.1.1:5000
            """)
        XCTAssertEqual(m.epg, "https://e.example/a.xml.gz")
        let x = m.groups[0].channels[0]
        XCTAssertEqual(m.groups[0].name, "G")
        XCTAssertEqual(x.name, "名称, 带逗号")
        XCTAssertEqual(x.format, "application/dash+xml")
        XCTAssertEqual(x.drm, ["type": "clearkey", "key": "k1:k2"])
        XCTAssertEqual(x.headers["Cookie"], "a=1")
        XCTAssertEqual(m.groups[1].name, "组")
        let media = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(x.mediaJSON(["User-Agent": "L"], "https://e.example/a.xml.gz").utf8)) as? [String: Any])
        XCTAssertEqual((media["headers"] as? [String: String])?["User-Agent"], "L")
        XCTAssertEqual(media["epg"] as? String, "https://e.example/a.xml.gz")
        XCTAssertEqual((media["urls"] as? [String])?.count, 1)
        // another header set of the same channel travels with its own line
        let merged = LiveParser.parse("ua=A\nC,http://a.example/1\nua=B 1\nC,http://b.example/2$备\n").groups[0].channels[0]
        XCTAssertEqual(merged.urls, ["http://a.example/1", "http://b.example/2|User-Agent=B%201$备"])
    }

    func testCatchupTemplates() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start: Int64 = 1_767_225_600_000 // 2026-01-01T00:00:00Z
        let end = start + 3_600_000
        func url(_ c: Catchup, _ s: String) -> String? { c.url(s, start, end, now: end + 60_000, zone: utc) }
        XCTAssertEqual(url(Catchup(type: "append", source: "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}"), "http://a.example/1.m3u8"), "http://a.example/1.m3u8?playseek=20260101000000-20260101010000")
        XCTAssertEqual(url(Catchup(type: "append", source: "?b={utc}"), "http://a.example/1?x=1"), "http://a.example/1?x=1&b=1767225600")
        XCTAssertEqual(url(Catchup(type: "default", source: "http://r.example/{utc}/{utcend}/{duration}/{duration:60}"), "http://a.example/1"), "http://r.example/1767225600/1767229200/3600/60")
        XCTAssertEqual(url(Catchup(type: "shift", source: ""), "http://a.example/1"), "http://a.example/1?utc=1767225600&lutc=1767229260")
        XCTAssertEqual(url(Catchup(type: "flussonic", source: ""), "http://a.example/ch/index.m3u8?token=t"), "http://a.example/ch/index-1767225600-3600.m3u8?token=t")
        XCTAssertEqual(url(Catchup(type: "xc", source: ""), "http://h.example:80/live/u/p/12.ts"), "http://h.example:80/timeshift/u/p/60/2026-01-01:00-00/12.ts")
        XCTAssertEqual(url(Catchup(type: "append", source: "{Y}/{m}/{d}/{H}"), "http://a.example/"), "http://a.example/2026/01/01/00")
        XCTAssertEqual(url(try XCTUnwrap(Catchup.implied("rtsp://h.example/PLTV/1")), "rtsp://h.example/PLTV/1"), "rtsp://h.example/TVOD/1?playseek=20260101000000-20260101010000")
        XCTAssertNil(Catchup.implied("http://a.example/1"))
        XCTAssertNil(url(Catchup(type: "default", source: ""), "http://a.example/1"))
        let c = Catchup(type: "append", source: "?x", days: 7, replace: "a,b")
        XCTAssertEqual(Catchup.fromJSON(c.toJSON()), c)
    }

    private static func chunks(_ d: Data, _ n: Int) -> () -> Data? {
        var at = 0
        return {
            guard at < d.count else { return nil }
            let c = d.subdata(in: at..<min(d.count, at + n))
            at += n
            return c
        }
    }

    func testProgrammeGuides() throws {
        let z = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let day = EpgParser.json(#"{"epg_data":[{"title":"新闻","start":"23:30","end":"00:30"},{"title":"","start":"01:00","end":"02:00"},{"title":"早间","start":"06:00","end":"07:00","desc":"d"}]}"#, "2026-11-25", z)
        XCTAssertEqual(day.map(\.title), ["早间", "新闻"])
        XCTAssertEqual(day[1].end - day[1].start, 3_600_000)
        let (now, next) = EpgService.nowNext(day, day[0].start + 1000)
        XCTAssertEqual(now?.title, "早间")
        XCTAssertEqual(next?.title, "新闻")
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE tv SYSTEM "xmltv.dtd"><tv><!-- a > b --><channel id="1"><display-name lang="zh">CCTV-1 综合</display-name></channel><channel id="2"><display-name>其他</display-name></channel>
            <programme start="20261125080000 +0800" stop="20261125090000 +0800" channel="1"><title lang="zh">朝闻 &amp; <![CDATA[天<下>]]></title><desc>x</desc></programme>
            <programme start="20261125080000" stop="20261125090000" channel="2"><title>不要</title></programme></tv>
            """
        let at: Int64 = 1_795_564_800_000
        let wanted: Set<String> = [EpgParser.key("cctv1综合")]
        for size in [1, 7, 100_000] {
            let map = try EpgParser.xmltv(Self.chunks(Data(xml.utf8), size), wanted: wanted, from: at - 30 * 86_400_000, to: at + 30 * 86_400_000, zone: z)
            XCTAssertEqual(Set(map.keys), ["cctv1综合"])
            XCTAssertEqual(map["cctv1综合"]?.map(\.title), ["朝闻 & 天<下>"])
            XCTAssertEqual(EpgParser.day(try XCTUnwrap(map["cctv1综合"]?.first).start, z), "2026-11-25")
        }
        let gz = Gzip.compress(Data(xml.utf8))
        let map = try EpgParser.xmltv(try TVBoxGzip.source(Self.chunks(gz, 64)), wanted: nil, from: at - 30 * 86_400_000, to: at + 30 * 86_400_000, zone: z)
        XCTAssertEqual(Set(map.keys), ["1", "cctv1综合", "2", "其他"])
        XCTAssertEqual(map["其他"]?.first?.start, map["1"]?.first?.start)
    }

    // MARK: Vod

    func testVodMappingFoldersFiltersAndContentRules() throws {
        let o = try XCTUnwrap(LenientJson.objectOrNull(#"""
            {"class":[{"type_id":1,"type_name":"电影"},{"type_id":"2","type_name":"小学生"},{"type_id":"3","type_name":"剧集"}],
            "filters":{"1":[{"key":"area","name":"地区","init":"cn","value":[{"n":"全部","v":""},{"n":"大陆","v":"cn"}]}]},
            "list":[{"vod_id":"a/b%c","vod_name":"片 &amp; 名","vod_pic":"//i.example/1.jpg","vod_remarks":"更新","vod_tag":"file"},{"vod_id":"f","vod_name":"目录","vod_tag":"folder"},{"vod_id":"","vod_name":"无"},{"vod_id":"z","vod_name":"萝莉"}]}
            """#))
        let h = VodMapper.home(o, "u1", ["剧集", "电影", "没有"]) { $0.hasPrefix("//") ? "https:" + $0 : $0 }
        XCTAssertEqual(h.categories.map(\.name), ["剧集", "电影"])
        XCTAssertEqual(h.filters["1"]?.first?.initial, "cn")
        XCTAssertEqual(h.items.map(\.title), ["片 & 名", "目录"])
        XCTAssertTrue(h.items[1].folder)
        XCTAssertEqual(h.items[0].cover, "https://i.example/1.jpg")
        XCTAssertEqual(h.items[0].series.id, "tvb.u1:a/b%c")
        XCTAssertEqual(TVBoxId.parseEpisode(TVBoxId.episode("{\"x\":\"#1#2\"}", 0, 12)), TVBoxId.Ep(id: "{\"x\":\"#1#2\"}", line: 0, index: 12))
        XCTAssertNil(TVBoxId.parseEpisode("id#1"))
        let v = JSONObject().put("vod_name", "剧").put("vod_content", "<p>简介&nbsp;一</p>").put("vod_year", "2026").put("vod_actor", "甲,乙")
            .put("vod_play_from", "qq$$$m3u8").put("vod_play_url", "1$abc#2$def$$$正片$https://v.example/1.m3u8")
        let d = try VodMapper.detail(JSONObject().put("list", [v]), "u1", "id1", TVBoxSite(key: "k", name: "站", type: 1, api: "")) { $0 }
        XCTAssertEqual(d.source, .tvbox("u1"))
        XCTAssertEqual(d.lines.count, 2)
        XCTAssertEqual(d.lines[0].episodes, d.episodes)
        XCTAssertEqual(d.lines[1].episodes.map(\.vid), ["id1#1#0"])
        let media = try XCTUnwrap(LenientJson.objectOrNull(d.episodes[0].media ?? ""))
        XCTAssertEqual(media.string("f"), "qq")
        XCTAssertEqual(media.string("id"), "abc")
        XCTAssertEqual(d.actors, ["甲", "乙"])
        XCTAssertTrue(d.desc.contains("简介"))
        XCTAssertFalse(VodMapper.page(try XCTUnwrap(LenientJson.objectOrNull(#"{"list":[{"vod_id":"1","vod_name":"a"}],"page":2,"pagecount":2}"#)), "u", 2) { $0 }.hasMore)
        XCTAssertTrue(VodMapper.page(try XCTUnwrap(LenientJson.objectOrNull(#"{"list":[{"vod_id":"1","vod_name":"a"}]}"#)), "u", 1) { $0 }.hasMore)
        XCTAssertEqual(VodMapper.localProxy("proxy://do=js&a=1", 9980, "k 1"), "http://127.0.0.1:9980/proxy?do=js&a=1&siteKey=k+1")
        XCTAssertEqual(VodMapper.localProxy("http://127.0.0.1:9978/proxy?do=bili", 9980, ""), "http://127.0.0.1:9980/proxy?do=bili")
    }

    // MARK: State

    func testStoreV1BecomesV2WithoutLosingChoices() throws {
        let v1 = try XCTUnwrap(LenientJson.objectOrNull(#"""
            {"activeRepoId":"r1","favoriteChannels":["CCTV1"],"repos":[
            {"id":"r1","name":"仓","url":"https://h.example/c.json","updatedAt":5,"sites":[{"key":"k1","name":"站","api":"https://cms.example/api.php/provide/vod/","enabled":false,"categories":[]},{"key":"k2","name":"二","api":"https://b.example/api"}],"lives":[{"id":"l1","name":"直播","url":"https://l.example/a.m3u","enabled":false}]},
            {"id":"r2","name":"本地","url":"","sites":[],"lives":[{"name":"粘贴","url":"","channels":[{"name":"A","group":"G","urls":["https://a.example/1"]}]}]}],
            "recentWatches":[{"siteKey":"k2","seriesId":"cms:k2:42","title":"剧","cover":"c","episodeIndex":3,"positionMs":61000,"durationMs":100000,"updatedAt":9},{"siteKey":"k2","seriesId":"43","episodeIndex":0,"positionSec":12.5,"durationSec":60,"updatedAt":1790000000.5},{"siteKey":"gone","seriesId":"cms:gone:1"}]}
            """#))
        let m = TVBoxState.migrateV1(v1)
        XCTAssertEqual(m.state.active, "r1")
        XCTAssertEqual(m.state.favorites, ["CCTV1"])
        let r = m.state.repos[0]
        XCTAssertEqual(r.disabled, [TVBoxConfig.siteUid("r1", "k1"), TVBoxConfig.liveUid("r1", "https://l.example/a.m3u")])
        XCTAssertEqual(r.trust, .ask)
        let c = try config(try XCTUnwrap(m.configs["r1"]))
        XCTAssertEqual(c.sites.map(\.key), ["k1", "k2"])
        XCTAssertEqual(c.lives.map(\.url), ["https://l.example/a.m3u"])
        XCTAssertEqual(try config(try XCTUnwrap(m.configs["r2"])).lives[0].groups[0].channels[0].name, "A")
        XCTAssertEqual(m.watches, [
            LegacyWatch(uid: TVBoxConfig.siteUid("r1", "k2"), vodId: "42", title: "剧", cover: "c", episodeIndex: 3, positionMs: 61_000, durationMs: 100_000, updatedAt: 9),
            LegacyWatch(uid: TVBoxConfig.siteUid("r1", "k2"), vodId: "43", title: "", cover: "", episodeIndex: 0, positionMs: 12_500, durationMs: 60_000, updatedAt: 1_790_000_000_500),
        ])
        // first refresh: the real config names the same site differently
        let fresh = try config(#"{"sites":[{"key":"real","name":"站二","type":1,"api":"http://b.example/api/"}]}"#)
        XCTAssertEqual(TVBoxState.aliases(r, fresh), [TVBoxConfig.siteUid("r1", "k2"): TVBoxConfig.siteUid("r1", "real")])
        var s = m.state
        s.unlocked = ["u": ["g"]]
        s.allowLan = true
        s.latency = ["x": 12]
        s.depots = [DepotRecord(id: "d", name: "多仓", url: "https://d.example", entries: [TVBoxDepotEntry(name: "一", url: "https://d.example/1")])]
        let o = try XCTUnwrap(LenientJson.objectOrNull(s.toJSON().toString()))
        XCTAssertEqual(J.int(o["v"]), 2)
        XCTAssertEqual(TVBoxState.fromJSON(o), s)
    }

    func testCacheKeepsTextsAndIsBounded() throws {
        let dir = tmp.appendingPathComponent("c2")
        let c = TVBoxCache(dir, maxBytes: 10)
        c.put("owner", "k|1", "文本")
        XCTAssertEqual(TVBoxCache(dir).get("owner", "k|1")?.text, "文本")
        c.put("other", "k", String(repeating: "x", count: 40))
        c.clear("owner")
        XCTAssertNil(c.get("owner", "k|1"))
        c.trim()
        XCTAssertNil(TVBoxCache(dir).get("other", "k"))
        // a text too big for memory never leaves an older one behind
        let d = TVBoxCache(dir)
        d.put("live", "list", "old")
        XCTAssertEqual(d.get("live", "list")?.text, "old")
        let big = String(repeating: "新", count: 500_000)
        d.put("live", "list", big)
        XCTAssertEqual(d.get("live", "list")?.text, big)
        d.put("live", "list", "new")
        XCTAssertEqual(d.get("live", "list")?.text, "new")
    }

    func testChannelsAreFoundAgainInANewerList() {
        func ep(_ group: String, _ name: String, _ url: String) -> HGEpisode { HGEpisode(ep: 1, vid: "", duration: 0, title: name, page: group, media: #"{"urls":["\#(url)"]}"#) }
        let now = [ep("央视", "CCTV1", "a"), ep("卫视", "湖南", "b"), ep("卫视", "湖南", "c"), ep("备用", "CCTV1", "d")]
        func at(_ group: String, _ name: String, _ url: String) -> Int? { ChannelKey(group: group, name: name, url: url).index(in: now) }
        XCTAssertEqual(at("备用", "CCTV1", ""), 3)
        XCTAssertEqual(at("卫视", "湖南", "c"), 2)
        XCTAssertEqual(at("卫视", "湖南", "moved"), 1)
        XCTAssertEqual(at("改名的组", "CCTV1", "d"), 3)
        XCTAssertEqual(at("", "湖南", ""), 1)
        XCTAssertNil(at("央视", "没有", "a"))
        XCTAssertNil(at("央视", "", "a"))
        XCTAssertEqual(ChannelKey(now[1]), ChannelKey(group: "卫视", name: "湖南", url: "b"))
        // among equals the place decides
        XCTAssertEqual(ChannelKey(group: "卫视", name: "湖南", url: "moved").index(in: now, near: 2), 2)
        XCTAssertEqual(ChannelKey(group: "卫视", name: "湖南", url: "moved").index(in: now, near: 3), 1)
        XCTAssertEqual(LiveHooks.place(0, ChannelKey(group: "卫视", name: "湖南", url: "c"), in: now), 2)
        XCTAssertEqual(LiveHooks.place(7, ChannelKey(group: "x", name: "没有", url: ""), in: now), 7)
        XCTAssertEqual(LiveHooks.place(7, nil, in: now), 7)
    }

    func testPlaybackAddressesFollowTheLanPolicy() async throws {
        let inside = ["http://192.168.1.1:4022/udp/239.0.0.1:5140", "http://10.0.0.1/", "rtp://239.1.1.1:5140", "udp://@239.0.0.1:1234", "rtsp://10.0.0.8/live", "http://nas.local/a.m3u8", "http://[fe80::1]/"]
        for u in inside {
            XCTAssertEqual(LanPolicy.refusal(u, lan: false, own: 0, bridge: ""), LanPolicy.message, u)
            XCTAssertNil(LanPolicy.refusal(u, lan: true, own: 0, bridge: ""), u)
            XCTAssertNil(LanPolicy.refusal(u, lan: nil, own: 0, bridge: ""), u)
        }
        XCTAssertNil(LanPolicy.refusal("http://192.168.1.2:9979/bridge/proxy?x", lan: false, own: 0, bridge: "192.168.1.2:9979"))
        XCTAssertEqual(LanPolicy.refusal("http://192.168.1.2:80/x", lan: false, own: 0, bridge: "192.168.1.2:9979"), LanPolicy.message)
        for lan in [true, false] {
            XCTAssertNil(LanPolicy.refusal("http://127.0.0.1:9978/proxy?do=js", lan: lan, own: 9978, bridge: ""))
            XCTAssertEqual(LanPolicy.refusal("http://127.0.0.1:1/x", lan: lan, own: 9978, bridge: ""), LanPolicy.device)
            XCTAssertEqual(LanPolicy.refusal("http://0.0.0.0:9/x", lan: lan, own: 9978, bridge: ""), LanPolicy.device)
            XCTAssertNil(LanPolicy.refusal("https://v.example/a.m3u8", lan: lan, own: 9978, bridge: ""))
        }
        XCTAssertNil(LanPolicy.refusal("data:video/mp4;base64,AAAA", lan: false, own: 0, bridge: ""))
        for u in ["file:///etc/hosts", "FILE:///etc/hosts", "/data/x.mp4", "lavf://http://192.168.1.1/a", "edl://http://127.0.0.1/a"] {
            XCTAssertEqual(LanPolicy.refusal(u, lan: true, own: 0, bridge: ""), LanPolicy.unsupported, u)
            XCTAssertNil(LanPolicy.refusal(u, lan: nil, own: 0, bridge: ""), u)
        }
        NetGuard.resolverOverride = { $0 == "inner.example" ? ["192.168.0.9"] : $0 == "loop.example" ? ["127.0.0.1"] : ["93.184.216.34"] }
        func refused(_ u: String, _ lan: Bool?) async -> Bool { do { try await LanPolicy.check(u, lan: lan); return false } catch { return true } }
        var r = await refused("http://inner.example/x", false)
        XCTAssertTrue(r)
        r = await refused("http://inner.example/x", true)
        XCTAssertFalse(r)
        r = await refused("http://loop.example/x", true)
        XCTAssertTrue(r)
        r = await refused("http://v.example/x", false)
        XCTAssertFalse(r)
        // an imported file or this device is no private network
        XCTAssertFalse(TVBoxNet.isPrivateAddress("clan://localhost/cfg.json"))
        XCTAssertFalse(TVBoxNet.isPrivateAddress("http://127.0.0.1:9978/file/cfg.json"))
        XCTAssertTrue(TVBoxNet.isPrivateAddress("http://nas.lan/cfg.json"))
        // through the engine: refused lines are left out, a list without any other says why
        TVBoxStub.routes["/live.txt"] = { _ in .init(body: "组,#genre#\n甲,http://192.168.1.1:4022/a#http://a.example/1.m3u8\n乙,http://192.168.1.1:4022/b\n") }
        let c = try config("{\"sites\":[{\"key\":\"a\",\"type\":1,\"api\":\"https://a.example\"}],\"lives\":[{\"name\":\"直播\",\"url\":\"\(at("/live.txt"))\"}]}")
        let uid = TVBoxConfig.liveUid("r", at("/live.txt"))
        engine.setRepos([RepoRuntime("r", "仓", c, trusted: true, allowPrivate: false)], active: "r")
        let eps = try await engine.liveDetail(uid, unlocked: []).episodes
        let first = try await engine.resolveLive(uid, eps[0], unlocked: [])
        XCTAssertEqual(first.streams.map(\.url), ["http://a.example/1.m3u8"])
        let m = await failure { _ = try await self.engine.resolveLive(uid, eps[1], unlocked: []) }
        XCTAssertEqual(m, LanPolicy.message)
        engine.setRepos([RepoRuntime("r", "仓", c, trusted: true, allowPrivate: true)], active: "r")
        let second = try await engine.resolveLive(uid, eps[1], unlocked: [])
        XCTAssertEqual(second.streams.first?.lan, true)
    }

    // MARK: Parse chain

    private func chain(_ json: String = "\"flags\":[]", _ http: CannedHttp, jar: JarParsers? = nil, preferred: String = "") throws -> ParseChain {
        ParseChain(config: try config("{\"sites\":[{\"key\":\"a\",\"type\":1,\"api\":\"https://a.example\"}],\(json)}", ""), http: http, sniffer: sniffer, jar: jar, allowPrivate: false, preferred: preferred, timeoutMs: 2000)
    }

    private func run(_ c: ParseChain, _ r: String, _ flag: String = "qq", _ click: String = "") async throws -> ParsedVideo { try await c.resolve(try PlayerResult.parse(r), flag, click: click) }

    func testDirectResultsAreNotTouched() async throws {
        let http = CannedHttp()
        let c = try chain(#""flags":["qq"],"parses":[{"name":"w","type":0,"url":"https://w.example/?u="}]"#, http)
        var v = try await run(c, #"{"parse":0,"url":"https://v.example/a.m3u8"}"#)
        XCTAssertEqual(v.urls, [PlayUrl(name: "", url: "https://v.example/a.m3u8")])
        v = try await run(c, #"{"parse":0,"playUrl":"https://pre.example/?u=","url":"abc"}"#)
        XCTAssertEqual(v.urls.map(\.url), ["https://pre.example/?u=abc"])
        let open = try chain("\"flags\":[]", http)
        v = try await run(open, #"{"parse":1,"url":"https://v.example/b.mp4"}"#)
        XCTAssertEqual(v.urls.map(\.url), ["https://v.example/b.mp4"])
        v = try await run(open, #"{"url":"http://127.0.0.1:9978/proxy?do=x"}"#)
        XCTAssertEqual(v.urls.map(\.url), ["http://127.0.0.1:9978/proxy?do=x"])
        XCTAssertTrue(sniffer.requests.isEmpty)
        _ = try await run(open, #"{"url":"https://page.example/play/1"}"#) // a missing parse means "needs parsing"
        XCTAssertEqual(sniffer.requests.map(\.url), ["https://page.example/play/1"])
        sniffer.requests = []
        _ = try await run(open, #"{"parse":1,"url":"http://127.0.0.1:9978/proxy?do=page"}"#) // explicit: the proxied page is opened
        XCTAssertEqual(sniffer.requests.count, 1)
        let p2p = await failure { _ = try await self.run(c, #"{"parse":0,"url":"magnet:?xt=1"}"#) }
        XCTAssertTrue(p2p.contains("P2P"))
        let login = await failure { _ = try await self.run(c, #"{"parse":0,"msg":"需要登录"}"#) }
        XCTAssertTrue(login.contains("需要登录"))
    }

    func testPlayUrlPrefixesPickTheirParse() async throws {
        let http = CannedHttp()
        http.bodies["https://p.example/?url=abc"] = #"{"code":200,"url":"https://v.example/j.m3u8","User-Agent":"P","header":{"Referer":"https://r.example"}}"#
        let c = try chain(#""parses":[{"name":"甲","type":1,"url":"https://p2.example/?url=","ext":{"header":{"X":"1"}}}]"#, http)
        let j = try await run(c, #"{"parse":0,"playUrl":"json:https://p.example/?url=","url":"abc"}"#)
        XCTAssertEqual(j.urls.map(\.url), ["https://v.example/j.m3u8"])
        XCTAssertEqual(j.headers, ["Referer": "https://r.example", "User-Agent": "P"])
        http.bodies["https://p2.example/?url=abc"] = #"{"data":{"url":"https://v.example/k.mp4"}}"#
        let k = try await run(c, #"{"playUrl":"parse:甲","url":"abc"}"#)
        XCTAssertEqual(k.urls.map(\.url), ["https://v.example/k.mp4"])
        XCTAssertEqual(http.requests.last?.headers["X"], "1")
        let e = await failure { _ = try await self.run(c, #"{"playUrl":"parse:没有","url":"abc"}"#) }
        XCTAssertTrue(e.contains("没有"))
    }

    func testPagesAreSniffedWithRulesClickAndHeaders() async throws {
        let c = try chain(#""rules":[{"hosts":["page.example"],"regex":["\\.php\\?v="],"exclude":["ad\\."],"script":["document.x()"]}],"ads":["ad.example"]"#, CannedHttp())
        _ = try await run(c, #"{"parse":1,"url":"https://page.example/1.html","header":{"User-Agent":"U"},"click":"a()"}"#, "", "b()")
        let s = try XCTUnwrap(sniffer.requests.first)
        XCTAssertEqual(s.url, "https://page.example/1.html")
        XCTAssertEqual(s.headers["User-Agent"], "U")
        XCTAssertEqual(s.scripts, ["a()", "b()", "document.x()"])
        XCTAssertEqual(s.ads, ["ad.example"])
        XCTAssertTrue(SniffRules.isVideo("https://cdn.example/x.php?v=1", s.url, s.rules))
        XCTAssertFalse(SniffRules.isVideo("https://ad.example/ad.m3u8", s.url, s.rules))
        XCTAssertFalse(SniffRules.isVideo("https://cdn.example/x.js", s.url, s.rules))
        XCTAssertTrue(SniffRules.isAd("x.ad.example", s.ads))
        XCTAssertFalse(SniffRules.isAd("good.example", s.ads))
    }

    func testFlaggedAndJxResultsRaceAllParses() async throws {
        let http = CannedHttp()
        http.bodies["https://slow.example/"] = #"{"url":"https://v.example/slow.m3u8"}"#
        http.bodies["https://bad.example/"] = #"{"code":404,"msg":"解析失败"}"#
        let cancelled = Counter()
        sniffer.answer = { _ in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { cancelled.add(); throw error }
            return SniffResult(url: "", headers: [:])
        }
        let parses = #""flags":["qq"],"parses":[{"name":"坏","type":1,"url":"https://bad.example/?u="},{"name":"慢","type":1,"url":"https://slow.example/?u="},{"name":"网","type":0,"url":"https://w.example/?u="},{"name":"超级","type":4,"url":""}]"#
        let t = Date()
        let r = try await run(try chain(parses, http), #"{"parse":1,"url":"https://v.qq.example/x.html"}"#)
        XCTAssertEqual(r.urls.map(\.url), ["https://v.example/slow.m3u8"])
        XCTAssertEqual(r.via, "慢")
        XCTAssertLessThan(Date().timeIntervalSince(t), 1.5)
        XCTAssertEqual(cancelled.value, 1)
        // the browser parse wins when it is faster
        sniffer.answer = { _ in try await Task.sleep(nanoseconds: 20_000_000); return SniffResult(url: "https://v.example/web.mp4", headers: [:]) }
        let web = try await run(try chain(parses, http), #"{"parse":0,"jx":1,"url":"https://v.qq.example/x.html"}"#)
        XCTAssertEqual(web.urls.map(\.url), ["https://v.example/web.mp4"])
        // not flagged: only the page itself is sniffed
        sniffer.requests = []
        _ = try await run(try chain(parses, http), #"{"parse":1,"url":"https://v.other.example/x.html"}"#, "other")
        XCTAssertEqual(sniffer.requests.map(\.url), ["https://v.other.example/x.html"])
    }

    func testParsesMayBeLimitedToFlagsAndAUserChoice() async throws {
        let http = CannedHttp()
        http.bodies["https://one.example/"] = #"{"url":"https://v.example/one.m3u8"}"#
        http.bodies["https://two.example/"] = #"{"url":"https://v.example/two.m3u8"}"#
        let parses = #""flags":["qq","iqiyi"],"parses":[{"name":"一","type":1,"url":"https://one.example/?u=","ext":{"flag":["iqiyi"]}},{"name":"二","type":1,"url":"https://two.example/?u=","ext":{"flag":["qq"]}}]"#
        let page = #"{"parse":1,"url":"https://x.example/1.html"}"#
        var v = try await run(try chain(parses, http), page)
        XCTAssertEqual(v.urls.map(\.url), ["https://v.example/two.m3u8"])
        XCTAssertFalse(http.requests.contains { $0.url.hasPrefix("https://one.example") })
        v = try await run(try chain(parses, http, preferred: "一"), page)
        XCTAssertEqual(v.urls.map(\.url), ["https://v.example/one.m3u8"])
        http.bodies["https://one.example/"] = nil
        v = try await run(try chain(parses, http, preferred: "一"), page)
        XCTAssertEqual(v.urls.map(\.url), ["https://v.example/two.m3u8"])
        http.bodies = [:]
        let e = await failure { _ = try await self.run(try self.chain(parses, http), page) }
        XCTAssertTrue(e.contains("解析"))
    }

    func testJsonResultsThatStillNeedABrowserAndJarExtensions() async throws {
        let http = CannedHttp()
        http.bodies["https://p.example/"] = #"{"parse":1,"url":"https://player.example/?id=1","header":{"Referer":"https://p.example"}}"#
        let r = try await run(try chain(#""parses":[{"name":"p","type":1,"url":"https://p.example/?u="}]"#, http), #"{"jx":1,"url":"https://v.qq.example/x.html"}"#)
        XCTAssertEqual(r.urls.map(\.url), ["https://sniffed.example/v.m3u8"])
        XCTAssertEqual(sniffer.requests.first?.url, "https://player.example/?id=1")
        XCTAssertEqual(sniffer.requests.first?.headers["Referer"], "https://p.example")

        let parsers = FakeParsers()
        let parses = #""parses":[{"name":"一","type":1,"url":"https://one.example/?url=","ext":{"a":1}},{"name":"包","type":2,"url":"Demo"},{"name":"混","type":3,"url":"M"}]"#
        var v = try await run(try chain(parses, http, jar: parsers, preferred: "包"), #"{"jx":1,"url":"u"}"#)
        XCTAssertEqual(v.urls.map(\.url), ["https://v.example/x.m3u8"])
        v = try await run(try chain(parses, http, jar: parsers, preferred: "混"), #"{"jx":1,"url":"u"}"#)
        XCTAssertEqual(v.urls.map(\.url), ["https://v.example/y.m3u8"])
        XCTAssertEqual(parsers.calls, ["json Demo https://one.example/?cat_ext=eyJhIjoxfQ==&url= u", "mix M 混 qq 1 u"])
        let e = await failure { _ = try await self.run(try self.chain(#""parses":[{"name":"包","type":2,"url":"Demo"}]"#, http, preferred: "包"), #"{"jx":1,"url":"https://u.example/1"}"#) }
        XCTAssertTrue(e.contains("JAR"))
    }

    // MARK: Sessions

    func testTimeoutsAndCancellationReleaseTheSpider() async throws {
        let s = SpiderSession("测", initTimeoutMs: 1000, graceMs: 400) { SleepySpider(interruptible: true) }
        let t = Date()
        let late = await failure { _ = try await s.call(200, "首页") { try $0.homeContent(filter: true) } }
        XCTAssertTrue(late.contains("超时"))
        XCTAssertLessThan(Date().timeIntervalSince(t), 2)
        let ok = try await s.call(1000, "首页") { try $0.homeContent(filter: false) } // the interrupted thread is usable again
        XCTAssertEqual(ok, "ok")
        let job = Task { try await s.call(5000, "首页") { try $0.homeContent(filter: true) } }
        try await Task.sleep(nanoseconds: 100_000_000)
        job.cancel()
        do { _ = try await job.value; XCTFail("not cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let again = try await s.call(1000, "首页") { try $0.homeContent(filter: false) }
        XCTAssertEqual(again, "ok")
        XCTAssertFalse(s.dead)
        // the deadline starts with the call, not with the wait for the one before it
        async let first: String = s.call(1500, "一") { _ in Thread.sleep(forTimeInterval: 0.7); return "1" }
        async let second: String = s.call(1500, "二") { _ in Thread.sleep(forTimeInterval: 0.7); return "2" }
        async let third: String = s.call(1500, "三") { _ in Thread.sleep(forTimeInterval: 0.7); return "3" }
        let all = try await [first, second, third]
        XCTAssertEqual(all, ["1", "2", "3"])
        // a spider that ignores interrupts poisons its session, queued calls fail instead of hanging
        let stuck = SpiderSession("死", initTimeoutMs: 1000, graceMs: 400) { SleepySpider(interruptible: false) }
        _ = await failure { _ = try await stuck.call(100, "首页") { try $0.homeContent(filter: true) } }
        let queued = await failure { _ = try await stuck.call(5000, "二") { _ in "x" } }
        XCTAssertTrue(queued.contains("停止"))
        XCTAssertTrue(stuck.dead)
        XCTAssertThrowsError(try stuck.callBlocking(100, "三") { _ in "x" }) { XCTAssertTrue($0 is SpiderStopped) }
        s.close()
        stuck.close()
    }

    func testFailedInitialisationIsRememberedBriefly() async {
        let n = Counter()
        let s = SpiderSession("坏") { n.add(); throw URLError(.cannotFindHost) }
        for _ in 0..<3 {
            let m = await failure { _ = try await s.call(1000, "首页") { _ in "x" } }
            XCTAssertTrue(m.contains("「坏」无法解析域名"))
        }
        XCTAssertEqual(n.value, 1)
        XCTAssertEqual(SpiderErrors.text(URLError(.timedOut)), "网络超时")
        XCTAssertEqual(SpiderErrors.text(TVBoxError("站点：x")), "站点：x")
    }

    // MARK: Network

    func testNetworkPolicyBlocksPrivateAndForeignLoopbackTargets() throws {
        let open = TVBoxNet.Scope(net, NetRules()), lan = TVBoxNet.Scope(net, NetRules(allowPrivate: true))
        for bad in ["http://10.0.0.1/x", "http://192.168.1.2:8080/", "http://[fe80::1]/", "http://127.0.0.1:1/", "http://localhost:1/", "http://169.254.1.1/"] { XCTAssertThrowsError(try open.check(bad), bad) }
        try lan.check("http://192.168.1.2:8080/")
        XCTAssertThrowsError(try lan.check("http://127.0.0.1:1/"))
        XCTAssertThrowsError(try lan.check("http://0.0.0.0/"))
        try open.check("http://8.8.8.8/")
        try open.check("http://127.0.0.1:9978/")
        TVBoxStub.routes["/hop"] = { _ in .init(code: 302, headers: ["Location": "http://10.1.2.3/secret"]) }
        XCTAssertThrowsError(try open.execute(NetRequest(url: at("/hop")))) { XCTAssertTrue($0.localizedDescription.contains("拦截")) }
        TVBoxStub.routes["/post"] = { _ in .init(code: 303, headers: ["Location": "/done"]) }
        TVBoxStub.routes["/done"] = { .init(body: $0.httpMethod ?? "") }
        let r = try open.execute(NetRequest(url: at("/post"), method: "POST", body: Data("x".utf8)))
        XCTAssertEqual(r.text(), "GET")
        XCTAssertEqual(r.url, at("/done"))
        XCTAssertEqual(try open.execute(NetRequest(url: at("/hop"), redirect: false)).code, 302)
        XCTAssertThrowsError(try open.execute(NetRequest(url: at("/done"), maxBytes: 1)))
        XCTAssertTrue(TVBoxNet.isPrivateAddress("http://192.168.1.5:9978/c.json"))
        XCTAssertFalse(TVBoxNet.isPrivateAddress("http://www.饭太硬.com/tv"))
        // names that resolve into a private range
        NetGuard.resolverOverride = { $0 == "inner.example" ? ["192.168.0.9"] : ["127.0.0.1"] }
        XCTAssertThrowsError(try open.execute(NetRequest(url: "http://inner.example/done"))) { XCTAssertTrue($0.localizedDescription.contains("拦截")) }
        XCTAssertEqual(try lan.execute(NetRequest(url: "http://inner.example/done")).text(), "GET")
        XCTAssertThrowsError(try lan.execute(NetRequest(url: "http://loop.example/done")))
    }

    func testHostsHeadersAndLocalFiles() throws {
        TVBoxStub.routes["/h"] = { r in
            let names = ["Host", "Referer", "X", "User-Agent", "Authorization"]
            let values = names.map { r.value(forHTTPHeaderField: $0) ?? "" }
            return .init(body: ([r.url?.host ?? ""] + values).joined(separator: "|"))
        }
        // a hosts entry may not be used to reach this device
        let bad = TVBoxNet.Scope(net, NetRules(hosts: ["mapped.example": "127.0.0.1"]))
        XCTAssertThrowsError(try bad.execute(NetRequest(url: "http://mapped.example/h")))
        let s = TVBoxNet.Scope(net, NetRules(hosts: ["mapped.example": "other.example"], headers: [TVBoxHeaderRule(host: "example", headers: ["Referer": "https://r.example"])]))
        XCTAssertEqual(try s.execute(NetRequest(url: "http://u:p@mapped.example/h", headers: ["X": "中"])).text(), "other.example|mapped.example|https://r.example|%E4%B8%AD|okhttp/4.12.0|Basic dTpw")
        try Data("{}".utf8).write(to: tmp.appendingPathComponent("local/cfg.json"))
        XCTAssertEqual(try s.execute(NetRequest(url: "clan://localhost/cfg.json")).text(), "{}")
        XCTAssertEqual(try s.execute(NetRequest(url: "file:///sdcard/x/cfg.json")).text(), "{}")
        XCTAssertThrowsError(try s.execute(NetRequest(url: "file:///../cache/../../etc/passwd")))
    }

    func testTaggedRequestsAreAbortedAndTimeOut() throws {
        TVBoxStub.routes["/slow"] = { _ in .init(body: "x", delay: 5) }
        let s = TVBoxNet.Scope(net, NetRules())
        let tag = NSObject()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { s.cancel(tag) }
        let t = Date()
        XCTAssertThrowsError(try s.execute(NetRequest(url: at("/slow"), tag: tag))) { XCTAssertEqual(($0 as? URLError)?.code, .cancelled) }
        XCTAssertThrowsError(try s.execute(NetRequest(url: at("/slow"), timeoutMs: 300))) { XCTAssertEqual(($0 as? URLError)?.code, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(t), 3)
    }

    func testConfigLoaderReadsConfigsDepotsAndLists() async throws {
        let loader = ConfigLoader(net: net)
        TVBoxStub.routes["/c.json"] = { _ in .init(body: "GIF89aAbCd1234**" + Data(#"{"sites":[{"key":"a","type":3,"api":"csp_A"}],"spider":"./a.jar"}"#.utf8).base64EncodedString()) }
        TVBoxStub.routes["/d.json"] = { _ in .init(body: #"{"urls":[{"name":"一","url":"./c.json"}]}"#) }
        TVBoxStub.routes["/l.txt"] = { _ in .init(body: "组,#genre#\nA,http://a.example/1") }
        TVBoxStub.routes["/web"] = { _ in .init(body: "<html>") }
        guard case .config(let c) = try await loader.load(at("/c.json"), allowLan: false).parsed else { return XCTFail("config") }
        XCTAssertEqual(c.spider, at("/a.jar"))
        XCTAssertEqual(TVBoxStub.seen.last?.value(forHTTPHeaderField: "User-Agent"), "okhttp/4.12.0")
        guard case .depot(let d) = try await loader.load(at("/d.json"), allowLan: false).parsed else { return XCTFail("depot") }
        XCTAssertEqual(d.map(\.url), [at("/c.json")])
        guard case .live = try await loader.load(at("/l.txt"), allowLan: false).parsed else { return XCTFail("live") }
        let web = await failure { _ = try await loader.load(self.at("/web"), allowLan: false) }
        XCTAssertTrue(web.contains("网页"))
        let gone = await failure { _ = try await loader.load(self.at("/none"), allowLan: false) }
        XCTAssertTrue(gone.contains("404"))
        XCTAssertEqual(try ConfigLoader.normalize(" a.example/x "), "http://a.example/x")
        XCTAssertThrowsError(try ConfigLoader.normalize("ftp://x/y"))
        XCTAssertThrowsError(try ConfigLoader.normalize("hello"))
    }

    // MARK: Engine

    func testT4SendsTheAgreedParameters() async throws {
        TVBoxStub.routes["/t4"] = { r in
            let q = TVBoxStub.query(r)
            if q["play"] != nil { return .init(body: #"{"parse":0,"url":["1080P","https://v.example/a.m3u8?k=a$b|c|Referer=https%3A%2F%2Fr.example%2F","720P","https://v.example/b.mp4"],"header":"{\"User-Agent\":\"T4\"}","danmaku":"https://d.example/1.xml","subs":[{"name":"中","url":"https://s.example/a.srt","format":"application/x-subrip"}]}"#) }
            if let wd = q["wd"] { return .init(body: "{\"list\":[{\"vod_id\":\"9\",\"vod_name\":\"\(wd)\"}]}") }
            if q["ids"] != nil { return .init(body: #"{"list":[{"vod_id":"9","vod_name":"剧","vod_play_from":"a$$$b","vod_play_url":"1$x#2$y$$$01$z"}]}"#) }
            if q["t"] != nil { return .init(body: #"{"list":[{"vod_id":"1","vod_name":"页"}],"page":1,"pagecount":3}"#) }
            return .init(body: #"{"class":[{"type_id":"1","type_name":"电影"}],"filters":{"1":[{"key":"k","name":"n","value":[{"n":"a","v":"b"}]}]},"list":[{"vod_id":"1","vod_name":"推荐"}]}"#)
        }
        TVBoxStub.routes["/ext.json"] = { _ in .init(body: "EXT-BODY") }
        let uid = try XCTUnwrap(try use("{\"sites\":[{\"key\":\"t\",\"name\":\"T4\",\"type\":4,\"api\":\"\(at("/t4"))\",\"ext\":\"\(at("/ext.json"))\",\"header\":{\"X-Site\":\"1\"}}],\"headers\":[{\"host\":\"v.example\",\"header\":{\"X-Rule\":\"2\"}}]}")["t"])
        let home = try await collect(engine.home(uid))
        XCTAssertEqual(home.count, 1)
        XCTAssertTrue(home[0].fresh)
        XCTAssertEqual(home[0].value.categories.map(\.name), ["电影"])
        XCTAssertEqual(home[0].value.items.map(\.title), ["推荐"])
        XCTAssertEqual(home[0].value.filters["1"]?.first?.options.first?.value, "b")
        let page = try await collect(engine.category(uid, "1", 1, ["k": "b"]))
        XCTAssertEqual(page.last?.value.hasMore, true)
        let found = try await engine.search(uid, "关键")
        XCTAssertEqual(found.items.map(\.title), ["关键"])
        let d = try await engine.detail(uid, "9")
        XCTAssertEqual(d.lines.map(\.name), ["a", "b"])
        let v = try await engine.resolve(uid, d.lines[0].episodes[1])
        XCTAssertEqual(v.streams.map(\.quality), ["1080P", "720P"])
        XCTAssertEqual(v.streams.map(\.kind), [.hls, .mp4Clear])
        XCTAssertEqual(v.streams[0].url, "https://v.example/a.m3u8?k=a$b|c")
        XCTAssertEqual(v.streams[0].lan, false)
        XCTAssertEqual(v.streams[0].headers, ["X-Site": "1", "User-Agent": "T4", "Referer": "https://r.example/", "X-Rule": "2"])
        XCTAssertEqual(v.danmaku, "https://d.example/1.xml")
        XCTAssertEqual(v.streams[0].subtitles.first?.format, "application/x-subrip")
        // an episode restored from history has no media: it is looked up again
        let restored = try await engine.resolve(uid, HGEpisode(ep: 1, vid: TVBoxId.episode("9", 1, 0), duration: 0, title: ""))
        XCTAssertEqual(restored.url, "https://v.example/a.m3u8?k=a$b|c")
        let calls = TVBoxStub.seen.filter { $0.url?.path == "/t4" }
        XCTAssertTrue(calls.allSatisfy { TVBoxStub.query($0)["extend"] == "EXT-BODY" && $0.value(forHTTPHeaderField: "X-Site") == "1" && $0.value(forHTTPHeaderField: "User-Agent") == "okhttp/4.12.0" })
        let q = calls.map { TVBoxStub.query($0) }
        XCTAssertEqual(q.first?["filter"], "true")
        let cat = try XCTUnwrap(q.first { $0["t"] != nil })
        XCTAssertEqual(cat["ac"], "detail")
        XCTAssertEqual(cat["pg"], "1")
        XCTAssertEqual(Data(base64Encoded: cat["ext"] ?? "").map { String(decoding: $0, as: UTF8.self) }, #"{"k":"b"}"#)
        let play = try XCTUnwrap(q.first { $0["play"] != nil })
        XCTAssertEqual([play["play"], play["flag"]], ["y", "a"])
    }

    func testCmsJsonAndXmlKeepEveryLine() async throws {
        TVBoxStub.routes["/api.php"] = { r in
            TVBoxStub.query(r)["ac"] == "list" ? .init(body: #"{"code":1,"class":[{"type_id":1,"type_name":"剧集"}],"list":[{"vod_id":1,"vod_name":"无图"}]}"#)
                : .init(body: #"{"code":1,"page":"1","pagecount":2,"list":[{"vod_id":7,"vod_name":"片","vod_pic":"http://i.example/1.jpg","vod_play_from":"m3u8$$$qq","vod_play_url":"1$https://v.example/1.m3u8$$$1$https://v.qq.example/x.html"}]}"#)
        }
        TVBoxStub.routes["/xml"] = { _ in .init(body: "<?xml version=\"1.0\" encoding=\"gbk\"?><rss><list page=\"1\" pagecount=\"1\"><video><id>42</id><name>海岸</name><dl><dd flag=\"高清\"><![CDATA[第一集$https://m.example/a.m3u8]]></dd></dl></video></list><class><ty id=\"7\">纪录片</ty></class></rss>", type: "text/xml; charset=utf-8") }
        let u = try use("{\"sites\":[{\"key\":\"j\",\"name\":\"J\",\"type\":1,\"api\":\"\(at("/api.php"))\"},{\"key\":\"x\",\"name\":\"X\",\"type\":0,\"api\":\"\(at("/xml"))\"}],\"flags\":[\"qq\"],\"parses\":[{\"name\":\"web\",\"type\":0,\"url\":\"https://jx.example/?url=\"}]}", trusted: false)
        let j = try XCTUnwrap(u["j"]), x = try XCTUnwrap(u["x"])
        let h = try await collect(engine.home(j))
        XCTAssertEqual(h.last?.value.categories.map(\.name), ["剧集"])
        XCTAssertEqual(h.last?.value.items.map(\.cover), ["http://i.example/1.jpg"])
        let d = try await engine.detail(j, "7")
        XCTAssertEqual(d.lines.map(\.name), ["m3u8", "qq"])
        let direct = try await engine.resolve(j, d.lines[0].episodes[0])
        XCTAssertEqual(direct.url, "https://v.example/1.m3u8")
        XCTAssertTrue(sniffer.requests.isEmpty)
        sniffer.answer = { SniffResult(url: "https://sniff.example/v.m3u8", headers: ["Referer": $0.url]) }
        let parsed = try await engine.resolve(j, d.lines[1].episodes[0])
        XCTAssertEqual(parsed.url, "https://sniff.example/v.m3u8")
        XCTAssertEqual(sniffer.requests.map(\.url), ["https://jx.example/?url=https://v.qq.example/x.html"])
        XCTAssertEqual(parsed.streams.first?.headers["Referer"], "https://jx.example/?url=https://v.qq.example/x.html")
        let xml = try await collect(engine.home(x))
        XCTAssertEqual(xml.last?.value.categories.map(\.name), ["纪录片"])
        XCTAssertEqual(xml.last?.value.items.map(\.title), ["海岸"])
        XCTAssertEqual(TVBoxStub.seen.last { $0.url?.path == "/xml" }.map { TVBoxStub.query($0)["ac"] }, "videolist")
    }

    func testCachedHomeAppearsFirstAndSurvivesFailures() async throws {
        let n = Counter()
        TVBoxStub.routes["/t4"] = { _ in
            let i = n.add()
            return i >= 3 ? .init(code: 500) : .init(body: "{\"class\":[{\"type_id\":\"\(i)\",\"type_name\":\"类\"}],\"list\":[{\"vod_id\":\"1\",\"vod_name\":\"片\"}]}")
        }
        let uid = try XCTUnwrap(try use("{\"sites\":[{\"key\":\"t\",\"name\":\"T4\",\"type\":4,\"api\":\"\(at("/t4"))\"}]}")["t"])
        let first = try await collect(engine.home(uid))
        XCTAssertEqual(first.map { $0.value.categories[0].id }, ["1"])
        let again = try await collect(engine.home(uid))
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(n.value, 1) // still fresh: no request
        let forced = try await collect(engine.home(uid, force: true))
        XCTAssertEqual(forced.map { $0.value.categories[0].id }, ["1", "2"])
        XCTAssertEqual(forced.map(\.fresh), [false, true])
        let failed = try await collect(engine.home(uid, force: true))
        XCTAssertEqual(failed.map { $0.value.categories[0].id }, ["2", "2"])
        XCTAssertNotNil(failed.last?.error)
        XCTAssertEqual(engine.knownHome(uid)?.categories.map(\.id), ["2"])
    }

    func testCodeSitesNeedTrustAPairedDeviceAndARuntime() async throws {
        let text = #"{"spider":"https://j.example/a.jar","sites":[{"key":"a","name":"甲","type":3,"api":"csp_A","ext":"E"},{"key":"p","name":"蟒","type":3,"api":"https://p.example/a.py"},{"key":"s","name":"脚","type":3,"api":"https://p.example/a.js"},{"key":"z","name":"怪","type":9,"api":"?"}]}"#
        let u = try use(text, trusted: false)
        func fails(_ key: String) async -> String { await failure { _ = try await self.collect(self.engine.home(u[key] ?? "")) } }
        var m = await fails("a")
        XCTAssertTrue(m.contains("尚未信任"))
        try use(text, trusted: true)
        jar.paired = false
        m = await fails("a")
        XCTAssertEqual(m, "JAR 站点需要配对 Android 桥接")
        jar.paired = true
        engine.restart("r")
        let home = try await collect(engine.home(u["a"] ?? ""))
        XCTAssertEqual(home.last?.value.categories.map(\.id), ["E"])
        m = await fails("p")
        XCTAssertTrue(m.contains("Python"))
        m = await fails("s")
        XCTAssertTrue(m.contains("JavaScript"))
        m = await fails("z")
        XCTAssertTrue(m.contains("不支持的站点类型"))
        m = await failure { _ = try await self.engine.detail("gone", "1") }
        XCTAssertTrue(m.contains("已删除"))
    }

    func testProxyRoutesToTheSpiderFilesAndLists() async throws {
        let u = try use(#"{"spider":"https://j.example/a.jar","sites":[{"key":"a-1","name":"甲","type":3,"api":"csp_A"}]}"#)["a-1"] ?? ""
        let home = try await collect(engine.home(u))
        XCTAssertEqual(home.last?.value.items.first?.cover, "http://127.0.0.1:9978/proxy?do=csp&siteKey=a-1&u=1")
        XCTAssertEqual(engine.runningPort, 9978)
        let v = try await engine.resolve(u, HGEpisode(ep: 1, vid: TVBoxId.episode("x", 0, 0), duration: 0, title: "", media: #"{"f":"f","id":"77"}"#))
        XCTAssertEqual(v.streams.first?.headers["User-Agent"], "J")
        let engine = engine!
        func get(_ p: [String: String]) async -> ProxyReply { await withCheckedContinuation { c in DispatchQueue.global().async { c.resume(returning: engine.proxy(p)) } } }
        func text(_ r: ProxyReply) -> String { String(decoding: r.body, as: UTF8.self) }
        var r = await get(["do": "ck"])
        XCTAssertEqual(text(r), "ok")
        r = await get(["do": "csp", "siteKey": "a-1", "u": "77", "range": "bytes=0-1"])
        XCTAssertEqual(r.code, 206)
        XCTAssertEqual(text(r), "77|bytes=0-1")
        r = await get(["do": "js", "siteKey": "none"])
        XCTAssertEqual(r.code, 404)
        r = await get(["do": "other"])
        XCTAssertEqual(r.code, 404)
        try Data("本地".utf8).write(to: tmp.appendingPathComponent("local/规则 1.json"))
        r = await get(["do": "file", "path": "规则 1.json"])
        XCTAssertEqual(text(r), "本地")
        r = await get(["do": "file", "path": "../../passwd"])
        XCTAssertEqual(r.code, 404)
        TVBoxStub.routes["/live.txt"] = { _ in .init(body: "央视,#genre#\nCCTV1,http://a.example/1.m3u8") }
        r = await get(["do": "live", "type": "txt", "ext": Data(at("/live.txt").utf8).base64EncodedString()])
        XCTAssertTrue(text(r).contains("CCTV1"))
        XCTAssertEqual(try config(#"{"sites":[{"key":"l","name":"L","type":3,"api":"./a.js","ext":"./规则 1.json"}]}"#, "clan://localhost/cfg.json").sites[0].ext, "clan://localhost/规则 1.json")
    }

    func testAggregatedSearchStreamsWithoutABarrier() async throws {
        let u = try use(#"{"spider":"https://j.example/a.jar","sites":[{"key":"s","name":"慢","type":3,"api":"csp_Slow"},{"key":"a","name":"快","type":3,"api":"csp_A"},{"key":"b","name":"坏","type":3,"api":"csp_Broken"}]}"#)
        var order: [SearchHit] = []
        for await h in engine.searchAll([u["s"] ?? "", u["a"] ?? "", u["b"] ?? "", "unknown"], "词") { order.append(h) }
        XCTAssertEqual(order.count, 3)
        XCTAssertEqual(order.last?.ref.site.name, "慢")
        XCTAssertEqual(order.first { $0.ref.site.name == "快" }?.items.map(\.title), ["词"])
        XCTAssertNotNil(order.first { $0.ref.site.name == "坏" }?.error)
    }

    func testEmptyRefreshKeepsWhatWorks() async throws {
        let n = Counter()
        TVBoxStub.routes["/t4"] = { _ in n.add() == 1 ? .init(body: #"{"class":[{"type_id":"1","type_name":"类"}],"list":[{"vod_id":"1","vod_name":"片"}]}"#) : .init(body: "{}") }
        let uid = try XCTUnwrap(try use("{\"sites\":[{\"key\":\"t\",\"name\":\"T4\",\"type\":4,\"api\":\"\(at("/t4"))\"}]}")["t"])
        _ = try await collect(engine.home(uid))
        let again = try await collect(engine.home(uid, force: true))
        XCTAssertEqual(again.last?.value.categories.map(\.name), ["类"])
        XCTAssertNotNil(again.last?.error)
        let kept = try await collect(engine.home(uid))
        XCTAssertEqual(kept.last?.value.items.map(\.title), ["片"])
    }

    func testCategoriesComeBeforeTheRecommendedRail() async throws {
        TVBoxStub.routes["/api.php"] = { r in
            TVBoxStub.query(r)["ac"] == "list" ? .init(body: #"{"code":1,"class":[{"type_id":1,"type_name":"剧集"}],"list":[{"vod_id":1,"vod_name":"无图"}]}"#) : .init(code: 500)
        }
        let u = try XCTUnwrap(try use("{\"sites\":[{\"key\":\"j\",\"name\":\"J\",\"type\":1,\"api\":\"\(at("/api.php"))\"}]}")["j"])
        let h = try await collect(engine.home(u))
        XCTAssertEqual(h.map(\.fresh), [false, true])
        XCTAssertEqual(h[0].value.categories.map(\.name), ["剧集"])
        XCTAssertTrue(h[0].value.items.isEmpty, "the list of categories has no covers")
        XCTAssertEqual(h[1].value.categories.map(\.name), ["剧集"])
    }

    func testCancelledInitialisationIsNotRemembered() async throws {
        let n = Counter()
        let gate = DispatchSemaphore(value: 0)
        let s = SpiderSession("慢", create: { SleepySpider(interruptible: true) }, begin: { _ in
            if n.add() == 1, gate.wait(timeout: .now() + 0.6) == .timedOut { throw TVBoxError("脚本加载失败：请求被中断") }
        })
        let job = Task { try await s.call(1000, "首页") { _ in "a" } }
        try await Task.sleep(nanoseconds: 150_000_000)
        job.cancel()
        do { _ = try await job.value; XCTFail("not cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let again = try await s.call(1000, "首页") { _ in "b" }
        XCTAssertEqual(again, "b")
        XCTAssertEqual(n.value, 2)
        // somebody else still needs it: a cancelled caller does not stop it
        let m = Counter()
        let shared = SpiderSession("共", create: { SleepySpider(interruptible: true) }, begin: { s in
            m.add()
            if (try? s.homeContent(filter: true)) == nil { throw TVBoxError("中断") }
        })
        let first = Task { try await shared.call(1000, "一") { _ in "1" } }
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = Task { try await shared.call(1000, "二") { _ in "2" } }
        try await Task.sleep(nanoseconds: 100_000_000)
        first.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(m.value, 1, "still the first initialisation")
        second.cancel()
        s.close()
        shared.close()
    }

    func testSpidersClosedWhileTheyStartAreDestroyed() async throws {
        final class Slow: Spider {
            let ended: Counter
            init(_ c: Counter) { ended = c }
            func start(ext: String) throws { Thread.sleep(forTimeInterval: 0.3) }
            func destroy() { ended.add() }
        }
        let ended = Counter(), made = Counter()
        let s = SpiderSession("关", create: { made.add(); return Slow(ended) }, begin: { try $0.start(ext: "") })
        let job = Task { try await s.call(1000, "首页") { _ in "a" } }
        try await Task.sleep(nanoseconds: 100_000_000)
        s.close()
        _ = await job.result
        try await wait { ended.value > 0 }
        let late = await failure { _ = try await s.call(100, "x") { _ in "b" } }
        XCTAssertTrue(late.contains("停止"))
        XCTAssertEqual(made.value, 1)
    }

    func testStaleScriptsAreUsedAtOnceAndRefreshedBehind() async throws {
        let dir = tmp.appendingPathComponent("sc"), url = "https://s.example/a.js"
        let http = CannedHttp()
        http.bodies[url] = "v1"
        let cache = ScriptCache(dir, freshMs: 0)
        XCTAssertEqual(try cache.load(url, http: http), "v1")
        http.bodies[url] = "v2"
        XCTAssertEqual(try cache.load(url, http: http), "v1", "the stored copy does not wait for the network")
        try await wait { (try? cache.load(url, http: http)) == "v2" }
        // an unreachable host is asked once, the date moves on
        http.bodies[url] = nil
        let f = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let old = Date(timeIntervalSinceNow: -7200)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path)
        let hourly = ScriptCache(dir, freshMs: 3_600_000)
        XCTAssertEqual(try hourly.load(url, http: http), "v2")
        let at = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as? Date)
        XCTAssertLessThan(Date().timeIntervalSince(at), 60)
        cache.clear()
        XCTAssertThrowsError(try cache.load(url, http: http))
    }

    func testRemoteSitesNeverReceiveLocalFiles() async throws {
        TVBoxStub.routes["/t4"] = { r in .init(body: "{\"class\":[{\"type_id\":\"1\",\"type_name\":\"\(TVBoxStub.query(r)["extend"] ?? "")\"}],\"list\":[{\"vod_id\":\"1\",\"vod_name\":\"a\"}]}") }
        try Data("SECRET".utf8).write(to: tmp.appendingPathComponent("local/secret.json"))
        TVBoxStub.routes["/file/secret.json"] = { _ in .init(body: "SECRET") }
        TVBoxStub.routes["/hop.json"] = { _ in .init(code: 302, headers: ["Location": "http://127.0.0.1:9978/file/secret.json"]) }
        for ext in ["clan://localhost/secret.json", "http://127.0.0.1:9978/file/secret.json", "http://localhost:9978/file/secret.json", at("/hop.json")] {
            let c = try config("{\"sites\":[{\"key\":\"t\",\"name\":\"T\",\"type\":4,\"api\":\"\(at("/t4"))\",\"ext\":\"\(ext)\"}]}")
            engine.setRepos([RepoRuntime("r", "仓", c, trusted: true, allowPrivate: true, local: true)], active: "r")
            engine.clearCache(TVBoxConfig.siteUid("r", "t"))
            let h = try await collect(engine.home(TVBoxConfig.siteUid("r", "t"), force: true))
            XCTAssertEqual(h.last?.value.categories.map(\.name), [ext], ext)
        }
        // a local config with a server on this device may
        let open = TVBoxNet.Scope(net, NetRules())
        let own = RemoteSpider(TVBoxSite(key: "t", name: "T", type: 4, api: "http://127.0.0.1:9978/t4"), open, localExt: true)
        try own.start(ext: "clan://localhost/secret.json")
        XCTAssertTrue(try own.homeContent(filter: true).contains("SECRET"))
        XCTAssertEqual(try open.execute(NetRequest(url: at("/hop.json"))).text(), "SECRET")
        XCTAssertThrowsError(try open.execute(NetRequest(url: at("/hop.json"), loopback: false))) { XCTAssertTrue($0.localizedDescription.contains("本机")) }
    }

    func testGuidesSurviveBrokenAnswers() async throws {
        let now = Catchup.nowMs, dir = tmp.appendingPathComponent("guides"), url = "https://e.example/e.xml"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss Z"
        let from = f.string(from: Date(timeIntervalSinceNow: -600)), to = f.string(from: Date(timeIntervalSinceNow: 600))
        let guide = "<?xml version=\"1.0\"?><tv><channel id=\"1\"><display-name>CCTV1</display-name></channel><programme start=\"\(from)\" stop=\"\(to)\" channel=\"1\"><title>朝闻</title></programme></tv>"
        func ask(_ s: EpgService, _ http: CannedHttp) async throws -> [String] { try await s.programmes(http, url, LiveChannel(name: "CCTV1", urls: []), ["cctv1"], now, .current).map(\.title) }
        func files() -> [URL] { (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] }
        for bad in ["<!DOCTYPE html><html><body>登录</body></html>", "{\"code\":1}", nil] {
            let http = CannedHttp(), s = EpgService(dir)
            http.bodies[url] = bad
            let first = try await ask(s, http), second = try await ask(s, http)
            XCTAssertEqual(first + second, [], bad ?? "down")
            XCTAssertEqual(http.requests.count, 1, "once, not per channel")
            XCTAssertEqual(files(), [], bad ?? "down")
        }
        let http = CannedHttp()
        http.bodies[url] = guide
        var titles = try await ask(EpgService(dir), http)
        XCTAssertEqual(titles, ["朝闻"])
        let file = try XCTUnwrap(files().first)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: file.path)
        http.bodies[url] = "<html>维护中</html>"
        titles = try await ask(EpgService(dir), http)
        XCTAssertEqual(titles, ["朝闻"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), guide)
        // broken off, with absurd times
        let cut = guide.substringBefore("</tv>") + "<programme start=\"x\" stop=\"99999999999999 +9999\" channel=\"1\"><title>a</title></programme><programme><title>b<c></title>"
        var chunks = [Data(cut.utf8)]
        let map = try EpgParser.xmltv({ if chunks.isEmpty { throw URLError(.cannotDecodeContentData) }; return chunks.removeFirst() }, wanted: nil, from: now - 86_400_000, to: now + 86_400_000)
        XCTAssertEqual(map["cctv1"]?.map(\.title), ["朝闻"])
    }

    func testRemovingAConfigDestroysItsSpiders() async throws {
        let u = try use(#"{"spider":"https://j.example/a.jar","sites":[{"key":"a","name":"甲","type":3,"api":"csp_A"}]}"#)["a"] ?? ""
        _ = try await collect(engine.home(u))
        XCTAssertEqual(engine.status(u), .ready)
        engine.restart("r")
        try await wait { self.jar.closed.value == 1 }
        XCTAssertEqual(engine.status(u), .idle)
        _ = try await collect(engine.home(u, force: true))
        XCTAssertEqual(engine.status(u), .ready)
        engine.setRepos([], active: "")
        try await wait { self.jar.closed.value == 2 }
        XCTAssertNil(engine.site(u))
    }

    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<150 where !done() { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(done())
    }

    func testLiveChannelsGroupsGuideCatchupAndSpiderLists() async throws {
        TVBoxStub.routes["/live.txt"] = { _ in .init(body: "央视,#genre#\nCCTV1,http://a.example/1.m3u8$主#http://b.example/PLTV/2|User-Agent=X\n密_pw,#genre#\n锁,http://c.example/3\n") }
        TVBoxStub.routes["/epg"] = { _ in .init(body: #"{"epg_data":[{"title":"全天","start":"00:00","end":"23:59"}]}"#) }
        let c = try config("{\"spider\":\"https://j.example/a.jar\",\"sites\":[{\"key\":\"a\",\"type\":1,\"api\":\"https://a.example\"}],\"lives\":[{\"name\":\"直播\",\"url\":\"\(at("/live.txt"))\",\"ua\":\"LIVE\",\"epg\":\"\(at("/epg"))?ch={name}&date={date}\"},{\"name\":\"包\",\"type\":3,\"api\":\"csp_Live\"}]}", "")
        engine.setRepos([RepoRuntime("r", "仓", c, trusted: true, allowPrivate: false)], active: "r")
        let uid = TVBoxConfig.liveUid("r", at("/live.txt"))
        let d = try await engine.liveDetail(uid, unlocked: [])
        XCTAssertTrue(d.isLive)
        XCTAssertEqual(d.source, .tvboxLive(uid))
        XCTAssertEqual(d.episodes.map(\.title), ["CCTV1"])
        XCTAssertEqual(d.episodes[0].page, "央视")
        XCTAssertEqual(d.episodes[0].vid, "\(uid)#0")
        XCTAssertEqual(TVBoxStub.seen.last { $0.url?.path == "/live.txt" }?.value(forHTTPHeaderField: "User-Agent"), "LIVE")
        let open = try await engine.liveDetail(uid, unlocked: ["密"])
        XCTAssertEqual(open.episodes.map(\.title), ["CCTV1", "锁"])
        let v = try await engine.resolveLive(uid, d.episodes[0], unlocked: [])
        XCTAssertEqual(v.streams.map(\.quality), ["主", "线路 2"])
        XCTAssertEqual(v.streams[0].headers["User-Agent"], "LIVE")
        XCTAssertEqual(v.streams[1].headers["User-Agent"], "X")
        XCTAssertEqual(v.streams[1].url, "http://b.example/PLTV/2")
        let restored = try await engine.resolveLive(uid, HGEpisode(ep: 1, vid: "\(uid)#0", duration: 0, title: ""), unlocked: [])
        XCTAssertEqual(restored.url, v.url)
        let guide = try await engine.guide(uid, "CCTV1")
        XCTAssertEqual(guide.map(\.title), ["全天"])
        XCTAssertEqual(TVBoxStub.seen.last { $0.url?.path == "/epg" }.map { TVBoxStub.query($0)["ch"] }, "CCTV1")
        let replay = try XCTUnwrap(engine.catchup(uid, d.episodes[0], Programme(start: 1_767_225_600_000, end: 1_767_229_200_000, title: "p")))
        XCTAssertEqual(replay.streams.count, 1)
        XCTAssertTrue(replay.streams[0].url.hasPrefix("http://b.example/TVOD/2?playseek="))
        let spider = try await engine.liveDetail(TVBoxConfig.liveUid("r", "csp_Live "), unlocked: [])
        XCTAssertEqual(spider.episodes.map(\.title), ["频道"])
    }

    func testJarParseExtensionsRunThroughTheChain() async throws {
        TVBoxStub.routes["/t4"] = { _ in .init(body: #"{"parse":1,"jx":1,"url":"https://v.qq.example/x.html"}"#) }
        let u = try use("{\"spider\":\"https://j.example/a.jar\",\"sites\":[{\"key\":\"t\",\"name\":\"T\",\"type\":4,\"api\":\"\(at("/t4"))\"}],\"parses\":[{\"name\":\"包\",\"type\":2,\"url\":\"Demo\"},{\"name\":\"j1\",\"type\":1,\"url\":\"https://none.invalid/?url=\"}]}")["t"] ?? ""
        TVBoxStub.routes["/"] = { _ in .init(code: 500) }
        let v = try await engine.resolve(u, HGEpisode(ep: 1, vid: TVBoxId.episode("x", 0, 0), duration: 0, title: "", media: #"{"f":"qq","id":"5"}"#))
        XCTAssertEqual(v.url, "https://ext.example/Demo.m3u8")
        XCTAssertEqual(v.streams.first?.headers["Referer"], "j1")
    }

    func testLatencyMeasurementsStream() async throws {
        TVBoxStub.routes["/t4"] = { _ in .init(body: #"{"class":[{"type_id":"1","type_name":"类"}]}"#) }
        let u = try use("{\"sites\":[{\"key\":\"t\",\"name\":\"T\",\"type\":4,\"api\":\"\(at("/t4"))\"},{\"key\":\"n\",\"name\":\"N\",\"type\":4,\"api\":\"\(at("/none"))\"}]}")
        var m: [String: Int] = [:]
        for await r in engine.latencies(Array(u.values)) { m[r.uid] = r.ms }
        XCTAssertGreaterThan(m[u["t"] ?? ""] ?? 0, 0)
        XCTAssertEqual(m[u["n"] ?? ""], -1)
    }

    // MARK: App layer

    @MainActor func testSourcesAreWiredIntoTheCatalog() {
        XCTAssertTrue(Sites.provider(.tvbox("0123456789ab")) is TVBoxProvider)
        XCTAssertTrue(Sites.provider(.tvboxLive("0123456789ab")) is TVBoxLiveProvider)
        XCTAssertFalse(DramaSource.tvboxLive("0123456789ab").isAdult)
        XCTAssertFalse(DramaSource.tvbox("0123456789ab").isAdult)
        XCTAssertTrue(SourceGate.shared.isVisible(DramaSource.tvbox("0123456789ab")))
        XCTAssertTrue(SourceGate.shared.isVisible(DramaSource.tvboxLive("0123456789ab")))
        XCTAssertEqual(DramaSource.tvboxLive("0123456789ab").streamSectionTitle, "线路")
    }

    @MainActor func testStoreImportsAndRemovesALocalConfig() async throws {
        let store = TVBoxStore.shared
        await store.ready()
        let text = #"{"name":"夹具","sites":[{"key":"a","name":"站甲","type":1,"api":"https://cms.example/api"},{"key":"x","name":"🔞","type":1,"api":"https://adult.example/api"}],"lives":[{"name":"台","url":"https://l.example/a.m3u"}]}"#
        guard case .imported(let repo) = try await store.importText(text) else { return XCTFail("not imported") }
        XCTAssertEqual(store.activeRepo?.id, repo.id)
        XCTAssertFalse(repo.needsTrust)
        let site = repo.sites[0], adult = repo.sites[1], live = repo.lives[0]
        XCTAssertEqual(TVBoxStore.site(site.uid)?.name, "站甲")
        XCTAssertEqual(TVBoxStore.live(live.uid)?.name, "台")
        XCTAssertEqual(DramaSource.tvbox(site.uid).label, "站甲")
        XCTAssertEqual(DramaSource.tvbox(site.uid).siteHost, "cms.example")
        XCTAssertTrue(DramaSource.tvbox(adult.uid).isAdult)
        XCTAssertEqual(store.visibleSites(repo, adult: false).map(\.uid), [site.uid])
        store.setEnabled(repo.id, site.uid, false)
        XCTAssertEqual(store.activeRepo.map { store.visibleSites($0, adult: true).map(\.uid) }, [adult.uid])
        store.toggleFavoriteChannel("测试台")
        XCTAssertTrue(store.isFavoriteChannel("测试台"))
        store.toggleFavoriteChannel("测试台")
        XCTAssertFalse(store.isFavoriteChannel("测试台"))
        store.unlock(live.uid, "密")
        XCTAssertEqual(store.unlocked(live.uid), ["密"])
        XCTAssertEqual(store.liveSeries(live).id, "tvl.\(live.uid):\(live.uid)")
        store.remove(repo.id)
        XCTAssertNil(TVBoxStore.site(site.uid))
        XCTAssertTrue(DramaSource.tvbox(adult.uid).isAdult, "remembered after the config is gone")
        XCTAssertFalse(store.repos.contains { $0.id == repo.id })
        do { _ = try await store.importText("hello"); XCTFail("no error") } catch { XCTAssertTrue(error.localizedDescription.contains("TVBox")) }
    }
}

// MARK: - Doubles

private final class Counter {
    private let lock = NSLock()
    private var n = 0
    @discardableResult func add() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class NoHost: ScriptHosting {
    let tag: AnyObject = NSObject()
    func call(_ name: String, _ argsJson: String) -> String { "{}" }
    func endCall() {}
}

private final class FakeSniffer: Sniffer {
    private let lock = NSLock()
    private var list: [SniffRequest] = []
    var requests: [SniffRequest] {
        get { lock.lock(); defer { lock.unlock() }; return list }
        set { lock.lock(); list = newValue; lock.unlock() }
    }
    var answer: (SniffRequest) async throws -> SniffResult = { SniffResult(url: "https://sniffed.example/v.m3u8", headers: ["Referer": $0.url]) }
    func sniff(_ r: SniffRequest) async throws -> SniffResult {
        requests.append(r)
        return try await answer(r)
    }
}

private final class FakeParsers: JarParsers {
    var calls: [String] = []
    func json(_ key: String, _ jxs: [String: String], _ url: String) async throws -> JSONObject? {
        calls.append("json \(key) \(jxs["一"] ?? "") \(url)")
        return JSONObject().put("url", "https://v.example/x.m3u8")
    }
    func mix(_ key: String, _ name: String, _ flag: String, _ jxs: [String: [String: String]], _ url: String) async throws -> JSONObject? {
        calls.append("mix \(key) \(name) \(flag) \(jxs["一"]?["type"] ?? "") \(url)")
        return JSONObject().put("url", "https://v.example/y.m3u8")
    }
}

private final class SleepySpider: Spider {
    private let interruptible: Bool
    private let gate = DispatchSemaphore(value: 0)
    init(interruptible: Bool) { self.interruptible = interruptible }
    func homeContent(filter: Bool) throws -> String {
        guard filter else { return "ok" }
        if interruptible {
            if gate.wait(timeout: .now() + 10) == .success { throw URLError(.cancelled) }
        } else { Thread.sleep(forTimeInterval: 4) }
        return "late"
    }
    func interrupt() { if interruptible { gate.signal() } }
}

private final class FakeJar: JarHost {
    var paired = true
    let closed = Counter()

    final class Remote: Spider {
        let site: TVBoxSite
        let closed: Counter
        init(_ site: TVBoxSite, _ closed: Counter) { self.site = site; self.closed = closed }
        func homeContent(filter: Bool) throws -> String {
            "{\"class\":[{\"type_id\":\"\(site.ext.isEmpty ? "1" : site.ext)\",\"type_name\":\"类\"}],\"list\":[{\"vod_id\":\"1\",\"vod_name\":\"片\",\"vod_pic\":\"proxy://do=csp&siteKey=\(site.key)&u=1\"}]}"
        }
        func playerContent(flag: String, id: String, vipFlags: [String]) throws -> String {
            JSONObject().put("parse", 0).put("url", "http://127.0.0.1:9978/proxy?do=csp&siteKey=\(site.key)&u=\(id)").put("header", JSONObject().put("ua", "J")).toString()
        }
        func searchContent(key: String, quick: Bool, pg: String) throws -> String {
            if site.api == "csp_Slow" { Thread.sleep(forTimeInterval: 0.6) }
            return "{\"list\":[{\"vod_id\":\"\(key)\",\"vod_name\":\"\(key)\"}]}"
        }
        func proxyLocal(_ params: [String: String]) throws -> ProxyReply? {
            ProxyReply(code: 206, type: "video/mp2t", headers: ["Content-Range": "bytes 0-1/2"], body: Data("\(params["u"] ?? "")|\(params["range"] ?? "")".utf8))
        }
        func liveContent(url: String) throws -> String { "组,#genre#\n频道,http://l.example/1" }
        func destroy() { closed.add() }
    }

    func spider(site: TVBoxSite, jar: String) throws -> Spider {
        if site.api == "csp_Broken" { throw TVBoxError("与当前版本不兼容") }
        return Remote(site, closed)
    }

    func parse(jar: String, method: String, args: [Any]) throws -> String {
        let jxs = args.count > 1 ? args[1] as? [String: String] ?? [:] : [:]
        return JSONObject().put("url", "https://ext.example/\(args.first as? String ?? "").m3u8").put("header", JSONObject().put("Referer", jxs.keys.sorted().joined(separator: "+"))).toString()
    }
}

private final class CannedHttp: TVBoxHttp {
    private let lock = NSLock()
    private var table: [String: String] = [:]
    private var log: [NetRequest] = []
    var bodies: [String: String] {
        get { lock.lock(); defer { lock.unlock() }; return table }
        set { lock.lock(); table = newValue; lock.unlock() }
    }
    var requests: [NetRequest] { lock.lock(); defer { lock.unlock() }; return log }
    func execute(_ r: NetRequest) throws -> NetResponse {
        lock.lock()
        log.append(r)
        let body = table.first { r.url.hasPrefix($0.key) }?.value
        lock.unlock()
        if r.url.contains("slow") { Thread.sleep(forTimeInterval: 0.3) }
        guard let body else { throw URLError(.notConnectedToInternet) }
        return NetResponse(code: 200, url: r.url, headers: [:], body: Data(body.utf8))
    }
    func cancel(_ tag: AnyObject) {}
}

/// Plays every site of a test below the address policy of `TVBoxNet`.
final class TVBoxStub: URLProtocol {
    struct Reply {
        var code = 200
        var headers: [String: String] = [:]
        var body = ""
        var type = "application/json; charset=utf-8"
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    private static var table: [String: (URLRequest) -> Reply] = [:]
    private static var log: [URLRequest] = []

    static var routes: [String: (URLRequest) -> Reply] {
        get { lock.lock(); defer { lock.unlock() }; return table }
        set { lock.lock(); table = newValue; lock.unlock() }
    }
    static var seen: [URLRequest] { lock.lock(); defer { lock.unlock() }; return log }
    static func reset() { lock.lock(); table = [:]; log = []; lock.unlock() }

    static func query(_ r: URLRequest) -> [String: String] {
        let items = r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { $1 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let gate = NSLock()
    private var stopped = false

    override func startLoading() {
        let r = request
        Self.lock.lock()
        Self.log.append(r)
        let route = Self.table[r.url?.path ?? ""]
        Self.lock.unlock()
        let reply = route?(r) ?? Reply(code: 404)
        if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { self.answer(r, reply) } } else { answer(r, reply) }
    }

    private func answer(_ r: URLRequest, _ reply: Reply) {
        gate.lock()
        let off = stopped
        gate.unlock()
        guard !off, let url = r.url, let resp = HTTPURLResponse(url: url, statusCode: reply.code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.type].merging(reply.headers) { $1 }) else { return }
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { gate.lock(); stopped = true; gate.unlock() }
}
