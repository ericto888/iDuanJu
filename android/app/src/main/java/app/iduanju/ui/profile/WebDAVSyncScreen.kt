package app.iduanju.ui.profile

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.IdjApp
import app.iduanju.ui.components.*
import app.iduanju.ui.theme.IdjThemeColors
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 我的 → 数据备份与迁移 → WebDAV 多端同步 (1:1 parity with iOS WebDAVSyncView). */
@Composable
fun WebDAVSyncScreen(onBack: () -> Unit) {
    val c = IdjThemeColors
    val sync = IdjApp.instance.webdav
    val scope = rememberCoroutineScope()
    var message by remember { mutableStateOf<String?>(null) }
    var isError by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }

    fun runAction(work: suspend () -> String) {
        scope.launch {
            runCatching { work() }
                .onSuccess { msg ->
                    message = msg
                    isError = false
                    GlassToast.show(msg, long = true)
                }
                .onFailure { e ->
                    val err = e.message ?: "同步失败"
                    message = err
                    isError = true
                    GlassToast.show(err, long = true)
                }
        }
    }

    val statusDetail = remember(sync.busy, sync.lastStatus, sync.lastSyncAt) {
        when {
            sync.busy != null -> sync.busy!!
            sync.lastStatus != null -> {
                val at = sync.lastSyncAt
                if (at > 0L) {
                    val fmt = SimpleDateFormat("M月d日 HH:mm", Locale.CHINA).format(Date(at))
                    "${sync.lastStatus} · $fmt"
                } else sync.lastStatus!!
            }
            else -> "与 iOS / Android 多端互通：同步观看进度、我的收藏、已安装插件及脚本、订阅源、采集站、TVBox 与阅读书源。"
        }
    }

    SettingsPage("WebDAV 多端同步", onBack) {
        // Status card
        Row(
            Modifier.fillMaxWidth().dsCard(20.dp).padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            IconWell(if (sync.isConfigured) Icons.Outlined.CloudUpload else Icons.Outlined.CloudOff, 46.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    if (sync.isConfigured) "多端智能合并同步" else "尚未配置 WebDAV",
                    color = c.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
                )
                Text(
                    statusDetail,
                    color = c.secondary, fontSize = 12.sp, lineHeight = 17.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
                )
            }
        }

        Group("常用服务快捷填充") {
            LinkRow("坚果云 WebDAV", Icons.Outlined.Cloud, sub = "https://dav.jianguoyun.com/dav/") {
                sync.serverURL = "https://dav.jianguoyun.com/dav/"
                if (sync.remoteFolder.isBlank()) sync.remoteFolder = "iDuanJu"
                message = "已填入坚果云地址，请填写注册邮箱与应用专用密码"
                isError = false
                GlassToast.show(message!!)
            }
            RowDivider()
            LinkRow("Alist / OpenList / NAS", Icons.Outlined.Dns, sub = "支持局域网 http:// 与公网 https://") {
                if (sync.serverURL.isBlank()) sync.serverURL = "https://your-nas.example.com/dav/"
                message = "请将地址改为你的 WebDAV 根路径"
                isError = false
                GlassToast.show(message!!)
            }
        }

        Group(
            "服务器配置",
            footer = "密码经系统密钥库加密保存在本机，不会写入导出的备份文件。坚果云请前往网页版「安全选项」生成应用专用密码。",
        ) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                GlassTextField(
                    value = sync.serverURL,
                    onValueChange = { sync.serverURL = it },
                    placeholder = "服务器地址，如 https://dav.jianguoyun.com/dav/",
                    icon = Icons.Outlined.Link,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                )
                GlassTextField(
                    value = sync.username,
                    onValueChange = { sync.username = it },
                    placeholder = "账号 / 邮箱",
                    icon = Icons.Outlined.Person,
                )
                GlassTextField(
                    value = sync.password,
                    onValueChange = { sync.password = it },
                    placeholder = "应用密码",
                    icon = Icons.Outlined.Key,
                    secure = true,
                )
                GlassTextField(
                    value = sync.remoteFolder,
                    onValueChange = { sync.remoteFolder = it },
                    placeholder = "远程目录（默认 iDuanJu）",
                    icon = Icons.Outlined.Folder,
                )
            }
            RowDivider()
            SwitchRow(
                title = "自动多端同步",
                icon = Icons.Outlined.Sync,
                sub = "启动与切到后台时自动双向合并进度和插件",
                on = sync.autoSync,
            ) { on ->
                sync.autoSync = on
                sync.saveConfig()
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            GlassButton(
                text = sync.busy ?: "立即双向同步（推荐）",
                modifier = Modifier.fillMaxWidth(),
                tone = ButtonTone.Primary,
                size = ButtonSize.Large,
                icon = Icons.Outlined.Sync,
                enabled = sync.busy == null,
                loading = sync.busy != null,
            ) { runAction { sync.syncNow() } }

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                GlassButton(
                    text = "测试并保存",
                    modifier = Modifier.weight(1f),
                    tone = ButtonTone.Glass,
                    size = ButtonSize.Regular,
                    enabled = sync.busy == null,
                ) { runAction { sync.testConnection() } }
                GlassButton(
                    text = "仅上传",
                    modifier = Modifier.weight(1f),
                    tone = ButtonTone.Glass,
                    size = ButtonSize.Regular,
                    enabled = sync.busy == null,
                ) { runAction { sync.pushOnly() } }
                GlassButton(
                    text = "仅拉取",
                    modifier = Modifier.weight(1f),
                    tone = ButtonTone.Glass,
                    size = ButtonSize.Regular,
                    enabled = sync.busy == null,
                ) { runAction { sync.pullOnly() } }
            }
        }

        if (message != null) Note(message, error = isError)

        if (sync.isConfigured) {
            Group("管理") {
                LinkRow("清除 WebDAV 配置", Icons.Outlined.Delete, tint = c.danger) {
                    confirmClear = true
                }
            }
        }
    }

    if (confirmClear) {
        GlassConfirm(
            onDismissRequest = { confirmClear = false },
            title = "清除 WebDAV 配置？",
            message = "仅清除本机保存的服务器信息与密码，不会删除云端已同步文件。",
            confirmText = "清除配置",
            destructive = true,
            onConfirm = {
                sync.clearConfig()
                confirmClear = false
                message = "已清除 WebDAV 配置"
                isError = false
                GlassToast.show(message!!)
            },
        )
    }
}
