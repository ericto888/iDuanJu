package app.iduanju.core.tvbox

import app.iduanju.core.util.Bytes
import app.iduanju.core.util.J
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.TimeZone
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

class TVBoxConfigTest {
    private val plain = """{"sites":[{"key":"a","name":"站点","type":1,"api":"http://1.2.3.4:8080/api"}]}"""
    private fun pad(s: String) = (s + "0000000000000000").substring(0, 16)

    private fun config(text: String, base: String = "https://h.example/dir/cfg.json") = (TVBoxConfig.parse(text, base) as ParsedConfig.Config).config

    @Test fun decryptsCbcHexConfigs() {
        val key = "abc123"; val iv = "1700000000000" // the last 13 characters
        val c = Cipher.getInstance("AES/CBC/PKCS5Padding").apply { init(Cipher.ENCRYPT_MODE, SecretKeySpec(pad(key).toByteArray(), "AES"), IvParameterSpec(pad(iv).toByteArray())) }
        val hex = Bytes.hex("$#$key#$".toByteArray()) + Bytes.hex(c.doFinal(plain.toByteArray())) + Bytes.hex(iv.toByteArray())
        assertTrue(hex.startsWith("2423"))
        assertEquals(plain, TVBoxDecoder.decode(hex))
        // the same text hidden behind the Base64 marker of a picture
        val carried = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 2, 3) + ("xyzAbCd1234**" + Bytes.b64(hex.toByteArray())).toByteArray()
        assertEquals(plain, TVBoxDecoder.decode(carried))
        assertThrows(LenientJson.Malformed::class.java) { TVBoxDecoder.decode(hex.dropLast(40)) }
    }

    @Test fun picturesCarryJars() {
        val jar = byteArrayOf('P'.code.toByte(), 'K'.code.toByte(), 3, 4) + ByteArray(300) { (it * 7).toByte() }
        val picture = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0, 1) + ByteArray(200) { (it * 31).toByte() } + ("\nqwerTY12**" + Bytes.b64(jar) + "\n").toByteArray()
        assertTrue(jar.contentEquals(TVBoxDecoder.carried(picture)!!))
        assertNull(TVBoxDecoder.carried(byteArrayOf(1, 2, 3)))
        assertEquals("https://h.example/Md5.txt", SpiderRef.parse("https://h.example/a.jar;md5;https://h.example/Md5.txt").md5)
    }

    @Test fun decryptsEcbConfigsWithTheAddressKey() {
        val (url, key) = TVBoxDecoder.splitKey("https://h.example/c.json;pk;secret")
        assertEquals("https://h.example/c.json", url)
        val c = Cipher.getInstance("AES/ECB/PKCS5Padding").apply { init(Cipher.ENCRYPT_MODE, SecretKeySpec(pad(key).toByteArray(), "AES")) }
        assertEquals(plain, TVBoxDecoder.decode(Bytes.hex(c.doFinal(plain.toByteArray())), key))
        assertThrows(LenientJson.Malformed::class.java) { TVBoxDecoder.decode(Bytes.hex(c.doFinal(plain.toByteArray())), "wrong") }
    }

    @Test fun readsTheFullFieldModelAndTolerantTypes() {
        val c = config("""
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
             "rules":[{"name":"新","hosts":["v.example"],"regex":["master,m3u8"],"exclude":["ad"],"script":["1"]},{"host":"www.old.example","rule":["\\.php\\?x="]},{"host":"*","filter":["/ads/"]},{"name":"空"}]}
        """.trimIndent())
        assertEquals("https://h.example/dir/jar/a.jar", SpiderRef.parse(c.spider).url)
        assertEquals("https://h.example/dir/l.png", c.logo); assertEquals("提示", c.notice)
        assertEquals(listOf("js", "jar", "py", "t4", "x", "无 key"), c.sites.map { it.key })
        val (js, jar, py, t4) = c.sites
        assertEquals(SiteKind.Js, js.kind); assertEquals("https://h.example/dir/js/rule.js", js.ext); assertFalse(js.searchable); assertTrue(js.filterable); assertEquals(30_000, js.timeoutMs); assertEquals(listOf("电影", "剧集"), js.categories)
        assertEquals("https://h.example/x.json", JSONObject(jar.ext).getString("site")); assertEquals("https://h.example/dir/y.txt", JSONObject(jar.ext).getJSONArray("list").getString(0))
        assertEquals("https://h.example/dir/b.jar", c.jarOf(jar)); assertEquals(mapOf("User-Agent" to "U1"), jar.headers); assertEquals(c.spider, c.jarOf(js)); assertFalse(jar.changeable)
        assertEquals("https://h.example/dir/py/demo.py" to "", PySpider.script(py.api, py.ext))
        assertEquals("https://t4.example/api", t4.api); assertTrue(c.sites[4].adult)
        assertEquals(SiteKind.CmsXml, c.sites[5].kind)
        assertTrue(c.hasCode)
        assertEquals(listOf("聚合", "json", "web"), c.parses.map { it.name }); assertEquals(listOf("qq", "qiyi"), c.parses[1].flags); assertEquals("P", c.parses[1].headers["User-Agent"])
        assertEquals(mapOf("a.example" to "1.2.3.4"), c.hosts); assertEquals("v.example", c.headers.single().host); assertEquals(listOf("阿里"), c.doh.map { it.name })
        assertEquals(3, c.rules.size); assertTrue(c.rules[1].matches("www.old.example")); assertTrue(c.rules[2].matches("any.example")); assertEquals(listOf("master,m3u8"), c.rules[0].regex)
    }

    @Test fun depotsAreListedAndMayNestOnce() {
        val a = TVBoxConfig.parse("""{"storeHouse":[{"sourceName":"仓一","sourceUrl":"./one.json"},{"sourceName":"坏","sourceUrl":""}]}""", "https://h.example/d/x.json") as ParsedConfig.Depot
        assertEquals(listOf(TVBoxDepotEntry("仓一", "https://h.example/d/one.json")), a.entries)
        val b = TVBoxConfig.parse("""{"urls":[{"url":"http://a.example/1","name":"线路1"},{"url":"http://a.example/1","name":"重复"},{"url":"http://b.example/2"}]}""", "https://h.example/x.json") as ParsedConfig.Depot
        assertEquals(listOf("线路1", "b.example"), b.entries.map { it.name })
        // a nested depot is again a depot; a single config with sites is never mistaken for one
        assertTrue(TVBoxConfig.parse("""{"urls":[{"url":"x","name":"y"}],"sites":[{"key":"k","api":"https://a.example","type":1}]}""", "") is ParsedConfig.Config)
    }

    @Test fun messagesAndForeignContentAreReadableErrors() {
        assertEquals("账号已过期", assertThrows(LenientJson.Malformed::class.java) { TVBoxConfig.parse("""{"code":500,"msg":"账号已过期"}""", "") }.message)
        assertTrue(assertThrows(LenientJson.Malformed::class.java) { TVBoxConfig.parse("<!DOCTYPE html><html></html>", "") }.message!!.contains("网页"))
        assertTrue(assertThrows(LenientJson.Malformed::class.java) { TVBoxConfig.parse("""{"sites":[],"spider":""}""", "") }.message!!.contains("没有点播站点"))
        assertThrows(LenientJson.Malformed::class.java) { TVBoxConfig.parse("hello", "") }
        assertTrue(TVBoxConfig.parse("#EXTM3U\n#EXTINF:-1,A\nhttp://a.example/1.m3u8", "") is ParsedConfig.Live)
        assertTrue(TVBoxConfig.parse("央视,#genre#\nCCTV1,http://a.example/1", "") is ParsedConfig.Live)
        assertTrue(TVBoxConfig.parse("# 注释\n{\"lives\":[{\"name\":\"a\",\"url\":\"http://a.example/l.txt\"}]}", "") is ParsedConfig.Config)
        assertTrue(TVBoxConfig.parse("""[{"group":"g","channel":[{"name":"n","urls":["http://a.example/1"]}]}]""", "") is ParsedConfig.Live)
    }

    @Test fun liveVariants() {
        val b64 = Bytes.b64("https://l.example/list.txt".toByteArray())
        val c = config("""{"lives":[
            {"group":"redirect","channels":[{"name":"轮播","urls":["proxy://do=live&type=txt&ext=$b64"]}]},
            {"name":"新版","type":0,"url":"./tv.m3u","epg":"https://e.example/?ch={name}&date={date}","ua":"U","referer":"https://r.example","timeout":20},
            {"name":"包","type":3,"api":"csp_Live","ext":"x"},
            {"name":"内嵌","groups":[{"name":"g","pass":"1","channel":[{"name":"n","urls":["http://a.example/1"],"ua":"C"}]}]},
            {"group":"央视","channels":[{"name":"CCTV1","urls":["http://a.example/cctv1"]}]}]}""")
        assertEquals(listOf("配置直播", "轮播", "新版", "包", "内嵌"), c.lives.map { it.name })
        assertEquals("https://l.example/list.txt", c.lives[1].url)
        assertEquals("https://h.example/dir/tv.m3u", c.lives[2].url); assertEquals(mapOf("User-Agent" to "U", "Referer" to "https://r.example"), c.lives[2].requestHeaders); assertEquals(20_000, c.lives[2].timeoutMs)
        assertEquals(SiteKind.Jar, c.lives[3].kind); assertTrue(c.hasCode)
        assertEquals("1", c.lives[4].groups.single().pass); assertEquals("C", c.lives[4].groups.single().channels.single().headers["User-Agent"])
        assertEquals("CCTV1", c.lives[0].groups.single().channels.single().name)
        assertEquals("https://p.example/l?a=1", TVBoxConfig.proxyLive("proxy://do=live&ext=https%3A%2F%2Fp.example%2Fl%3Fa%3D1"))
    }

    @Test fun textListDirectivesPasswordsAndMergedLines() {
        val l = LiveParser.parse("ua=UA 1\nA,http://a.example/1\n分组_pw,#genre#\nheader={\"Referer\":\"https://r.example/\"}\nparse=1\nB,https://b.example/page#frag#https://b.example/2\$备用\n")
        assertEquals(listOf("默认分组", "分组"), l.groups.map { it.name })
        assertEquals(mapOf("User-Agent" to "UA 1"), l.groups[0].channels.single().headers)
        val b = l.groups[1].channels.single()
        assertEquals("pw", l.groups[1].pass); assertEquals(listOf("https://b.example/page#frag", "https://b.example/2\$备用"), b.urls); assertTrue(b.parse); assertEquals("https://r.example/", b.headers["Referer"])
        assertEquals("", LiveParser.parse("分组_pw,#genre#\nB,https://b.example/1", skipPass = true).groups.single().pass)
        val m = LiveParser.parse("#EXTM3U url-tvg=\"https://e.example/a.xml.gz\"\n#EXTINF:-1 group-title=\"G;H\" tvg-logo=\"l\",名称, 带逗号\n#KODIPROP:inputstream.adaptive.manifest_type=mpd\n#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=k1:k2\n#EXTHTTP:{\"Cookie\":\"a=1\"}\nhttps://a.example/x\n#EXTINF:-1,无分组\n#EXTGRP:组\nrtp://239.1.1.1:5000\n")
        assertEquals("https://e.example/a.xml.gz", m.epg)
        val x = m.groups[0].channels.single()
        assertEquals("G", m.groups[0].name); assertEquals("名称, 带逗号", x.name); assertEquals("application/dash+xml", x.format); assertEquals(mapOf("type" to "clearkey", "key" to "k1:k2"), x.drm); assertEquals("a=1", x.headers["Cookie"])
        assertEquals("组", m.groups[1].name)
        val media = JSONObject(x.mediaJSON(mapOf("User-Agent" to "L"), "https://e.example/a.xml.gz"))
        assertEquals("L", media.getJSONObject("headers").getString("User-Agent")); assertEquals("https://e.example/a.xml.gz", media.getString("epg")); assertEquals(1, media.getJSONArray("urls").length())
    }

    @Test fun catchupTemplates() {
        val utc = TimeZone.getTimeZone("UTC")
        val start = 1_767_225_600_000L // 2026-01-01T00:00:00Z
        val end = start + 3_600_000
        fun url(c: Catchup, s: String) = c.url(s, start, end, end + 60_000, utc)
        assertEquals("http://a.example/1.m3u8?playseek=20260101000000-20260101010000", url(Catchup("append", "?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}"), "http://a.example/1.m3u8"))
        assertEquals("http://a.example/1?x=1&b=1767225600", url(Catchup("append", "?b={utc}"), "http://a.example/1?x=1"))
        assertEquals("http://r.example/1767225600/1767229200/3600/60", url(Catchup("default", "http://r.example/{utc}/{utcend}/{duration}/{duration:60}"), "http://a.example/1"))
        assertEquals("http://a.example/1?utc=1767225600&lutc=1767229260", url(Catchup("shift", ""), "http://a.example/1"))
        assertEquals("http://a.example/ch/index-1767225600-3600.m3u8?token=t", url(Catchup("flussonic", ""), "http://a.example/ch/index.m3u8?token=t"))
        assertEquals("http://h.example:80/timeshift/u/p/60/2026-01-01:00-00/12.ts", url(Catchup("xc", ""), "http://h.example:80/live/u/p/12.ts"))
        assertEquals("http://a.example/2026/01/01/00", url(Catchup("append", "{Y}/{m}/{d}/{H}"), "http://a.example/"))
        assertEquals("rtsp://h.example/TVOD/1?playseek=20260101000000-20260101010000", url(Catchup.implied("rtsp://h.example/PLTV/1")!!, "rtsp://h.example/PLTV/1"))
        assertNull(Catchup.implied("http://a.example/1")); assertNull(url(Catchup("default", ""), "http://a.example/1"))
        assertEquals(Catchup("append", "?x", 7, "a,b"), Catchup.fromJSON(Catchup("append", "?x", 7, "a,b").toJSON()))
    }

    @Test fun programmeGuides() {
        val z = TimeZone.getTimeZone("Asia/Shanghai")
        val day = EpgParser.json("""{"epg_data":[{"title":"新闻","start":"23:30","end":"00:30"},{"title":"","start":"01:00","end":"02:00"},{"title":"早间","start":"06:00","end":"07:00","desc":"d"}]}""", "2026-11-25", z)
        assertEquals(listOf("早间", "新闻"), day.map { it.title }); assertEquals(3_600_000, day.last().let { it.end - it.start })
        val (now, next) = EpgService.nowNext(day, day[0].start + 1000)
        assertEquals("早间", now?.title); assertEquals("新闻", next?.title)
        val xml = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE tv SYSTEM "xmltv.dtd"><tv><channel id="1"><display-name lang="zh">CCTV-1 综合</display-name></channel><channel id="2"><display-name>其他</display-name></channel>
            <programme start="20261125080000 +0800" stop="20261125090000 +0800" channel="1"><title lang="zh">朝闻</title><desc>x</desc></programme>
            <programme start="20261125080000" stop="20261125090000" channel="2"><title>不要</title></programme></tv>"""
        val at = 1_795_564_800_000L
        val map = EpgParser.xmltv(xml.byteInputStream(), setOf(EpgParser.key("cctv1综合")), at - 30L * 86_400_000, at + 30L * 86_400_000, z)
        assertEquals(setOf("cctv1综合"), map.keys); assertEquals("朝闻", map.values.single().single().title)
        assertEquals("2026-11-25", EpgParser.day(map.values.single().single().start, z))
    }

    @Test fun vodMappingFoldersFiltersAndContentRules() {
        val o = JSONObject("""{"class":[{"type_id":1,"type_name":"电影"},{"type_id":"2","type_name":"小学生"},{"type_id":"3","type_name":"剧集"}],
            "filters":{"1":[{"key":"area","name":"地区","init":"cn","value":[{"n":"全部","v":""},{"n":"大陆","v":"cn"}]}]},
            "list":[{"vod_id":"a/b%c","vod_name":"片 &amp; 名","vod_pic":"//i.example/1.jpg","vod_remarks":"更新","vod_tag":"file"},{"vod_id":"f","vod_name":"目录","vod_tag":"folder"},{"vod_id":"","vod_name":"无"},{"vod_id":"z","vod_name":"萝莉"}]}""")
        val h = VodMapper.home(o, "u1", listOf("剧集", "电影", "没有"), { if (it.startsWith("//")) "https:$it" else it })
        assertEquals(listOf("剧集", "电影"), h.categories.map { it.name }); assertEquals("cn", h.filters["1"]!!.single().initial)
        assertEquals(listOf("片 & 名", "目录"), h.items.map { it.title }); assertTrue(h.items[1].folder); assertEquals("https://i.example/1.jpg", h.items[0].cover); assertEquals("tvb:u1:a/b%c", h.items[0].sid)
        assertEquals(TVBoxId.Vod("u1", "a/b%c"), TVBoxId.parseVod("tvb:u1:a/b%c"))
        assertEquals(TVBoxId.Ep("u1", "{\"x\":\"#1#2\"}", 0, 12), TVBoxId.parseEpisode(TVBoxId.episode("u1", "{\"x\":\"#1#2\"}", 0, 12)))
        val d = VodMapper.detail(JSONObject().put("list", JSONArray().put(JSONObject().put("vod_name", "剧").put("vod_content", "<p>简介&nbsp;一</p>").put("vod_year", "2026").put("vod_actor", "甲,乙").put("vod_play_from", "qq$$\$m3u8").put("vod_play_url", "1\$abc#2\$def$$\$正片\$https://v.example/1.m3u8"))), "u1", "id1", TVBoxSite("k", "站", 1, ""), { it })
        assertEquals(2, d.lines.size); assertEquals(d.lines[0].episodes, d.episodes); assertEquals("tvb:u1:id1#1#0", d.lines[1].episodes.single().vid)
        assertEquals("qq", JSONObject(d.episodes[0].media!!).getString("f")); assertEquals("abc", JSONObject(d.episodes[0].media!!).getString("id")); assertEquals(listOf("甲", "乙"), d.actors); assertTrue(d.desc.contains("简介"))
        assertFalse(VodMapper.page(JSONObject("""{"list":[{"vod_id":"1","vod_name":"a"}],"page":2,"pagecount":2}"""), "u", 2) { it }.hasMore)
        assertTrue(VodMapper.page(JSONObject("""{"list":[{"vod_id":"1","vod_name":"a"}]}"""), "u", 1) { it }.hasMore)
        assertEquals("http://127.0.0.1:9980/proxy?do=js&a=1&siteKey=k+1", VodMapper.localProxy("proxy://do=js&a=1", 9980, "k 1"))
        assertEquals("http://127.0.0.1:9980/proxy?do=bili", VodMapper.localProxy("http://127.0.0.1:9978/proxy?do=bili", 9980, ""))
    }

    @Test fun storeV1BecomesV2WithoutLosingChoices() {
        val v1 = JSONObject("""{"activeRepoId":"r1","favoriteChannels":["CCTV1"],"repos":[
            {"id":"r1","name":"仓","url":"https://h.example/c.json","updatedAt":5,"sites":[{"key":"k1","name":"站","api":"https://cms.example/api.php/provide/vod/","enabled":false,"categories":[]},{"key":"k2","name":"二","api":"https://b.example/api"}],"lives":[{"id":"l1","name":"直播","url":"https://l.example/a.m3u","enabled":false}]},
            {"id":"r2","name":"本地","url":"","sites":[],"lives":[{"name":"粘贴","url":"","channels":[{"name":"A","group":"G","urls":["https://a.example/1"]}]}]}],
            "recentWatches":[{"siteKey":"k2","seriesId":"cms:k2:42","title":"剧","cover":"c","episodeIndex":3,"positionMs":61000,"durationMs":100000,"updatedAt":9},{"siteKey":"gone","seriesId":"cms:gone:1"}]}""")
        val m = TVBoxState.migrateV1(v1)
        assertEquals("r1", m.state.active); assertEquals(listOf("CCTV1"), m.state.favorites)
        val r = m.state.repos.first()
        assertEquals(setOf(TVBoxConfig.siteUid("r1", "k1"), TVBoxConfig.liveUid("r1", "https://l.example/a.m3u")), r.disabled); assertEquals(Trust.Ask, r.trust)
        val c = config(m.configs["r1"]!!)
        assertEquals(listOf("k1", "k2"), c.sites.map { it.key }); assertEquals("https://l.example/a.m3u", c.lives.single().url)
        assertEquals("A", config(m.configs["r2"]!!).lives.single().groups.single().channels.single().name)
        val w = m.watches.single()
        assertEquals("tvb:${TVBoxConfig.siteUid("r1", "k2")}:42", w.sid); assertEquals(3, w.episodeIndex); assertEquals(61_000, w.positionMs)
        // first refresh: the real config names the same site differently
        val fresh = config("""{"sites":[{"key":"real","name":"站二","type":1,"api":"http://b.example/api/"}]}""")
        assertEquals(mapOf(TVBoxConfig.siteUid("r1", "k2") to TVBoxConfig.siteUid("r1", "real")), TVBoxState.aliases(r, fresh))
        val round = TVBoxState.fromJSON(JSONObject(m.state.copy(unlocked = mapOf("u" to setOf("g")), allowLan = true, bridgeCode = "ABCD2345", latency = mapOf("x" to 12)).toJSON().toString()))
        assertEquals(m.state.repos, round.repos); assertEquals(setOf("g"), round.unlocked["u"]); assertTrue(round.allowLan); assertEquals(12, round.latency["x"]); assertEquals(2, J.int(round.toJSON().opt("v")))
    }
}
