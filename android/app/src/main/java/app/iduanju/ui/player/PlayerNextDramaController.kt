package app.iduanju.ui.player

import android.content.Context
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import app.iduanju.IdjApp
import app.iduanju.ui.components.Motion
import com.kyant.backdrop.Backdrop
import kotlinx.coroutines.delay

/** 播完连刷推荐 countdown before the recommended drama starts. */
private const val NEXT_DRAMA_COUNTDOWN_MS = 3_000L

/** 播完连刷推荐 for numeric catalogue series (never for chapter queues, live lists or fixtures). */
@Stable
internal class NextDramaController(private val ctx: Context, private val session: PlayerSession) {
    private val lib = IdjApp.instance.library
    internal var onSwitchSeries: (String) -> Unit = {}

    val capable: Boolean get() = !session.queued && !session.fixture && !session.channelList && session.seriesId.isNotEmpty() && session.seriesId.all { it.isDigit() }
    var enabled by mutableStateOf(PlayerPrefs.getAutoContinueNextDrama(ctx))
        private set
    var pick by mutableStateOf<NextDramaPick?>(null)
        private set
    var loading by mutableStateOf(false)
        private set
    var countdownOn by mutableStateOf(false)
        private set
    private var countdownMs by mutableLongStateOf(NEXT_DRAMA_COUNTDOWN_MS)
    private var awaiting by mutableStateOf(false)
    /** Bumped to (re-)pick: 换一部 or a retry when the final episode ended before a pick was ready. */
    private var nonce by mutableIntStateOf(0)
    private var switching = false

    val progress: () -> Float = { 1f - countdownMs.toFloat() / NEXT_DRAMA_COUNTDOWN_MS }
    val secondsLeft: () -> Int = { ((countdownMs + 999L) / 1000L).toInt() }
    /** Swiping up past the last episode opens this. */
    val swipePick: NextDramaPick? get() = pick?.takeIf { capable && enabled }

    fun applyEnabled(on: Boolean) {
        enabled = on
        PlayerPrefs.setAutoContinueNextDrama(ctx, on)
        if (!on) { countdownOn = false; awaiting = false }
        session.hint = if (on) "播完连刷推荐：已开启" else "播完连刷推荐：已关闭"
    }

    /** Final episode finished: the countdown shows as soon as a pick is ready. */
    fun onFinalEnded() { if (capable && enabled) awaiting = true }

    /** Replayed / sought back from the end: the user is still watching this drama. */
    private fun onReplayed() { if (!switching) { countdownOn = false; awaiting = false } }

    fun play(p: NextDramaPick) {
        if (switching) return
        switching = true
        countdownOn = false; awaiting = false
        onSwitchSeries(p.series.seriesId)
    }

    /** Navigation replaces the screen; only undo if it somehow did not. */
    fun switchFailed() { switching = false }

    fun swap() {
        val cur = pick ?: return
        PlayerNextDrama.skip(cur.series.seriesId)
        countdownMs = NEXT_DRAMA_COUNTDOWN_MS
        pick = null
        nonce++
    }

    fun cancel() { countdownOn = false; session.hint = "已取消连刷，上滑仍可播放推荐" }

    @Composable
    fun Effects(paused: Boolean) {
        val n = session.episodes.size
        val nearFinal = n > 0 && session.epIndex >= n - 2
        val onFinal = n > 0 && session.epIndex == n - 1
        // Lazily pick on the last 1–2 episodes, then warm the pick's detail so the switch has no detail round-trip.
        LaunchedEffect(capable, enabled, nearFinal, session.detail?.seriesId, nonce) {
            val d = session.detail
            if (!capable || !enabled || !nearFinal || d == null || pick != null) return@LaunchedEffect
            loading = true
            val watched = lib.history.mapTo(HashSet()) { it.seriesId }
            val p = try { PlayerNextDrama.pickNextDrama(d, watched) }
                catch (e: kotlinx.coroutines.CancellationException) { throw e }
                catch (e: Exception) { android.util.Log.w("IDJ", "next drama pick failed", e); null }
                finally { loading = false }
            pick = p
            if (p == null) {
                if (awaiting || countdownOn) session.hint = "暂无更多推荐"
                awaiting = false; countdownOn = false
                return@LaunchedEffect
            }
            PlayerNextDrama.prefetchDetail(p.series.seriesId)
        }
        // On the final episode, resolve the pick's episode 1 too (≥ 8 s after this episode's own resolve, so the
        // back-to-back player registrations are never soft-rejected).
        LaunchedEffect(onFinal, pick?.series?.seriesId, enabled) {
            val p = pick
            if (!onFinal || !enabled || p == null || !IdjApp.instance.settings.prefetchEnabled) return@LaunchedEffect
            delay(8_000)
            PlayerNextDrama.prefetchDetail(p.series.seriesId)?.let { PlayerNextDrama.prepareFirstEpisode(it) }
        }
        LaunchedEffect(awaiting, pick, loading) {
            if (!awaiting) return@LaunchedEffect
            when {
                pick != null -> { countdownMs = NEXT_DRAMA_COUNTDOWN_MS; countdownOn = true; awaiting = false }
                !loading -> nonce++
            }
        }
        LaunchedEffect(session.ended) { if (!session.ended) onReplayed() }
        // 3-second countdown, frame-clocked (stops with rendering); paused while a settings sheet is open.
        val isPaused by rememberUpdatedState(paused)
        LaunchedEffect(countdownOn, pick, paused) {
            val p = pick
            if (!countdownOn || p == null || isPaused) return@LaunchedEffect
            var last = withFrameMillis { it }
            while (countdownMs > 0L) {
                val now = withFrameMillis { it }
                countdownMs = (countdownMs - (now - last)).coerceAtLeast(0L)
                last = now
            }
            play(p)
        }
    }

    @Composable
    fun CountdownCard(visible: Boolean, paused: Boolean, backdrop: Backdrop?, modifier: Modifier) {
        AnimatedVisibility(visible && countdownOn, modifier, enter = Motion.modalEnter, exit = Motion.modalExit) {
            NextDramaCountdownCard(
                pick = pick,
                loading = loading,
                progressProvider = progress,
                secondsLeftProvider = secondsLeft,
                paused = paused,
                onPlay = { pick?.let { play(it) } },
                onSwap = ::swap,
                onCancel = ::cancel,
                backdrop = backdrop,
                // swallow taps on the card background so they never toggle the HUD underneath
                modifier = Modifier.pointerInput(Unit) { detectTapGestures { } },
            )
        }
    }
}
