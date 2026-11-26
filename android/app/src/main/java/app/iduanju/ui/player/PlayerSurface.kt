@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package app.iduanju.ui.player

import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.PlayerView
import app.iduanju.core.hongguo.HGEpisode
import app.iduanju.ui.components.Motion

/** Centre-zone drag distances. */
internal object EpisodeSwipe {
    /** Fraction of the player height (capped at [MAX]) the drag must pass before releasing switches the episode. */
    const val THRESHOLD = 0.14f
    val MAX = 105.dp
    val FLICK_VELOCITY = 750.dp
    val FLICK_DISTANCE = 36.dp
}

/**
 * The video with everything that moves with it: 画面比例 zoom, the follow-finger offset, the first-frame handoff and
 * the neighbouring episode / channel sliding in. Drag and zoom are read in layer blocks, so they redraw without
 * recomposing.
 */
@Composable
internal fun PlayerSurface(session: PlayerSession, ui: PlayerUi, enhance: EnhanceState, aspect: Float, height: Float, nextDrama: NextDramaController, modifier: Modifier = Modifier) {
    // 画面比例 铺满: a Compose-side zoom of the FIT-sized video. PlayerView.resizeMode = ZOOM only re-lays out the inner
    // AspectRatioFrameLayout, which the AndroidView holder often skips (outer size unchanged), and does nothing visible
    // for 9:16 sources that already match the screen or carry baked-in letterbox bars.
    val target = remember(ui.fill, session.videoAspect, aspect) {
        if (!ui.fill) 1f
        else (if (session.videoAspect > 0f && aspect > 0f) maxOf(aspect / session.videoAspect, session.videoAspect / aspect) else 1.22f).coerceIn(1.18f, 2.4f)
    }
    val zoom = animateFloatAsState(target, tween(Motion.MEDIUM), label = "videoZoom")
    Box(modifier.background(Color.Black)) {
        Box(Modifier.fillMaxSize().graphicsLayer { translationY = ui.dragY }) {
            VideoView(session, enhance, Modifier.fillMaxSize().clipToBounds().graphicsLayer { scaleX = zoom.value; scaleY = zoom.value })
        }
        if (session.shade) Box(Modifier.fillMaxSize().background(Color.Black))
        // First frame of the new episode until the player renders it (no second ExoPlayer / MediaCodec).
        session.handoff?.let { bmp ->
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                Image(remember(bmp) { bmp.asImageBitmap() }, null, Modifier.fillMaxSize().clipToBounds().graphicsLayer { scaleX = zoom.value; scaleY = zoom.value },
                    contentScale = if (ui.fill) ContentScale.Crop else ContentScale.Fit)
            }
        }
        DragNeighbour(session, ui, height, nextDrama)
    }
}

@Composable
private fun VideoView(session: PlayerSession, enhance: EnhanceState, modifier: Modifier) {
    AndroidView(
        factory = {
            (android.view.LayoutInflater.from(it).inflate(app.iduanju.R.layout.player_texture_view, null) as PlayerView).apply {
                useController = false
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
                setShutterBackgroundColor(android.graphics.Color.TRANSPARENT)
                setKeepContentOnPlayerReset(true)
                resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                subtitleView?.apply {
                    setStyle(CaptionStyleCompat(android.graphics.Color.WHITE, android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT,
                        CaptionStyleCompat.EDGE_TYPE_OUTLINE, 0xCC000000.toInt(), null))
                    setFractionalTextSize(androidx.media3.ui.SubtitleView.DEFAULT_TEXT_SIZE_FRACTION * 0.92f)
                }
                player = session.player
                (videoSurfaceView as? android.view.TextureView)?.let { tv ->
                    tv.isOpaque = false
                    enhance.textureView = tv
                }
            }
        },
        update = { view ->
            // Re-run on every new video size: the aspect-ratio frame inside must be laid out again.
            session.videoAspect
            if (view.player !== session.player) view.player = session.player
            view.findViewById<android.view.View>(androidx.media3.ui.R.id.exo_content_frame)?.requestLayout()
            val tv = view.videoSurfaceView as? android.view.TextureView
            tv?.isOpaque = false
            if (tv !== enhance.textureView) enhance.textureView = tv
        },
        onRelease = { it.player = null },
        modifier = modifier,
    )
}

/** What slides in under the finger: next / previous episode, channel, or the recommended drama after the last episode. */
@Composable
private fun DragNeighbour(session: PlayerSession, ui: PlayerUi, height: Float, nextDrama: NextDramaController) {
    val dir by remember(ui) { derivedStateOf { if (ui.dragY < -0.5f) 1 else if (ui.dragY > 0.5f) -1 else 0 } }
    if (dir == 0) return
    val index = session.neighbour(dir)
    val ep = index?.let { session.episodes.getOrNull(it) }
    val place = Modifier.fillMaxSize().graphicsLayer { translationY = ui.dragY + if (dir > 0) height else -height }
    if (ep != null) {
        if (session.channelList) ChannelPreview(ep, index + 1, place) else EpisodeFramePreview(ep, ui.fill, place)
        return
    }
    val pick = nextDrama.swipePick?.takeIf { dir > 0 } ?: return
    val threshold = with(androidx.compose.ui.platform.LocalDensity.current) { minOf(height * EpisodeSwipe.THRESHOLD, EpisodeSwipe.MAX.toPx()) }
    val armed by remember(threshold) { derivedStateOf { kotlin.math.abs(ui.dragY) > threshold } }
    NextDramaSwitchPreview(pick = pick, armed = armed, modifier = place)
}

/** The cached first video frame, or a clean black card with the episode number. */
@Composable
private fun EpisodeFramePreview(ep: HGEpisode, fill: Boolean, modifier: Modifier) {
    val bmp = remember(ep.vid) { EpisodeCache.peekFirstFrame(ep.vid)?.asImageBitmap() }
    Box(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        if (bmp != null) Image(bmp, null, Modifier.fillMaxSize(), contentScale = if (fill) ContentScale.Crop else ContentScale.Fit)
        else Text(ep.title.takeIf { it.isNotBlank() && it.length <= 24 } ?: "第 ${ep.ep} 集", color = Color.White.copy(0.5f), fontSize = 16.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun ChannelPreview(ep: HGEpisode, number: Int, modifier: Modifier) {
    Column(modifier.background(Color.Black).padding(horizontal = 40.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text("%03d".format(number), color = Color.White.copy(0.45f), fontSize = 15.sp, fontWeight = FontWeight.Medium)
        Text(ep.title.ifBlank { "频道 $number" }, color = Color.White, fontSize = 24.sp, lineHeight = 31.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center, modifier = Modifier.padding(top = 8.dp))
        ep.page?.takeIf { it.isNotBlank() }?.let { Text(it, color = Color.White.copy(0.55f), fontSize = 13.sp, modifier = Modifier.padding(top = 6.dp)) }
    }
}
