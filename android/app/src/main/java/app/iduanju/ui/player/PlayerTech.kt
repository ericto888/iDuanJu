@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package app.iduanju.ui.player

import android.content.Context
import android.view.TextureView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.exoplayer.ExoPlayer
import app.iduanju.ui.components.pressClick
import app.iduanju.ui.theme.IdjDarkColors

/** What the decoder is really playing. */
@Immutable
data class TechTags(val res: String? = null, val range: String? = null, val codec: String? = null, val audio: String? = null, val fps: Int? = null) {
    companion object {
        private val resolutionLabel = Regex("""\d{3,4}[pP]""")

        fun from(p: ExoPlayer, quality: String?): TechTags {
            val v = p.videoFormat; val a = p.audioFormat
            // Source labels are often line names ("线路 1 · 高清"); only a real resolution replaces the measured one.
            val res = quality?.takeIf { resolutionLabel.matches(it) }?.uppercase()
                ?: v?.let { f -> val h = minOf(f.width, f.height); if (h > 0) "${h}P" else null }
            val codec = v?.sampleMimeType?.let {
                when { it.contains("hevc") -> "HEVC"; it.contains("avc") -> "H.264"; it.contains("av01") -> "AV1"; it.contains("vp9") || it.contains("vp09") -> "VP9"; else -> null }
            }
            val dolbyVision = v?.sampleMimeType == MimeTypes.VIDEO_DOLBY_VISION ||
                v?.codecs?.let { c -> c.startsWith("dvh") || c.startsWith("dvav") || c.startsWith("dva1") || c.startsWith("dav1") } == true
            val range = when {
                dolbyVision -> "Dolby Vision"
                v?.colorInfo?.colorTransfer == C.COLOR_TRANSFER_HLG -> "HLG"
                v?.colorInfo?.colorTransfer == C.COLOR_TRANSFER_ST2084 -> "HDR10"
                else -> "SDR"
            }
            val audio = a?.let { f -> val n = audioName(f.sampleMimeType) ?: "音频"; if (f.channelCount > 0) "$n ${f.channelCount}.0" else n }
            val fps = v?.frameRate?.takeIf { it > 0 }?.let { Math.round(it) }
            return TechTags(res, if (v != null) range else null, codec, audio, fps)
        }

        fun audioName(mime: String?): String? = when {
            mime == null -> null
            "mp4a" in mime -> "AAC"
            "eac3" in mime -> "E-AC-3"
            "ac3" in mime -> "AC-3"
            "true-hd" in mime -> "TrueHD"
            "dts" in mime -> "DTS"
            "opus" in mime -> "Opus"
            "flac" in mime -> "FLAC"
            "mpeg" in mime -> "MP3"
            else -> null
        }
    }
}

/**
 * Technical status badges: neutral pills for resolution / codec / high frame rate and accent pills for the active GPU
 * stages (AI 超分, SDR→HDR) or a native HDR range. Tapping opens the enhancement panel.
 */
@Composable
internal fun StatusBadges(t: TechTags, enhanceOn: Boolean, hdrOn: Boolean, nativeRange: String?, enabled: Boolean, onClick: () -> Unit) {
    val items = buildList {
        t.res?.let { add(it to false) }
        t.codec?.let { add(it to false) }
        t.fps?.takeIf { it >= 48 }?.let { add("${it}FPS" to false) }
        when {
            nativeRange != null -> add(nativeRange to true)
            hdrOn -> add("SDR→HDR" to true)
        }
        if (enhanceOn && nativeRange == null) add("AI 超分" to true)
    }
    if (items.isEmpty()) return
    val pc = IdjDarkColors
    Row(Modifier.clip(RoundedCornerShape(7.dp)).pressClick(0.96f, enabled = enabled, label = "画质增强", onClick = onClick),
        horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
        items.forEach { (label, accent) ->
            Box(Modifier.heightIn(min = 19.dp).clip(RoundedCornerShape(6.dp))
                .background(if (accent) pc.accent.copy(0.22f) else Color.White.copy(0.14f))
                .border(0.6.dp, if (accent) pc.accent.copy(0.62f) else Color.White.copy(0.14f), RoundedCornerShape(6.dp))
                .padding(horizontal = 6.dp), contentAlignment = Alignment.Center) {
                Text(label, color = if (accent) pc.accent else Color.White.copy(0.9f), fontSize = 10.sp, lineHeight = 12.sp,
                    fontWeight = FontWeight.SemiBold, letterSpacing = 0.2.sp, maxLines = 1, softWrap = false)
            }
        }
    }
}

