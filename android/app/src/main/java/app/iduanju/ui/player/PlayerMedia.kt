@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package app.iduanju.ui.player

import android.app.ActivityManager
import android.content.Context
import android.net.Uri
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.upstream.DefaultAllocator
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
import app.iduanju.IdjApp
import app.iduanju.core.cms.MacCMS
import app.iduanju.core.hongguo.HGNet
import app.iduanju.core.hongguo.HGStreamKind
import app.iduanju.core.hongguo.HGSubtitle
import app.iduanju.core.tvbox.TVBoxNet
import app.iduanju.tvbox.TVBoxMediaGuard
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import okhttp3.ConnectionPool
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.IOException
import java.net.Proxy
import java.util.concurrent.TimeUnit

/** One HTTP client for everything the player fetches (playlists, media, keys, subtitles), so connections are reused. */
internal object PlayerHttp {
    private val direct = OkHttpClient.Builder().proxy(Proxy.NO_PROXY)
        .connectionPool(ConnectionPool(8, 3, TimeUnit.MINUTES))
        .retryOnConnectionFailure(true)
        .connectTimeout(8, TimeUnit.SECONDS).readTimeout(12, TimeUnit.SECONDS).build()
    private val system = direct.newBuilder().proxy(null).build()
    private fun guarded(c: OkHttpClient) = c.newBuilder().dns(TVBoxMediaGuard).addNetworkInterceptor(TVBoxMediaGuard).build()
    private val guardedDirect by lazy { guarded(direct) }
    private val guardedSystem by lazy { guarded(system) }
    val client: OkHttpClient get() = if (HGNet.playerUsesSystemProxy) system else direct
    /** [lan] = false: never into the local network (TVBox configs without that permission). */
    fun client(lan: Boolean): OkHttpClient = if (lan) client else if (HGNet.playerUsesSystemProxy) guardedSystem else guardedDirect
    /** Same pool with a short overall limit (sniffing). */
    fun quick(lan: Boolean, ms: Long): OkHttpClient = client(lan).newBuilder().callTimeout(ms, TimeUnit.MILLISECONDS).build()

    /**
     * A playlist and nothing else: many addresses only mention `m3u8`, and what answers may be the whole film or a stream that
     * never ends.
     */
    fun playlist(resp: Response): String {
        val start = resp.peekBody(64).string().trimStart('\uFEFF', ' ', '\r', '\n', '\t')
        if (!start.startsWith("#EXTM3U")) throw IOException("不是播放列表")
        return String(TVBoxNet.capped(resp.body!!.byteStream(), MAX_PLAYLIST), Charsets.UTF_8)
    }

    private const val MAX_PLAYLIST = 8 shl 20

    /** Header values come from configs; OkHttp rejects control / non-ASCII characters, and the player sets its own ranges. */
    fun safe(headers: Map<String, String>): Map<String, String> = headers.entries
        .filter { (k, _) -> k.isNotBlank() && !k.equals("range", true) && k.all { it.code in 0x21..0x7e && it != ':' } }
        .associate { (k, v) ->
            k to v.trim().filter { it == '\t' || it.code >= 0x20 && it.code != 0x7f }
                .map { if (it.code <= 0x7e) it.toString() else Uri.encode(it.toString()) }.joinToString("")
        }
}

/** Container families that need their own media source. */
enum class MediaKind(val mime: String?) {
    Hls(MimeTypes.APPLICATION_M3U8), Dash(MimeTypes.APPLICATION_MPD), Ss(MimeTypes.APPLICATION_SS),
    Rtsp(MimeTypes.APPLICATION_RTSP), Progressive(null),
}

internal object MediaKinds {
    private val progressive = setOf(
        "mp4", "m4v", "mov", "mkv", "webm", "flv", "f4v", "ts", "m2ts", "mts", "avi", "mpg", "mpeg", "3gp", "wmv", "vob",
        "mp3", "m4a", "aac", "flac", "ogg", "opus", "wav",
    )

