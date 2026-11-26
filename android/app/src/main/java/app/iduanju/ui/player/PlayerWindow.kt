package app.iduanju.ui.player

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.util.Rational
import android.view.OrientationEventListener
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import app.iduanju.PipHost

/** FLAG_KEEP_SCREEN_ON on the hosting window while video plays; cleared on pause, end, error and leaving the player. */
internal fun keepScreenOn(activity: Activity?, on: Boolean) {
    val w = activity?.window ?: return
    if (on) w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    else w.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    android.util.Log.i("IDJ", "keepScreenOn=$on")
}

/** Returns true when system auto-rotation (`ACCELEROMETER_ROTATION == 1`) is enabled. */
private fun isAutoRotateEnabled(ctx: Context): Boolean =
    runCatching { android.provider.Settings.System.getInt(ctx.contentResolver, android.provider.Settings.System.ACCELEROMETER_ROTATION, 0) == 1 }.getOrDefault(false)

private fun requestOrientation(activity: Activity?, locked: Boolean, manual: Boolean?) {
    activity?.requestedOrientation = when {
        locked -> ActivityInfo.SCREEN_ORIENTATION_LOCKED
        manual == true -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        manual == false -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        else -> ActivityInfo.SCREEN_ORIENTATION_USER
    }
}

internal fun setLandscape(activity: Activity?, ui: PlayerUi, on: Boolean) {
    ui.manualLandscape = on
    requestOrientation(activity, ui.locked, on)
}

/** The player the window belongs to: while one screen fades into the next, both are there for a moment. */
private var windowOwner: Any? = null

/** Orientation lock / release, immersive bars, keep-screen-on, colour mode and backlight; everything is restored on leave. */
@Composable
internal fun PlayerWindowEffects(session: PlayerSession, ui: PlayerUi, enhance: EnhanceState, activity: Activity?, ctx: Context, landscape: Boolean) {
    LaunchedEffect(ui.locked, ui.manualLandscape, activity) { requestOrientation(activity, ui.locked, ui.manualLandscape) }
    DisposableEffect(activity) {
        val me = Any().also { windowOwner = it }
        val listener = object : OrientationEventListener(ctx) {
            override fun onOrientationChanged(orientation: Int) {
                if (orientation == ORIENTATION_UNKNOWN || ui.locked) return
                val target = ui.manualLandscape ?: return
                val portrait = orientation <= 30 || orientation >= 330
                val sideways = orientation in 60..120 || orientation in 240..300
                // Back to the sensor once the device is held the way the user asked for.
                if (((target && sideways) || (!target && portrait)) && isAutoRotateEnabled(ctx)) {
                    ui.manualLandscape = null
                    activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_USER
                }
            }
        }
        if (listener.canDetectOrientation()) listener.enable()
        onDispose {
            listener.disable()
            if (windowOwner !== me) return@onDispose
            windowOwner = null
            keepScreenOn(activity, false)
            activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            activity?.window?.let { w ->
                w.colorMode = ActivityInfo.COLOR_MODE_DEFAULT
                w.attributes = w.attributes.apply { screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE }
                WindowCompat.getInsetsController(w, w.decorView).show(WindowInsetsCompat.Type.systemBars())
            }
        }
    }
    BackHandler(enabled = !ui.locked && landscape && ui.manualLandscape == true) { setLandscape(activity, ui, false) }
    BackHandler(enabled = ui.panel != null) { ui.panel = null }
    BackHandler(enabled = ui.channelDrawer) { ui.channelDrawer = false }
    val hideBars = landscape || (!ui.showChrome && ui.panel == null)
    LaunchedEffect(hideBars) {
        val w = activity?.window ?: return@LaunchedEffect
        val ic = WindowCompat.getInsetsController(w, w.decorView)
        ic.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (hideBars) ic.hide(WindowInsetsCompat.Type.systemBars()) else ic.show(WindowInsetsCompat.Type.systemBars())
    }
    // Awake only while frames play or the next episode is about to.
    val awake = session.playing || (session.error == null && session.status.isNotEmpty() && session.detail != null)
    LaunchedEffect(awake) { keepScreenOn(activity, awake) }
    // Wide colour gamut for SDR→HDR / native HDR. Not COLOR_MODE_HDR: on a TextureView that would dim the Compose
    // overlays and break the getBitmap() ambient readback. SDR→HDR additionally lifts the window backlight (+0.22 over
    // the user's system brightness, clamped to 0.45..1.0) so the shader's inverse tone mapping reads as a real gain.
    LaunchedEffect(enhance.sdrToHdr, session.nativeHdr, enhance.failed) {
        val w = activity?.window ?: return@LaunchedEffect
        w.colorMode = if ((enhance.sdrToHdr && !enhance.failed) || session.nativeHdr) ActivityInfo.COLOR_MODE_WIDE_COLOR_GAMUT else ActivityInfo.COLOR_MODE_DEFAULT
        val boost = enhance.hdrOn
        w.attributes = w.attributes.apply {
            screenBrightness = if (boost) (systemBrightness(ctx) + 0.22f).coerceIn(0.45f, 1.0f) else WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        }
    }
    LaunchedEffect(enhance.level, enhance.sdrToHdr, session.nativeHdr, enhance.failed, enhance.textureView) { enhance.sync(activity) }
    LaunchedEffect(enhance.level > 0, enhance.sdrToHdr, session.nativeHdr, enhance.failed) { enhance.install() }
    DisposableEffect(enhance.textureView) {
        val tv = enhance.textureView ?: return@DisposableEffect onDispose {}
        val l = android.view.View.OnLayoutChangeListener { _, left, t, r, b, ol, ot, or, ob -> if ((r - left) != (or - ol) || (b - t) != (ob - ot)) enhance.sync(activity) }
        tv.addOnLayoutChangeListener(l)
        if (tv.width > 0 && tv.height > 0) enhance.sync(activity)
        onDispose { tv.removeOnLayoutChangeListener(l) }
    }
    DisposableEffect(enhance) { onDispose { clearWindowAndFallback(enhance.effect) } }
}

