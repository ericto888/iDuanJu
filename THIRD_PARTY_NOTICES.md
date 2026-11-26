# Third-party notices (i短剧 / STV multi-source)

## UAV-Downloader — Apache License 2.0
Copyright © ALOS (https://github.com/Alos21750/UAV-Downloader), commit de92300 (latest as of 2026-11-10).
MissAV / Jable / SupJav / Hanime1 / Huangguo-AI parsing logic was ported to Swift (regex instead of BeautifulSoup)
and modified for this app. Full license text: `STV/Resources/Licenses/` (shown in 我的 → 片源管理 → 开源许可).

## yt-dlp — The Unlicense (public domain)
https://github.com/yt-dlp/yt-dlp — page structures / endpoints for Eporner (xhr hash), XVideos / XNXX (html5player),
Pornhub / YouPorn / RedTube (mediaDefinitions) were cross-checked against its extractors. The Swift code is an independent implementation.

## Interface references without code reuse
- Huangguo AI site (huangguoai.com and mirrors): the 2026-11-09 `POST /api/videos/<id>/episodes/<ep>/playback`
  flow was derived by reading the site's own public front-end scripts (services/playback.js); no third-party code copied.
- Hanime1 compact-grid markup change (`search-videos hover-lighter`) was observed on the live site.
- HQPorner list cards and the mydaddy.cc embed `<source title="720p">` tags (2026-11) were read from those sites' public HTML. No third-party code copied.

## TDLibKit (MIT) / TDLibFramework / TDLib (Boost Software License 1.0)
- https://github.com/Swiftgram/TDLibKit 1.5.2-tdlib-1.8.69-6126ecae (SPM dependency, MIT)
- https://github.com/tdlib/td 1.8.69 (BSL-1.0), prebuilt by https://github.com/Swiftgram/TDLibFramework
- Used only with the user's own api_id / api_hash entered in the app; none are bundled.

## Telegram web preview / MangaDex / 包子漫画
- t.me/s public channel preview: own HTML parser (interface reference only, no third-party code).
- MangaDex public API (api.mangadex.org), used per its API docs; only safe/suggestive content ratings are requested.
- 包子漫画 mobile pages: own HTML parser (interface reference only).

## QuickJS-ng — MIT
- https://github.com/quickjs-ng/quickjs v0.10.1 (commit 3c9afc9), vendored unmodified in `Packages/QuickJS/Sources/CQuickJS`
  (quickjs.c, libregexp.c, libunicode.c, cutils.c, xsum.c and headers). Full text: `Packages/QuickJS/LICENSE-quickjs-ng.txt`,
  also bundled as `STV/Resources/Licenses/quickjs-ng-LICENSE.txt` and shown in 开源许可.
- `idj_sandbox.c/.h` (eval-less sandbox wrapper, interrupt deadline, host bridge) is this app's own code.

## CPython — PSF License 2.0 (iOS, optional Python runtime for TVBox Python spiders)
- https://github.com/python/cpython 3.13.18 with the Apple-platform patches of BeeWare Python-Apple-support, downloaded at
  build time as the unmodified release asset `Python-3.13-iOS-support.b18.tar.gz` of
  https://github.com/beeware/Python-Apple-support (tag 3.13-b18, MIT build scripts; SHA-256 pinned in
  `scripts/fetch-ios-python.sh`). Not in this repository; builds with `IDJ_PYTHON=0` do not contain it.
- Shipped as `Frameworks/Python.framework`, one framework per extension module and `python/lib/stdlib.pyz`.
  Changes: architectures thinned, symbols and install names stripped/rewritten, standard library trimmed and byte-compiled
  (`scripts/embed-ios-python.sh`).
- Statically included in the shipped binaries: Expat 2 (MIT), libffi 3.4.7 (MIT), mpdecimal 4.0.0 (BSD-2-Clause),
  bzip2 1.0.8 (bzip2 license), liblzma / XZ Utils 5.6.4 (0BSD), HACL* (MIT), BLAKE2 (CC0), mimalloc (MIT), SipHash (MIT),
  dtoa, Mersenne Twister and others named in the texts. zlib is the system library. OpenSSL is not shipped (`_ssl` and
  `_hashlib` are left out; TLS goes through the app).
- Texts: `STV/Resources/Licenses/CPython-LICENSE.txt` and `CPython-components.txt` (bundled, shown in 开源许可).
- `Packages/PythonHost` and `PythonRuntime.swift` are this app's own code; they declare the parts of the C API they call.

