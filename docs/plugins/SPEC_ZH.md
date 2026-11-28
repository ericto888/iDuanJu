# i短剧 插件规范 idj1（给写源的人看）

> 版本：idj1 草案 · 2026-11-10（UTC+8）。App 还没有实现，这份是要冻结的格式。
> 字段的完整类型标注见同目录 `idj-plugin.d.ts`，可运行的示例见 `manga18fx/`，检查和测试工具见 `harness/idj.mjs`。

## 1. 一个插件长什么样

```
manga18fx/
├── manifest.json   必须：身份、类型、权限、更新地址
├── main.js         必须：入口脚本（manifest.entry）
└── icon.png        可选
```

插件只有一个脚本文件（不支持 import，包括相对路径 import）。分发时打成 `.idjplugin`：一个 JSON 文件 `{"manifest": {...}, "files": {"main.js": "..."}}`（不是 zip，`files` 里只能有入口脚本）。也可以直接给 `manifest.json` 的网址，App 按 `entry` 把同目录的脚本一起下回来。

## 2. manifest.json 逐项说明

| 字段 | 必填 | 说明 |
|---|---|---|
| `schema` | ✓ | 固定 `1` |
| `id` | ✓ | 反向域名，全局唯一，如 `com.yourname.manga18fx`。装好后不能改，改了算另一个插件 |
| `name` / `version` | ✓ | 显示名；版本号 `x.y.z`，升级必须变大 |
| `author` | ✓ | `{ "name": "...", "contact": "..." }` |
| `type` | ✓ | `video` 长视频 · `shortdrama` 短剧（竖屏、多集） · `comic` 漫画 · `live` 直播 |
| `adult` | ✓ | 必须显式写 `true/false`。`true` 的插件只在「片源管理」打开成人内容并通过 Face ID 后才出现 |
| `minAppVersion` | ✓ | 低于这个版本的 App 拒绝安装 |
| `entry` | ✓ | 入口脚本文件名 |
| `permissions.http` | ✓ | 脚本能请求的域名。只能写 `a.com` 或 `*.a.com`；不能写 `*`、IP、端口 |
| `permissions.media` | | 播放器/图片加载器能去的域名（CDN 常和网页不同）。不写 = 同 `http` |
| `permissions.cloudflare` | | `true` = 允许 App 在后台浏览器里替它过 CF 验证（只对 `http` 里的域名） |
| `permissions.storage` | | `true` = 可用 `host.storage`（每插件 1MB，互相看不到） |
| `permissions.login` | | `true` = 可以请用户在 App 的独立浏览器里登录这个站（cookie 只进本插件） |
| `capabilities` | ✓ | 实现了哪些函数。video/shortdrama 至少 `detail`+`play`；comic 至少 `detail`+`pages`；声明首页功能时还需包含 `home` |
| `homeFeatures` | | 首页展示能力，可选值：`featured`（精选轮播）、`categoryShelves`（按真实分类显示多条横向货架）、`numbered`（分类「全部」列表显示序号）。可组合；不声明 `numbered` 时使用普通无序号海报网格。声明任一首页功能时，`capabilities` 必须包含 `home` |
| `settings` | | 让用户填的配置项，如镜像地址、API key：`[{ "key": "mirror", "name": "镜像", "type": "text\|select\|secret", "default": "..." }]`。`secret` 类型脚本只拿到句柄，见安全说明 |
| `update.url` | | 新版 manifest 的地址。必须是 https |
| `integrity` | ✓(打包时) | 每个文件的 `sha256-…`，由 `idj pack` 填写；`signature` 可选（作者 Ed25519 签名） |

**权限越少越好。** 安装时用户会看到完整列表；升级时如果权限变多（多了域名、开了 CF/登录），App 会单独弹窗让用户再确认一次，不同意就停在旧版。

## 3. 要写哪些函数

`export default { ... }`，每个函数收**一个参数对象**，返回**普通对象**（可以 `async`）。