    /** From the source's hint, the scheme and the path; null = only the response can tell. */
    fun guess(url: String, format: String? = null, kind: HGStreamKind? = null): MediaKind? {
        val scheme = url.substringBefore("://", "").lowercase()
        if (scheme == "rtsp") return MediaKind.Rtsp
        if (scheme.startsWith("rtmp") || scheme == "udp" || scheme == "rtp") return MediaKind.Progressive
        if (kind == HGStreamKind.hls) return MediaKind.Hls
        byMime(format)?.let { return it }
        val path = url.substringBefore('#').substringBefore('?').lowercase()
        when (path.substringAfterLast('/').substringAfterLast('.', "")) {
            "m3u8", "m3u" -> return MediaKind.Hls
            "mpd" -> return MediaKind.Dash
            "ism", "isml" -> return MediaKind.Ss
            in progressive -> return MediaKind.Progressive
        }
        if (path.endsWith("/manifest") && ".ism" in path) return MediaKind.Ss
        val query = url.substringAfter('?', "").lowercase()
        return when {
            ".m3u8" in query || "type=m3u8" in query || "format=m3u8" in query -> MediaKind.Hls
            ".mpd" in query -> MediaKind.Dash
            "mime_type=video_mp4" in query || ".mp4" in query || ".flv" in query -> MediaKind.Progressive
            else -> null
        }
    }

    private fun byMime(mime: String?): MediaKind? {
        val m = mime?.lowercase()?.substringBefore(';')?.trim().orEmpty()
        return when {
            m.isEmpty() -> null
            "mpegurl" in m || m == "hls" || m == "m3u8" -> MediaKind.Hls
            "dash+xml" in m || m == "dash" || m == "mpd" -> MediaKind.Dash
            "ms-sstr" in m || m == "ss" -> MediaKind.Ss
            m == "flv" || m == "mp4" || m == "ts" || m == "mkv" -> MediaKind.Progressive
            m.startsWith("video/") || m.startsWith("audio/") -> MediaKind.Progressive
            else -> null
        }
    }

    /** One small request within [ms]: content type, final address after redirects, then the first bytes. */
    fun sniff(url: String, headers: Map<String, String>, lan: Boolean, ms: Long): MediaKind {
        val client = PlayerHttp.quick(lan, ms)
        val until = System.nanoTime() + ms * 1_000_000
        fun request(ranged: Boolean) = Request.Builder().url(url)
            .apply { if (ranged) header("Range", "bytes=0-1023") }
            .apply { if (headers.keys.none { it.equals("user-agent", true) }) header("User-Agent", MacCMS.UA) }
            .apply { PlayerHttp.safe(headers).forEach { (k, v) -> header(k, v) } }.build()
        val first = client.newCall(request(true)).execute()
        // Playlist scripts and some live servers refuse range requests outright.
        val answer = if (first.isSuccessful || first.code !in setOf(400, 403, 405, 416)) first else {
            first.close()
            client.newCall(request(false)).apply { timeout().timeout((until - System.nanoTime()).coerceAtLeast(1_000_000), TimeUnit.NANOSECONDS) }.execute()
        }
        return answer.use { resp ->
            if (!resp.isSuccessful) return MediaKind.Progressive
            val type = resp.header("Content-Type")
            byMime(type)?.takeIf { it != MediaKind.Progressive }?.let { return it }
            val buf = ByteArray(1024)
            var n = 0
            val input = resp.body?.byteStream() ?: return MediaKind.Progressive
            while (n < buf.size) { val r = input.read(buf, n, buf.size - n); if (r < 0) break; n += r }
            val text = String(buf, 0, n, Charsets.ISO_8859_1).trimStart('﻿', ' ', '\r', '\n', '\t', 'ï', '»', '¿')
            when {
                text.startsWith("#EXTM3U") -> MediaKind.Hls
                "<MPD" in text -> MediaKind.Dash
                "SmoothStreamingMedia" in text -> MediaKind.Ss
                else -> guess(resp.request.url.toString()) ?: MediaKind.Progressive
            }
        }
    }
}

/** First bytes of the next episode, so its start needs no round trip. Playback only reads it, it never fills it. */
internal object MediaHeadCache {
    private const val MAX_BYTES = 96L shl 20
    private var opened = false
    private var cache: SimpleCache? = null

