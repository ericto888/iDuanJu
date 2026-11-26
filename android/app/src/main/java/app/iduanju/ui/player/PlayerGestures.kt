package app.iduanju.ui.player

import android.app.Activity
import android.content.Context
import android.media.AudioManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeDown
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.BrightnessHigh
import androidx.compose.material.icons.filled.BrightnessLow
import androidx.compose.material.icons.filled.BrightnessMedium
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.util.addPointerInputChange
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.ui.components.DS
import app.iduanju.ui.components.Motion
import app.iduanju.ui.components.glassSurface
import app.iduanju.ui.components.rememberHaptics
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private enum class HudKind { Brightness, Volume }

/** Brightness / volume level shown while a side zone is dragged. */
@Stable
internal class GestureHud {
    private var kindState by mutableStateOf(HudKind.Brightness)
    private var value by mutableFloatStateOf(0f)
    private var visible by mutableStateOf(false)
    private var dragging by mutableStateOf(false)

    fun brightness(v: Float) { kindState = HudKind.Brightness; value = v; dragging = true; visible = true }
    fun volume(v: Float) { kindState = HudKind.Volume; value = v; dragging = true; visible = true }
    fun level(v: Float) { value = v }
    fun end() { dragging = false }

    @Composable
    fun Overlay(enabled: Boolean, modifier: Modifier) {
        LaunchedEffect(dragging) { if (!dragging) { delay(550); visible = false } }
        AnimatedVisibility(visible && enabled, modifier, enter = fadeIn(tween(Motion.QUICK)), exit = fadeOut(tween(Motion.MEDIUM))) {
            Pill(kindState) { value }
        }
    }

