package app.iduanju.ui.profile

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.ui.components.dsCard
import app.iduanju.ui.theme.IdjThemeColors

/** iOS LicensesView (我的 → 开源许可), Android libraries + the shared ports. */
@Composable
fun LicensesScreen(onBack: () -> Unit) {
    SettingsListPage("开源许可", onBack, spacing = 14.dp) {
        license("i短剧", "GPL-3.0 · 禁止付费分发", "本应用源码以 GPL-3.0 开源。")
        license("AndroidX · Jetpack Compose · Media3", "Apache License 2.0", "界面、播放器（ExoPlayer、HLS、DASH、SmoothStreaming、RTSP、RTMP、OkHttp 数据源）。")
        license("Jellyfin Media3 FFmpeg Decoder", "GPL-3.0", "音频软件解码。使用 org.jellyfin.media3:media3-ffmpeg-decoder:1.5.0+1，源码见 github.com/jellyfin/jellyfin-androidx-media。")
        license("OkHttp · Okio", "Apache License 2.0 · Square, Inc.", "网络请求与安全 DNS。")
        license("LibRtmp Client for Android 3.2.0", "Apache License 2.0 · Ant Media", "RTMP 播放（media3-datasource-rtmp 的依赖，未修改），封装 RTMPDump 的 librtmp（LGPL-2.1）；来源 github.com/mekya/LibRtmp-Client-for-Android。")
        license("Haze · AndroidLiquidGlass", "Apache License 2.0 · Chris Banes · Kyant", "毛玻璃与液态玻璃材质。")
        license("Coil", "Apache License 2.0", "封面与漫画图片加载。")
        license("Kotlin · kotlinx.coroutines", "Apache License 2.0 · JetBrains", null)
        license("QuickJS", "MIT License", "插件与 TVBox 脚本运行时（经 QuickJS 包装库），沙箱封装为本应用代码。")
        license("crypto-js 4.2.0", "MIT License · Jeff Mott, Evan Vosberg", "TVBox JS 站点使用的加密库（随 shared/tvbox/js/lib 分发，保留原许可文本），来源 github.com/brix/crypto-js。")
        license("Gson 2.11.0", "Apache License 2.0 · Google Inc.", "TVBox JAR 站点的宿主接口，未修改；来源 github.com/google/gson。")
        if (app.iduanju.tvbox.runtime.PyRuntime.INCLUDED) license("Chaquopy 16.1.0 · CPython 3.11", "MIT License · PSF License",
            "TVBox Python 站点运行时；随附 requests、urllib3、certifi、idna、charset-normalizer、lxml、pycryptodome、pyquery、cssselect、beautifulsoup4、soupsieve，许可见仓库 THIRD_PARTY_NOTICES.md。")
        license("Rhino 1.7.15", "Mozilla Public License 2.0", "小说书源脚本引擎，未修改；来源 github.com/mozilla/rhino，许可随安装包 assets/licenses 分发。")
        license("hongguo-open-player", "GPL-3.0-only · zfdang (commit 3f687c5)",
            "红果播放签名（Argus 551 / Ladon）参考其 src/server/native/argus.js 移植，与 iOS 实现逐字节一致。")
        license("红果当前播放器签名", "Apache-2.0 变换来源 · OpenHongguo 05aa580 / gateway 0613b49",
            "当前 Medusa 封装移植自 get_video_streaming，KS/自定义变换源自 OpenHongguo，已按原生合成向量验证。源码、修改范围和许可见仓库 THIRD_PARTY_NOTICES.md。")
        license("UAV-Downloader · yt-dlp · JMComic-Crawler-Python", "Apache-2.0 · Unlicense · MIT",
            "部分站点解析与 18comic 图片还原算法参考这些项目，代码为独立实现。")
        license("MangaDex API · 包子漫画 · Telegram 网页预览", null, "漫画与频道解析均为本应用独立实现；MangaDex 只请求全年龄 / 轻度分级内容。")
    }
}

/** One card per project, like iOS. */
private fun LazyListScope.license(name: String, license: String?, note: String?) = item(name, "license") {
    val c = IdjThemeColors
    Column(Modifier.fillMaxWidth().dsCard(18.dp).padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(name, color = c.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        license?.let { Text(it, color = c.secondary, fontSize = 14.sp, lineHeight = 19.sp) }
        note?.let { Text(it, color = c.secondary, fontSize = 12.sp, lineHeight = 17.sp) }
    }
}