| 函数 | 参数 | 返回 | 何时调用 |
|---|---|---|---|
| `init` | `{}` | 无 | 每次加载插件 |
| `home` | `{}` | `{ categories, items? }` | 打开插件首页；仅声明 `categoryShelves` 才进入统一多货架首页；同时声明 `featured` 且有有效 `items` 时使用精选轮播，否则按分类顺序选第一个有内容的分类作为轮播来源 |
| `category` | `{ id, page, filters }` | `{ items, page, hasMore }` | 分类翻页，`page` 从 1 开始 |
| `search` | `{ keyword, page }` | `{ items, page, hasMore }` | 全局搜索会并发调用所有开着的插件 |
| `detail` | `{ id }` | 视频：`{ title, cover, desc, lines:[{name, episodes:[{id,name}]}] }`；漫画：`{ title, cover, desc, chapters:[{id,name}] }` | 进详情页 |
| `play` | `{ line, episodeId, id }` | `{ streams:[{ url, format, headers, proxy? }], subtitles?, danmaku?, skip? }` | 点播放；`expiresAt` 到期前会再调 |
| `pages` | `{ chapterId }` | `{ images:[{ url, transform? }], headers? }` | 漫画进章节 |
| `danmaku` | `{ episodeKey, episodeId, seriesId, id, line, title, episodeName, ep, url, from, to }` | `{ items:[{ time, text, color?, mode?, likes? }], truncated? }` 等 | 可选；支持独立 `danmaku()` 导出或由 `play()` 直接返回 |

首页声明示例：
```json
{
  "capabilities": ["detail", "play", "home"],
  "homeFeatures": ["featured", "categoryShelves"]
}
```
如需在分类「全部」列表显示序号，再加入 `"numbered"`；不声明时不显示排名数字。`categoryShelves` 是启用统一多货架首页的必要开关；`featured` 只决定该首页是否优先使用插件提供的精选数据，未声明或没有有效精选时仍会从真实分类中寻找第一个有内容的分类作为轮播来源。未声明 `categoryShelves` 的旧插件继续使用原有首页路径。首页布局和分页由 App 统一提供。

规则：
- **id 都是你自己定的字符串**，App 原样存、原样传回。不要把 cookie、token 塞进 id（会被存进观看历史）。
- 所有地址必须是 `http(s)` 绝对地址，相对地址自己补全。
- 列表里 `title` 和 `id` 不能空；没有封面就不写，别写占位图。
- 漫画 `chapters`、视频 `episodes` 一律**旧→新**。
- 出错用 `throw host.error('E_PARSE', '人能看懂的原因')`，不要吞掉错误返回空列表（空列表 App 会当成「真的没有」）。

## 4. 播放怎么描述（插件不碰播放器）

插件只告诉 App **去哪取、带什么请求头、要不要本地代理做什么处理**。播放、倍速、画质切换、预缓冲、弹幕渲染、字幕渲染、横竖屏，全在 App 里，插件不能也不需要控制。

```js
return {
  streams: [{
    name: '1080P', url: 'https://cdn.example.com/x/index.m3u8', format: 'hls',
    headers: { Referer: 'https://example.com/' },
    proxy: { stripFakeHeader: 'auto' }          // TS 段前有假 PNG 头时
  }],
  subtitles: [{ url: 'https://example.com/a.vtt', lang: 'zh', format: 'vtt' }],
  skip: { introEnd: 90 }
};
```

`proxy` 能声明的处理（都由 App 原生代码执行，插件不在播放热路径里跑代码）：`stripFakeHeader`（去假头）、`hlsKey`（覆盖 AES-128 key）、`segmentDecrypt`（分段解密）、`drm: {type:'cenc-ctr', key}`（CENC MP4 解密）、`rewriteHosts`（段地址换 CDN）。

图片同理：`transform: {type:'stripes', segments: 10}` 让 App 原生把打乱的横条拼回去（18comic 这类）；`{type:'aes', ...}` 解密加密图片（黄果封面这类）。

