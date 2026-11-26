package app.iduanju.ui.components

import android.os.Build
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback

/**
 * Every duration / easing / transition of the app in one place. Selection, panel and press springs stay in [DS]
 * (the iOS springs); this adds the page and overlay transitions so no screen invents its own.
 */
object Motion {
    const val QUICK = 120
    const val SHORT = 180
    const val MEDIUM = 240
    const val LONG = 320

    val Emphasized = CubicBezierEasing(0.2f, 0f, 0f, 1f)
    val Decelerate = CubicBezierEasing(0.05f, 0.7f, 0.1f, 1f)
    val Accelerate = CubicBezierEasing(0.3f, 0f, 0.8f, 0.15f)

    fun <T> fade(ms: Int = SHORT) = tween<T>(ms)

    /** Centred modal panels (dialogs, countdown cards, tablet sheets). */
    val modalEnter: EnterTransition get() = fadeIn(tween(SHORT)) + scaleIn(DS.panel(), initialScale = 0.94f)
    val modalExit: ExitTransition get() = fadeOut(tween(QUICK)) + scaleOut(tween(SHORT), targetScale = 0.96f)

    /** Panels rising from the bottom edge (player sheets, play bars, toasts). */
    val riseEnter: EnterTransition get() = fadeIn(tween(SHORT)) + slideInVertically(DS.panel()) { it / 6 }
    val riseExit: ExitTransition get() = fadeOut(tween(QUICK)) + slideOutVertically(tween(SHORT, easing = Accelerate)) { it / 8 }

    /** Side drawers (landscape channel list, danmaku settings). */
    val sideEnter: EnterTransition get() = fadeIn(tween(SHORT)) + slideInHorizontally(DS.panel()) { it / 4 }
    val sideExit: ExitTransition get() = fadeOut(tween(QUICK)) + slideOutHorizontally(tween(SHORT, easing = Accelerate)) { it / 4 }

    // ── Page transitions ────────────────────────────────────────────────────────────────────────────────
    // navigation-compose defaults to a 700 ms cross-fade, which reads as lag. Pushes slide a fifth of the width like
    // iOS (a full-width slide would show the first, heaviest frames of the new page); tabs only fade.
    val pagePushEnter: EnterTransition get() =
        slideInHorizontally(tween(LONG, easing = Decelerate)) { it / 5 } + fadeIn(tween(SHORT))
    val pagePushExit: ExitTransition get() =
        slideOutHorizontally(tween(LONG, easing = Decelerate)) { -it / 10 } + fadeOut(tween(SHORT))
    val pagePopEnter: EnterTransition get() =
        slideInHorizontally(tween(LONG, easing = Decelerate)) { -it / 10 } + fadeIn(tween(SHORT))
    val pagePopExit: ExitTransition get() =
        slideOutHorizontally(tween(MEDIUM, easing = Emphasized)) { it / 5 } + fadeOut(tween(SHORT))

    val tabEnter: EnterTransition get() = fadeIn(tween(SHORT))
    val tabExit: ExitTransition get() = fadeOut(tween(QUICK))
}

/** Semantic haptics; devices without the richer constants fall back to a clock tick. */
@Stable
class Haptics(private val feedback: HapticFeedback) {
    /** A value moved past a notch (sliders, segmented scrubbing). */
    fun tick() = feedback.performHapticFeedback(HapticFeedbackType.SegmentFrequentTick)
    /** A different option was chosen. */
    fun select() = feedback.performHapticFeedback(HapticFeedbackType.SegmentTick)
    fun toggle(on: Boolean) = feedback.performHapticFeedback(if (on) HapticFeedbackType.ToggleOn else HapticFeedbackType.ToggleOff)
    fun confirm() = feedback.performHapticFeedback(HapticFeedbackType.Confirm)
    fun reject() = feedback.performHapticFeedback(HapticFeedbackType.Reject)
    fun longPress() = feedback.performHapticFeedback(HapticFeedbackType.LongPress)
}

@Composable
fun rememberHaptics(): Haptics {
    val f = LocalHapticFeedback.current
    return remember(f) { Haptics(f) }
}

/**
 * Whole-element press feedback for an element that already owns an interaction source. Put it first in the chain, so
 * the surface scales together with its label; the animated value is read in the layer block only.
 */
@Composable
fun Modifier.pressScale(source: InteractionSource, scale: Float = 0.97f, dim: Float = 0.9f): Modifier {
    val pressed by source.collectIsPressedAsState()
    val s = animateFloatAsState(if (pressed) scale else 1f, DS.press(), label = "pressScale")
    return this.graphicsLayer {
        scaleX = s.value; scaleY = s.value
        alpha = if (scale >= 1f) 1f else 1f - (1f - dim) * ((1f - s.value) / (1f - scale)).coerceIn(0f, 1f)
    }
}

/** True when the platform can blur behind another window (dialogs and sheets). */
internal fun windowBlurSupported(wm: android.view.WindowManager): Boolean =
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && wm.isCrossWindowBlurEnabled
