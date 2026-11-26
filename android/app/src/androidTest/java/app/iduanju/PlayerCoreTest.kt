package app.iduanju

import androidx.test.ext.junit.runners.AndroidJUnit4
import app.iduanju.core.cenc.CENCDecryptor
import app.iduanju.core.hongguo.HGDanmaku
import app.iduanju.core.hongguo.HGEpisode
import app.iduanju.core.hongguo.HGStreamKind
import app.iduanju.ui.components.EpisodeNames
import app.iduanju.ui.player.CencLayout
import app.iduanju.ui.player.ExternalDanmaku
import app.iduanju.ui.player.MediaKind
import app.iduanju.ui.player.MediaKinds
import app.iduanju.ui.player.RangeSet
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.util.Random
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Offline checks of the unified player's media core. */
@RunWith(AndroidJUnit4::class)
class PlayerCoreTest {
    private val key = ByteArray(16) { (it * 7 + 3).toByte() }
    private val hex = key.joinToString("") { "%02x".format(it) }
    private fun be(n: Int) = ByteBuffer.allocate(4).putInt(n).array()
    private fun box(t: String, b: ByteArray) = be(b.size + 8) + t.toByteArray() + b
    private fun full(t: String, b: ByteArray, flags: Int = 0) = box(t, be(flags) + b)
    private fun join(l: List<ByteArray>): ByteArray = java.io.ByteArrayOutputStream().also { o -> l.forEach { o.write(it) } }.toByteArray()

    private fun encrypted(samples: Int): ByteArray {
        val r = Random(7)
        val sizes = IntArray(samples) { 20 + r.nextInt(4000) }
        val ivs = List(samples) { ByteArray(8).also(r::nextBytes) }
        val media = List(samples) { i ->
            val plain = ByteArray(sizes[i]).also(r::nextBytes)
            Cipher.getInstance("AES/CTR/NoPadding").run { init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(ivs[i].copyOf(16))); doFinal(plain) }
        }
        fun moov(base: Int): ByteArray {
            val tenc = full("tenc", byteArrayOf(0, 0, 1, 8) + ByteArray(16))
            val sinf = box("sinf", box("frma", "avc1".toByteArray()) + full("schm", "cenc".toByteArray() + be(65536)) + box("schi", tenc))
            val stbl = full("stsd", be(1) + box("encv", ByteArray(78) + sinf)) + full("stsz", be(0) + be(samples) + join(sizes.map(::be))) +
                full("stsc", be(1) + be(1) + be(samples) + be(1)) + full("stco", be(1) + be(base)) + full("senc", be(samples) + join(ivs))
            return box("moov", box("trak", full("tkhd", ByteArray(8) + be(1) + ByteArray(68)) + box("mdia", box("minf", box("stbl", stbl)))))
        }
        val ftyp = box("ftyp", "isom".toByteArray() + be(1))
        return ftyp + moov(ftyp.size + moov(0).size + 8) + box("mdat", join(media))
    }

    @Test fun streamingDecryptEqualsWholeFileDecrypt() {
        val file = encrypted(120)
        val expect = CENCDecryptor.decryptCopy(file, hex)
        val at = 16
        val size = ByteBuffer.wrap(file, at, 4).int
        val layout = CencLayout.parse(file.copyOfRange(at, at + size), at.toLong(), hex) { _, _ -> error("aux info is inline") }!!
        val out = file.copyOf()
        val r = Random(1)
        var p = 0
        while (p < out.size) { val n = minOf(1 + r.nextInt(9000), out.size - p); layout.apply(p.toLong(), out, p, n); p += n }
        assertArrayEquals(expect, out)
        repeat(100) {
            val a = r.nextInt(file.size); val n = minOf(1 + r.nextInt(3000), file.size - a)
            val part = file.copyOfRange(a, a + n)
            layout.apply(a.toLong(), part, 0, n)
            assertArrayEquals(expect.copyOfRange(a, a + n), part)
        }
    }

    @Test fun rangesMerge() {
        val s = RangeSet()
        s.add(0, 10); s.add(20, 30); s.add(8, 20)
        assertEquals(30L, s.available(0)); assertEquals(30L, s.firstMissing(3)); assertTrue(s.covers(30)); assertFalse(s.covers(31))
    }

    @Test fun containerIsPickedBeforeOpening() {
        assertEquals(MediaKind.Hls, MediaKinds.guess("https://a/b/index.m3u8?x=1"))
        assertEquals(MediaKind.Hls, MediaKinds.guess("https://a/play?url=https%3A//x/y.m3u8"))
        assertEquals(MediaKind.Hls, MediaKinds.guess("https://a/b", "application/x-mpegURL"))
        assertEquals(MediaKind.Hls, MediaKinds.guess("https://a/b", null, HGStreamKind.hls))
        assertEquals(MediaKind.Dash, MediaKinds.guess("https://a/b.mpd"))
        assertEquals(MediaKind.Ss, MediaKinds.guess("https://a/b.ism/Manifest"))
        assertEquals(MediaKind.Rtsp, MediaKinds.guess("rtsp://a/b"))
        assertEquals(MediaKind.Progressive, MediaKinds.guess("rtmp://a/live/1"))
        assertEquals(MediaKind.Progressive, MediaKinds.guess("http://a/live.flv"))
        assertNull(MediaKinds.guess("http://a:8080/live/1"))
        assertNull(MediaKinds.guess("http://a/play", "application/octet-stream"))
    }

    @Test fun externalCommentsParse() {
        val xml = ExternalDanmaku.parse("""<?xml version="1.0"?><i><d p="12.5,1,25,16711680,0,0,0,0">你好 &amp; 再见</d><d p="3,5,25,255,0">顶部</d></i>""")
        assertEquals(listOf(3.0, 12.5), xml.map { it.time })
        assertEquals("你好 & 再见", xml[1].text)
        assertEquals("#FF0000", xml[1].color)
        assertEquals(HGDanmaku.Mode.top, xml[0].mode)
        val json = ExternalDanmaku.parse("""{"code":0,"danmuku":[[1.5,"right","#fff","","弹幕"]]}""")
        assertEquals("弹幕", json.single().text)
        assertEquals("#ffffff", json.single().color)
        // broken times fall out, the rest stays
        assertEquals(listOf("好"), ExternalDanmaku.parse("""{"danmuku":[[NaN,"right","#fff","","坏"],[Infinity,"right","#fff","","坏"],[1e300,"right","#fff","","坏"],["x","right","#fff","","坏"],[2,"right","#fff","","好"]]}""").map { it.text })
        assertEquals(listOf("好"), ExternalDanmaku.parse("""<i><d p="Infinity,1,25,0">坏</d><d p="NaN,1">坏</d><d p="-1,1">坏</d><d p="1e300,1">坏</d><d p="">坏</d><d p="4,99,x,99999999999999999999">好</d></i>""").map { it.text })
    }

    @Test fun episodeTitles() {
        assertFalse(EpisodeNames.textual(listOf(HGEpisode(1, "a", title = "第01集"), HGEpisode(2, "b", title = "2"))))
        assertTrue(EpisodeNames.textual(listOf(HGEpisode(1, "a", title = "HD中字"))))
        assertEquals("第 3 集", EpisodeNames.full(HGEpisode(3, "a", title = "第3集")))
        assertEquals("正片", EpisodeNames.full(HGEpisode(1, "a", title = "正片")))
    }
}