    @Synchronized fun get(): SimpleCache? {
        if (!opened) {
            opened = true
            val app = IdjApp.instance
            cache = runCatching { SimpleCache(File(app.cacheDir, "media-head"), LeastRecentlyUsedCacheEvictor(MAX_BYTES), StandaloneDatabaseProvider(app)) }
                .onFailure { android.util.Log.w("IDJ", "media head cache unavailable", it) }.getOrNull()
        }
        return cache
    }

    /** Fetches [bytes] of [url] (all of it when 0); failures only mean no warm start. */
    suspend fun warm(context: Context, url: String, headers: Map<String, String>, bytes: Long) {
        if (!url.startsWith("http", true)) return
        val c = get() ?: return
        val spec = DataSpec.Builder().setUri(url).apply { if (bytes > 0) setPosition(0).setLength(bytes) }.build()
        val source = CacheDataSource.Factory().setCache(c).setUpstreamDataSourceFactory(PlayerSources.http(headers)).createDataSource()
        try {
            runInterruptible(Dispatchers.IO) { CacheWriter(source, spec, null, null).cache() }
        } catch (e: kotlinx.coroutines.CancellationException) { throw e
        } catch (e: Exception) { android.util.Log.i("IDJ", "warm-up skipped: ${e.javaClass.simpleName}") }
    }
}

internal object PlayerSources {
    fun http(headers: Map<String, String>, lan: Boolean = true): DataSource.Factory {
        val safe = PlayerHttp.safe(headers)
        // OkHttp (HTTP/2) like iOS URLSession: some CDNs behind Cloudflare 403 HttpURLConnection (HTTP/1.1 only).
        return OkHttpDataSource.Factory(PlayerHttp.client(lan))
            .setUserAgent(safe.entries.firstOrNull { it.key.equals("user-agent", true) }?.value ?: MacCMS.UA)
            .setDefaultRequestProperties(safe.filterKeys { !it.equals("user-agent", true) })
    }

    private fun data(context: Context, headers: Map<String, String>, live: Boolean, lan: Boolean): DataSource.Factory {
        val http = http(headers, lan)
        val local = DefaultDataSource.Factory(context, http)
        return DataSource.Factory {
            RoutingDataSource(
                files = { lan || runCatching { File(it.path.orEmpty()).canonicalPath.startsWith(EpisodeCache.folder) }.getOrDefault(false) },
                local = { local.createDataSource() },
                http = {
                    val c = if (live) null else MediaHeadCache.get()
                    if (c == null) http.createDataSource()
                    else CacheDataSource.Factory().setCache(c).setCacheWriteDataSinkFactory(null).setUpstreamDataSourceFactory(http)
                        .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR).createDataSource()
                },
            )
        }
    }

    /** Refused addresses do not come back by retrying; failing at once lets the player switch source. */
    private val errorPolicy = object : DefaultLoadErrorHandlingPolicy() {
        override fun getRetryDelayMsFor(info: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
            val code = (info.exception as? HttpDataSource.InvalidResponseCodeException)?.responseCode
            return if (code != null && code in 400..499 && code != 408 && code != 416 && code != 429) C.TIME_UNSET else super.getRetryDelayMsFor(info)
        }
    }

    fun create(context: Context, p: Playable): MediaSource {
        val uri = if (p.uri.startsWith("/")) Uri.fromFile(File(p.uri)) else Uri.parse(p.uri)
        val kind = p.kind ?: if (p.hls) MediaKind.Hls else null
        val item = MediaItem.Builder().setUri(uri)
            .apply { kind?.mime?.let { setMimeType(it) } }
            .setSubtitleConfigurations(p.subtitles.mapNotNull(::subtitle).mapIndexed { i, s -> if (i == 0) s.buildUpon().setSelectionFlags(C.SELECTION_FLAG_DEFAULT).build() else s })
            .build()
        val extractors = DefaultExtractorsFactory()
            .setConstantBitrateSeekingEnabled(true)
            .setTsExtractorFlags(DefaultTsPayloadReaderFactory.FLAG_ALLOW_NON_IDR_KEYFRAMES)
        return DefaultMediaSourceFactory(data(context, p.headers, p.live, p.lan), extractors)
            .setLoadErrorHandlingPolicy(errorPolicy).createMediaSource(item)
    }

    private fun subtitle(s: HGSubtitle): MediaItem.SubtitleConfiguration? {
        if (s.url.isBlank()) return null
        val hint = (s.format.orEmpty() + " " + s.url.substringBefore('?').substringAfterLast('.')).lowercase()
        val mime = when {
            "vtt" in hint -> MimeTypes.TEXT_VTT
            "ass" in hint || "ssa" in hint -> MimeTypes.TEXT_SSA
            "ttml" in hint || "dfxp" in hint || "xml" in hint -> MimeTypes.APPLICATION_TTML
            else -> MimeTypes.APPLICATION_SUBRIP
        }
        return MediaItem.SubtitleConfiguration.Builder(Uri.parse(s.url)).setMimeType(mime).setLabel(s.name.ifBlank { null })
            .setLanguage(s.language?.ifBlank { null }).setId("ext:" + s.url.hashCode()).build()
    }
}

