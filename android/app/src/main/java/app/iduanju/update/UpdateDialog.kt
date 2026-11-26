package app.iduanju.update

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.SystemUpdate
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.core.update.AppRelease
import app.iduanju.ui.components.ButtonTone
import app.iduanju.ui.components.DialogAction
import app.iduanju.ui.components.GlassAlert
import app.iduanju.ui.components.GlassProgressBar
import app.iduanju.ui.theme.IdjThemeColors
import kotlinx.coroutines.launch

/** 发现新版本: notes, then 更新 → progress → 安装 (system installer). 稍后 / 忽略此版本 close it. */
@Composable
fun UpdateDialog(u: AppUpdater) {
    val r = u.offer ?: return
    val c = IdjThemeColors
    val scope = rememberCoroutineScope()
    var hint by remember(r.tag) { mutableStateOf<String?>(null) }
    val phase = u.phase
    val downloading = phase is AppUpdater.Phase.Downloading
    val notes = remember(r.tag) { AppRelease.plainNotes(r.notes).ifBlank { r.name } }
    val confirm = when (phase) {
        is AppUpdater.Phase.Downloading -> DialogAction("下载中…", ButtonTone.Primary, loading = true) {}
        is AppUpdater.Phase.Ready -> DialogAction("安装", ButtonTone.Primary) {
            if (!u.install(phase.file)) hint = "请允许 i短剧「安装未知应用」，返回后再点一次「安装」。"
        }
        is AppUpdater.Phase.Failed -> DialogAction("重试", ButtonTone.Primary) { scope.launch { u.download(r) } }
        AppUpdater.Phase.Idle -> DialogAction("更新", ButtonTone.Primary) { scope.launch { u.download(r) } }
    }
    GlassAlert(
        onDismissRequest = { if (phase !is AppUpdater.Phase.Downloading) u.dismiss() },
        title = "发现新版本 ${r.versionName}",
        icon = Icons.Outlined.SystemUpdate,
        dismissible = !downloading,
        message = "当前 ${u.currentVersion.joinToString(".")} · 安装包 ${"%.1f".format(r.apkSize / 1048576.0)} MB",
        actions = buildList {
            add(confirm)
            if (!downloading) {
                add(DialogAction("稍后") { u.dismiss() })
                add(DialogAction("忽略此版本", ButtonTone.Plain) { u.ignore(r) })
            }
        },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            when (phase) {
                is AppUpdater.Phase.Downloading -> {
                    val p = if (phase.total > 0) phase.read.toFloat() / phase.total else 0f
                    GlassProgressBar({ p }, height = 5.dp)
                    Text("正在下载 ${(p * 100).toInt()}%", color = c.secondary, fontSize = 12.sp)
                }
                is AppUpdater.Phase.Failed -> Text(phase.message, color = c.accentWarm, fontSize = 13.sp, lineHeight = 18.sp)
                else -> {}
            }
            hint?.let { Text(it, color = c.accent, fontSize = 13.sp, lineHeight = 18.sp) }
            Text(notes, color = c.text, fontSize = 14.sp, lineHeight = 20.sp)
        }
    }
}
