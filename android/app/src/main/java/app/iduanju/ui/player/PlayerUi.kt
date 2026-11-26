package app.iduanju.ui.player

import android.content.Context
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.iduanju.BuildConfig
import app.iduanju.ui.UiEvidence
import app.iduanju.ui.components.LayoutMetrics

internal enum class PlayerPanel(val id: String) {
    Episodes("episodes"), Speed("speed"), Quality("quality"), Tracks("audio"), More("more"), Danmaku("danmaku"), Channels("channels"), Guide("guide");

    companion object { fun of(id: String?) = entries.firstOrNull { it.id == id } }
}

/** View state of the player screen: chrome, the one open panel, lock, aspect, gestures. */
@Stable
internal class PlayerUi(private val ctx: Context) {
    var showChrome by mutableStateOf(true)
    /** One panel at a time. */
    var panel by mutableStateOf(if (BuildConfig.DEBUG) PlayerPanel.of(UiEvidence.panel) else null)
    var locked by mutableStateOf(false)
    var danmaku by mutableStateOf(PlayerPrefs.getDanmaku(ctx))
        private set
    var fill by mutableStateOf(PlayerPrefs.getFillMode(ctx))
        private set
    var padDrawerOpen by mutableStateOf(true)
    var showTech by mutableStateOf(false)
    /** Landscape live: the channel drawer on the right edge. */
    var channelDrawer by mutableStateOf(false)
    /** null = follow the sensor, true / false = chosen by hand. */
    var manualLandscape by mutableStateOf<Boolean?>(null)
    /** Vertical offset (px) of the video while the centre zone is dragged; read in draw / layout only. */
    var dragY by mutableFloatStateOf(0f)

    fun toggle(p: PlayerPanel) { panel = if (panel == p) null else p }
    fun applyFill(on: Boolean) { fill = on; PlayerPrefs.setFillMode(ctx, on) }
    fun applyDanmaku(on: Boolean) { danmaku = on; PlayerPrefs.setDanmaku(ctx, on) }
}

/** Sizes of the chrome for phone portrait / phone landscape / tablet. */
@Stable
internal class PlayerDimens(val metrics: LayoutMetrics) {
    val tablet: Boolean get() = metrics.isTablet
    val landscape: Boolean get() = metrics.isLandscape
    /** Landscape phones and every tablet get the floating console; portrait phones keep the short-drama layout. */
    val wide: Boolean get() = landscape || tablet
    val button: Dp get() = if (tablet) 48.dp else 42.dp
    val buttonIcon: Dp get() = if (tablet) 22.dp else 20.dp
    val pad: Dp get() = when { tablet && landscape -> 32.dp; landscape -> 52.dp; tablet -> 24.dp; else -> 14.dp }
    val main: Dp get() = when { tablet -> 76.dp; landscape -> 64.dp; else -> 68.dp }
    val side: Dp get() = if (tablet) 48.dp else 44.dp
}

/** Base colour of every glass surface over video. */
internal val PlayerGlass = Color(0xFF15171C)

internal fun fmtClock(ms: Long): String {
    val s = (ms.coerceAtLeast(0L) / 1000).toInt(); val h = s / 3600; val m = s / 60 % 60; val r = s % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, r) else "%d:%02d".format(m, r)
}

internal fun speedText(s: Float): String = if (s == 1f) "1.0×" else "${s}×".replace(".0×", "×")
