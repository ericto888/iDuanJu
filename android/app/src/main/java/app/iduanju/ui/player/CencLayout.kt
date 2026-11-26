package app.iduanju.ui.player

import java.io.IOException
import java.util.Arrays
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Random-access view of an encrypted progressive MP4 (ISO/IEC 23001-7 `cenc`, AES-128-CTR): built from the `moov` box
 * alone, it can decrypt any byte range of the file in place. Same box handling as core's `CENCDecryptor`, which needs
 * the whole file in memory; fragmented files are reported as [Unsupported] and go through that one instead.
 */
internal class CencLayout private constructor(
    private val key: SecretKeySpec,
    /** Samples of every encrypted track, sorted by file offset. */
    private val offsets: LongArray,
    private val sizes: IntArray,
    private val ivs: Array<ByteArray>,
    /** null = the whole sample is encrypted; else alternating (offset in sample, length) of its encrypted parts. */
    private val parts: Array<IntArray?>,
    /** Absolute-offset byte patches (encv → avc1, sinf / senc / pssh → free). */
    private val patches: List<Pair<Long, ByteArray>>,
) {
    class Unsupported(message: String) : IOException(message)

    private val cipher: Cipher = Cipher.getInstance("AES/CTR/NoPadding")

    /** Decrypts [len] bytes at [off] of [buf], which hold the file's bytes from [fileOffset] on. Single-threaded. */
    fun apply(fileOffset: Long, buf: ByteArray, off: Int, len: Int) {
        if (len <= 0) return
        val end = fileOffset + len
        for ((at, bytes) in patches) {
            if (at + bytes.size <= fileOffset || at >= end) continue
            for (i in bytes.indices) {
                val p = at + i
                if (p in fileOffset until end) buf[off + (p - fileOffset).toInt()] = bytes[i]
            }
        }
        var i = Arrays.binarySearch(offsets, fileOffset)
        if (i < 0) i = (-i - 2).coerceAtLeast(0)
        // Tables may hold overlapping empty samples at the same offset: step back over them.
        while (i > 0 && offsets[i - 1] + sizes[i - 1] > fileOffset) i--
        while (i < offsets.size && offsets[i] < end) {
            val start = offsets[i]
            if (start + sizes[i] > fileOffset) {
                val p = parts[i]
                if (p == null) span(i, start, sizes[i], 0, fileOffset, end, buf, off)
                else {
                    var done = 0
                    var k = 0
                    while (k < p.size) {
                        span(i, start + p[k], p[k + 1], done, fileOffset, end, buf, off)
                        done += p[k + 1]
                        k += 2
                    }
                }
            }
            i++
        }
    }

    /** One encrypted span; [before] = encrypted bytes of the same sample that precede it (the CTR stream position). */
    private fun span(sample: Int, start: Long, length: Int, before: Int, from: Long, to: Long, buf: ByteArray, off: Int) {
        val a = maxOf(start, from)
        val b = minOf(start + length, to)
        if (a >= b) return
        val skip = before + (a - start).toInt()
        val n = (b - a).toInt()
        val at = off + (a - from).toInt()
        val iv = ivs[sample].copyOf(16)
        var carry = (skip / 16).toLong()
        var j = 15
        while (carry != 0L && j >= 0) {
            val sum = (iv[j].toLong() and 0xff) + carry
            iv[j] = sum.toByte()
            carry = sum ushr 8
            j--
        }
        cipher.init(Cipher.DECRYPT_MODE, key, IvParameterSpec(iv))
        val rem = skip % 16
        if (rem == 0) {
            cipher.doFinal(buf, at, n, buf, at)
        } else {
            val tmp = ByteArray(rem + n)
            System.arraycopy(buf, at, tmp, rem, n)
            System.arraycopy(cipher.doFinal(tmp), rem, buf, at, n)
        }
    }

    private class Box(val type: String, val start: Int, val body: Int, val end: Int)

    private class Track(val offsets: ArrayList<Long> = ArrayList(), val sizes: ArrayList<Int> = ArrayList(), val ivs: ArrayList<ByteArray> = ArrayList(), val parts: ArrayList<IntArray?> = ArrayList())

    companion object {
        /**
         * @param moov the complete box including its header, at [moovOffset] of the file
         * @param fetch reads auxiliary sample info (`saio`) stored outside the moov box
         * @return null when nothing is encrypted
         */
        fun parse(moov: ByteArray, moovOffset: Long, keyHex: String, fetch: (Long, Int) -> ByteArray): CencLayout? {
            val key = hex(keyHex) ?: throw IOException("content key 不是 32 位 hex")
            val root = boxes(moov, 0, moov.size).firstOrNull { it.type == "moov" } ?: throw IOException("缺少 moov")
            val patches = ArrayList<Pair<Long, ByteArray>>()
            val tracks = ArrayList<Track>()
            for (b in boxes(moov, root.body, root.end)) when (b.type) {
                "mvex" -> throw Unsupported("分片 MP4")
                "pssh" -> patches.add(moovOffset + b.start + 4 to "free".toByteArray())
                "trak" -> trak(moov, b, moovOffset, patches, fetch)?.let { tracks.add(it) }
            }
            if (tracks.isEmpty()) return null
            val n = tracks.sumOf { it.offsets.size }
            if (n == 0) throw Unsupported("没有可解密的样本")
            val offs = LongArray(n); val sizes = IntArray(n)
            val ivs = arrayOfNulls<ByteArray>(n); val parts = arrayOfNulls<IntArray>(n)
            var k = 0
            val order = ArrayList<Triple<Long, Int, Int>>(n)
            tracks.forEachIndexed { t, tr -> tr.offsets.forEachIndexed { i, o -> order.add(Triple(o, t, i)) } }
            order.sortBy { it.first }
            for ((o, t, i) in order) {
                offs[k] = o; sizes[k] = tracks[t].sizes[i]; ivs[k] = tracks[t].ivs[i]; parts[k] = tracks[t].parts[i]; k++
            }
            @Suppress("UNCHECKED_CAST")
            return CencLayout(SecretKeySpec(key, "AES"), offs, sizes, ivs as Array<ByteArray>, parts, patches)
        }

        private fun hex(s: String): ByteArray? {
            if (s.length != 32) return null
            return runCatching { ByteArray(16) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() } }.getOrNull()
        }

        private fun u8(b: ByteArray, o: Int) = b[o].toInt() and 0xff
        private fun u16(b: ByteArray, o: Int) = (u8(b, o) shl 8) or u8(b, o + 1)
        private fun u32(b: ByteArray, o: Int): Long = (u8(b, o).toLong() shl 24) or (u8(b, o + 1).toLong() shl 16) or (u8(b, o + 2).toLong() shl 8) or u8(b, o + 3).toLong()
        private fun u64(b: ByteArray, o: Int): Long = (u32(b, o) shl 32) or u32(b, o + 4)

        private fun boxes(b: ByteArray, from: Int, to: Int): List<Box> {
            val out = ArrayList<Box>()
            var p = from
            while (p + 8 <= to) {
                var size = u32(b, p); var hdr = 8
                val type = String(b, p + 4, 4, Charsets.ISO_8859_1)
                if (size == 1L) {
                    if (p + 16 > to) break
                    size = u64(b, p + 8); hdr = 16
                } else if (size == 0L) size = (to - p).toLong()
                if (size < hdr || p + size > to) break
                out.add(Box(type, p, p + hdr, (p + size).toInt()))
                p += size.toInt()
            }
            return out
        }

        private fun child(b: ByteArray, box: Box, vararg path: String): Box? {
            var cur = box
            for (t in path) cur = boxes(b, cur.body, cur.end).firstOrNull { it.type == t } ?: return null
            return cur
        }

        private fun deep(b: ByteArray, box: Box, type: String): Box? {
            for (c in boxes(b, box.body, box.end)) {
                if (c.type == type) return c
                deep(b, c, type)?.let { return it }
            }
            return null
        }

        private fun trak(b: ByteArray, trak: Box, base: Long, patches: ArrayList<Pair<Long, ByteArray>>, fetch: (Long, Int) -> ByteArray): Track? {
            val stbl = child(b, trak, "mdia", "minf", "stbl") ?: return null
            val stsd = child(b, stbl, "stsd") ?: return null
            if (u32(b, stsd.body + 4) == 0L) return null
            val entry = boxes(b, stsd.body + 8, stsd.end).firstOrNull() ?: return null
            if (entry.type != "encv" && entry.type != "enca") return null
            val sinf = boxes(b, entry.body + if (entry.type == "encv") 78 else 28, entry.end).firstOrNull { it.type == "sinf" } ?: throw Unsupported("缺少 sinf")
            val schm = child(b, sinf, "schm") ?: throw Unsupported("缺少 schm")
            if (String(b, schm.body + 4, 4, Charsets.ISO_8859_1) != "cenc") throw Unsupported("仅支持 cenc AES-CTR")
            val frma = deep(b, sinf, "frma") ?: throw Unsupported("缺少 frma")
            patches.add(base + entry.start + 4 to b.copyOfRange(frma.body, frma.body + 4))
            val tenc = deep(b, sinf, "tenc") ?: throw Unsupported("缺少 tenc")
            if (tenc.body + 24 > tenc.end) throw Unsupported("tenc 截断")
            val ivSize = u8(b, tenc.body + 7)
            if (ivSize != 0 && ivSize != 8 && ivSize != 16) throw Unsupported("IV 长度异常")
            var constIv = ByteArray(0)
            if (ivSize == 0) {
                val at = tenc.body + 24
                if (at >= tenc.end) throw Unsupported("缺少常量 IV")
                val len = u8(b, at)
                if ((len != 8 && len != 16) || at + 1 + len > tenc.end) throw Unsupported("常量 IV 无效")
                constIv = b.copyOfRange(at + 1, at + 1 + len)
            }
            patches.add(base + sinf.start + 4 to "free".toByteArray())

            val track = Track()
            readOffsets(b, stbl, track)
            val senc = deep(b, stbl, "senc")
            if (senc != null) {
                patches.add(base + senc.start + 4 to "free".toByteArray())
                readSenc(b, senc, ivSize, constIv, track)
            } else readAux(b, stbl, ivSize, constIv, base, track, patches, fetch)
            if (track.offsets.isEmpty()) return null
            if (track.ivs.isEmpty()) throw Unsupported("缺少样本加密信息")
            if (track.ivs.size != track.offsets.size) throw Unsupported("样本数量不一致")
            return track
        }

        /** stsz + stsc + stco / co64 → absolute offset and size of every sample. */
        private fun readOffsets(b: ByteArray, stbl: Box, t: Track) {
            val stsz = child(b, stbl, "stsz") ?: return
            val fixed = u32(b, stsz.body + 4).toInt()
            val count = u32(b, stsz.body + 8).toInt()
            val stco = child(b, stbl, "stco"); val co64 = child(b, stbl, "co64")
            val table = stco ?: co64 ?: return
            val chunks = u32(b, table.body + 4).toInt()
            val stsc = child(b, stbl, "stsc")
            val runs = stsc?.let { u32(b, it.body + 4).toInt() } ?: 0
            var run = 0
            var sample = 0
            for (c in 0 until chunks) {
                var off = if (stco != null) u32(b, table.body + 8 + c * 4) else u64(b, table.body + 8 + c * 8)
                while (stsc != null && run + 1 < runs && u32(b, stsc.body + 8 + (run + 1) * 12) <= (c + 1).toLong()) run++
                val per = if (stsc != null && runs > 0) u32(b, stsc.body + 8 + run * 12 + 4).toInt() else 1
                repeat(per) {
                    val size = if (fixed != 0) fixed else if (sample < count) u32(b, stsz.body + 12 + sample * 4).toInt() else 0
                    t.offsets.add(off); t.sizes.add(size)
                    off += size
                    sample++
                }
            }
        }

        private fun readSenc(b: ByteArray, box: Box, ivSize: Int, constIv: ByteArray, t: Track) {
            val subs = u8(b, box.body + 3) and 0x2 != 0
            val count = u32(b, box.body + 4).toInt()
            var p = box.body + 8
            repeat(count) {
                val iv = when {
                    ivSize > 0 -> b.copyOfRange(p, p + ivSize).also { p += ivSize }
                    constIv.isNotEmpty() -> constIv
                    else -> ByteArray(8)
                }
                var ranges: IntArray? = null
                if (subs) {
                    val n = u16(b, p); p += 2
                    ranges = subsamples(b, p, n)
                    p += n * 6
                }
                t.ivs.add(iv); t.parts.add(ranges)
            }
        }

        private fun subsamples(b: ByteArray, from: Int, n: Int): IntArray {
            val out = ArrayList<Int>(n * 2)
            var p = from
            var at = 0
            repeat(n) {
                at += u16(b, p)
                val enc = u32(b, p + 2).toInt()
                p += 6
                if (enc < 0) throw Unsupported("子样本长度无效")
                if (enc > 0) { out.add(at); out.add(enc) }
                at += enc
            }
            return out.toIntArray()
        }

        private fun readAux(b: ByteArray, stbl: Box, ivSize: Int, constIv: ByteArray, base: Long, t: Track, patches: ArrayList<Pair<Long, ByteArray>>, fetch: (Long, Int) -> ByteArray) {
            val saiz = child(b, stbl, "saiz") ?: return
            val saio = child(b, stbl, "saio") ?: throw Unsupported("缺少 saio")
            var p = saiz.body + 4
            if (u8(b, saiz.body + 3) and 1 != 0) p += 8
            val fixed = u8(b, p)
            val count = u32(b, p + 1).toInt()
            p += 5
            val lens = IntArray(count) { if (fixed != 0) fixed else u8(b, p + it) }
            var q = saio.body + 4
            if (u8(b, saio.body + 3) and 1 != 0) q += 8
            val n = u32(b, q).toInt()
            q += 4
            val wide = u8(b, saio.body) == 1
            val starts = LongArray(n) { if (wide) u64(b, q + it * 8) else u32(b, q + it * 4) }
            // One contiguous block is the common layout; per-chunk blocks outside moov would need a request each.
            val total = lens.sum()
            val perChunk: IntArray? = if (n == 1) null else chunkCounts(b, stbl).also { if (it.size != n) throw Unsupported("saio 偏移数量无效") }
            fun read(at: Long, len: Int): ByteArray {
                val rel = at - base
                return if (rel >= 0 && rel + len <= b.size) b.copyOfRange(rel.toInt(), (rel + len).toInt()) else fetch(at, len)
            }
            var index = 0
            for (s in 0 until n) {
                val many = if (perChunk == null) count else perChunk[s]
                var len = 0
                for (i in index until minOf(index + many, count)) len += lens[i]
                if (n > 4) {
                    val rel = starts[s] - base
                    if (rel < 0 || rel + len > b.size) throw Unsupported("辅助信息分散在媒体数据中")
                }
                if (len > 8 shl 20 || total > 16 shl 20) throw Unsupported("辅助信息过大")
                val raw = read(starts[s], len)
                var at = 0
                repeat(many) {
                    if (index >= count) return@repeat
                    val l = lens[index]
                    if (l < ivSize || at + l > raw.size) throw Unsupported("辅助信息越界")
                    val iv = if (ivSize > 0) raw.copyOfRange(at, at + ivSize) else constIv
                    var ranges: IntArray? = null
                    if (l > ivSize) {
                        val subs = u16(raw, at + ivSize)
                        if (ivSize + 2 + subs * 6 > l) throw Unsupported("子样本截断")
                        ranges = subsamples(raw, at + ivSize + 2, subs)
                    }
                    t.ivs.add(iv); t.parts.add(ranges)
                    at += l
                    index++
                }
            }
            if (index != count) throw Unsupported("辅助信息样本数量不一致")
            patches.add(base + saiz.start + 4 to "free".toByteArray())
            patches.add(base + saio.start + 4 to "free".toByteArray())
        }

        private fun chunkCounts(b: ByteArray, stbl: Box): IntArray {
            val table = child(b, stbl, "stco") ?: child(b, stbl, "co64") ?: return IntArray(0)
            val chunks = u32(b, table.body + 4).toInt()
            val stsc = child(b, stbl, "stsc") ?: return IntArray(chunks)
            val runs = u32(b, stsc.body + 4).toInt()
            return IntArray(chunks) { c ->
                var per = 0
                for (r in 0 until runs) if (u32(b, stsc.body + 8 + r * 12) <= (c + 1).toLong()) per = u32(b, stsc.body + 8 + r * 12 + 4).toInt()
                per
            }
        }
    }
}
