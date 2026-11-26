import Network
import WebKit
import XCTest
@testable import STV

/// Runtimes of the TVBox engine: script host, QuickJS spiders (same cases as JsSpiderTest.kt), loopback proxy, JAR-bridge
/// client (vectors of BridgeTest.kt), sniffer, Python spiders.
final class TVBoxRuntimeTests: XCTestCase {
    // MARK: Fixtures

    private final class Canned: TVBoxHttp {
        var files: [String: String] = [:]
        var requests: [NetRequest] = []
        var delay: TimeInterval = 0
        private let lock = NSLock()
        private var cancelled = false

        func execute(_ r: NetRequest) throws -> NetResponse {
            lock.lock(); requests.append(r); lock.unlock()
            if delay > 0 {
                let end = Date().addingTimeInterval(delay)
                while Date() < end {
                    lock.lock(); let stop = cancelled; lock.unlock()
                    if stop { throw URLError(.cancelled) }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            guard let body = files[r.url] ?? files[r.url.substringBefore("?")] else { throw TVBoxIOError("no fixture \(r.url)") }
            return NetResponse(code: 200, url: r.url, headers: ["Content-Type": ["text/html; charset=utf-8"], "Set-Cookie": ["a=1", "b=2"]], body: Data(body.utf8))
        }

        func cancel(_ tag: AnyObject) { lock.lock(); cancelled = true; lock.unlock() }
        func reset() { lock.lock(); cancelled = false; lock.unlock() }
    }

    private final class Memory: ScriptStorage {
        var values: [String: String] = [:]
        func get(_ ns: String, _ k: String) -> String? { values["\(ns)|\(k)"] }
        func set(_ ns: String, _ k: String, _ v: String) { values["\(ns)|\(k)"] = v }
        func delete(_ ns: String, _ k: String) { values["\(ns)|\(k)"] = nil }
    }

    private let http = Canned()
    private let storage = Memory()
    private var opened: [JsSpider] = []
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rt-" + UUID().uuidString)

    override func tearDown() {
        opened.forEach { $0.destroy() }
        opened = []
        try? FileManager.default.removeItem(at: dir)
    }

    private func spider(_ source: String, ext: String = "", api: String = "https://s.example/js/site.js") throws -> JsSpider {
        http.files[api] = source
        let site = TVBoxSite(key: "站点", name: "站点", type: 3, api: api, ext: ext)
        let host = ScriptHost(siteKey: site.key, http: http, storage: storage, proxyPort: { 9978 })
        let modules = JsModules(asset: { TVBoxRuntime.jsAsset("lib/" + $0) }, http: http, cache: ScriptCache(dir.appendingPathComponent(UUID().uuidString)), entry: api, tag: host.tag)
        let s = JsSpider(site: site, engineFactory: { try QuickJSEngine() }, host: host, modules: modules, bootstrap: try XCTUnwrap(TVBoxRuntime.jsAsset("bootstrap.js")))
        s.onInterrupt = { [http] in http.cancel(host.tag) }
        opened.append(s)
        try s.start(ext: ext)
        return s
    }

    private func obj(_ s: String, line: UInt = #line) throws -> [String: Any] { try XCTUnwrap(RT.object(s), s, line: line) }
    private func message(_ body: () throws -> Any) -> String { do { _ = try body(); return "" } catch { return SpiderErrors.text(error) } }

    private func host(_ name: String, _ args: [String: Any], _ h: ScriptHost? = nil, line: UInt = #line) throws -> Any? {
        let h = h ?? ScriptHost(siteKey: "k", http: http, storage: storage, proxyPort: { 9981 })
        let o = try obj(h.call(name, RT.json(args)), line: line)
        if let e = o["e"] as? String { throw TVBoxError(e) }
        return o["v"] is NSNull ? nil : o["v"]
    }

    private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    // MARK: JavaScript

    func testDefaultExportWithSyncFunctions() throws {
        let s = try spider("""
            let cfg = {};
            export default {
              init: ext => { cfg = ext; local.set('r', 'k', 'v1'); },
              home: f => JSON.stringify({ class: [{ type_id: '1', type_name: cfg.name }], filter: f, saved: local.get('r', 'k'), def: local.get('r', 'none', 'd') }),
              homeVod: () => ({ list: [] }),
              category: (tid, pg, filter, ext) => ({ tid, pg, area: ext.area }),
              detail: id => ({ id }),
              search: (k, quick, pg) => ({ k, quick, pg }),
              play: (flag, id, flags) => ({ parse: 0, url: id, flag, n: flags.length }),
              proxy: p => [206, 'video/mp2t', 'ab中', { 'X-A': p.a }],
              isVideo: u => /x/.test(u), sniffer: () => true,
            }
            """, ext: #"{"name":"名称"}"#)
        let home = try obj(try s.homeContent(filter: true))
        XCTAssertEqual((home["class"] as? [[String: Any]])?.first?["type_name"] as? String, "名称")
        XCTAssertEqual(home["saved"] as? String, "v1"); XCTAssertEqual(home["def"] as? String, "d"); XCTAssertEqual(home["filter"] as? Bool, true)
        XCTAssertEqual(try s.homeVideoContent(), #"{"list":[]}"#)
        XCTAssertEqual(try obj(try s.categoryContent(tid: "t", pg: "2", filter: true, extend: ["area": "cn"]))["area"] as? String, "cn")
        XCTAssertEqual(try obj(try s.detailContent(ids: ["a/b"]))["id"] as? String, "a/b")
        XCTAssertEqual(try obj(try s.searchContent(key: "关键", quick: false, pg: "2"))["k"] as? String, "关键")
        XCTAssertEqual(try obj(try s.playerContent(flag: "f", id: "u", vipFlags: ["a", "b"]))["n"] as? Int, 2)
        let p = try XCTUnwrap(try s.proxyLocal(["a": "1"]))
        XCTAssertEqual(p.code, 206); XCTAssertEqual(String(decoding: p.body, as: UTF8.self), "ab中"); XCTAssertEqual(p.headers["X-A"], "1"); XCTAssertEqual(p.type, "video/mp2t")
        XCTAssertTrue(try s.isVideoFormat("x")); XCTAssertTrue(try s.manualVideoCheck()); XCTAssertEqual(try s.action("nothing"), "")
    }

    func testCatVodStyleAsyncAndTimers() throws {
        http.files["https://s.example/page"] = #"<html><body><ul class="list"><li><a href="/1">一<b>号</b></a><img data-src="p1"></li><li><a href="/2">二</a></li></ul></body></html>"#
        let s = try spider("""
            import { load, _, Crypto, Uri, dayjs } from 'assets://js/lib/cat.js';
            let skey = '';
            async function init(cfg) { skey = cfg.skey + ':' + cfg.stype + ':' + cfg.ext.a; }
            async function home(filter) {
              const r = await req('https://s.example/page', { headers: { A: 'b' } });
              const $ = load(r.content);
              const list = $('ul.list > li').map((i, el) => ({ vod_id: $(el).find('a').attr('href'), vod_name: $(el).find('a').text(), vod_pic: $('img', el).data('src') })).get();
              await new Promise(resolve => setTimeout(resolve, 20));
              return JSON.stringify({ skey, list, cookies: r.headers['Set-Cookie'], first: _.first(list).vod_id, md5: Crypto.MD5('a').toString(), q: new Uri('http://x/?a=%20b').getQueryParamValue('a'), y: dayjs('2026-01-02 03:04:05').format('YYYY/MM/DD HH:mm') });
            }
            function detail(id) { return Promise.reject(new Error('坏了')); }
            async function category() { await new Promise(() => {}); }
            export function __jsEvalReturn() { return { init, home, detail, category, homeVod: null, search: null, play: null }; }
            """, ext: #"{"a":7}"#)
        let h = try obj(try s.homeContent(filter: true)), list = try XCTUnwrap(h["list"] as? [[String: Any]])
        XCTAssertEqual(h["skey"] as? String, "站点:3:7"); XCTAssertEqual(list[0]["vod_name"] as? String, "一号"); XCTAssertEqual(list[0]["vod_pic"] as? String, "p1"); XCTAssertEqual(list.count, 2)
        XCTAssertEqual((h["cookies"] as? [Any])?.count, 2); XCTAssertEqual(h["first"] as? String, "/1")
        XCTAssertEqual(h["md5"] as? String, "0cc175b9c0f1b6a831c399e269772661"); XCTAssertEqual(h["q"] as? String, " b"); XCTAssertEqual(h["y"] as? String, "2026/01/02 03:04")
        XCTAssertEqual(http.requests.last { $0.url.hasSuffix("/page") }?.headers["A"], "b")
        XCTAssertTrue(message { try s.detailContent(ids: ["1"]) }.contains("坏了"))
        XCTAssertTrue(message { try s.categoryContent(tid: "1", pg: "1", filter: true, extend: [:]) }.contains("没有返回结果"))
    }

    func testRequestsBodiesAndBinaryReplies() throws {
        for n in ["post", "form", "raw"] { http.files["https://s.example/\(n)"] = "" }
        http.files["https://s.example/bin"] = "AB"; http.files["https://s.example/page2"] = "two"; http.files["https://s.example/json"] = #"{"v":"值"}"#
        let s = try spider("""
            export function home() {
              req('https://s.example/post', { method: 'post', data: { a: 1 } });
              req('https://s.example/form', { method: 'POST', postType: 'form', data: { a: '中 文', b: 2 } });
              req('https://s.example/raw', { method: 'post', body: 'x=1', headers: { 'Content-Type': 'text/plain' }, redirect: 0, timeout: 1234 });
              const bin = req('https://s.example/bin', { buffer: 2 }), arr = req('https://s.example/bin', { buffer: 1 }), bad = req('https://none.example/');
              return { b64: bin.content, arr: arr.content.slice(0, 2), bad: bad.content, code: bad.code, list: batchFetch([{ url: 'https://s.example/bin' }, { url: 'https://s.example/page2' }]) };
            }
            export async function search() {
              const r = await fetch('https://s.example/json'); const u = new URL('../x?a=1&b=2#h', 'https://h.example/p/q/r'); u.searchParams.set('a', '9');
              const body = await http.get('https://s.example/json');
              return { v: (await r.json()).v, ok: r.ok, href: u.href, host: u.host, d: body.data.v, dec: new TextDecoder('gbk').decode(new Uint8Array([0xd6, 0xd0])), enc: Array.from(new TextEncoder().encode('é😀')), b: atob(btoa('ok')) };
            }
            """)
        let h = try obj(try s.homeContent(filter: false))
        XCTAssertEqual(h["b64"] as? String, "QUI="); XCTAssertEqual(h["arr"] as? [Int], [65, 66]); XCTAssertEqual(h["bad"] as? String, ""); XCTAssertEqual(h["code"] as? Int, 0); XCTAssertEqual(h["list"] as? [String], ["AB", "two"])
        func request(_ n: String) throws -> NetRequest { try XCTUnwrap(http.requests.first { $0.url.hasSuffix(n) }) }
        XCTAssertEqual(try request("/post").body, Data(#"{"a":1}"#.utf8)); XCTAssertEqual(try request("/post").headers["Content-Type"], "application/json")
        XCTAssertEqual(try request("/form").body, Data("a=%E4%B8%AD+%E6%96%87&b=2".utf8))
        let raw = try request("/raw")
        XCTAssertEqual(raw.body, Data("x=1".utf8)); XCTAssertFalse(raw.redirect); XCTAssertEqual(raw.timeoutMs, 1234); XCTAssertEqual(raw.headers["Content-Type"], "text/plain")
        let r = try obj(try s.searchContent(key: "k", quick: false, pg: "1"))
        XCTAssertEqual(r["v"] as? String, "值"); XCTAssertEqual(r["href"] as? String, "https://h.example/p/x?a=9&b=2#h"); XCTAssertEqual(r["host"] as? String, "h.example"); XCTAssertEqual(r["d"] as? String, "值")
        XCTAssertEqual(r["dec"] as? String, "中"); XCTAssertEqual(r["b"] as? String, "ok"); XCTAssertEqual(r["enc"] as? [Int], [0xc3, 0xa9, 0xf0, 0x9f, 0x98, 0x80])
    }

    func testDrpyToolbox() throws {
        let s = try spider("""
            import cheerio from 'assets://js/lib/cheerio.min.js';
            import 'assets://js/lib/crypto-js.js';
            import './json5.js';
            import 'pako.min.js';
            import { gbkTool } from 'assets://js/lib/gbk.js';
            import 模板 from 'assets://js/lib/模板.js';
            const html = `<div class="list"><ul><li class="on"><a href="/v/1" title="甲"><img data-original="/p/1.jpg"></a><span>备注<em>广告</em></span></li><li><a href="//o.example/2">乙</a></li><li><a href="http://x.example/3">丙</a></li></ul><div id="box" style="background:url('/b.png')">t</div></div>`;
            export function home() {
              return {
                a: pdfa(html, '.list&&li').length, t: pdfh(html, 'li:eq(1)&&a&&Text'), attr: pdfh(html, 'li&&a&&nope||title'), last: pdfh(html, 'li:eq(-1) a&&Text'),
                u: pd(html, 'li&&img&&data-original', 'https://h.example/x/'), u2: pd(html, 'li:eq(1)&&a&&href', 'https://h.example/x/'), ex: pdfh(html, 'li&&span--em&&Text'), style: pd(html, '#box&&style', 'https://h.example/'),
                inner: pdfh(html, '#box&&Html'), alt: pdfh(html, '.none&&Text||#box&&Text'), l: pdfl(html, '.list&&li', 'a&&Text', 'a&&href', 'https://h.example/'), gt: pdfa(html, 'li:gt(0)').length, join: joinUrl('https://h.example/a/b', '../c?d=1'),
                jp: cheerio.jp('$.data.list[*].name', { data: { list: [{ name: 'x' }, { name: 'y' }] } }), jp2: cheerio.jp('$..id', { a: { id: 1 }, b: [{ id: 2 }] }), jp3: cheerio.jp("$.l[?(@.n=='b')].v", { l: [{ n: 'a', v: 1 }, { n: 'b', v: 2 }] }),
                jinja: cheerio.jinja2("/list/{{fl.cateId or '1'}}{% if fl.area %}/{{fl.area}}{% else %}/all{% endif %}-{{ fl.year | default('2026') }}{% for x in [1,2] %}.{{x}}{% endfor %}", { fl: { area: 'cn' } }),
                j5: JSON5.parse("{a:'x',/*c*/b:[1,],}"), muban: Object.keys(模板.muban).length > 3 && 模板.getMubans().mxpro.一级.length > 0,
              };
            }
            export function search() {
              const aesKey = 'abcdefghabcdefgh', iv = '1234567812345678';
              const ct = aesX('AES/CBC/PKCS7', true, '明文', false, aesKey, iv, true);
              const same = CryptoJS.AES.encrypt('明文', CryptoJS.enc.Utf8.parse(aesKey), { iv: CryptoJS.enc.Utf8.parse(iv), mode: CryptoJS.mode.CBC, padding: CryptoJS.pad.Pkcs7 }).toString();
              const pass = CryptoJS.AES.decrypt(CryptoJS.AES.encrypt('pw', 'k').toString(), 'k').toString(CryptoJS.enc.Utf8);
              const g = gbkTool();
              return { ct, same, back: aesX('AES/CBC/PKCS7', false, ct, true, aesKey, iv, false), pass, md5: md5X('a'), gz: ungzip(gzip('压缩')), pako: pako.ungzip(pako.gzip('pk'), { to: 'string' }), pako2: pako.inflate(pako.deflate('zl'), { to: 'string' }), gbk: g.encode('中 a'), ungbk: g.decode('%D6%D0'), des: desX('DESede/ECB/PKCS7', false, desX('DESede/ECB/PKCS7', true, 'd', false, 'k1k2k3k4k5k6k7k8k9k0k1k2', '', true), true, 'k1k2k3k4k5k6k7k8k9k0k1k2', '', false), proxy: getProxy(true), js2: js2Proxy(true, 3, 'k', 'http://a/b?c=1', { A: 'b' }), s2t: s2t('国'), t2s: t2s('國') };
            }
            export function detail() {
              const $ = cheerio.load(html);
              const own = $('li').eq(0).find('span').clone().children().remove().end().text();
              return { own, kept: $('li').eq(0).find('span').text(), sib: $('li.on').next().find('a').attr('href'), up: $('img').closest('li').hasClass('on'), idx: $('li').last().index(), kids: $('ul').children('li').length, each: $('li a').toArray().map(e => e.attribs.href), node: $('span').contents().filter(function () { return this.nodeType === 3; }).text(), html: $('#box').html(), not: $('li').not('.on').length, is: $('li').first().is('.on'), par: $('a').parent('li').length, all: $('li').slice(1).length, str: $('em') + '' };
            }
            """)
        let h = try obj(try s.homeContent(filter: true))
        func str(_ o: [String: Any], _ k: String) -> String { J.str(o[k]) }
        XCTAssertEqual(J.int(h["a"]), 3)
        for (k, v) in ["t": "乙", "attr": "甲", "last": "丙", "u": "https://h.example/p/1.jpg", "u2": "https://o.example/2", "ex": "备注", "style": "https://h.example/b.png", "inner": "t", "alt": "t",
                       "join": "https://h.example/c?d=1", "jinja": "/list/1/cn-2026.1.2"] { XCTAssertEqual(str(h, k), v, k) }
        XCTAssertEqual((h["l"] as? [String])?.first?.substringAfter("$"), "https://h.example/v/1"); XCTAssertEqual(J.int(h["gt"]), 2)
        XCTAssertEqual(h["jp"] as? [String], ["x", "y"]); XCTAssertEqual((h["jp2"] as? [Any])?.count, 2); XCTAssertEqual((h["jp3"] as? [Int])?.first, 2)
        XCTAssertEqual((h["j5"] as? [String: Any])?["a"] as? String, "x"); XCTAssertEqual(h["muban"] as? Bool, true)
        let c = try obj(try s.searchContent(key: "", quick: false, pg: "1"))
        XCTAssertEqual(str(c, "ct"), str(c, "same"))
        for (k, v) in ["back": "明文", "pass": "pw", "md5": "0cc175b9c0f1b6a831c399e269772661", "gz": "压缩", "pako": "pk", "pako2": "zl", "gbk": "%D6%D0%20a", "ungbk": "中", "des": "d",
                       "proxy": "http://127.0.0.1:9978/proxy?do=js&siteKey=%E7%AB%99%E7%82%B9", "s2t": "國", "t2s": "国"] { XCTAssertEqual(str(c, k), v, k) }
        XCTAssertTrue(str(c, "js2").contains("&from=catvod"))
        let d = try obj(try s.detailContent(ids: ["1"]))
        for (k, v) in ["own": "备注", "kept": "备注广告", "sib": "//o.example/2", "node": "备注", "html": "t", "str": "<em>广告</em>"] { XCTAssertEqual(str(d, k), v, k) }
        XCTAssertEqual(d["up"] as? Bool, true); XCTAssertEqual(J.int(d["idx"]), 2); XCTAssertEqual(J.int(d["kids"]), 3); XCTAssertEqual(J.int(d["not"]), 2); XCTAssertEqual(d["is"] as? Bool, true); XCTAssertEqual(J.int(d["par"]), 3)
        XCTAssertEqual(d["each"] as? [String], ["/v/1", "//o.example/2", "http://x.example/3"])
    }

    /// drpy engines load their rule text with a direct eval that assigns a module variable.
    func testRulesAreEvaluatedInsideTheModule() throws {
        http.files["https://s.example/rule.js"] = "var rule = { title: '规则', host: 'https://h.example', 一级: 'ul&&li;a&&Text' };"
        let s = try spider("""
            let rule = {};
            function init(ext) { const js = req(ext).content; eval('(function(){' + js.replace('var rule', 'rule') + '})()'); }
            export default { init, home: () => JSON.stringify({ t: rule.title, l: rule.一级.split(';').length }) };
            """, ext: "https://s.example/rule.js")
        let h = try obj(try s.homeContent(filter: true))
        XCTAssertEqual(h["t"] as? String, "规则"); XCTAssertEqual(h["l"] as? Int, 2)
    }

    func testModulesResolveAndFailuresAreReadable() throws {
        http.files["https://s.example/lib/util.js"] = "export const v = 'rel'; export const at = import.meta.url;"
        let s = try spider("import { v, at } from '../lib/util.js'; import m from './模板.js'; export default function () { return { home: () => ({ v, at, m: !!m.muban }), search: async () => (await import('../lib/util.js')).v }; }")
        let h = try obj(try s.homeContent(filter: true))
        XCTAssertEqual(h["v"] as? String, "rel"); XCTAssertEqual(h["at"] as? String, "https://s.example/lib/util.js"); XCTAssertEqual(h["m"] as? Bool, true)
        XCTAssertEqual(try s.searchContent(key: "", quick: false, pg: "1"), "rel")
        XCTAssertEqual(try spider("__JS_SPIDER__ = { home() { return { g: 1 }; } };").homeContent(filter: true), #"{"g":1}"#)
        func fails(_ src: String, _ api: String = "https://s.example/js/site.js") -> String { message { try spider(src, api: api) } }
        XCTAssertTrue(fails("//bb0123456").contains("字节码"))
        XCTAssertTrue(fails("import x from './missing.js'; export default {};").contains("missing.js"))
        XCTAssertTrue(fails("export const nothing = 1;").contains("没有导出"))
        XCTAssertTrue(fails("throw new Error('炸了')").contains("炸了"))
        let syntax = fails("export default { home( }")
        XCTAssertTrue(syntax.contains("脚本加载失败"), syntax); XCTAssertTrue(syntax.contains("site.js:1"), syntax)
        XCTAssertTrue(fails("<!DOCTYPE html><html>", "https://s.example/web.js").contains("网页"))
    }

    func testEndlessScriptsAndBlockedRequestsAreInterrupted() throws {
        let s = try spider("""
            let n = 0;
            export default {
              home: () => { while (true) { try { while (true) n++; } catch (e) { n = 0; } } },
              category: async () => { for (;;) await null; },
              search: () => { try { req('https://s.example/slow'); } catch (e) {} return { late: 1 }; },
              detail: () => ({ ok: n > 0 }),
            };
            """)
        http.files["https://s.example/slow"] = "x"
        func interrupted(_ body: () throws -> String) -> (String, TimeInterval) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { s.interrupt() }
            let from = Date()
            return (message { try body() }, Date().timeIntervalSince(from))
        }
        for body in [{ try s.homeContent(filter: false) }, { try s.categoryContent(tid: "", pg: "", filter: false, extend: [:]) }] as [() throws -> String] {
            let (m, t) = interrupted(body)
            XCTAssertTrue(m.contains("中断"), m); XCTAssertLessThan(t, 3)
        }
        http.delay = 20
        http.reset()   // the interrupts above cancelled it already
        let (m, t) = interrupted { try s.searchContent(key: "", quick: false, pg: "") }
        XCTAssertTrue(m.contains("中断"), m); XCTAssertLessThan(t, 3)
        // the context is still usable
        XCTAssertEqual(try obj(try s.detailContent(ids: ["1"]))["ok"] as? Bool, true)
    }

    func testDeepRecursionAndMemoryAreBounded() throws {
        let s = try spider("""
            function f(n) { return f(n + 1) + 1; }
            export default { home: () => f(0), search: () => { const a = []; for (;;) a.push(new Array(100000).fill(1.5)); }, detail: () => ({ ok: 1 }) };
            """)
        XCTAssertTrue(message { try s.homeContent(filter: false) }.lowercased().contains("stack"))
        XCTAssertTrue(message { try s.searchContent(key: "", quick: false, pg: "") }.contains("memory"))
        XCTAssertEqual(try s.detailContent(ids: ["1"]), #"{"ok":1}"#)
    }

    // MARK: Host functions

    func testHashAndCipherVectors() throws {
        XCTAssertEqual(try host("hash", ["alg": "md5", "b64": b64("abc")]) as? String, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(try host("hash", ["alg": "sha1", "b64": b64("abc")]) as? String, "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(try host("hash", ["alg": "sha256", "b64": b64("what do ya want for nothing?"), "hmacB64": b64("Jefe")]) as? String, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        XCTAssertEqual((try host("hash", ["alg": "sha512", "b64": "", "hmacB64": ""]) as? String)?.count, 128)
        XCTAssertThrowsError(try host("hash", ["alg": "crc", "b64": ""]))

        // NIST SP 800-38A, AES-128
        let key = "2b7e151628aed2a6abf7158809cf4f3c", iv = "000102030405060708090a0b0c0d0e0f", plain = "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
        func cipher(_ alg: String, _ mode: String, _ pad: String, _ encrypt: Bool, _ k: String, _ v: String, _ d: String) throws -> String {
            func x(_ h: String) -> String { Data(Bytes.fromHex(h)!).base64EncodedString() }
            let r = try host("cipher", ["alg": alg, "mode": mode, "pad": pad, "encrypt": encrypt, "keyB64": x(k), "ivB64": x(v), "dataB64": x(d)]) as? String
            return Bytes.hex([UInt8](Data(base64Encoded: r ?? "")!))
        }
        for (mode, start, out) in [("ecb", "", "3ad77bb40d7a3660a89ecaf32466ef97f5d3d58503b9699de785895a96fdbaaf"), ("cbc", iv, "7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2"),
                                   ("cfb", iv, "3b3fd92eb72dad20333449f8e83cfb4ac8a64537a0b3a93fcde3cdad9f1ce58b"), ("ofb", iv, "3b3fd92eb72dad20333449f8e83cfb4a7789508d16918f03f53c52dac54ed825"),
                                   ("ctr", "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff", "874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff")] {
            XCTAssertEqual(try cipher("aes", mode, "none", true, key, start, plain), out, mode)
            XCTAssertEqual(try cipher("aes", mode, "none", false, key, start, out), plain, mode)
            // a short last block, padded and not
            XCTAssertEqual(try cipher("aes", mode, "pkcs7", false, key, start, try cipher("aes", mode, "pkcs7", true, key, start, String(plain.prefix(42)))), String(plain.prefix(42)), mode)
            if mode != "ecb", mode != "cbc" { XCTAssertEqual(try cipher("aes", mode, "none", true, key, start, String(plain.prefix(42))), String(out.prefix(42)), mode) }
        }
        let gcm = ("feffe9928665731c6d6a8f9467308308", "cafebabefacedbaddecaf888", "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255",
                   "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985" + "4d5c2af327cd64a62cf35abd2ba6fab4")
        XCTAssertEqual(try cipher("aes", "gcm", "none", true, gcm.0, gcm.1, gcm.2), gcm.3); XCTAssertEqual(try cipher("aes", "gcm", "none", false, gcm.0, gcm.1, gcm.3), gcm.2)
        XCTAssertEqual(try cipher("des", "ecb", "none", true, "133457799bbcdff1", "", "0123456789abcdef"), "85e813540f0ab405")
        XCTAssertEqual(try cipher("3des", "ecb", "none", true, "133457799bbcdff1133457799bbcdff1", "", "0123456789abcdef"), "85e813540f0ab405")
        for mode in ["cbc", "cfb", "ofb", "ctr"] { XCTAssertEqual(try cipher("3des", mode, "pkcs7", false, "0123456789abcdef23456789abcdef01456789abcdef0123", "0011223344556677", try cipher("3des", mode, "pkcs7", true, "0123456789abcdef23456789abcdef01456789abcdef0123", "0011223344556677", "aabbcc")), "aabbcc", mode) }
        XCTAssertEqual(try cipher("rc4", "", "", true, Bytes.hex(Array("Key".utf8)), "", Bytes.hex(Array("Plaintext".utf8))), "bbf316e8d940af0ad3")
        XCTAssertEqual(try cipher("aes", "cbc", "zero", false, key, iv, try cipher("aes", "cbc", "zero", true, key, iv, "0102")), "0102")
        XCTAssertThrowsError(try cipher("aes", "cbc", "pkcs7", false, key, iv, plain))
        XCTAssertThrowsError(try cipher("aes", "cbc", "pkcs7", false, key, iv, "00"))
    }

    func testRSA() throws {
        var err: Unmanaged<CFError>?
        let pri = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024] as CFDictionary, &err)), pub = try XCTUnwrap(SecKeyCopyPublicKey(pri))
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(pri, nil) as Data?), pubDer = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, nil) as Data?)
        func tlv(_ tag: UInt8, _ d: Data) -> Data { Data([tag]) + (d.count < 128 ? Data([UInt8(d.count)]) : Data([0x82, UInt8(d.count >> 8), UInt8(d.count & 255)])) + d }
        let alg = tlv(0x30, Data([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]))
        let pkcs8 = tlv(0x30, Data([2, 1, 0]) + alg + tlv(4, pkcs1)), spki = tlv(0x30, alg + tlv(3, Data([0]) + pubDer))
        func pem(_ d: Data, _ n: String) -> String { "-----BEGIN \(n)-----\n" + d.base64EncodedString(options: .lineLength64Characters) + "\n-----END \(n)-----" }
        let publicKeys = [pubDer.base64EncodedString(), spki.base64EncodedString(), pem(spki, "PUBLIC KEY"), pem(pubDer, "RSA PUBLIC KEY")]
        let privateKeys = [pkcs1.base64EncodedString(), pem(pkcs1, "RSA PRIVATE KEY"), pkcs8.base64EncodedString(), pem(pkcs8, "PRIVATE KEY")]
        func rsa(_ op: String, _ key: String, _ pub: Bool, _ pad: String, _ d: Data) throws -> Data {
            let out = try host("rsa", ["op": op, "key": key, "public": pub, "pad": pad, "dataB64": d.base64EncodedString()])
            return Data(base64Encoded: out as? String ?? "") ?? Data()
        }
        let long = Data(String(repeating: "长", count: 45).utf8)   // two blocks; debug builds do big numbers slowly
        for (a, b) in zip(publicKeys, privateKeys) {
            for pad in ["pkcs1", "oaep"] {
                XCTAssertEqual(try rsa("decrypt", b, false, pad, try rsa("encrypt", a, true, pad, long)), long)
                XCTAssertEqual(try rsa("decrypt", b, false, pad, try rsa("encrypt", a, true, pad, Data())), Data())
            }
            XCTAssertEqual(try rsa("decrypt", a, true, "pkcs1", try rsa("encrypt", b, false, "pkcs1", Data("签".utf8))), Data("签".utf8))
        }
        // against Security.framework
        XCTAssertEqual(SecKeyCreateDecryptedData(pri, .rsaEncryptionOAEPSHA1, try rsa("encrypt", publicKeys[1], true, "oaep", Data("o".utf8)) as CFData, nil) as Data?, Data("o".utf8))
        XCTAssertEqual(try rsa("decrypt", privateKeys[2], false, "pkcs1", try XCTUnwrap(SecKeyCreateEncryptedData(pub, .rsaEncryptionPKCS1, Data("p".utf8) as CFData, nil) as Data?)), Data("p".utf8))
        let none = try rsa("encrypt", publicKeys[0], true, "none", Data([1, 2, 3]))
        XCTAssertEqual(try rsa("decrypt", privateKeys[0], false, "none", none).suffix(4), Data([0, 1, 2, 3]))
        for (hash, a) in [("sha1", SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA1), ("sha256", .rsaSignatureMessagePKCS1v15SHA256)] {
            let sig = try XCTUnwrap(try host("rsa", ["op": "sign", "key": privateKeys[2], "hash": hash, "dataB64": b64("x")]) as? String)
            XCTAssertTrue(SecKeyVerifySignature(pub, a, Data("x".utf8) as CFData, Data(base64Encoded: sig)! as CFData, nil))
            XCTAssertEqual(try host("rsa", ["op": "verify", "key": publicKeys[1], "hash": hash, "dataB64": b64("x"), "sigB64": sig]) as? Bool, true)
            XCTAssertEqual(try host("rsa", ["op": "verify", "key": publicKeys[1], "hash": hash, "dataB64": b64("y"), "sigB64": sig]) as? Bool, false)
        }
        XCTAssertThrowsError(try rsa("encrypt", "AAAA", true, "pkcs1", Data()))
        // the textbook key, and a modulus that is not a multiple of a limb
        XCTAssertEqual(BigMod.pow([0x41], [0x11], [0x0c, 0xa1]), [0x0a, 0xe6])
    }

    func testTextFunctions() throws {
        XCTAssertEqual(try host("gbk", ["op": "encode", "s": "中a"]) as? String, Data([0xd6, 0xd0, 0x61]).base64EncodedString())
        XCTAssertEqual(try host("gbk", ["op": "decode", "b64": Data([0xd6, 0xd0, 0xff, 0x61]).base64EncodedString()]) as? String, "中\u{FFFD}a")
        XCTAssertEqual(try host("joinUrl", ["base": "https://h.example/a/b?x", "ref": "../c"]) as? String, "https://h.example/c")
        XCTAssertEqual(try host("proxyUrl", ["local": true, "kind": "py"]) as? String, "http://127.0.0.1:9981/proxy?do=py&siteKey=k")
        XCTAssertEqual((try host("json5", ["s": "{a:'x',/*c*/b:[1,],}"]) as? [String: Any])?["a"] as? String, "x")
        XCTAssertNil(try host("local.get", ["ns": "", "k": "v"])); XCTAssertNil(try host("local.set", ["ns": "", "k": "v", "v": "null"]))
        XCTAssertEqual(try host("local.get", ["ns": "k", "k": "v"]) as? String, "null")
        for (kind, raw) in [("zlib", "eJxLTEoGAAJNASc="), ("raw", "S0xKBgA="), ("gzip", "H4sIAAAAAAACCktMSgYAwkEkNQMAAAA=")] { XCTAssertEqual(try host("inflate", ["b64": raw, "kind": kind]) as? String, b64("abc"), kind) }
        XCTAssertThrowsError(try host("inflate", ["b64": "AAAA", "kind": "gzip"]))
        XCTAssertThrowsError(try host("nope", [:]))
        // half a surrogate pair in a JavaScript string
        XCTAssertEqual(ScriptHost(siteKey: "k", http: http, storage: storage, proxyPort: { 0 }).call("joinUrl", #"{"base":"","ref":"a\ud83dz"}"#), "{\"v\":\"a\u{FFFD}z\"}")
    }

    func testHtmlFunctions() throws {
        let h = ScriptHost(siteKey: "k", http: http, storage: storage, proxyPort: { 0 })
        let doc = try XCTUnwrap(try host("html.load", ["html": "<div><p>a</p><p>b<b>c</b></p>\n x&nbsp;<br>y</div><a HREF='1' title=\"&quot;q&quot;\">t</a><script>if (a < b) {}</script>"], h) as? Int)
        func select(_ css: String) throws -> [Int] { try host("html.select", ["ids": [doc], "css": css], h) as? [Int] ?? [] }
        func text(_ css: String) throws -> String { try select(css).map { try host("html.text", ["id": $0], h) as? String ?? "" }.joined(separator: "|") }
        XCTAssertEqual(try text("div"), "a bc x y"); XCTAssertEqual(try text("p"), "a|bc"); XCTAssertEqual(try text("p:contains(B)"), "bc"); XCTAssertEqual(try text("p:has(b)"), "bc"); XCTAssertEqual(try text("p:not(:has(b)), a"), "a|t")
        XCTAssertEqual(try text("p + p"), "bc"); XCTAssertEqual(try text("div > p:first b, p:eq(1) > b"), "c"); XCTAssertEqual(try text("p:last"), "bc"); XCTAssertEqual(try text("p:nth-child(odd)"), "a"); XCTAssertEqual(try text("[title*=Q]"), "t"); XCTAssertEqual(try text("p:matches(^b)"), "bc")
        XCTAssertEqual(try text("p:foo"), "")
        let a = try select("a")[0]
        XCTAssertEqual(try host("html.attr", ["id": a, "k": "href"], h) as? String, "1"); XCTAssertNil(try host("html.attr", ["id": a, "k": "none"], h))
        XCTAssertEqual(try host("html.outer", ["id": a], h) as? String, #"<a href="1" title="&quot;q&quot;">t</a>"#)
        XCTAssertEqual(try host("html.html", ["id": try select("script")[0]], h) as? String, "if (a < b) {}")
        XCTAssertEqual((try host("html.rel", ["id": a, "op": "siblings"], h) as? [Int])?.count, 2); XCTAssertEqual((try host("html.rel", ["id": a, "op": "parent"], h) as? [Int])?.count, 1)
        XCTAssertEqual(try host("html.rel", ["id": try select("p")[1], "op": "prev"], h) as? [Int], [try select("p")[0]])
        XCTAssertEqual((try host("html.xpath", ["id": doc, "q": "//a/@href"], h) as? [[String: Any]])?.first?["s"] as? String, "1")
        XCTAssertEqual((try host("html.xpath", ["id": doc, "q": "count(//p)"], h) as? [[String: Any]])?.first?["s"] as? String, "2")
        XCTAssertEqual((try host("html.xpath", ["id": try select("div")[0], "q": "//p"], h) as? [[String: Any]])?.compactMap { $0["n"] as? Int }, try select("p"))
        // loose text stays loose, Chinese addresses stay readable
        XCTAssertEqual(try host("pdfh", ["html": "字<b>粗</b>", "rule": "body&&Text"]) as? String, "字粗")
        XCTAssertEqual(try host("pdfa", ["html": "<a href='/搜索/1?a=1&b=2'>x</a>", "rule": "a"]) as? [String], ["<a href=\"/搜索/1?a=1&amp;b=2\">x</a>"])
        XCTAssertEqual(try host("pd", ["html": "<li><a href='x.html'>1</a></li>", "rule": "li&&a&&href", "base": "https://h.example/d/"]) as? String, "https://h.example/d/x.html")
        XCTAssertEqual((try host("pdfa", ["html": "<table><thead><tr><td>h</td></tr></thead><tr><td>1</td></tr><tr><td>2</td></tr></table>", "rule": "table&&tbody&&tr"]) as? [String])?.count, 2)
        h.endCall()
        XCTAssertEqual(try host("html.text", ["id": a], h) as? String, "")
    }

    func testFileStorageIsPersistentAndCapped() {
        let a = FileScriptStorage(dir: dir)
        a.set("站/点", "k", "v"); a.set("站/点", "big", String(repeating: "x", count: FileScriptStorage.maxValue + 1)); a.set("other", "k", "o"); a.set("other", "gone", "1"); a.delete("other", "gone")
        a.flush()
        let b = FileScriptStorage(dir: dir)
        XCTAssertEqual(b.get("站/点", "k"), "v"); XCTAssertNil(b.get("站/点", "big")); XCTAssertEqual(b.get("other", "k"), "o"); XCTAssertNil(b.get("other", "gone"))
        for i in 0..<20 { b.set("full", "k\(i)", String(repeating: "y", count: 400 << 10)) }
        XCTAssertNotNil(b.get("full", "k0")); XCTAssertNil(b.get("full", "k19"))
    }

    // MARK: Loopback proxy

    /// One raw request; status line, headers (lower case) and body as it came over the wire.
    private func ask(_ port: Int, _ request: String) throws -> (status: Int, headers: [String: String], body: Data) {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        final class Box: @unchecked Sendable { var d = Data() }
        let box = Box(), done = DispatchSemaphore(value: 0)
        func more() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, end, e in
                if let d { box.d.append(d) }
                if end || e != nil { done.signal() } else { more() }
            }
        }
        c.start(queue: DispatchQueue(label: "ask"))
        c.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
        more()
        XCTAssertEqual(done.wait(timeout: .now() + 15), .success)
        c.cancel()
        guard let cut = box.d.range(of: Data("\r\n\r\n".utf8)) else { throw TVBoxError("no reply") }
        let lines = String(decoding: box.d[..<cut.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for l in lines.dropFirst() { headers[l.substringBefore(":").lowercased()] = l.substringAfter(":").trimmed }
        return (Int(lines[0].split(separator: " ")[1])!, headers, Data(box.d[cut.upperBound...]))
    }

    func testProxyServesRangesHeadAndChunks() throws {
        let p = LocalProxy(ports: [19_970, 19_971, 19_972])
        var seen: [[String: String]] = []
        let lock = NSLock()
        p.setHandler { q in
            lock.lock(); seen.append(q); lock.unlock()
            switch q["do"] {
            case "js": return ProxyReply(type: "video/mp2t", headers: ["X-A": "b", "Access-Control-Allow-Origin": "*", "Bad": "x\r\ny"], body: Data((0..<100).map { UInt8($0) }))
            case "stream":
                var left = 3
                return ProxyReply(type: "text/plain", stream: { left -= 1; return left >= 0 ? Data("part\(left)".utf8) : nil })
            case "sized":
                var at = 0
                return ProxyReply(type: "video/mp4", stream: { defer { at += 10 }; return at < 100 ? Data((at..<(at + 10)).map { UInt8($0) }) : nil }, length: 100)
            case "break":
                var first = true
                return ProxyReply(type: "video/mp4", stream: { if first { first = false; return Data("abc".utf8) }; throw URLError(.networkConnectionLost) })
            case "file": return .text(q["path"] ?? "")
            case "slow": Thread.sleep(forTimeInterval: 0.5); return .text("slow")
            default: return .text("none", code: 404)
            }
        }
        let port = p.start()
        defer { p.stop() }
        XCTAssertEqual(port, 19_970); XCTAssertEqual(p.start(), port)
        func get(_ target: String, _ headers: String = "", method: String = "GET") throws -> (status: Int, headers: [String: String], body: Data) {
            try ask(port, "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\(headers)\r\n")
        }
        XCTAssertEqual(try get("/proxy?do=ck").body, Data("ok".utf8))
        let whole = try get("/proxy?do=js&x=%E4%B8%AD+a&user-agent=mine", "User-Agent: other\r\nX-B: c\r\n")
        XCTAssertEqual(whole.status, 200); XCTAssertEqual(whole.body.count, 100); XCTAssertEqual(whole.headers["content-length"], "100"); XCTAssertEqual(whole.headers["content-type"], "video/mp2t"); XCTAssertEqual(whole.headers["x-a"], "b")
        XCTAssertNil(whole.headers["access-control-allow-origin"]); XCTAssertNil(whole.headers["bad"])
        XCTAssertEqual(seen.last?["x"], "中 a"); XCTAssertEqual(seen.last?["user-agent"], "mine"); XCTAssertEqual(seen.last?["x-b"], "c")
        for target in ["/proxy?do=js", "/proxy?do=sized"] {
            let part = try get(target, "Range: bytes=15-24\r\n")
            XCTAssertEqual(part.status, 206, target); XCTAssertEqual(part.headers["content-range"], "bytes 15-24/100", target); XCTAssertEqual(part.headers["content-length"], "10"); XCTAssertEqual([UInt8](part.body), (15...24).map { UInt8($0) }, target)
            XCTAssertEqual([UInt8](try get(target, "Range: bytes=-3\r\n").body), [97, 98, 99]); XCTAssertEqual([UInt8](try get(target, "Range: bytes=98-\r\n").body), [98, 99]); XCTAssertEqual(try get(target, "Range: bytes=200-\r\n").status, 416)
            let head = try get(target, method: "HEAD")
            XCTAssertEqual(head.status, 200); XCTAssertEqual(head.headers["content-length"], "100"); XCTAssertTrue(head.body.isEmpty)
        }
        let chunked = try get("/proxy?do=stream")
        XCTAssertEqual(chunked.headers["transfer-encoding"], "chunked"); XCTAssertEqual(String(decoding: chunked.body, as: UTF8.self), "5\r\npart2\r\n5\r\npart1\r\n5\r\npart0\r\n0\r\n\r\n")
        if let broken = try? get("/proxy?do=break") { XCTAssertFalse(String(decoding: broken.body, as: UTF8.self).hasSuffix("0\r\n\r\n")) }
        XCTAssertEqual(try get("/file/%E4%B8%AD.js").body, Data("中.js".utf8))
        XCTAssertEqual(try get("/other").status, 404); XCTAssertEqual(try get("/proxy/?do=ck").status, 200)
        // a form body counts as query
        XCTAssertEqual(try ask(port, "POST /proxy HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 13\r\n\r\ndo=file&path=").status, 200)
        // web pages have no business here
        for h in ["Origin: https://evil.example", "Origin: null", "Sec-Fetch-Site: cross-site"] { XCTAssertEqual(try get("/proxy?do=js", h + "\r\n").status, 403, h) }
        XCTAssertEqual(try get("/proxy?do=js", "Origin: http://127.0.0.1:\(port)\r\n").status, 200)
        XCTAssertEqual(try ask(port, "GET /proxy?do=js HTTP/1.1\r\nHost: evil.example\r\n\r\n").status, 403)
        // refused before the announced body is waited for
        XCTAssertEqual(try ask(port, "POST /proxy HTTP/1.1\r\nHost: evil.example\r\nContent-Length: 4000000\r\n\r\n").status, 403)
        // requests do not wait for each other
        let from = Date()
        DispatchQueue.concurrentPerform(iterations: 6) { _ in _ = try? get("/proxy?do=slow") }
        XCTAssertLessThan(Date().timeIntervalSince(from), 2)
    }

    func testProxyTakesTheNextPortAndComesBackOnTheSameOne() throws {
        let a = LocalProxy(ports: [19_980, 19_981]), b = LocalProxy(ports: [19_980, 19_981])
        XCTAssertFalse(LocalProxy.ports.contains(9979)); XCTAssertEqual(LocalProxy.ports.first, 9978)
        let pa = a.start(), pb = b.start()
        defer { a.stop(); b.stop() }
        XCTAssertGreaterThan(pa, 0); XCTAssertGreaterThan(pb, 0); XCTAssertNotEqual(pa, pb)
        a.check()
        XCTAssertEqual(a.start(), pa)
        XCTAssertEqual(try ask(pa, "GET /proxy?do=ck HTTP/1.1\r\n\r\n").body, Data("ok".utf8))
        a.stop()
        XCTAssertEqual(a.port, 0)
        XCTAssertEqual(a.start(), pa)
        XCTAssertEqual(try ask(pa, "GET /proxy?do=ck HTTP/1.1\r\n\r\n").status, 200)
    }

    // MARK: JAR bridge

    private func bridge(code: String = "ABCD2345EFGH", reply: @escaping (URLRequest) throws -> (Int, String)) -> BridgeClient {
        BridgeClient(store: .init(address: { "192.168.1.2:9979" }, setAddress: { _ in }, code: { code }, setCode: { _ in }), now: { Date(timeIntervalSince1970: 1_800_000_000) }, nonce: { "nonce-0001" }) { r, _ in
            let (s, t) = try reply(r)
            return (s, Data(t.utf8))
        }
    }

    /// Same inputs as `BridgeAuth` in BridgeTest.kt, values computed with an independent HMAC.
    func testBridgeSignatures() {
        XCTAssertEqual(BridgeClient.sign(code: "ABCD2345", time: "1800000000", nonce: "nonce-0001", body: Data(#"{"api":"csp_A"}"#.utf8)), "a67869f2a8dc3a096bbfede3fa01213540a14ea9ff1079fd1e1ffba80a4a1f0e")
        XCTAssertEqual(BridgeClient.sign(code: "ABCD2345", time: "1800000000", nonce: "nonce-0001", body: Data()), "028410763c0bd0af5c2f36cd2ae4c9d059f7eecf84301b0f57b47ae34266791c")
        XCTAssertEqual(HostCrypto.hex(BridgeClient.hmac("ABCD2345", "proxy\n1800014400\ndo=bili&id=%E4%B8%AD")), "3e2ffa0284e6068584708ede8c69e216de6390de75b02a1b11922c418b79e9ca")
    }

    func testBridgeCallsAreSignedAndAnswersAreRead() throws {
        var last: URLRequest?
        let c = bridge { r in last = r; return (200, #"{"v":"{\"url\":\"http://192.168.1.2:9979/bridge/proxy?do=x&idj_exp=1&idj_sign=2\"}"}"#) }
        XCTAssertTrue(c.paired)
        let site = TVBoxSite(key: "k", name: "n", type: 3, api: "csp_A", ext: #"{"a":1}"#)
        let s = try c.spider(site: site, jar: "https://j.example/a.jar;md5;0")
        XCTAssertEqual(try s.playerContent(flag: "f", id: "id", vipFlags: ["qq"]), #"{"url":"http://192.168.1.2:9979/bridge/proxy?do=x&idj_exp=1&idj_sign=2"}"#)
        let r = try XCTUnwrap(last), body = try XCTUnwrap(r.httpBody), o = try obj(String(decoding: body, as: UTF8.self))
        XCTAssertEqual(r.url?.absoluteString, "http://192.168.1.2:9979/bridge/call"); XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(o["siteKey"] as? String, "k"); XCTAssertEqual(o["api"] as? String, "csp_A"); XCTAssertEqual(o["ext"] as? String, #"{"a":1}"#); XCTAssertEqual(o["jar"] as? String, "https://j.example/a.jar;md5;0"); XCTAssertEqual(o["method"] as? String, "playerContent")
        XCTAssertEqual(RT.json(o["args"] as Any), #"["f","id",["qq"]]"#)
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Idj-Time"), "1800000000"); XCTAssertEqual(r.value(forHTTPHeaderField: "X-Idj-Nonce"), "nonce-0001")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Idj-Sign"), BridgeClient.sign(code: "ABCD2345EFGH", time: "1800000000", nonce: "nonce-0001", body: body))
        _ = try c.parse(jar: "j", method: "jsonExt", args: ["key", ["甲": "https://p.example/?url="], "https://v.example/1"])
        XCTAssertEqual((try obj(String(decoding: try XCTUnwrap(last?.httpBody), as: UTF8.self))["args"] as? [Any])?.count, 3)
        _ = try s.detailContent(ids: ["a"])
        XCTAssertEqual(RT.json(try obj(String(decoding: try XCTUnwrap(last?.httpBody), as: UTF8.self))["args"] as Any), #"[["a"]]"#)
        let yes = bridge { _ in (200, #"{"v":"true"}"#) }
        XCTAssertTrue(try yes.spider(site: site, jar: "j").manualVideoCheck())
    }

    func testBridgeErrorsAreReadable() throws {
        func fails(_ code: Int, _ body: String) -> String { message { try bridge { _ in (code, body) }.call(siteKey: "", api: "a", ext: "", jar: "", method: "homeContent", args: [], tag: nil) } }
        XCTAssertTrue(fails(401, #"{"e":"两台设备的时间相差超过 60 秒"}"#).contains("自动设置时间")); XCTAssertTrue(fails(401, #"{"e":"配对码不正确"}"#).contains("重新配对"))
        XCTAssertTrue(fails(403, #"{"e":"这台设备还没有信任该配置"}"#).contains("还没有信任")); XCTAssertTrue(fails(429, #"{"e":"x"}"#).contains("一分钟")); XCTAssertEqual(fails(502, #"{"e":"「站」网络超时"}"#), "桥接：「站」网络超时")
        XCTAssertTrue(fails(404, #"{"e":"没有这个接口"}"#).contains("版本")); XCTAssertTrue(fails(200, "<html>").contains("没有 i短剧"))
        XCTAssertTrue(message { try bridge { _ in throw URLError(.cannotConnectToHost) }.call(siteKey: "", api: "", ext: "", jar: "", method: "x", args: [], tag: nil) }.contains("同一局域网"))
        let none = BridgeClient(store: .init(address: { "" }, setAddress: { _ in }, code: { nil }, setCode: { _ in }))
        XCTAssertFalse(none.paired); XCTAssertTrue(message { try none.spider(site: TVBoxSite(key: "k", name: "n", type: 3, api: "csp_A"), jar: "") }.contains("配对"))
    }

    func testBridgePairing() async throws {
        XCTAssertEqual(BridgeClient.normalizeCode(" abcd-2345 efgh\n"), "ABCD2345EFGH"); XCTAssertEqual(BridgeClient.normalizeCode("ＡＢ－２３"), "AB23")
        XCTAssertEqual(try BridgeClient.normalizeAddress("http://192.168.1.2/"), "192.168.1.2:9979"); XCTAssertEqual(try BridgeClient.normalizeAddress("10.0.0.3:8000"), "10.0.0.3:8000"); XCTAssertEqual(try BridgeClient.normalizeAddress("box.local"), "box.local:9979")
        for bad in ["8.8.8.8", "evil.example", "", "192.168.1.2:99999"] { XCTAssertThrowsError(try BridgeClient.normalizeAddress(bad), bad) }
        var stored: (String, String?) = ("", nil)
        var answer = (401, #"{"e":"配对码不正确"}"#)
        let c = BridgeClient(store: .init(address: { stored.0 }, setAddress: { stored.0 = $0 }, code: { stored.1 }, setCode: { stored.1 = $0 })) { r, _ in
            XCTAssertEqual(r.url?.path, "/bridge/ping"); XCTAssertEqual(r.httpBody ?? Data(), Data())
            return (answer.0, Data(answer.1.utf8))
        }
        do { try await c.pair(address: "192.168.1.2", code: "abcd-2345-efgh"); XCTFail("accepted") } catch { XCTAssertTrue(SpiderErrors.text(error).contains("配对码不正确")) }
        do { try await c.pair(address: "192.168.1.2", code: "abcd"); XCTFail("short") } catch { XCTAssertTrue(SpiderErrors.text(error).contains("12")) }
        XCTAssertFalse(c.paired); XCTAssertNil(stored.1)
        answer = (200, #"{"v":"ok"}"#)
        try await c.pair(address: "192.168.1.2", code: "abcd-2345-efgh")
        XCTAssertTrue(c.paired); XCTAssertEqual(stored.0, "192.168.1.2:9979"); XCTAssertEqual(stored.1, "ABCD2345EFGH")
        await c.refresh()
        try await Task.sleep(nanoseconds: 100_000_000)
        let state = await c.status.state
        XCTAssertEqual(state, .online)
        c.unpair()
        XCTAssertFalse(c.paired); XCTAssertEqual(stored.0, "")
    }

    // MARK: Sniffer

    private func page(_ html: String, _ extra: [String: String] = [:]) throws -> (LocalProxy, Int) {
        let p = LocalProxy(ports: Array(19_990...19_998))
        p.setHandler { q in
            if q["do"] == "page" { return .text(html, type: "text/html; charset=utf-8") }
            if let t = extra[q["do"] ?? ""] { return .text(t, type: "text/html; charset=utf-8") }
            return .text("", code: 404)
        }
        let port = p.start()
        XCTAssertGreaterThan(port, 0)
        return (p, port)
    }

    private func sniff(_ html: String, _ extra: [String: String] = [:], _ edit: (inout SniffRequest) -> Void = { _ in }) async throws -> SniffResult {
        let (server, port) = try page(html, extra)
        defer { server.stop() }
        var r = SniffRequest(url: "http://127.0.0.1:\(port)/proxy?do=page", headers: ["User-Agent": "UA-1", "Cookie": "sid=7"], allowPrivate: true, timeoutMs: 60_000)   // cold WebKit on a CI machine
        edit(&r)
        return try await WebSniffer(ownPort: { port }).sniff(r)
    }

    func testSnifferSeesXHRFetchAndMedia() async throws {
        let xhr = try await sniff("<script>setTimeout(function(){var x=new XMLHttpRequest();x.open('GET','https://cdn.invalid/a/index.m3u8?t=1');x.send();},50)</script>")
        XCTAssertEqual(xhr.url, "https://cdn.invalid/a/index.m3u8?t=1"); XCTAssertEqual(xhr.headers["User-Agent"], "UA-1"); XCTAssertTrue(xhr.headers["Referer"]?.hasPrefix("http://127.0.0.1:") == true); XCTAssertTrue(xhr.headers["Origin"]?.hasPrefix("http://127.0.0.1:") == true)
        let fetched = try await sniff("<script>fetch(new Request('https://cdn.invalid/b/v.mp4')).catch(function(){})</script>")
        XCTAssertEqual(fetched.url, "https://cdn.invalid/b/v.mp4")
        let media = try await sniff("<body><script>var v=document.createElement('video');v.src='https://cdn.invalid/c/v.mp4';document.body.appendChild(v);</script>")
        XCTAssertEqual(media.url, "https://cdn.invalid/c/v.mp4")
        let tag = try await sniff("<video><source src='https://cdn.invalid/d/v.m3u8'></video>")
        XCTAssertEqual(tag.url, "https://cdn.invalid/d/v.m3u8")
        let frame = try await sniff("<iframe src='/proxy?do=inner'></iframe>", ["inner": "<script>fetch('https://cdn.invalid/e/v.flv').catch(function(){})</script>"])
        XCTAssertEqual(frame.url, "https://cdn.invalid/e/v.flv"); XCTAssertTrue(frame.headers["Referer"]?.hasPrefix("http://127.0.0.1:") == true)
        let moved = try await sniff("<script>location.href='https://cdn.invalid/f/v.mp4'</script>")
        XCTAssertEqual(moved.url, "https://cdn.invalid/f/v.mp4")
    }

    func testSnifferRulesScriptsAndChecks() async throws {
        let clicked = try await sniff("<button id='p' onclick=\"fetch('https://cdn.invalid/play?id=9').catch(function(){})\">p</button>") {
            $0.scripts = ["document.getElementById('p').click()"]
            $0.rules = [TVBoxRule(name: "r", hosts: ["cdn.invalid"], regex: ["play\\?id="], exclude: [], script: [])]
        }
        XCTAssertEqual(clicked.url, "https://cdn.invalid/play?id=9")
        let kept = try await sniff("<script>fetch('https://ad.invalid/x.mp4').catch(function(){});fetch('https://cdn.invalid/skip.mp4').catch(function(){});setTimeout(function(){fetch('https://cdn.invalid/good.mp4').catch(function(){})},100)</script>") {
            $0.ads = ["ad.invalid"]
            $0.rules = [TVBoxRule(name: "r", hosts: ["cdn.invalid"], regex: [], exclude: ["skip"], script: [])]
        }
        XCTAssertEqual(kept.url, "https://cdn.invalid/good.mp4")
        let manual = try await sniff("<script>fetch('https://cdn.invalid/a.mp4').catch(function(){});fetch('https://cdn.invalid/real').catch(function(){})</script>") { $0.isVideo = { $0.hasSuffix("/real") } }
        XCTAssertEqual(manual.url, "https://cdn.invalid/real")
        let cookie = try await sniff("<script>document.cookie='own=1';fetch('/proxy?do=v&n=.mp4').catch(function(){});setTimeout(function(){fetch(location.origin+'/media/v.mp4').catch(function(){})},100)</script>")
        XCTAssertTrue(cookie.headers["Cookie"]?.contains("sid=7") == true, "\(cookie.headers)"); XCTAssertTrue(cookie.headers["Cookie"]?.contains("own=1") == true)
    }

    func testSnifferTimesOutCancelsAndCleansUp() async throws {
        let from = Date()
        do { _ = try await sniff("<p>nothing</p>") { $0.timeoutMs = 800 }; XCTFail("found something") } catch { XCTAssertTrue(SpiderErrors.text(error).contains("超时")) }
        XCTAssertLessThan(Date().timeIntervalSince(from), 6)
        let (server, port) = try page("<p>nothing</p>")
        defer { server.stop() }
        let sniffer = WebSniffer(ownPort: { port })
        let r = SniffRequest(url: "http://127.0.0.1:\(port)/proxy?do=page", allowPrivate: true)
        let running = (0..<4).map { _ in Task { try await sniffer.sniff(r) } }
        try await Task.sleep(nanoseconds: 500_000_000)
        running.forEach { $0.cancel() }
        for t in running { do { _ = try await t.value; XCTFail("not cancelled") } catch { XCTAssertTrue(error is CancellationError, "\(error)") } }
        // both slots are free again
        do { _ = try await sniffer.sniff(SniffRequest(url: "http://127.0.0.1:\(port)/proxy?do=page", allowPrivate: true, timeoutMs: 300)) } catch { XCTAssertTrue(SpiderErrors.text(error).contains("超时")) }
        let left = await MainActor.run { UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).flatMap(\.subviews).filter { $0 is WKWebView && $0.alpha < 0.015 }.count }
        XCTAssertEqual(left, 0)
        // another local port is off limits, and so is the LAN
        for bad in ["http://127.0.0.1:1/x.html", "http://192.168.1.1/x.html"] {
            do { _ = try await WebSniffer(ownPort: { port }).sniff(SniffRequest(url: bad, timeoutMs: 600)); XCTFail(bad) } catch { XCTAssertTrue(error is TVBoxError, "\(error)") }
        }
    }

    // MARK: Python

    func testPythonSpider() throws {
        guard PythonRuntime.isAvailable else { throw XCTSkip(PythonRuntime.missingMessage) }
        http.files["https://s.example/page"] = "<ul><li><a href='/1'>一</a></li><li><a href='/2'>二</a></li></ul>"
        let site = TVBoxSite(key: "站点", name: "站点", type: 3, api: "https://s.example/site.py")
        let host = ScriptHost(siteKey: site.key, http: http, storage: storage, proxyPort: { 9978 })
        let s = PySpider(uid: "rt-" + UUID().uuidString, site: site, engine: PythonEngine.shared, host: host, source: { """
            import json, time
            from concurrent.futures import ThreadPoolExecutor
            from base.spider import Spider
            from Crypto.Cipher import AES
            from lxml import etree
            class Spider(Spider):
                def init(self, extend=''):
                    self.extend = extend
                def homeContent(self, filter):
                    r = self.fetch('https://s.example/page', headers={'A': 'b'})
                    names = etree.HTML(r.text).xpath('//li/a/text()')
                    self.setCache('k', {'n': 1})
                    with ThreadPoolExecutor(4) as pool:
                        sizes = list(pool.map(lambda u: len(self.fetch(u).text), ['https://s.example/page'] * 4))
                    aes = AES.new(b'abcdefghabcdefgh', AES.MODE_CBC, b'1234567812345678')
                    return {'ext': self.extend, 'key': self.siteKey, 'names': names, 'sizes': sizes, 'cache': self.getCache('k'), 'aes': aes.encrypt(b'0123456789abcdef').hex(), 'proxy': self.getProxyUrl()}
                def searchContent(self, key, quick, pg='1'):
                    raise ValueError('坏了')
                def categoryContent(self, tid, pg, filter, extend):
                    while True:
                        pass
                def localProxy(self, param):
                    return [200, 'text/plain', 'p' + param['a']]
                def destroy(self):
                    pass
            """ }, url: "https://s.example/site.py")
        try s.start(ext: "参数")
        let h = try obj(try s.homeContent(filter: true))
        XCTAssertEqual(h["ext"] as? String, "参数"); XCTAssertEqual(h["key"] as? String, "站点"); XCTAssertEqual(h["names"] as? [String], ["一", "二"]); XCTAssertEqual((h["sizes"] as? [Int])?.count, 4)
        XCTAssertEqual(Set(h["sizes"] as? [Int] ?? []).count, 1); XCTAssertEqual((h["aes"] as? String)?.count, 32); XCTAssertTrue((h["proxy"] as? String)?.contains("do=py") == true)
        XCTAssertEqual(http.requests.first { $0.url.hasSuffix("/page") }?.headers["A"], "b")
        let m = message { try s.searchContent(key: "", quick: false, pg: "1") }
        XCTAssertTrue(m.contains("坏了") && m.contains("第") && !m.contains("RuntimeError"), m)
        XCTAssertEqual(String(decoding: try XCTUnwrap(try s.proxyLocal(["a": "1"])).body, as: UTF8.self), "p1")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { s.interrupt() }
        let from = Date()
        XCTAssertTrue(message { try s.categoryContent(tid: "", pg: "", filter: false, extend: [:]) }.contains("超时"))
        XCTAssertLessThan(Date().timeIntervalSince(from), 4)
        XCTAssertEqual(try obj(try s.homeContent(filter: true))["key"] as? String, "站点")
        s.destroy()
    }

    func testPythonFailuresAreReadable() throws {
        guard PythonRuntime.isAvailable else {
            XCTAssertNil(TVBoxRuntime.platform().python)
            XCTAssertEqual(message { try PythonEngine.shared.load(key: "x", source: "", ext: "", siteKey: "", url: "", host: ScriptHost(siteKey: "", http: http, storage: storage, proxyPort: { 0 })) }, "此版本未包含 Python 运行时")
            return
        }
        XCTAssertNotNil(TVBoxRuntime.platform().python)
        let host = ScriptHost(siteKey: "k", http: http, storage: storage, proxyPort: { 0 })
        func fails(_ source: String) -> String { message { try PythonEngine.shared.load(key: UUID().uuidString, source: source, ext: "", siteKey: "k", url: "https://s.example/a.py", host: host) } }
        XCTAssertTrue(fails("x = (").contains("语法错误")); XCTAssertTrue(fails("import not_there").contains("缺少 Python 模块 not_there")); XCTAssertTrue(fails("x = 1").contains("没有 Spider 类"))
    }

    func testPlatformIsComplete() throws {
        let p = TVBoxRuntime.platform()
        XCTAssertNotNil(p.js); XCTAssertNotNil(p.jar); XCTAssertNotNil(p.jsAsset("bootstrap.js")); XCTAssertNotNil(p.jsAsset("lib/模板.js")); XCTAssertNil(p.jsAsset("../py/idj_runner.py")); XCTAssertNil(p.jsAsset("lib/none.js"))
        let port = TVBoxRuntime.startProxy { q in .text("seen " + (q["a"] ?? "")) }
        XCTAssertTrue(LocalProxy.ports.contains(UInt16(port))); XCTAssertEqual(TVBoxRuntime.proxyPort, port)
        XCTAssertEqual(try ask(port, "GET /proxy?do=js&a=1 HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n").body, Data("seen 1".utf8))
    }
}