/** 更多 → 技术信息: one muted line (iOS PlayerTechStrip). */
@Composable
internal fun TechStrip(t: TechTags, modifier: Modifier = Modifier) {
    val text = listOfNotNull(t.res, t.range, t.codec, t.audio, t.fps?.let { "$it fps" }).joinToString(" · ")
    if (text.isEmpty()) return
    Text("$text · Media3", modifier.graphicsLayer { alpha = 0.72f }, color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Medium, maxLines = 1,
        style = androidx.compose.ui.text.TextStyle(shadow = androidx.compose.ui.graphics.Shadow(Color.Black.copy(0.6f), blurRadius = 4f)))
}

/** AI 超分 / SDR→HDR choices of one player, kept in sync with the surface and the window. */
@Stable
internal class EnhanceState(private val ctx: Context, private val session: PlayerSession) {
    var level by mutableIntStateOf(PlayerPrefs.getEnhanceLevel(ctx))
        private set
    var sdrToHdr by mutableStateOf(PlayerPrefs.getSdrToHdr(ctx))
        private set
    var failed by mutableStateOf(false)
        private set
    var textureView by mutableStateOf<TextureView?>(null)
    // One persistent GlEffect; only installed while GPU sharpen or SDR→HDR is on, so default playback stays on the
    // direct hardware surface (avoids VideoFrameProcessor black screens on some SoCs and its start-up cost).
    val effect = VideoEnhanceEffect(level, sdrToHdr)
    private val installer = VideoEnhancer(session.player, effect)

    val enhanceOn: Boolean get() = level > 0 && !failed
    val hdrOn: Boolean get() = sdrToHdr && !failed && !session.nativeHdr
    private val wanted: Boolean get() = !failed && (level > 0 || (sdrToHdr && !session.nativeHdr))

    fun sync(activity: android.app.Activity?) {
        effect.level = if (failed) 0 else level
        effect.sdrToHdr = !failed && sdrToHdr && !session.nativeHdr
        syncWindowAndFallback(activity, textureView, effect, session.nativeHdr)
    }

    fun install() = installer.install(wanted, session.live)

    fun onFailure(): Boolean {
        if (failed) return false
        android.util.Log.w("IDJ", "VideoFrameProcessor error, falling back to the direct surface")
        failed = true
        level = 0
        sdrToHdr = false
        effect.level = 0
        effect.sdrToHdr = false
        PlayerPrefs.setEnhanceLevel(ctx, 0)
        PlayerPrefs.setSdrToHdr(ctx, false)
        installer.install(false, session.live)
        return true
    }

    fun applyLevel(value: Int) {
        if (value > 0 && failed) { session.hint = "当前设备不支持 GPU 画质增强"; return }
        level = value
        PlayerPrefs.setEnhanceLevel(ctx, value)
        session.hint = when (value) { 1 -> "AI 超分辨率：标准"; 2 -> "AI 超分辨率：强效"; else -> "AI 超分辨率：已关闭" }
    }

    fun applyHdr(on: Boolean) {
        when {
            session.nativeHdr -> session.hint = "当前片源已是原生 ${session.tags.range}"
            on && failed -> session.hint = "当前设备不支持 GPU 画质增强"
            else -> {
                sdrToHdr = on
                PlayerPrefs.setSdrToHdr(ctx, on)
                session.hint = if (on) "SDR 转 HDR：已开启" else "SDR 转 HDR：已关闭"
            }
        }
    }
}
