package app.iduanju.novel

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBackIos
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import app.iduanju.ui.components.*
import app.iduanju.ui.theme.IdjThemeColors

/** Full-screen novel sub page (缓存与下载) in its own window, so the reader / detail underneath keeps its state. */
@Composable
internal fun NovelPage(title: String, onBack: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Dialog(onDismissRequest=onBack, properties=DialogProperties(usePlatformDefaultWidth=false, decorFitsSystemWindows=false)) {
        val view = LocalView.current
        val dark = IdjThemeColors.dark
        SideEffect {
            (view.parent as? DialogWindowProvider)?.window?.let { w ->
                WindowCompat.getInsetsController(w, view).run { isAppearanceLightStatusBars = !dark; isAppearanceLightNavigationBars = !dark }
            }
        }
        val scroll = rememberScrollState()
        val pinned by remember { derivedStateOf { scroll.value > 0 } }
        Box(Modifier.fillMaxSize().dsAmbient(cool = true), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier.widthIn(max = 720.dp).fillMaxSize().verticalScroll(scroll).statusBarsPadding().navigationBarsPadding()
                    .padding(top = 62.dp, bottom = 24.dp).padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp), content = content,
            )
            Box(Modifier.fillMaxWidth().dsPinned(pinned)) {
                DSNavBar(title, Modifier.statusBarsPadding().padding(bottom = 6.dp), leading = {
                    GlassTextButton("返回", icon = Icons.AutoMirrored.Rounded.ArrowBackIos, onClick = onBack)
                })
            }
        }
    }
}

/** Grouped card of a [NovelPage]. */
@Composable
internal fun NovelPanel(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().dsCard(20.dp).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp), content = content)
}
