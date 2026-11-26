package app.iduanju.core

import app.iduanju.core.cms.TVBoxImport
import app.iduanju.core.tvbox.ParsedConfig
import app.iduanju.core.tvbox.SiteKind
import app.iduanju.core.tvbox.TVBoxConfig
import org.junit.Assert.*
import org.junit.Test

class TVBoxImportTest {
    /** The plugin page still adds HTTPS CMS interfaces only; the TVBox tab keeps every site of the same config. */
    @Test fun pluginPageTakesCmsApisAndTheTVBoxTabTakesEverything() {
        val text = """{"name":"demo","sites":[
            {"key":"cms","name":"CMS","type":1,"api":"http://cms.example/api.php/provide/vod/"},
            {"key":"ip","name":"IP","type":1,"api":"http://1.2.3.4:8080/api.php"},
            {"key":"jar","name":"JAR","type":3,"api":"csp_demo"},
            {"key":"dup","name":"Duplicate","type":1,"api":"https://cms.example/api.php/provide/vod/"}
        ],"spider":"https://example.org/a.jar","lives":[{"name":"L","url":"https://live.example/a.m3u"},{"name":"H","url":"http://live.example/b.m3u"}]}"""
        val c = TVBoxImport.parse(text)
        assertEquals("demo", c.name)
        assertEquals(1, c.sites.size)
        assertEquals("https://cms.example/api.php/provide/vod/", c.sites.single().api)
        assertEquals(3, c.skipped)
        assertEquals(listOf("https://live.example/a.m3u"), c.lives.map { it.url })
        val full = (TVBoxConfig.parse(text, "") as ParsedConfig.Config).config
        assertEquals(listOf(SiteKind.CmsJson, SiteKind.CmsJson, SiteKind.Jar, SiteKind.CmsJson), full.sites.map { it.kind })
        assertEquals("http://1.2.3.4:8080/api.php", full.sites[1].api)
        assertEquals(2, full.lives.size)
    }

    @Test fun importsLargeMixedCatalogAndReadsXmlPlaybackLines() {
        val rows = (0..600).map { """{"key":"s$it","type":3,"api":"csp_$it"}""" } + (0..65).map { """{"key":"c$it","type":0,"api":"https://cms.example/$it"}""" }
        val started = System.nanoTime()
        val config = TVBoxImport.parse("""{"sites":[${rows.joinToString(",")}] }""")
        assertEquals(66, config.sites.size)
        assertEquals(667, (TVBoxConfig.parse("""{"sites":[${rows.joinToString(",")}] }""", "") as ParsedConfig.Config).config.sites.size)
        assertTrue("import never validates over the network", (System.nanoTime() - started) / 1_000_000 < 3_000)
        val xml = """<rss><list pagecount="2"><video><id>42</id><name>海岸</name><dl><dd flag="高清"><![CDATA[第一集${'$'}https://media.example/a.m3u8]]></dd></dl></video></list><class><ty id="7">纪录片</ty></class></rss>"""
        val doc = app.iduanju.core.cms.MacCMSXml.parse(xml)
        assertEquals("42", doc.getJSONArray("list").getJSONObject(0).getString("vod_id"))
        val record = doc.getJSONArray("list").getJSONObject(0)
        assertEquals("https://media.example/a.m3u8", app.iduanju.core.cms.MacCMS.lines(record.getString("vod_play_from"), record.getString("vod_play_url")).single().eps.single().second)
        assertEquals("纪录片", app.iduanju.core.cms.MacCMS.parseCategories(doc).single().name)
        assertThrows(IllegalArgumentException::class.java) { app.iduanju.core.cms.MacCMSXml.parse("<!DOCTYPE rss>" + xml) }
    }

    @Test fun refusesConfigWithoutImportableApi() {
        val e = assertThrows(IllegalArgumentException::class.java) {
            TVBoxImport.parse("""{"sites":[{"type":3,"api":"csp_demo"}],"spider":"x.jar"}""")
        }
        assertTrue(e.message.orEmpty().contains("type=1"))
        assertTrue(assertThrows(IllegalArgumentException::class.java) { TVBoxImport.parse("""{"urls":[{"url":"https://a.example/c.json","name":"a"}]}""") }.message.orEmpty().contains("多仓"))
    }
}
