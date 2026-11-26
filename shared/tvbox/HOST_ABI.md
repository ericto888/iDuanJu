# Script host ABI (JS and Python spiders)

Both platforms ship the same script libraries (`shared/tvbox/js`, `shared/tvbox/py`). The only native entry point is

- JS: `globalThis.__tv(name: string, argsJson: string): string`
- Python: `_idj_host.call(name: str, args_json: str) -> str`

The return value is JSON text: `{"v": <value>}` or `{"e": "<message>"}`. Calls block the spider's own thread; one spider
instance = one thread = one interpreter. Binary values travel as Base64. Everything below is `name(args) → v`.

| name | args | v |
|---|---|---|
| `http` | `{url, method, headers, body?, bodyB64?, timeout(ms), redirect(bool), verify(bool), out: "text"\|"b64", charset?}` | `{code, url, headers:{k:[v…]}, body}` (text is decoded by charset / content-type / meta, GBK aware) |
| `html.load` | `{html}` | `docId` (freed when the spider call returns) |
| `html.select` | `{ids:[int], css}` | `[nodeId]` (jQuery-style `:eq :first :last :gt :lt :has :contains :not` included) |
| `html.text` / `html.html` / `html.outer` | `{id}` | string |
| `html.attr` | `{id, k}` | string or null |
| `html.rel` | `{id, op:"parent"\|"children"\|"next"\|"prev"\|"siblings"}` | `[nodeId]` |
| `html.xpath` | `{id, q}` | `[{"n":nodeId}\|{"s":string}]` |
| `pdfh` / `pdfa` / `pd` / `pdfl` | `{html, rule, base, list?, url?}` | drpy semantics (`a&&b&&Text`, `\|\|`, `--`, `:eq(n)`, `Html/Text/attr`) |
| `joinUrl` | `{base, ref}` | absolute URL |
| `local.get` / `local.set` / `local.delete` | `{ns, k, v?}` | string / null (persisted per site) |
| `hash` | `{alg:"md5"\|"sha1"\|"sha256"\|"sha512", b64, hmacB64?}` | hex |
| `cipher` | `{alg:"aes"\|"des"\|"3des"\|"rc4", mode:"cbc"\|"ecb"\|"cfb"\|"ofb"\|"ctr"\|"gcm", pad:"pkcs7"\|"none"\|"zero", encrypt, keyB64, ivB64?, dataB64}` | Base64 |
| `rsa` | `{op:"encrypt"\|"decrypt"\|"sign"\|"verify", key(PEM or Base64 DER), public(bool), pad:"pkcs1"\|"oaep"\|"none", hash?, dataB64, sigB64?}` | Base64 / bool |
| `gbk` | `{op:"encode"\|"decode", s?, b64?}` | Base64 / string |
| `inflate` | `{b64, kind:"gzip"\|"zlib"\|"raw"}` | Base64 |
| `json5` | `{s}` | parsed value (lenient JSON parser) |
| `s2t` / `t2s` | `{s}` | string |
| `proxyUrl` | `{local, kind:"js"\|"py"}` | `http://127.0.0.1:<port>/proxy?do=js&siteKey=<key>` (with trailing query, ready for `&k=v`) |
| `log` | `{m}` | null |

## JS environment

- ES modules. Loader: `assets://js/lib/<f>` and bare `<f>` that exist in `shared/tvbox/js/lib` → bundled file; `http(s)://`
  → downloaded with the config UA and cached on disk; relative → against the importing module's URL. A module whose text
  starts with `//bb` (foreign QuickJS bytecode) is rejected with a readable error.
- Bootstrap `shared/tvbox/js/bootstrap.js` defines the globals scripts expect: `req`, `http`, `fetch`, `pdfh/pdfa/pdfl/pd`,
  `joinUrl`, `local`, `md5X`, `aesX`, `desX`, `rsaX`, `s2t`, `t2s`, `getProxy`, `js2Proxy`, `console`, `setTimeout`,
  `clearTimeout`, `atob`, `btoa`, `TextEncoder`, `TextDecoder`, `URL`, `URLSearchParams`, `gzip/ungzip`, `batchFetch`.
- Entry: the module's `__jsEvalReturn()` result, else its default export, else its named exports (`init, home, homeVod,
  category, detail, play, search, proxy, action`); drpy scripts are wrapped so `init(ext)` receives the site's `ext`.
- Functions may be sync or async; promises are awaited by draining the job queue. Results may be objects or JSON strings.

## Python environment

- `shared/tvbox/py/base/spider.py` provides `Spider` (`fetch`, `post`, `html`, `regStr`, `removeHtmlTags`, `cleanText`,
  `log`, `getCache/setCache/delCache`, `getProxyUrl`, `localProxy`, …). Scripts do `from base.spider import Spider`.
- A script is executed in a fresh module namespace; the class named `Spider` is instantiated, then
  `init(extend)` and the content methods are called; dict results are JSON-encoded by `shared/tvbox/py/idj_runner.py`:
  `load(key, source, ext) / call(key, method, args_json) / unload(key)`.
- Android provides real `requests`, `lxml`, `pycryptodome`, `pyquery`, `bs4`. iOS provides API-compatible modules over this
  ABI in `shared/tvbox/py/ios_site` (`requests`, `lxml.etree`, `lxml.html`, `pyquery`, `bs4`, `Crypto`), no third-party binaries.
