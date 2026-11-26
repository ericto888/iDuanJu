# 统一播放器与 TVBox 引擎（双端契约）

iOS 为主，Android 为次；两端共享同一套语义、同一套数据模型和同一份用例（`shared/tvbox/cases.json`）。
平台差异只允许出现在本文「平台差异」一节列出的地方。

## 1. 片源统一：一切都走 `Catalog → 详情页 → 播放器`

| 片源 | iOS `DramaSource` | Android sid | Provider |
|---|---|---|---|
| TVBox 点播站点 | `tvb.<uid>` | `tvb:<uid>:<vod_id>` | `TVBoxProvider` |
| TVBox 直播列表 | `tvl.<uid>` | `tvl:<uid>` | `TVBoxLiveProvider` |

- `uid = md5(repoId + "|" + site.key)` 前 12 位（直播为 `repoId + "|live|" + url`）。站点 key 可能含任意字符，不能直接进路由。
- 点播卡片 → `Route.series` / `detail/{sid}`（与短剧同一个详情页）；继续观看 → 直接进播放器。
- 直播 → `Route.play(series, 频道序号)` / `player/{sid}/{index}`，同一个播放器的直播模式。
- 删除 TVBox 专用点播 / 直播播放页、`TVBoxPlayerController`、`TVBoxVideoSurface`。播放历史、收藏统一进 `LibraryStore`（旧 `recentWatches` 首次启动迁移）。

### 模型

- `HGSeriesDetail.lines: [HGPlayLine]`：线路；`episodes` 恒为默认线路。`HGPlayLine { id, name, episodes }`。
- `HGSeriesDetail.isLive`：直播。`episodes` = 频道，`HGEpisode.page` = 分组名，`HGEpisode.media` = `{"urls":[…],"headers":{…},"logo":"","tvgId":"","tvgName":"","epg":"","catchup":{…}}`。
- 点播 `HGEpisode.vid = "<vod_id>#<线路序号>#<集序号>"`，`media = {"f":"<flag>","id":"<play id>"}`（Android vid 前缀 `tvb:<uid>:`）。
- `HGStream.subtitles / format / headers`；`HGResolvedVideo.danmaku`。

## 2. 播放内核

- 一个协调器、一套界面。短剧、长视频、TVBox 点播、TVBox 直播、视频书全部使用它。
- iOS 内核选择（设置「自动 / 系统 / MPV」，默认自动）：
  - 自动：HLS、MP4/MOV/M4V、本地文件、CENC → AVPlayer；FLV、MKV、TS、AVI、WebM、RTMP、RTSP、未知容器 → MPV；
  - AVPlayer 打不开 → 同源换 MPV；MPV 打不开 → 同源换 AVPlayer；两者都失败 → 下一条画质 / 线路。
- Android：ExoPlayer（Media3），按 `format` / 后缀 / 响应头选 HLS、DASH、SS、RTSP、Progressive。
- 起播超时：从开始打开算起，首帧 8 s 未出自动换源（直播 6 s）；每集最多自动换 3 次，之后显示错误和手动换线。稳定播放 60 s 后次数复原。
- 预先解析的下一集超过 3 分钟即作废；预解析地址返回 4xx 时先重新解析一次再换线。连接中途断开按失败恢复（原位置重取），不跳下一集。
- 脚本、JAR、配置缓存先用后刷新：磁盘上有副本就立即使用，后台更新一次。首页先出分类，推荐内容晚到不影响。
- 高频状态（进度、缓冲）不得驱动整页重绘：iOS 用独立 `PlaybackClock`，Android 用 lambda / derivedState 在绘制阶段读取。

## 3. TVBox 配置

- 请求 UA：`okhttp/4.12.0`（很多配置站对浏览器 UA 返回网页）。HTTP、IP、端口、IDN 都允许。
- 宽松 JSON：行 / 块注释、`#` 行注释、单引号、裸 key、尾逗号、字符串内裸换行、BOM。
- 解码：明文；`[A-Za-z0-9]{8}\*\*` 之后 Base64（含图片隐写）；以 `2423` 开头的十六进制 AES-CBC；`url;pk;key` 的 AES-ECB。
- 多仓：`urls[] {url,name}`、`storeHouse[] {sourceName,sourceUrl}`，可继续嵌套一层。
- 相对路径按配置地址解析（`./`、`../`），`clan://`、`file://` 指向本地导入文件。
- 字段：`spider`（`url;md5;xx`、`img+url`）、`sites`、`parses`、`flags`、`lives`、`rules`、`ads`、`headers`、`hosts`、`doh`、`wallpaper`、`logo`、`notice`/`warningText`、`msg`。
- 导入不做联网验证：解析完立即可用；分类、延迟按需惰性获取并缓存（先显示缓存，再后台刷新）。

### 站点类型