图片 CDN 权限：
- 图片地址优先使用 manifest 的 `permissions.media`（未声明时同 `permissions.http`）域名。
- 新版 App 会从该插件成功请求的、已授权 HTTPS `permissions.http` 响应中提取外部域名作为短期候选；支持 HTML、JSON、JavaScript、带路径的完整图片/CDN URL，以及不带路径或不带协议的 CDN 主机声明。候选本身不授予访问权限。
- 宿主只有在把同一主机上的准确 URL 识别为封面、海报、缩略图或漫画页，并转换为原生图片引用时，才会提升为该插件的图片授权。Nuxt 索引表等 URL 与图片字段不相邻的结构也可工作；不能仅凭域名出现或 `.jpg` 等文件后缀授权。
- 对 JSON 中的加密响应，App 只记录成功授权响应里有界的 Base64 密文片段；只有插件随后通过 `host.crypto.aes` 解密了与这些真实响应字节匹配的密文，解密后的文本才会进入候选扫描。插件自行构造的密文/JSON 不会因此获得授权。
- 动态学习只增加该插件的图片读取权限，不会扩大 `host.http` 权限。候选保留 10 分钟；经原生图片引用确认后授权 24 小时；按插件隔离，最多 64 个域名。响应扫描上限为 8MB，加密来源片段缓存有数量和内存上限。插件更新、卸载或清除数据后，旧请求不能重新写入缓存。
- 初始图片地址及每一跳重定向都会重新校验域名和 DNS 公网地址。重定向只允许 manifest 已授权、已学习，或来自可信响应候选且处于已确认图片请求链中的主机；任意外部跳转仍会被阻止，最多跟随 10 跳。动态域名仅 HTTPS 标准端口；manifest 明确授权的旧 HTTP:80 兼容规则不变。IP、本机及内网地址仍会被拦截，图片大小上限仍为 30MB。

### 4.1 三方插件弹幕接口（参考红果插件实现）

插件可以通过以下**任一方式**接入 App 原生弹幕层（支持竖屏短剧与横屏长视频、字号/透明度/区域/屏蔽词/重复合并全套能力）：

1. **方式 A：导出 `danmaku(arg)` 函数（推荐，与 `PluginsSrc/hongguo/main.js` 一致）**
   - 在 `manifest.json` 的 `capabilities` 中加入 `"danmaku"`（未写但脚本实际导出了 `danmaku` 函数也会自动识别）。
   - App 播放分集时会调用 `danmaku(arg)`，入参同时提供：
     - `episodeKey` / `episodeId`：当前集 ID（与 `play()` 的 `episodeId` 相同）
     - `seriesId` / `id`：剧集 ID（与 `detail()` / `play()` 的 `id` 相同）
     - `line`：当前线路名称；`title`：剧名；`episodeName`：分集标题；`ep`：集数序号（从 1 开始）；`url`：当前选中的视频流地址
     - `from` / `to`：起止秒数（全量拉取时均为 `0`）
   - 支持的返回格式（上限 12,000 条，自动去重与按时间排序）：
     ```js
     // 1) 标准结构化列表（红果插件同款）
     return {
       items: [
         {
           time: 12.5,          // 秒（也兼容毫秒字段 progress: 12500）
           text: '前方高能',     // 弹幕文本（<=200 字）
           color: '#FFFFFF',    // 可选：#RRGGBB 或十进制整数如 16777215
           mode: 'scroll',      // 可选：'scroll' | 'top' | 'bottom'（或 B 站 1/5/4）
           likes: 0             // 可选：点赞数（>=50 高亮加粗）
         }
       ],
       truncated: false
     };

     // 2) 直接透传 B 站 XML 或弹弹Play / DPlayer JSON 文本
     const res = await host.http.get('https://comment.example.com/123.xml');
     return { xml: res.body };

     // 3) 返回白名单内的 HTTPS 弹幕文件地址（自动附带插件 Cookie 与自定义请求头）
     return { url: 'https://comment.example.com/123.xml', headers: { Referer: 'https://example.com/' } };
     ```

2. **方式 B：在 `play()` 返回值中直接附带 `danmaku` 字段**
   - 适合在解析播放地址时就能一并拿到弹幕链接或内联弹幕数据的站点：
     ```js
     return {
       streams: [{ name: '1080P', url: m3u8Url, format: 'hls' }],
       danmaku: 'https://comment.example.com/ep1.xml' // 或 { url, headers } / { items: [...] } / { xml: '...' }
     };
     ```

## 5. 宿主能力 host.*