## Rhino — Mozilla Public License 2.0
- https://github.com/mozilla/rhino, version 1.7.15, unmodified Maven dependency `org.mozilla:rhino`.
- Android book-source JavaScript evaluation runs interpreted, with a class shutter and explicit host bridge; no Java class or filesystem access is exposed to source scripts.
- License: `STV/Resources/Licenses/Rhino-MPL-2.0.txt` (also bundled with Android). The shared Legado compatibility prelude is this project's own code.

## TVBox engine (Android and the shared script runtime)
- The config, spider, live and proxy behaviour follows the publicly documented TVBox / CatVod interface; the Kotlin engine
  (`android/core/.../core/tvbox`), the Java host API (`android/app/src/main/java/com/github/catvod`), the JavaScript runtime
  (`shared/tvbox/js`, except crypto-js below) and the Python runtime (`shared/tvbox/py`) are this project's own code. Class and
  method names of the host API are the interface jars are compiled against. No spider, jar or source is bundled.
- **crypto-js 4.2.0 — MIT** (https://github.com/brix/crypto-js), from the Maven Central webjar `org.webjars.npm:crypto-js:4.2.0`;
  comments stripped and the UMD wrapper replaced by an ES module. The licence text is kept at the top of
  `shared/tvbox/js/lib/crypto-js.js`.
- **Gson 2.11.0 — Apache-2.0** (https://github.com/google/gson), unmodified Maven dependency; used by the host API and by jars
  compiled against the host's copy.
- **okhttp-dnsoverhttps / mockwebserver 4.12.0 — Apache-2.0** (https://github.com/square/okhttp); mockwebserver is test-only.
- **kotlinx.coroutines 1.9.0 — Apache-2.0**. **GraalVM Polyglot / GraalJS 24.1.1 — UPL-1.0**, test-only (runs the shared
  JavaScript runtime in JVM tests, never packaged).
- **Chaquopy 16.1.0 — MIT** (https://github.com/chaquo/chaquopy) with CPython 3.11 (PSF License), only in builds made with
  `-Pidj.python=true`, together with the pip packages requests (Apache-2.0), urllib3 (MIT), certifi (MPL-2.0), idna
  (BSD-3-Clause), charset-normalizer (MIT), lxml (BSD-3-Clause, with libxml2 / libxslt, MIT), pycryptodome (BSD-2-Clause /
  public domain), pyquery (BSD-3-Clause), cssselect (BSD-3-Clause), beautifulsoup4 and soupsieve (MIT), typing_extensions (PSF).

## Media3 streaming modules (Android player)
- **androidx.media3 1.5.1 — Apache-2.0**: exoplayer-hls, exoplayer-dash, exoplayer-smoothstreaming, exoplayer-rtsp,
  datasource-okhttp and datasource-rtmp, unmodified Maven dependencies.
- **io.antmedia:rtmp-client 3.2.0 — Apache-2.0** (https://github.com/mekya/LibRtmp-Client-for-Android), unmodified Maven
  dependency of datasource-rtmp; it wraps librtmp from RTMPDump (LGPL-2.1).

## JMComic-Crawler-Python — MIT (algorithm reference only)
- https://github.com/hect0x7/JMComic-Crawler-Python — the public 18comic image segment algorithm
  (`JmImageTool.get_num` / `decode_and_save`) was re-implemented in Swift (`ImageStripes`) and in the bundled
  18comic plugin's JS. No code copied.

## Bundled plugin site references
- manga18fx / komikindo / 18comic plugins (`STV/Resources/Plugins/*.idjplugin`) parse the sites' public HTML with the
  host CSS selector API; independent implementations.
- 苹果 CMS v10 采集接口 (`?ac=list|detail`) adapter: independent implementation of the public API format.

## AetherEngine — LGPL-3.0 with App Store / DRM Exception (player core, 1.5 build 2+)
- https://github.com/superuser404notfound/AetherEngine — **tag 7.62.0** (commit a1d2cab8281cbf06f5f459b05dad4653ad12559f),
  SwiftPM product `AetherEngine`, statically linked, **unmodified**. Copyright (C) 2026 Vincent Herbst.
- Distributed under the license's App Store / DRM exception (end-user re-linking of the app binary is waived by that
  exception); the corresponding source is the 7.62.0 tag above. Full text: `STV/Resources/Licenses/AetherEngine-LICENSE.txt`
  (bundled, shown in 开源许可).
- Only the `AetherEngine` product is linked; SMBClient appears in Package.resolved but is not linked (no symbols).

## FFmpeg (via FFmpegBuild 3.14.0) — LGPL-2.1-or-later, dynamically linked
- https://github.com/superuser404notfound/FFmpegBuild — tag 3.14.0 (commit 2ff2238f6b65d7686e71c8aa9e45fa4e26f33e1d);
  build script, configure flags and local FFmpeg / libzvbi patches are in that tag's `build.sh` and `patches/`.
- FFmpeg built without `--enable-gpl` / `--enable-version3`. Shipped as dynamic frameworks in `STV.app/Frameworks/`
  (`AetherLibavcodec`, `AetherLibavformat`, `AetherLibavutil`, `AetherLibswresample`, `AetherLibswscale`, `AetherLibavfilter`),
  never merged into the app binary, so they can be replaced/relinked.
- libzvbi (`AetherLibzvbi`): LGPL-2.0-or-later conveyed under LGPL-2.1, `ure.c` MIT; GPL-2 files removed by build.sh.
- Texts: `STV/Resources/Licenses/FFmpeg-LGPL-2.1.txt`, `libzvbi-ure-MIT.txt`.

## dav1d — BSD-2-Clause (`AetherLibdav1d`), zimg — WTFPL (`AetherLibzimg`)
- Unmodified upstream sources built by FFmpegBuild 3.14.0. Texts: `dav1d-BSD-2-Clause.txt`, `zimg-WTFPL.txt`.

## libdovi (dovi_tool `dolby_vision` crate, via LibDovi 2.2.0) — MIT
- https://github.com/quietvoid/dovi_tool — Copyright (c) quietvoid and contributors (MIT OR Apache-2.0, used under MIT).
- Packaged by https://github.com/superuser404notfound/LibDovi tag 2.2.0 (static). Text: `LibDovi-LICENSE.txt`.

## Reverse-engineered protocol data (Hongguo / 红果)
- `STV/Providers/Hongguo/*` and `STV/Resources/medusa_tables.bin` implement the Hongguo app's request signing
  (X-Gorgon / X-Argus / X-Medusa) and device registration from interoperability analysis. Apart from the playback
  signer noted below, no third-party source code is included. No device identifiers, accounts or keys are bundled:
  every install registers / mints its own anonymous device.

## Hongguo playback authentication — GPL-3.0-only
The Argus 551 framing and Ladon implementation in `HGPlayerSign.swift` (`playbackHeaders`) is adapted to Swift from
`zfdang/hongguo-open-player`, commit 3f687c5, `src/server/native/argus.js` (SPDX: GPL-3.0-only),
which credits fqapp / N3urda/hongguoTV. The test vectors in `STVTests/PrefetchTests.swift` match that JS signer.
Source reference: https://github.com/zfdang/hongguo-open-player/commit/3f687c5

## License compatibility
### Current Hongguo player signer (2026-11-16)

`HGCurrentPlayer.swift` / `HGCurrentPlayer.kt` and `HGCurrentProfile.*` are ports of
`my-name-is-alan/get_video_streaming`, commit `0613b49`,
`internal/provider/hongguo/playersign/current*.go`. Swift and Kotlin use the same
fixed application constants and synthetic native test vectors. The KS/custom
transform originated in OpenHongguo commit `05aa580a2fa914becabc5ae4be5b05539c66bda6`
under Apache-2.0 and was modified and validated by the gateway implementation.
The ports adapt byte arithmetic, request construction and error handling to each
platform; category requests keep their separate 551 signing profile.

License and upstream notice: `STV/Resources/Licenses/HGCurrentPlayer-Apache-2.0.txt`
and `STV/Resources/Licenses/HGCurrentPlayer-NOTICE.md`. The constants are protocol
data, not device identities or session credentials. No captured SDK token is used
by the current player signer. Native synthetic vectors test arithmetic only;
server availability is checked separately.

All components above (Apache-2.0, MIT, BSD-2-Clause, PSF-2.0, 0BSD, bzip2, WTFPL, BSL-1.0, Unlicense, LGPL-2.1/LGPL-3.0 with exception, GPL-3.0-only) are
compatible with distributing the whole work under GPL-3.0. This project itself is licensed under **GPL-3.0** (see `LICENSE`).
