package app.iduanju

import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import app.iduanju.core.tvbox.TVBoxId
import app.iduanju.core.tvbox.Trust
import app.iduanju.tvbox.ImportResult
import app.iduanju.tvbox.TVBoxConfigScreen
import app.iduanju.tvbox.TVBoxHubScreen
import app.iduanju.tvbox.TVBoxRepo
import app.iduanju.ui.theme.IdjTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File

/** TVBox tab on a device with a local fixture config (the test APK is the jar): no network, no invented source. */
class TVBoxHubTest {
    @get:Rule val ui = createAndroidComposeRule<androidx.activity.ComponentActivity>()
    private val inst = InstrumentationRegistry.getInstrumentation()
    private val store get() = IdjApp.instance.tvbox
    private val opened = ArrayList<String>()
    private val played = ArrayList<Pair<String, Int>>()
    private var repo: TVBoxRepo? = null

    private fun <T> main(f: suspend () -> T): T = runBlocking { withContext(Dispatchers.Main) { f() } }

    private fun import(trust: Boolean) {
        main {
            store.importLocal(File(inst.context.packageCodePath).readBytes(), "hub.jar")
            store.importLocal("央视,#genre#\nCCTV-1 综合,http://127.0.0.1/1\nCCTV-5 体育,http://127.0.0.1/5#http://127.0.0.1/5b\n加锁_1234,#genre#\n锁定频道,http://127.0.0.1/9\n".toByteArray(), "hub-live.json")
            val r = store.importLocal("""{"spider":"./hub.jar","notice":"测试公告","sites":[{"key":"demo","name":"演示站","type":3,"api":"csp_Demo","ext":"E"},{"key":"cms","name":"采集站","type":1,"api":"https://cms.invalid/api.php"},{"key":"py","name":"蟒站","type":3,"api":"./none.py"}],"lives":[{"name":"演示直播","url":"clan://localhost/hub-live.json"}]}""".toByteArray(), "hub.json", "演示配置")
            repo = (r as ImportResult.Imported).repo
            store.setTrust(repo!!.id, if (trust) Trust.Trusted else Trust.Ask)
        }
    }

    @After fun cleanup() { main { store.repos.filter { it.record.url.contains("hub") }.forEach { store.remove(it.id) } } }

    private fun shot(name: String) {
        ui.waitForIdle()
        Thread.sleep(500)
        val b = inst.uiAutomation.takeScreenshot() ?: return
        val o = ByteArrayOutputStream()
        b.compress(Bitmap.CompressFormat.PNG, 100, o)
        saveNovelEvidence(name, o.toByteArray())
    }

    private fun hub(dark: Boolean = false) = ui.setContent { IdjTheme(dark) { TVBoxHubScreen(onOpenConfig = {}, onOpenDetail = { opened += it }, onPlay = { s, i -> played += s to i }) } }
    private fun wait(text: String, substring: Boolean = false) = ui.waitUntil(20_000) { ui.onAllNodesWithText(text, substring).fetchSemanticsNodes().isNotEmpty() }

    @Test fun siteCategoriesFoldersAndSearch() {
        import(trust = true)
        hub()
        wait("演示影片 Edemo")
        shot("tvbox-hub-vod.png")
        ui.onNodeWithText("演示影片 Edemo").performClick()
        assertEquals("id/1?x=%20&y={\"a\":1}#z", TVBoxId.parseVod(opened.single())!!.id)
        ui.onNodeWithText("演示分类").performClick()
        wait("第 0 部", true)
        ui.onNodeWithContentDescription("筛选").performClick()
        wait("大陆")
        shot("tvbox-hub-filter.png")
        ui.onNodeWithText("大陆").performClick(); ui.onNodeWithText("完成").performClick()
        wait("area=cn", true)
        ui.onNodeWithText("推荐").performClick()
        wait("演示目录")
        ui.onNodeWithText("演示目录").performClick()
        wait("folder{}", true)
        ui.onNodeWithText("返回").performClick()
        wait("演示影片 Edemo")
        ui.onNodeWithText("全部站").performClick()
        ui.onNode(hasSetTextAction()).performTextInput("关键词"); ui.onNode(hasSetTextAction()).performImeAction()
        ui.waitUntil(30_000) { ui.onAllNodes(hasText("关键词") and hasClickAction().not()).fetchSemanticsNodes().isNotEmpty() || ui.onAllNodesWithText("已返回", true).fetchSemanticsNodes().isNotEmpty() }
        shot("tvbox-hub-search.png")
    }

    @Test fun liveGroupsLocksAndPlayerRoute() {
        import(trust = true)
        hub(dark = true)
        wait("直播")
        ui.onNodeWithText("直播").performClick()
        wait("CCTV-1 综合")
        shot("tvbox-hub-live.png")
        ui.onNodeWithText("CCTV-5 体育").performClick()
        assertEquals(TVBoxId.live(repo!!.lives.single().uid) to 2, played.single())
        assertEquals(0, ui.onAllNodesWithText("锁定频道").fetchSemanticsNodes().size)
        ui.onNodeWithText("加锁（已锁）").performClick()
        wait("「加锁」已加锁")
        ui.onNode(hasSetTextAction() and hasAnyAncestor(isDialog())).performTextInput("1234")
        ui.onNodeWithText("打开").performClick()
        wait("锁定频道")
    }

    @Test fun untrustedConfigAsksFirst() {
        import(trust = false)
        hub()
        wait("信任后才会运行", true)
        ui.onNodeWithText("查看").performClick()
        wait("信任并启用")
        shot("tvbox-hub-trust.png")
        ui.onNodeWithText("信任并启用").performClick()
        ui.waitUntil(5_000) { store.repos.first { it.id == repo!!.id }.trusted }
    }

    @Test fun configScreenShowsSitesNetworkAndBridge() {
        import(trust = true)
        ui.setContent { IdjTheme(false) { TVBoxConfigScreen {} } }
        wait("演示配置")
        shot("tvbox-config.png")
        ui.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("开启桥接"))
        shot("tvbox-config-bridge.png")
        assertTrue(ui.onAllNodesWithText("局域网桥接").fetchSemanticsNodes().isNotEmpty())
    }
}