/**
 * Picks the delegate by scheme when a request is opened (local playlist, network segment, decrypting stream …). [files]: which
 * local addresses may be read (a playlist of an unknown source may name any).
 */
private class RoutingDataSource(private val files: (Uri) -> Boolean, private val local: () -> DataSource, private val http: () -> DataSource) : DataSource {
    private val listeners = ArrayList<TransferListener>(2)
    private var current: DataSource? = null

    override fun addTransferListener(transferListener: TransferListener) { listeners.add(transferListener) }

    override fun open(dataSpec: DataSpec): Long {
        val source = when (dataSpec.uri.scheme?.lowercase()) {
            CENC_SCHEME -> CencDataSource()
            "http", "https" -> http()
            null, "file", "content", "asset", "rawresource", "android.resource" -> if (files(dataSpec.uri)) local() else throw IOException("不支持的播放地址")
            else -> local()
        }
        listeners.forEach(source::addTransferListener)
        current = source
        return source.open(dataSpec)
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int = checkNotNull(current).read(buffer, offset, length)
    override fun getUri(): Uri? = current?.uri
    override fun getResponseHeaders(): Map<String, List<String>> = current?.responseHeaders ?: emptyMap()
    override fun close() { try { current?.close() } finally { current = null } }
}

/** First-use costs of the player (codec lists, native FFmpeg, HTTP client), paid in the background after launch. */
internal object PlayerWarmup {
    fun run() {
        runCatching { PlayerHttp.client }
        runCatching { androidx.media3.decoder.ffmpeg.FfmpegLibrary.isAvailable() }
        for (mime in listOf(MimeTypes.VIDEO_H264, MimeTypes.VIDEO_H265, MimeTypes.AUDIO_AAC))
            runCatching { androidx.media3.exoplayer.mediacodec.MediaCodecUtil.getDecoderInfos(mime, false, false) }
        runCatching { EpisodeCache.index() }
    }
}

/** The tuned player every screen uses. */
internal object PlayerFactory {
    fun create(context: Context): ExoPlayer = ExoPlayer.Builder(context, DecoderCaps.renderers(context))
        .setLoadControl(loadControl(context))
        // Within a second a key frame is taken (instant); otherwise the exact position is decoded.
        .setSeekParameters(SeekParameters(1_000_000L, 1_000_000L))
        .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
        .setHandleAudioBecomingNoisy(true)
        .build()

    /** First frame after ~0.8 s of media, 2 s after a rebuffer; the buffer is sized by the app's memory class. */
    fun loadControl(context: Context): DefaultLoadControl {
        val am = context.getSystemService(ActivityManager::class.java)
        val mb = if (am.isLowRamDevice) 128 else am.memoryClass
        val target = when { mb < 192 -> 48 shl 20; mb < 384 -> 96 shl 20; else -> 144 shl 20 }
        return DefaultLoadControl.Builder()
            .setAllocator(DefaultAllocator(true, C.DEFAULT_BUFFER_SEGMENT_SIZE))
            .setBufferDurationsMs(25_000, 60_000, 800, 3_500)
            .setTargetBufferBytes(target)
            .setPrioritizeTimeOverSizeThresholds(false)
            .apply { if (mb >= 384) setBackBuffer(6_000, true) }
            .build()
    }
}
