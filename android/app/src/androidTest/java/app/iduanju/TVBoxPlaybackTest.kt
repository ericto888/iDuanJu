package app.iduanju

import android.content.Intent
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import app.iduanju.core.tvbox.Trust
import app.iduanju.tvbox.ImportResult
import app.iduanju.ui.UiEvidence
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt-in device check against a real TVBox config (`-e tvboxUrl …`) and one caller-selected site (`-e tvboxSite <key>`). */
class TVBoxPlaybackTest {
    @Test fun importedSitePlaysInSeriesPlayer() {
        val args = InstrumentationRegistry.getArguments()
        val url = args.getString("tvboxUrl")
        val key = args.getString("tvboxSite")
        assumeTrue(url != null && key != null)
        val store = IdjApp.instance.tvbox
        val repo = runBlocking { withContext(Dispatchers.Main) { (store.importUrl(url!!) as ImportResult.Imported).repo.also { store.setTrust(it.id, Trust.Trusted) } } }
        try {
            val site = repo.sites.first { it.site.key == key }
            val item = runBlocking {
                val home = store.engine.home(site.uid).toList().last().value
                home.items.firstOrNull { !it.folder } ?: store.engine.category(site.uid, home.categories.first().id, 1).toList().last().value.items.first { !it.folder }
            }
            UiEvidence.playerPositionMs = 0
            UiEvidence.playerPlaying = false
            val ctx = InstrumentationRegistry.getInstrumentation().targetContext
            val intent = Intent(ctx, MainActivity::class.java).putExtra("route", "player/${android.net.Uri.encode(item.sid)}/1")
            ActivityScenario.launch<MainActivity>(intent).use {
                val deadline = SystemClock.elapsedRealtime() + 90000
                while (SystemClock.elapsedRealtime() < deadline && !(UiEvidence.playerPlaying && UiEvidence.playerPositionMs > 2000)) SystemClock.sleep(200)
                assertTrue("player position ${UiEvidence.playerPositionMs} ms", UiEvidence.playerPlaying && UiEvidence.playerPositionMs > 2000)
            }
        } finally { runBlocking { withContext(Dispatchers.Main) { store.remove(repo.id) } } }
    }
}