| type / api | 种类 | iOS | Android |
|---|---|---|---|
| 0 | CMS XML | 原生 | 原生 |
| 1 | CMS JSON | 原生 | 原生 |
| 4 | 远程 T4 / hipy | 原生 | 原生 |
| 3 `*.js` | JS（drpy / CatVod，QuickJS，ES module） | 本机 | 本机 |
| 3 `*.py` / `py_*` | Python | 本机（内嵌 CPython） | 本机（Chaquopy） |
| 3 `csp_*` | JAR（dex） | 桥接 | 本机（DexClassLoader） |

Spider 方法：`init / homeContent / homeVideoContent / categoryContent / detailContent / searchContent / playerContent / liveContent / proxyLocal / action / isVideoFormat / manualVideoCheck / destroy`。

### 播放解析

`playerContent → {parse, jx, url, playUrl, header, format, subs, danmaku, click, flag}`：

1. `parse=0` 且可直接播放 → 直接播放（`url` 可为 `[名称, 地址, …]` 多画质，header 可为字符串或对象）。
2. `playUrl` 前缀 `json:` / `parse:`，或 `jx=1`，或 flag 在 `flags` 中 → 走 `parses`：0 网页嗅探、1 JSON、2/3 JAR 扩展（iOS 走桥接）、4 超级解析（JSON 与嗅探并发，先到先用）。
3. `parse=1` → 隐藏 WebView 嗅探，受 `rules`（hosts / regex / exclude / script）、`click`、`ads` 影响，15 s 超时。

### 本地代理

`127.0.0.1:9978+`（被占用则递增）：`/proxy?do=ck` 返回 `ok`；`do=js|py|csp|live` 转给对应 spider 的 `proxyLocal`；仅回环地址可访问。

### 直播

频道按「分组 + 名称（+ 第一条地址）」识别，序号只是后备：列表刷新后不会点到别的频道。

TXT（`#genre#`、`url$名称#url2`、`分组_密码`）、M3U（`tvg-*`、`group-title`、`catchup*`、`#EXTVLCOPT`、`#KODIPROP`、`#EXTHTTP`）、JSON；EPG：`{name}/{date}` 模板与 XMLTV（含 gz）；回看 `append/default/shift`。

## 4. 安全

- JAR / PY / JS 是会在设备上执行的代码：导入含代码的配置时弹出一次确认，按配置记录「信任」。未信任时这些站点不加载，CMS / T4 / 直播照常使用。
- 本地导入的文件按文件名识别；同名文件内容变了，信任重置为「询问」，解析成功后才覆盖旧文件。
- JAR 下载后按 `md5` 校验（配置给出时不一致即拒绝），存入应用私有目录并置只读后加载。
- 私有网段：只有配置本身来自私有网段（http/https 地址；粘贴和本地文件不算），或用户打开「允许访问局域网」时才放行；配置、接口、
  播放地址、字幕、弹幕、直播一视同仁，拒绝时提示「该地址在局域网内，请在 TVBox 设置里打开「允许访问局域网」」。回环只允许访问自己的代理；
  Android 另外放行已信任 JAR 自己开的回环服务。
- T4 的 `ext` 是 `clan://` 或回环地址时不读取本机内容，除非配置是本地导入的、且 T4 服务也在本机。
- 成人站点仍受 `SourceGate` 控制；所有结果仍过 `ContentFilter`。

### JAR 桥接（iOS ← Android）

- Android「设置 → TVBox → 局域网桥接」，默认关闭；开启后显示地址与 12 位配对码，监听 9979。
- 请求 `POST /bridge/call`，正文 `{siteKey, api, ext, jar, method, args}`；头 `X-Idj-Time / X-Idj-Nonce / X-Idj-Sign = HMAC-SHA256(配对码, time + "\n" + nonce + "\n" + sha256(body))`，±60 s，nonce 去重。
- Android 只执行自己已导入且已信任的配置里的 JAR（按 jar 地址 + api 匹配），否则返回 403 与中文原因。
- 结果中指向 `127.0.0.1:<端口>/proxy` 的地址由 iOS 改写为桥接地址，并附带短期签名。

## 5. 界面

- 双端同一套信息架构与文案；组件只来自设计组件库（iOS `GlassKit` + `DesignKit`，Android `Glass.kt` + `DesignKit.kt`）。
- iOS 26+ 使用系统 Liquid Glass（`glassEffect` / `GlassEffectContainer`），iOS 16–25 统一材质回退；玻璃只用于浮在内容上的控制层，不做玻璃叠玻璃。
- 不直接暴露系统默认外观的 `List / Form / Picker / Toggle / Alert / confirmationDialog`（Android：Material 默认外观的 `AlertDialog / DropdownMenu / Switch / Slider / OutlinedTextField …`），统一换成组件库版本。
- 不改导航架构与返回栈。

## 平台差异

- JAR：iOS 无法执行 dex，走桥接；未配对时 JAR 站点显示「需要桥接」。
- 画中画、亮度 / 音量手势、系统分享等使用各自系统实现，入口和文案一致。
- P2P（thunder / ed2k / magnet / tvbus / force）依赖闭源原生库，两端均不支持，显示明确提示。