| 能力 | 说明 |
|---|---|
| `host.http.request(o)` | 唯一的联网方式。只能访问 `permissions.http` 里的域名（跳转后的落点也查），禁止本机/内网地址。自动带本插件自己的 cookie。`cloudflare:'auto'` 时遇到 CF 会由 App 在本插件专用的后台浏览器里过验证再重试 |
| `host.html.parse(text)` | 原生 HTML 解析，`select(css)` / `selectFirst(css)` / `text()` / `attr()` / `html()`。比在 JS 里用正则快得多 |
| `host.crypto.*` | md5 / sha1 / sha256 / hmac / aes(cbc/ecb/ctr/gcm) / rsa 公钥加密与验签 / 随机数 |
| `host.codec.*` | base64、hex、gunzip、`unpackPacker`（解 `eval(function(p,a,c,k,e,d)…)`，纯字符串替换，不执行） |
| `host.m3u8.parse` | 解析 master/media playlist，地址自动补全 |
| `host.storage` | 本插件私有 KV（需 `permissions.storage`） |
| `host.settings` | 用户在插件设置里填的值 |
| `host.log` | 写入本插件日志（「片源管理 → 插件 → 日志」可看） |
| `host.error(code, msg)` | 构造标准错误 |

**没有的东西**：`eval` / `new Function` / 动态 `import()`、`fetch` / `XMLHttpRequest` / `WebSocket`、`document` / `window`、文件系统、剪贴板、通知、打开网页、Telegram/红果/其他插件的任何数据。

## 6. 错误码

| 码 | 含义 | App 怎么处理 |
|---|---|---|
| `E_NETWORK` / `E_TIMEOUT` | 网络不通 / 超时 | 提示重试，可自动换镜像（如果插件设置里有） |
| `E_HTTP` | 非 2xx | 显示状态码 |
| `E_CF_REQUIRED` | 后台过不了 CF | 弹出「去验证」 |
| `E_LOGIN_REQUIRED` | 需要登录 | 有 `login` 权限时弹出登录页 |
| `E_PARSE` | 页面结构变了 | 提示「源可能失效，去更新」 |
| `E_NOT_FOUND` / `E_GEO` / `E_RATE_LIMIT` | 不存在 / 地区限制 / 被限流 | 原样提示 |
| `E_UNSUPPORTED` | 这个操作本插件不支持 | 隐藏入口 |
| `E_PERMISSION` | 访问了未声明的域名 | 宿主抛出，记日志 |
| `E_INTERNAL` | 其他 | 显示消息 |

## 7. 只支持 idj1 格式

App 只接受本规范（idj1）的插件，不提供 FongMi / 影视TV（CatVod）兼容模式；manifest 里出现 `compat` 且不是 `idj1` 会被拒绝安装。老脚本需要按本规范改写（函数名和返回结构见上文）。苹果 CMS 采集站（`/api.php/provide/vod/`）不需要脚本：App 内置通用适配器，在「我的 → 插件 → 采集站」里填接口地址，或写进订阅列表的 `cms` 数组。

可从插件导入入口选择 TVBox JSON 配置。App 只映射 `sites` 里 `type: 1` 且 `api` 可规范化为公网 HTTPS 的站点到内置苹果 CMS 适配器，并逐个请求分类接口验证；单次最多处理 50 个站点。其它 type、无效/重复地址会跳过。`spider`/JAR、CatVod JavaScript、Python spider、直播规则和解析器不会下载或执行，也不因此获得兼容支持。映射后的 MacCMS API 仍受本应用安全检查及只播放直链 m3u8/mp4 的限制。

订阅列表格式：`{"name": "...", "plugins": [{"id","name","manifest","type","adult","version","description"}], "cms": [{"name","api","adult"}]}`，`manifest` 可以是相对订阅地址的路径。

## 8. 写完怎么自测

```
cd harness && npm i && node idj.mjs validate ../你的插件
node idj.mjs test ../你的插件 搜索词
```

`validate` 查 manifest 格式、禁用写法（eval / fetch / require / window…）、脚本里写死但没声明的域名。`test` 在和 App 同样的限制下（无 eval、域名白名单、禁内网）实际跑 home → category → search → detail → pages/play，并校验返回结构，最后自检越权访问会被拦。App 里也会有同样的「插件调试」页。