// ── picture in picture ──────────────────────────────────────────────────────────────────────────────────

private const val ACTION_PIP_PLAY_PAUSE = "app.iduanju.action.PIP_PLAY_PAUSE"
private const val ACTION_PIP_NEXT = "app.iduanju.action.PIP_NEXT"

internal class PlayerPip(private val ctx: Context, private val activity: Activity?, private val session: PlayerSession, private val ui: PlayerUi) {

    fun enter() {
        val act = activity ?: return
        if (!ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) { session.hint = "当前设备不支持画中画"; return }
        ui.panel = null
        ui.channelDrawer = false
        ui.showChrome = false
        runCatching { act.enterPictureInPictureMode(params()) }.onFailure { session.hint = "无法开启画中画" }
    }

    private fun params(): PictureInPictureParams {
        val vs = session.player.videoSize
        val portrait = isPortraitMedia(session)
        val w = if (vs.width > 0 && vs.height > 0) vs.width else if (portrait) 9 else 16
        val h = if (vs.width > 0 && vs.height > 0) vs.height else if (portrait) 16 else 9
        // Android PiP requires an aspect ratio within [1/2.39, 2.39]
        val ratio = w.toFloat() / h.toFloat()
        val safe = when { ratio < 0.45f -> Rational(9, 19); ratio > 2.30f -> Rational(23, 10); else -> Rational(w, h) }
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        fun action(code: Int, name: String, icon: Int, title: String) = RemoteAction(Icon.createWithResource(ctx, icon), title, title,
            PendingIntent.getBroadcast(ctx, code, Intent(name).setPackage(ctx.packageName), flags))
        val playing = session.player.isPlaying
        val actions = mutableListOf(action(1001, ACTION_PIP_PLAY_PAUSE, if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play, if (playing) "暂停" else "播放"))
        if (session.hasNext) actions.add(action(1002, ACTION_PIP_NEXT, android.R.drawable.ic_media_next, if (session.channelList) "下一个频道" else "下一集"))
        return PictureInPictureParams.Builder().setAspectRatio(safe).setActions(actions).build()
    }

    @Composable
    fun Effects(inPip: Boolean) {
        DisposableEffect(session, activity) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    when (intent?.action) {
                        ACTION_PIP_PLAY_PAUSE -> session.togglePlay()
                        ACTION_PIP_NEXT -> session.next()
                    }
                }
            }
            val filter = IntentFilter().apply { addAction(ACTION_PIP_PLAY_PAUSE); addAction(ACTION_PIP_NEXT) }
            ContextCompat.registerReceiver(ctx, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
            val leave: () -> Unit = { if (session.player.isPlaying) enter() }
            PipHost.onUserLeaveHint = leave
            onDispose {
                // the next player may have taken over already
                if (PipHost.onUserLeaveHint === leave) PipHost.onUserLeaveHint = null
                runCatching { ctx.unregisterReceiver(receiver) }
            }
        }
        LaunchedEffect(inPip, session.playing, session.epIndex, session.detail) {
            if (inPip) runCatching { activity?.setPictureInPictureParams(params()) }
        }
    }
}

internal fun isPortraitMedia(session: PlayerSession): Boolean {
    val aspect = session.videoAspect
    return if (aspect > 0f) aspect <= 1f else session.seriesId.all { it.isDigit() }
}

// ── media session ───────────────────────────────────────────────────────────────────────────────────────

@Composable
internal fun PlayerMediaSessionEffects(session: PlayerSession, ctx: Context, label: String) {
    val media = androidx.compose.runtime.remember(session) {
        PlayerMediaSession(ctx, onPlayPause = { session.togglePlay() }, onNext = { session.next() }, onPrev = { session.prev() }, onSeekTo = { session.seekTo(it) })
    }
    DisposableEffect(media) { onDispose { media.release() } }
    val d = session.detail
    val title = if (session.channelList) session.episode?.title?.ifBlank { null } ?: d?.title.orEmpty() else d?.title.orEmpty()
    val subtitle = if (session.channelList) session.replay?.title ?: d?.title.orEmpty() else label
    val dur by rememberUpdatedState(session.clock)
    // One duration read per change, not per tick.
    val duration by androidx.compose.runtime.remember(session) { androidx.compose.runtime.derivedStateOf { dur.dur } }
    LaunchedEffect(media, title, subtitle, d?.cover, duration) {
        if (title.isNotEmpty() || subtitle.isNotEmpty()) media.updateMetadata(title, subtitle, d?.cover, duration)
    }
    val speed = if (session.holding) 2f else if (session.live) 1f else session.speed
    LaunchedEffect(media, session.playing, session.epIndex, session.hasPrev, session.hasNext, speed, session.seekTick) {
        if (session.detail != null) {
            val pos = runCatching { session.player.currentPosition.coerceAtLeast(0L) }.getOrDefault(0L)
            media.updatePlaybackState(session.playing, pos, speed, session.hasPrev, session.hasNext)
        }
    }
}
