package app.iduanju.core.tvbox

import app.iduanju.core.util.ProviderException
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException

/** shared/tvbox/js (bootstrap + libraries) against the Kotlin host ABI. */
class JsSpiderTest {
    @get:Rule val tmp = TemporaryFolder()
    private val files = HashMap<String, String>()
    private val requests = ArrayList<NetRequest>()
    private val stored = HashMap<String, String>()
    private val opened = ArrayList<JsSpider>()
    private val http = TVBoxHttp { r ->
        synchronized(requests) { requests += r }
        val body = files[r.url] ?: files[r.url.substringBefore('?')] ?: throw IOException("no fixture ${r.url}")
        NetResponse(200, r.url, mapOf("Content-Type" to listOf("text/html; charset=utf-8"), "Set-Cookie" to listOf("a=1", "b=2")), body.toByteArray())
    }
    private val storage = object : ScriptStorage {
        override fun get(ns: String, k: String) = stored["$ns|$k"]
        override fun set(ns: String, k: String, v: String) { stored["$ns|$k"] = v }
        override fun delete(ns: String, k: String) { stored.remove("$ns|$k") }
    }
    private fun asset(name: String) = javaClass.getResource("/js/$name")?.readText()

    private fun spider(source: String, ext: String = "", api: String = "https://s.example/js/site.js"): JsSpider {
        files[api] = source
        val site = TVBoxSite("站点", "站点", 3, api, ext)
        val host = ScriptHost(site.key, http, storage, { 9978 })
        return JsSpider(site, { GraalJsEngine() }, host, JsModules({ asset("lib/$it") }, http, ScriptCache(File(tmp.root, "js"), 0), api, host.tag), asset("bootstrap.js")!!).also { opened += it; it.init(ext) }
    }

    @After fun close() { opened.forEach { runCatching { it.destroy() } } }

    @Test fun defaultExportWithSyncFunctions() {
        val s = spider("""
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
        """, """{"name":"名称"}""")
        val home = JSONObject(s.homeContent(true))
        assertEquals("名称", home.getJSONArray("class").getJSONObject(0).getString("type_name")); assertEquals("v1", home.getString("saved")); assertEquals("d", home.getString("def")); assertTrue(home.getBoolean("filter"))
        assertEquals("""{"list":[]}""", s.homeVideoContent())
        assertEquals("cn", JSONObject(s.categoryContent("t", "2", true, mapOf("area" to "cn"))).getString("area"))
        assertEquals("a/b", JSONObject(s.detailContent(listOf("a/b"))).getString("id"))
        assertEquals("2", JSONObject(s.searchContent("关键", false, "2")).getString("pg"))
        assertEquals(2, JSONObject(s.playerContent("f", "u", listOf("a", "b"))).getInt("n"))
        val p = s.proxyLocal(mapOf("a" to "1"))!!
        assertEquals(206, p.code); assertEquals("ab中", p.body.readBytes().toString(Charsets.UTF_8)); assertEquals("1", p.headers["X-A"]); assertEquals("video/mp2t", p.type)
        assertTrue(s.isVideoFormat("x")); assertTrue(s.manualVideoCheck()); assertEquals("", s.action("nothing"))
    }

    @Test fun catVodStyleAsyncAndTimers() {
        val s = spider("""
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
        """, """{"a":7}""")
        files["https://s.example/page"] = """<html><body><ul class="list"><li><a href="/1">一<b>号</b></a><img data-src="p1"></li><li><a href="/2">二</a></li></ul></body></html>"""
        val h = JSONObject(s.homeContent(true))
        assertEquals("站点:3:7", h.getString("skey")); assertEquals("一号", h.getJSONArray("list").getJSONObject(0).getString("vod_name")); assertEquals("p1", h.getJSONArray("list").getJSONObject(0).getString("vod_pic"))
        assertEquals(2, h.getJSONArray("cookies").length()); assertEquals("0cc175b9c0f1b6a831c399e269772661", h.getString("md5")); assertEquals(" b", h.getString("q")); assertEquals("2026/01/02 03:04", h.getString("y"))
        assertEquals("b", requests.last { it.url.endsWith("/page") }.headers["A"])
        assertTrue(assertThrows(ProviderException::class.java) { s.detailContent(listOf("1")) }.message!!.contains("坏了"))
        assertTrue(assertThrows(ProviderException::class.java) { s.categoryContent("1", "1", true, emptyMap()) }.message!!.contains("没有返回结果"))
    }