    /** Centred glass pill: icon · white level bar · percentage. */
    @Composable
    private fun Pill(kind: HudKind, level: () -> Float) {
        val step by remember { derivedStateOf { (level().coerceIn(0f, 1f) * 100).toInt() } }
        val icon = when (kind) {
            HudKind.Brightness -> when { step < 34 -> Icons.Filled.BrightnessLow; step < 67 -> Icons.Filled.BrightnessMedium; else -> Icons.Filled.BrightnessHigh }
            HudKind.Volume -> when { step <= 0 -> Icons.AutoMirrored.Filled.VolumeOff; step < 50 -> Icons.AutoMirrored.Filled.VolumeDown; else -> Icons.AutoMirrored.Filled.VolumeUp }
        }
        Row(
            Modifier.glassSurface(RoundedCornerShape(50), dark = true, base = PlayerGlass, shadowRadius = 14.dp, fallbackAlpha = 0.55f).padding(horizontal = 18.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(icon, if (kind == HudKind.Brightness) "亮度" else "音量", tint = Color.White, modifier = Modifier.size(22.dp))
            Spacer(Modifier.width(12.dp))
            Box(Modifier.width(132.dp).height(4.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(0.22f)).drawBehind {
                drawRect(Color.White, size = Size(size.width * level().coerceIn(0f, 1f), size.height))
            })
            Spacer(Modifier.width(12.dp))
            Text("$step%", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.End, modifier = Modifier.widthIn(min = 40.dp))
        }
    }
}

/** The user's system brightness as 0..1 (handles OEM ranges above 255 via the framework's configured maximum). */
internal fun systemBrightness(ctx: Context): Float {
    val raw = runCatching { android.provider.Settings.System.getInt(ctx.contentResolver, android.provider.Settings.System.SCREEN_BRIGHTNESS) }.getOrDefault(128)
    val res = android.content.res.Resources.getSystem()
    val id = res.getIdentifier("config_screenBrightnessSettingMaximum", "integer", "android")
    val max = (if (id != 0) runCatching { res.getInteger(id) }.getOrDefault(255) else 255).coerceAtLeast(1)
    return (raw.toFloat() / maxOf(max, raw).toFloat()).coerceIn(0f, 1f)
}

/**
 * Tap = chrome · double-tap sides = ±10 s (middle: play / pause) · long-press = 2× · vertical drag = brightness (left
 * 28 %), volume (right 28 %), follow-finger previous / next episode or channel (centre) · horizontal drag = scrub.
 * Live: no seeking and no 2×; the centre swipe changes channel and wraps around.
 */
@Composable
internal fun GestureLayer(session: PlayerSession, ui: PlayerUi, hud: GestureHud, nextDrama: NextDramaController, activity: Activity?, inPip: Boolean, modifier: Modifier = Modifier) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptics = rememberHaptics()
    val audio = remember { ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    val pip by rememberUpdatedState(inPip)
    val settle = remember { arrayOfNulls<Job>(1) }
    Box(
        modifier
            .pointerInput(session) {
                detectTapGestures(
                    onTap = {
                        when {
                            ui.locked -> ui.showChrome = true
                            ui.panel != null -> ui.panel = null
                            ui.channelDrawer -> ui.channelDrawer = false
                            session.centerSuppressed -> { session.centerSuppressed = false; ui.showChrome = true }
                            else -> ui.showChrome = !ui.showChrome
                        }
                    },
                    onDoubleTap = onDoubleTap@{ o ->
                        if (ui.locked) return@onDoubleTap
                        val w = size.width
                        when {
                            session.live -> session.togglePlay()
                            o.x < w / 3 -> { haptics.tick(); session.seekBy(-10_000L) }
                            o.x > w * 2 / 3 -> { haptics.tick(); session.seekBy(10_000L) }
                            else -> session.togglePlay()
                        }
                    },
                    onPress = { tryAwaitRelease(); session.hold(false) },
                    onLongPress = { if (!ui.locked && !session.live) { haptics.longPress(); session.hold(true) } },
                )
            }
            .pointerInput(session) {
                // Zone fixed at touch-down: 0 = disabled, 1 = 亮度, 2 = 音量, 3 = 切集 / 换台.
                var zone = 0
                var level = 0f
                var maxVol = 1
                var rawY = 0f
                var committing = false
                var armed = false
                val velocity = VelocityTracker()
                val music = AudioManager.STREAM_MUSIC
                fun threshold() = minOf(size.height * EpisodeSwipe.THRESHOLD, EpisodeSwipe.MAX.toPx())
                fun finish(commit: Boolean) {
                    if (zone == 1 || zone == 2) hud.end()
                    if (zone == 3) {
                        val h = size.height.toFloat()
                        val off = ui.dragY
                        val vy = if (commit) velocity.calculateVelocity().y else 0f
                        val limit = threshold()
                        val flick = EpisodeSwipe.FLICK_VELOCITY.toPx()
                        val far = EpisodeSwipe.FLICK_DISTANCE.toPx()
                        val wantNext = off < -limit || (vy < -flick && off < -far)
                        val wantPrev = off > limit || (vy > flick && off > far)
                        val target = when { !commit -> null; wantNext -> session.neighbour(1); wantPrev -> session.neighbour(-1); else -> null }
                        // Final episode + 播完连刷推荐 ready: swiping up past the threshold opens the recommended drama.
                        val drama = nextDrama.swipePick?.takeIf { commit && wantNext && target == null && session.episodes.isNotEmpty() }
                        settle[0] = scope.launch {
                            if (drama != null) {
                                committing = true
                                try {
                                    haptics.confirm()
                                    animate(off, -h, animationSpec = tween(200)) { v, _ -> ui.dragY = v }
                                    nextDrama.play(drama)
                                    delay(800)
                                    nextDrama.switchFailed()
                                } finally { ui.dragY = 0f; committing = false }
                            } else if (target != null) {
                                committing = true
                                try {
                                    haptics.select()
                                    animate(off, if (off < 0f) -h else h, animationSpec = tween(Motion.SHORT, easing = Motion.Emphasized)) { v, _ -> ui.dragY = v }
                                    session.handoff = if (session.channelList) null else session.episodes.getOrNull(target)?.vid?.let { EpisodeCache.peekFirstFrame(it) }
                                    session.select(target)
                                } finally { ui.dragY = 0f; committing = false }
                            } else animate(off, 0f, animationSpec = DS.select()) { v, _ -> ui.dragY = v }
                        }
                    }
                    zone = 0
                }
                detectVerticalDragGestures(
                    onDragStart = { o ->
                        zone = when {
                            ui.locked || pip || ui.panel != null || ui.channelDrawer -> 0
                            o.x < size.width * 0.28f -> 1
                            o.x > size.width * 0.72f -> 2
                            committing -> 0
                            else -> 3
                        }
                        armed = false
                        when (zone) {
                            1 -> { level = activity?.window?.attributes?.screenBrightness?.takeIf { it >= 0f } ?: systemBrightness(ctx); hud.brightness(level) }
                            2 -> {
                                maxVol = audio.getStreamMaxVolume(music).coerceAtLeast(1)
                                level = audio.getStreamVolume(music).toFloat() / maxVol
                                hud.volume(level)
                            }
                            3 -> { settle[0]?.cancel(); rawY = ui.dragY; velocity.resetTracking() }
                        }
                    },
                    onDragEnd = { finish(commit = true) },
                    onDragCancel = { finish(commit = false) },
                ) { change, dy ->
                    if (zone == 0) return@detectVerticalDragGestures
                    change.consume()
                    val h = size.height.toFloat()
                    when (zone) {
                        1 -> {
                            level = (level - dy / (h * 0.65f)).coerceIn(0.02f, 1.0f)
                            activity?.window?.let { w -> val lp = w.attributes; lp.screenBrightness = level; w.attributes = lp }
                            hud.level(level)
                        }
                        2 -> {
                            level = (level - dy / (h * 0.65f)).coerceIn(0f, 1f)
                            val step = Math.round(level * maxVol)
                            // flags = 0: no system volume panel over our own HUD; DND can make this throw.
                            if (step != audio.getStreamVolume(music)) runCatching { audio.setStreamVolume(music, step, 0) }
                            hud.level(level)
                        }
                        else -> {
                            velocity.addPointerInputChange(change)
                            rawY += dy
                            val step = if (rawY < 0f) 1 else -1
                            val deadEnd = session.neighbour(step) == null && !(step == 1 && nextDrama.swipePick != null)
                            ui.dragY = if (deadEnd) rawY * 0.22f else rawY
                            val now = !deadEnd && kotlin.math.abs(ui.dragY) > threshold()
                            if (now != armed) { armed = now; haptics.tick() }
                        }
                    }
                }
            }
            .pointerInput(session) {
                var start = 0L
                var acc = 0f
                var on = false
                fun target(): Long = (start + (acc / size.width * 90_000).toLong()).coerceIn(0, session.clock.dur.coerceAtLeast(0))
                detectHorizontalDragGestures(
                    onDragStart = { on = !ui.locked && !session.live && ui.panel == null && session.clock.dur > 0; start = session.player.currentPosition; acc = 0f },
                    onDragEnd = { if (on) session.seekTo(target()); if (on) session.hint = null },
                    onDragCancel = { if (on) session.hint = null },
                ) { change, d ->
                    if (!on) return@detectHorizontalDragGestures
                    change.consume()
                    acc += d
                    session.hint = fmtClock(target()) + " / " + fmtClock(session.clock.dur)
                }
            },
    )
}