    @Test fun requestsBodiesAndBinaryReplies() {
        val s = spider("""
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
        listOf("post", "form", "raw").forEach { files["https://s.example/$it"] = "" }
        files["https://s.example/bin"] = "AB"; files["https://s.example/page2"] = "two"; files["https://s.example/json"] = """{"v":"值"}"""
        val h = JSONObject(s.homeContent(false))
        assertEquals("QUI=", h.getString("b64")); assertEquals(listOf(65, 66), h.getJSONArray("arr").toList()); assertEquals("", h.getString("bad")); assertEquals(0, h.getInt("code")); assertEquals(listOf("AB", "two"), h.getJSONArray("list").toList())
        val post = requests.first { it.url.endsWith("/post") }; assertEquals("""{"a":1}""", post.body!!.toString(Charsets.UTF_8)); assertEquals("application/json", post.headers["Content-Type"])
        assertEquals("a=%E4%B8%AD+%E6%96%87&b=2", requests.first { it.url.endsWith("/form") }.body!!.toString(Charsets.UTF_8))
        val raw = requests.first { it.url.endsWith("/raw") }; assertEquals("x=1", raw.body!!.toString(Charsets.UTF_8)); assertEquals(false, raw.redirect); assertEquals(1234, raw.timeoutMs); assertEquals("text/plain", raw.headers["Content-Type"])
        val r = JSONObject(s.searchContent("k", false, "1"))
        assertEquals("值", r.getString("v")); assertEquals("https://h.example/p/x?a=9&b=2#h", r.getString("href")); assertEquals("h.example", r.getString("host")); assertEquals("值", r.getString("d")); assertEquals("中", r.getString("dec")); assertEquals("ok", r.getString("b"))
        assertEquals(listOf(0xc3, 0xa9, 0xf0, 0x9f, 0x98, 0x80), r.getJSONArray("enc").toList())
    }

    @Test fun drpyToolbox() {
        val s = spider("""
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
              return { ct, same, back: aesX('AES/CBC/PKCS7', false, ct, true, aesKey, iv, false), pass, md5: md5X('a'), gz: ungzip(gzip('压缩')), pako: pako.ungzip(pako.gzip('pk'), { to: 'string' }), pako2: pako.inflate(pako.deflate('zl'), { to: 'string' }), gbk: g.encode('中 a'), ungbk: g.decode('%D6%D0'), des: desX('DESede/ECB/PKCS7', false, desX('DESede/ECB/PKCS7', true, 'd', false, 'k1k2k3k4k5k6k7k8k9k0k1k2', '', true), true, 'k1k2k3k4k5k6k7k8k9k0k1k2', '', false), proxy: getProxy(true), js2: js2Proxy(true, 3, 'k', 'http://a/b?c=1', { A: 'b' }) };
            }
            export function detail() {
              const $ = cheerio.load(html);
              const own = $('li').eq(0).find('span').clone().children().remove().end().text();
              return { own, kept: $('li').eq(0).find('span').text(), sib: $('li.on').next().find('a').attr('href'), up: $('img').closest('li').hasClass('on'), idx: $('li').last().index(), kids: $('ul').children('li').length, each: $('li a').toArray().map(e => e.attribs.href), node: $('span').contents().filter(function () { return this.nodeType === 3; }).text(), html: $('#box').html(), not: $('li').not('.on').length, is: $('li').first().is('.on'), par: $('a').parent('li').length, all: $('li').slice(1).length, str: $('em') + '' };
            }
        """)
        val h = JSONObject(s.homeContent(true))
        assertEquals(3, h.getInt("a")); assertEquals("乙", h.getString("t")); assertEquals("甲", h.getString("attr")); assertEquals("丙", h.getString("last")); assertEquals("https://h.example/p/1.jpg", h.getString("u")); assertEquals("https://o.example/2", h.getString("u2"))
        assertEquals("备注", h.getString("ex")); assertEquals("https://h.example/b.png", h.getString("style")); assertEquals("t", h.getString("inner")); assertEquals("t", h.getString("alt")); assertEquals("https://h.example/v/1", h.getJSONArray("l").getString(0).substringAfter('$')); assertEquals(2, h.getInt("gt"))
        assertEquals("https://h.example/c?d=1", h.getString("join")); assertEquals(listOf("x", "y"), h.getJSONArray("jp").toList()); assertEquals(2, h.getJSONArray("jp2").length()); assertEquals(2, h.getJSONArray("jp3").getInt(0))
        assertEquals("/list/1/cn-2026.1.2", h.getString("jinja")); assertEquals("x", h.getJSONObject("j5").getString("a")); assertTrue(h.getBoolean("muban"))
        val c = JSONObject(s.searchContent("", false, "1"))
        assertEquals(c.getString("same"), c.getString("ct")); assertEquals("明文", c.getString("back")); assertEquals("pw", c.getString("pass")); assertEquals("压缩", c.getString("gz")); assertEquals("pk", c.getString("pako")); assertEquals("zl", c.getString("pako2"))
        assertEquals("%D6%D0%20a", c.getString("gbk")); assertEquals("中", c.getString("ungbk")); assertEquals("d", c.getString("des")); assertEquals("http://127.0.0.1:9978/proxy?do=js&siteKey=%E7%AB%99%E7%82%B9", c.getString("proxy")); assertTrue(c.getString("js2").contains("&from=catvod"))
        val d = JSONObject(s.detailContent(listOf("1")))
        assertEquals("备注", d.getString("own")); assertEquals("备注广告", d.getString("kept")); assertEquals("//o.example/2", d.getString("sib")); assertTrue(d.getBoolean("up")); assertEquals(2, d.getInt("idx")); assertEquals(3, d.getInt("kids"))
        assertEquals(listOf("/v/1", "//o.example/2", "http://x.example/3"), d.getJSONArray("each").toList()); assertEquals("备注", d.getString("node")); assertEquals("t", d.getString("html")); assertEquals(2, d.getInt("not")); assertTrue(d.getBoolean("is")); assertEquals(3, d.getInt("par")); assertEquals("<em>广告</em>", d.getString("str"))
    }

    @Test fun rsaFacadesRoundTrip() {
        val pair = java.security.KeyPairGenerator.getInstance("RSA").apply { initialize(1024) }.generateKeyPair()
        val pub = java.util.Base64.getEncoder().encodeToString(pair.public.encoded); val pri = java.util.Base64.getEncoder().encodeToString(pair.private.encoded)
        val s = spider("""
            import 'assets://js/lib/jsencrypt.js';
            import NodeRSA from 'assets://js/lib/node-rsa.js';
            export function home() {
              const e = new JSEncrypt(); e.setPublicKey('$pub'); const d = new JSEncrypt(); d.setPrivateKey('-----BEGIN PRIVATE KEY-----\n$pri\n-----END PRIVATE KEY-----');
              const long = '长'.repeat(100), n = new NodeRSA('$pub', 'public'), m = new NodeRSA('$pri', 'private');
              return { s: d.decrypt(e.encrypt('短')), l: d.decryptLong(e.encryptLong(long)) === long, v: e.verify('x', d.sign('x')), bad: e.verify('y', d.sign('x')), x: rsaX('RSA/PKCS1', false, false, rsaX('RSA/PKCS1', true, true, 'rx', false, '$pub', true), true, '$pri', false), n: m.decrypt(n.encrypt('nr', 'base64'), 'utf8') };
            }
        """)
        val h = JSONObject(s.homeContent(false))
        assertEquals("短", h.getString("s")); assertTrue(h.getBoolean("l")); assertTrue(h.getBoolean("v")); assertEquals(false, h.getBoolean("bad")); assertEquals("rx", h.getString("x")); assertEquals("nr", h.getString("n"))
    }

    /** drpy engines load their rule text with a direct eval that assigns a module variable. */
    @Test fun rulesAreEvaluatedInsideTheModule() {
        files["https://s.example/rule.js"] = "var rule = { title: '规则', host: 'https://h.example', 一级: 'ul&&li;a&&Text' };"
        val s = spider("""
            let rule = {};
            function init(ext) { const js = req(ext).content; eval('(function(){' + js.replace('var rule', 'rule') + '})()'); }
            export default { init, home: () => JSON.stringify({ t: rule.title, l: rule.一级.split(';').length }) };
        """, "https://s.example/rule.js")
        val h = JSONObject(s.homeContent(true))
        assertEquals("规则", h.getString("t")); assertEquals(2, h.getInt("l"))
    }

    @Test fun modulesResolveAndFailuresAreReadable() {
        files["https://s.example/lib/util.js"] = "export const v = 'rel';"
        assertEquals("rel", JSONObject(spider("import { v } from '../lib/util.js'; import m from './模板.js'; export default function () { return { home: () => ({ v, m: !!m.muban }) }; }").homeContent(true)).getString("v"))
        assertEquals("""{"g":1}""", spider("__JS_SPIDER__ = { home() { return { g: 1 }; } };").homeContent(true))
        fun fails(src: String, api: String = "https://s.example/js/site.js") = assertThrows(ProviderException::class.java) { spider(src, "", api) }.message!!
        assertTrue(fails("//bb0123456").contains("字节码"))
        assertTrue(fails("import x from './missing.js'; export default {};").contains("missing.js"))
        assertTrue(fails("export const nothing = 1;").contains("没有导出"))
        assertTrue(fails("throw new Error('炸了')").contains("炸了"))
        assertTrue(fails("export default { home( }").contains("脚本加载失败"))
        files["https://s.example/web.js"] = "<!DOCTYPE html><html>"
        assertTrue(fails("<!DOCTYPE html><html>", "https://s.example/web.js").contains("网页"))
    }

    @Test fun hostErrorsReachTheScript() {
        val s = spider("""export function home() { try { __tvCall('cipher', { alg: 'aes', mode: 'cbc', pad: 'pkcs7', encrypt: false, keyB64: 'YWJjZGVmZ2hhYmNkZWZnaA==', dataB64: 'AAAA' }); } catch (e) { return { e: e.message.length > 0, x: __tvCall('html.xpath', { id: __tvCall('html.load', { html: '<a href="1">t</a>' }), q: '//a/@href' }) }; } }""")
        val h = JSONObject(s.homeContent(true))
        assertTrue(h.getBoolean("e")); assertEquals("1", (h.get("x") as JSONArray).getJSONObject(0).getString("s"))
    }
}
