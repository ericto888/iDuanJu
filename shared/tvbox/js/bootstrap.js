/*
 * i短剧 TVBox script bootstrap (Android + iOS). Plain global script, evaluated once per spider context, before the spider
 * module. The only native entry point is `__tv(name, argsJson)` (shared/tvbox/HOST_ABI.md).
 *
 * Host driver protocol
 *   1. define `globalThis.__tv`, install the module loader, evaluate this file as a *global script*;
 *   2. evaluate a module `import * as m from "<api>"; __idj.attach(m)` (the loader rewrites the identifier `__JS_SPIDER__`
 *      of the entry module to `globalThis.__JS_SPIDER__`); `__idj.status()` then tells `{"ok":true}`, `{"e":"…"}` or `{}`
 *      (module body threw: `import("<api>").catch(__idj.fail)` + `status()` again reports why);
 *   3. per call: `__idj.start(method, argsJson)`, drain the job queue, then `__idj.poll()` until it reports `done`.
 *        poll() -> '{"done":true,"v":"<result text>"}' | '{"done":true,"e":"<message>"}' | '{"wait":<ms>}'
 *      After a `wait` the host sleeps at most that long (0 = again right away), drains the job queue and polls again.
 *   Methods are the spider names of the contract; `init` takes [ext, siteKey, siteType].
 *   `proxyLocal` resolves to {"code","type","b64","headers"}; everything else to the script's JSON text ("" when empty).
 *
 * ABI argument notes: `pdfl` sends {html, rule: list rule, list: text rule, url: url rule, base}; `http` sends `redirect`
 * and `verify` as booleans and `charset` only when the script names one.
 */
(function () {
  'use strict';
  var g = globalThis;

  function tv(name, args) {
    var raw = g.__tv(name, JSON.stringify(args === undefined ? {} : args));
    if (raw === undefined || raw === null || raw === '') return undefined;
    var r = JSON.parse(raw);
    if (r && r.e !== undefined && r.e !== null) throw new Error(String(r.e));
    return r ? r.v : undefined;
  }
  Object.defineProperty(g, '__tvCall', { value: tv, enumerable: false });
  if (typeof g.window === 'undefined') g.window = g;
  if (typeof g.self === 'undefined') g.self = g;
  if (typeof g.global === 'undefined') g.global = g;

  // ---------------------------------------------------------------- bytes
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var B64R = {};
  for (var bi = 0; bi < 64; bi++) B64R[B64.charCodeAt(bi)] = bi;
  B64R[45] = 62; B64R[95] = 63; // url-safe alphabet

  function utf8(str) {
    var s = String(str), out = new Uint8Array(s.length * 3), n = 0;
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      if (c >= 0xd800 && c < 0xdc00 && i + 1 < s.length) {
        var d = s.charCodeAt(i + 1);
        if (d >= 0xdc00 && d < 0xe000) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
      }
      if (c < 0x80) out[n++] = c;
      else if (c < 0x800) { out[n++] = 0xc0 | (c >> 6); out[n++] = 0x80 | (c & 63); }
      else if (c < 0x10000) { out[n++] = 0xe0 | (c >> 12); out[n++] = 0x80 | ((c >> 6) & 63); out[n++] = 0x80 | (c & 63); }
      else { out[n++] = 0xf0 | (c >> 18); out[n++] = 0x80 | ((c >> 12) & 63); out[n++] = 0x80 | ((c >> 6) & 63); out[n++] = 0x80 | (c & 63); }
    }
    return out.slice(0, n);
  }
  function unutf8(bytes) {
    var parts = [], buf = '', i = 0, n = bytes.length;
    while (i < n) {
      var c = bytes[i++] & 255, cp;
      if (c < 0x80) cp = c;
      else if (c >= 0xc2 && c < 0xe0 && i < n) cp = ((c & 31) << 6) | (bytes[i++] & 63);
      else if (c >= 0xe0 && c < 0xf0 && i + 1 < n) cp = ((c & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
      else if (c >= 0xf0 && c < 0xf5 && i + 2 < n) cp = ((c & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
      else cp = 0xfffd;
      buf += cp > 0xffff ? String.fromCharCode(0xd800 + ((cp - 0x10000) >> 10), 0xdc00 + ((cp - 0x10000) & 1023)) : String.fromCharCode(cp);
      if (buf.length > 4096) { parts.push(buf); buf = ''; }
    }
    parts.push(buf);
    return parts.join('');
  }
  function b64e(bytes) {
    var parts = [], buf = '', n = bytes.length;
    for (var i = 0; i < n; i += 3) {
      var a = bytes[i] & 255, b = i + 1 < n ? bytes[i + 1] & 255 : 0, c = i + 2 < n ? bytes[i + 2] & 255 : 0;
      buf += B64[a >> 2] + B64[((a & 3) << 4) | (b >> 4)] + (i + 1 < n ? B64[((b & 15) << 2) | (c >> 6)] : '=') + (i + 2 < n ? B64[c & 63] : '=');
      if (buf.length > 4096) { parts.push(buf); buf = ''; }
    }
    parts.push(buf);
    return parts.join('');
  }
  function b64d(text) {
    var s = String(text), out = new Uint8Array(Math.ceil(s.length * 3 / 4)), n = 0, acc = 0, bits = 0;
    for (var i = 0; i < s.length; i++) {
      var v = B64R[s.charCodeAt(i)];
      if (v === undefined) continue;
      acc = ((acc << 6) | v) & 0xffffff; bits += 6;
      if (bits >= 8) { bits -= 8; out[n++] = (acc >> bits) & 255; }
    }
    return out.slice(0, n);
  }
  function latin1(s) { var o = new Uint8Array(s.length); for (var i = 0; i < s.length; i++) o[i] = s.charCodeAt(i) & 255; return o; }
  function unlatin1(b) {
    var parts = [];
    for (var i = 0; i < b.length; i += 4096) parts.push(String.fromCharCode.apply(null, Array.prototype.slice.call(b, i, i + 4096)));
    return parts.join('');
  }
  function toBytes(v) {
    if (v === undefined || v === null) return new Uint8Array(0);
    if (typeof v === 'string') return utf8(v);
    if (v instanceof Uint8Array) return v;
    if (v instanceof ArrayBuffer) return new Uint8Array(v);
    if (ArrayBuffer.isView && ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
    if (Array.isArray(v)) return Uint8Array.from(v, function (x) { return x & 255; });
    return utf8(JSON.stringify(v));
  }
  Object.defineProperty(g, '__idjBytes', { value: { utf8: utf8, unutf8: unutf8, b64e: b64e, b64d: b64d, latin1: latin1, unlatin1: unlatin1, toBytes: toBytes }, enumerable: false });

  g.btoa = function (s) { return b64e(latin1(String(s))); };
  g.atob = function (s) { return unlatin1(b64d(s)); };

  g.TextEncoder = function TextEncoder() { this.encoding = 'utf-8'; };
  g.TextEncoder.prototype.encode = function (s) { return utf8(s === undefined ? '' : s); };
  g.TextDecoder = function TextDecoder(label) { this.encoding = String(label || 'utf-8').toLowerCase(); };
  g.TextDecoder.prototype.decode = function (b) {
    var bytes = toBytes(b === undefined ? [] : b);
    if (/^(gb|gbk|gb2312|gb18030)/.test(this.encoding)) return tv('gbk', { op: 'decode', b64: b64e(bytes) });
    if (/^(latin1|iso-8859-1|ascii|us-ascii|windows-1252)$/.test(this.encoding)) return unlatin1(bytes);
    return unutf8(bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf ? bytes.slice(3) : bytes);
  };

  if (!g.crypto) g.crypto = {};
  if (!g.crypto.getRandomValues) {
    var seed = 0;
    g.crypto.getRandomValues = function (arr) {
      var view = new Uint8Array(arr.buffer, arr.byteOffset, arr.byteLength), i = 0;
      while (i < view.length) {
        var hex = tv('hash', { alg: 'sha512', b64: b64e(utf8(Date.now() + ':' + Math.random() + ':' + Math.random() + ':' + (++seed))) });
        for (var j = 0; j < hex.length && i < view.length; j += 2) view[i++] = parseInt(hex.substr(j, 2), 16);
      }
      return arr;
    };
  }

  // ---------------------------------------------------------------- console
  function show(v) {
    if (typeof v === 'string') return v;
    if (v instanceof Error) return v.message + (v.stack ? '\n' + v.stack : '');
    try { return JSON.stringify(v); } catch (e) { return String(v); }
  }
  function log() {
    var out = [];
    for (var i = 0; i < arguments.length; i++) out.push(show(arguments[i]));
    var text = out.join(' ');
    try { tv('log', { m: text.length > 4000 ? text.slice(0, 4000) + '…' : text }); } catch (e) { /* logging never breaks a spider */ }
  }
  g.console = { log: log, info: log, warn: log, error: log, debug: log, trace: log, table: log, time: function () {}, timeEnd: function () {} };
  if (typeof g.print !== 'function') g.print = log;

  // ---------------------------------------------------------------- timers
  var timers = new Map(), timerSeq = 0;
  function addTimer(fn, ms, args, every) {
    var id = ++timerSeq;
    timers.set(id, { at: Date.now() + Math.max(0, Number(ms) || 0), fn: fn, args: args, every: every });
    return id;
  }
  g.setTimeout = function (fn, ms) { return addTimer(fn, ms, Array.prototype.slice.call(arguments, 2), 0); };
  g.setInterval = function (fn, ms) { return addTimer(fn, ms, Array.prototype.slice.call(arguments, 2), Math.max(10, Number(ms) || 0)); };
  g.clearTimeout = g.clearInterval = function (id) { timers.delete(id); };
  g.setImmediate = function (fn) { return addTimer(fn, 0, Array.prototype.slice.call(arguments, 1), 0); };
  g.clearImmediate = g.clearTimeout;
  if (typeof g.queueMicrotask !== 'function') g.queueMicrotask = function (fn) { Promise.resolve().then(fn); };
  function runTimers() {
    var now = Date.now(), due = [];
    timers.forEach(function (t, id) { if (t.at <= now) due.push([t.at, id, t]); });
    due.sort(function (a, b) { return a[0] - b[0] || a[1] - b[1]; });
    due.forEach(function (d) {
      if (!timers.has(d[1])) return;
      if (d[2].every) d[2].at = now + d[2].every; else timers.delete(d[1]);
      try { if (typeof d[2].fn === 'function') d[2].fn.apply(g, d[2].args); else (0, eval)(String(d[2].fn)); } catch (e) { log('timer', e); }
    });
    return due.length;
  }
  function nextTimer() {
    var at = Infinity;
    timers.forEach(function (t) { if (t.at < at) at = t.at; });
    return at === Infinity ? -1 : Math.max(0, at - Date.now());
  }

  // ---------------------------------------------------------------- URL
  function encodeForm(v) { return encodeURIComponent(String(v)).replace(/%20/g, '+'); }
  function decodeForm(v) { try { return decodeURIComponent(String(v).replace(/\+/g, ' ')); } catch (e) { return String(v); } }
  g.URLSearchParams = function URLSearchParams(init) {
    this._ = [];
    var self = this;
    if (init === undefined || init === null) return;
    if (init instanceof URLSearchParams) this._ = init._.map(function (p) { return [p[0], p[1]]; });
    else if (Array.isArray(init)) init.forEach(function (p) { self._.push([String(p[0]), String(p[1])]); });
    else if (typeof init === 'object') Object.keys(init).forEach(function (k) { self._.push([k, String(init[k])]); });
    else String(init).replace(/^\?/, '').split('&').forEach(function (p) {
      if (!p) return;
      var i = p.indexOf('=');
      self._.push(i < 0 ? [decodeForm(p), ''] : [decodeForm(p.slice(0, i)), decodeForm(p.slice(i + 1))]);
    });
  };
  var usp = g.URLSearchParams.prototype;
  usp.get = function (k) { for (var i = 0; i < this._.length; i++) if (this._[i][0] === k) return this._[i][1]; return null; };
  usp.getAll = function (k) { return this._.filter(function (p) { return p[0] === k; }).map(function (p) { return p[1]; }); };
  usp.has = function (k) { return this.get(k) !== null; };
  usp.append = function (k, v) { this._.push([String(k), String(v)]); this._sync(); };
  usp.set = function (k, v) {
    var hit = false;
    this._ = this._.filter(function (p) { if (p[0] !== k) return true; if (hit) return false; hit = true; p[1] = String(v); return true; });
    if (!hit) this._.push([String(k), String(v)]);
    this._sync();
  };
  usp.delete = function (k) { this._ = this._.filter(function (p) { return p[0] !== k; }); this._sync(); };
  usp.forEach = function (fn) { this._.slice().forEach(function (p) { fn(p[1], p[0], this); }, this); };
  usp.keys = function () { return this._.map(function (p) { return p[0]; })[Symbol.iterator](); };
  usp.values = function () { return this._.map(function (p) { return p[1]; })[Symbol.iterator](); };
  usp.entries = usp[Symbol.iterator] = function () { return this._.map(function (p) { return [p[0], p[1]]; })[Symbol.iterator](); };
  usp.sort = function () { this._.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; }); this._sync(); };
  usp.toString = function () { return this._.map(function (p) { return encodeForm(p[0]) + '=' + encodeForm(p[1]); }).join('&'); };
  usp._sync = function () { if (this._url) { var s = this.toString(); this._url._search = s ? '?' + s : ''; } };

  var URL_RE = /^([a-zA-Z][a-zA-Z0-9+.-]*:)(?:\/\/(?:([^@\/?#]*)@)?(\[[^\]]*\]|[^:\/?#]*)(?::(\d*))?)?([^?#]*)(\?[^#]*)?(#[\s\S]*)?$/;
  g.URL = function URL(url, base) {
    var text = String(url).trim();
    if (base !== undefined && base !== null && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(text)) text = tv('joinUrl', { base: String(base), ref: text });
    var m = URL_RE.exec(text);
    if (!m) throw new TypeError('Invalid URL: ' + url);
    this.protocol = m[1].toLowerCase();
    var auth = (m[2] || '').split(':');
    this.username = auth[0] || '';
    this.password = auth.slice(1).join(':');
    this.hostname = (m[3] || '').toLowerCase();
    var port = m[4] || '';
    this.port = (this.protocol === 'http:' && port === '80') || (this.protocol === 'https:' && port === '443') ? '' : port;
    this.pathname = m[5] || (m[3] !== undefined ? '/' : '');
    this._search = m[6] && m[6] !== '?' ? m[6] : '';
    this.hash = m[7] && m[7] !== '#' ? m[7] : '';
    this.searchParams = new g.URLSearchParams(this._search);
    Object.defineProperty(this.searchParams, '_url', { value: this, enumerable: false });
  };
  Object.defineProperties(g.URL.prototype, {
    search: {
      get: function () { return this._search; },
      set: function (v) { var s = String(v); this._search = s && s[0] !== '?' ? '?' + s : s === '?' ? '' : s; this.searchParams._ = new g.URLSearchParams(this._search)._; },
    },
    host: { get: function () { return this.hostname + (this.port ? ':' + this.port : ''); } },
    origin: { get: function () { return /^(https?|wss?|ftp):$/.test(this.protocol) ? this.protocol + '//' + this.host : 'null'; } },
    href: {
      get: function () {
        var auth = this.username ? this.username + (this.password ? ':' + this.password : '') + '@' : '';
        return this.protocol + (this.hostname || /^(https?|file):$/.test(this.protocol) ? '//' + auth + this.host : '') + this.pathname + this._search + this.hash;
      },
      set: function (v) { g.URL.call(this, v); },
    },
  });
  g.URL.prototype.toString = g.URL.prototype.toJSON = function () { return this.href; };
  g.URL.canParse = function (u, b) { try { new g.URL(u, b); return true; } catch (e) { return false; } };

  // ---------------------------------------------------------------- network
  function headerMap(h) {
    var out = {};
    if (!h) return out;
    if (typeof h.forEach === 'function' && !Array.isArray(h)) { h.forEach(function (v, k) { out[k] = String(v); }); return out; }
    Object.keys(h).forEach(function (k) { if (h[k] !== undefined && h[k] !== null) out[k] = Array.isArray(h[k]) ? h[k].join('; ') : String(h[k]); });
    return out;
  }
  function headerGet(h, name) {
    var n = name.toLowerCase(), keys = Object.keys(h);
    for (var i = 0; i < keys.length; i++) if (keys[i].toLowerCase() === n) return h[keys[i]];
    return undefined;
  }
  function form(data) {
    if (typeof data === 'string') return data;
    if (data instanceof g.URLSearchParams) return data.toString();
    return Object.keys(data || {}).map(function (k) { return encodeForm(k) + '=' + encodeForm(typeof data[k] === 'object' && data[k] !== null ? JSON.stringify(data[k]) : data[k]); }).join('&');
  }
  function multipart(data, boundary) {
    var s = '';
    Object.keys(data || {}).forEach(function (k) { s += '--' + boundary + '\r\nContent-Disposition: form-data; name="' + k + '"\r\n\r\n' + data[k] + '\r\n'; });
    return s + '--' + boundary + '--\r\n';
  }
  /** Raw host request -> { code, url, headers:{k:[v]}, body }. */
  function send(url, o, out) {
    var headers = headerMap(o.headers), args = {
      url: String(url), method: String(o.method || 'get').toUpperCase(), headers: headers,
      timeout: Number(o.timeout) > 0 ? Number(o.timeout) : 10000,
      redirect: !(o.redirect === 0 || o.redirect === false || o.redirect === '0' || o.redirect === 'manual' || o.redirect === 'error'),
      verify: !(o.rejectUnauthorized === false || o.verify === false), out: out,
    };
    var ct = headerGet(headers, 'Content-Type');
    var def = function (v) { if (!ct) headers['Content-Type'] = ct = v; };
    if (args.method !== 'GET' && args.method !== 'HEAD') {
      if (o.body !== undefined && o.body !== null) {
        if (typeof o.body === 'string') args.body = o.body;
        else if (o.body instanceof g.URLSearchParams) { def('application/x-www-form-urlencoded'); args.body = o.body.toString(); }
        else if (o.body instanceof Uint8Array || o.body instanceof ArrayBuffer || Array.isArray(o.body)) args.bodyB64 = b64e(toBytes(o.body));
        else { def('application/json'); args.body = JSON.stringify(o.body); }
      } else if (o.data !== undefined && o.data !== null) {
        var type = String(o.postType || (ct && /x-www-form-urlencoded/i.test(ct) ? 'form' : 'json'));
        if (type === 'form') { def('application/x-www-form-urlencoded'); args.body = form(o.data); }
        else if (type === 'form-data') {
          var boundary = '----idj' + Date.now() + Math.floor(Math.random() * 1e9);
          headers['Content-Type'] = ct = 'multipart/form-data; boundary=' + boundary;
          args.body = multipart(o.data, boundary);
        } else if (type === 'raw') args.body = typeof o.data === 'string' ? o.data : JSON.stringify(o.data);
        else { def('application/json'); args.body = typeof o.data === 'string' ? o.data : JSON.stringify(o.data); }
      }
    }
    var cs = o.charset || o.encoding || (ct && (/charset=([\w-]+)/i.exec(ct) || [])[1]);
    if (cs) args.charset = String(cs);
    return tv('http', args);
  }
  function flat(h) {
    var out = {};
    Object.keys(h || {}).forEach(function (k) { var v = h[k]; out[k] = Array.isArray(v) ? (v.length === 1 ? v[0] : v) : v; });
    return out;
  }
  /** TVBox `req`: buffer 0 text, 1 byte array, 2 Base64. Network failures come back as an empty response, never as a throw. */
  function request(url, options) {
    var o = options || {}, buffer = Number(o.buffer) || 0;
    try {
      var r = send(url, o, buffer ? 'b64' : 'text');
      return { code: r.code, url: r.url, ok: r.code >= 200 && r.code < 300, headers: flat(r.headers), content: buffer === 1 ? Array.from(b64d(r.body)) : r.body };
    } catch (e) {
      log('req ' + url + ': ' + e.message);
      return { code: 0, url: String(url), ok: false, headers: {}, content: buffer === 1 ? [] : '', error: e.message };
    }
  }
  function http(url, options) {
    var o = Object.assign({}, options || {});
    if (url && typeof url === 'object') { o = Object.assign({}, url); url = o.url; }
    if (o.async === false) return request(url, o);
    return new Promise(function (resolve) { resolve(request(url, o)); }).then(function (r) {
      r.data = r.content;
      try { r.data = JSON.parse(r.content); } catch (e) { /* text stays text */ }
      return r;
    });
  }
  ['get', 'post', 'put', 'delete', 'head', 'patch', 'options'].forEach(function (m) {
    http[m] = function (url, options) { return http(url, Object.assign({}, options || {}, { method: m })); };
  });
  http.request = http;
  g.http = http;
  g.req = request;
  g.batchFetch = function (list) {
    return (list || []).map(function (it) { return typeof it === 'string' ? request(it).content : request(it.url, it.options || it).content; });
  };
  g.Headers = function Headers(init) {
    var m = this._ = {};
    var h = init instanceof Headers ? init._ : init || {};
    if (Array.isArray(h)) h.forEach(function (p) { m[String(p[0]).toLowerCase()] = String(p[1]); });
    else Object.keys(h).forEach(function (k) { m[k.toLowerCase()] = Array.isArray(h[k]) ? h[k].join(', ') : String(h[k]); });
  };
  g.Headers.prototype = {
    constructor: g.Headers,
    get: function (k) { var v = this._[String(k).toLowerCase()]; return v === undefined ? null : v; },
    has: function (k) { return String(k).toLowerCase() in this._; },
    set: function (k, v) { this._[String(k).toLowerCase()] = String(v); },
    append: function (k, v) { var n = String(k).toLowerCase(); this._[n] = n in this._ ? this._[n] + ', ' + v : String(v); },
    delete: function (k) { delete this._[String(k).toLowerCase()]; },
    forEach: function (fn) { Object.keys(this._).forEach(function (k) { fn(this._[k], k, this); }, this); },
    entries: function () { var m = this._; return Object.keys(m).map(function (k) { return [k, m[k]]; })[Symbol.iterator](); },
    keys: function () { return Object.keys(this._)[Symbol.iterator](); },
  };
  g.Headers.prototype[Symbol.iterator] = g.Headers.prototype.entries;
  g.fetch = function (input, init) {
    return new Promise(function (resolve, reject) {
      var o = Object.assign({}, init || {}), url = input && typeof input === 'object' && input.url ? input.url : input, r;
      try { r = send(url, o, 'b64'); } catch (e) { reject(new TypeError(e.message)); return; }
      var bytes = b64d(r.body), used = new g.Headers(r.headers);
      var charset = (/charset=["']?([\w-]+)/i.exec(used.get('content-type') || '') || [])[1];
      resolve({
        ok: r.code >= 200 && r.code < 300, status: r.code, statusText: '', url: r.url, redirected: r.url !== String(url), headers: used,
        text: function () { return Promise.resolve(new g.TextDecoder(charset).decode(bytes)); },
        json: function () { return this.text().then(JSON.parse); },
        arrayBuffer: function () { return Promise.resolve(bytes.slice().buffer); },
        bytes: function () { return Promise.resolve(bytes); },
        clone: function () { return this; },
      });
    });
  };

  // ---------------------------------------------------------------- html / crypto / misc globals
  function S(v) { return v === undefined || v === null ? '' : typeof v === 'string' ? v : typeof v === 'object' ? JSON.stringify(v) : String(v); }
  g.pdfh = function (html, rule, base) { return tv('pdfh', { html: S(html), rule: S(rule), base: S(base) }) || ''; };
  g.pdfa = function (html, rule) { return tv('pdfa', { html: S(html), rule: S(rule), base: '' }) || []; };
  g.pd = function (html, rule, base) { return tv('pd', { html: S(html), rule: S(rule), base: S(base) }) || ''; };
  /** pdfl(html, listRule, textRule, urlRule, baseUrl) -> ["text$url", …] */
  g.pdfl = function (html, rule, texts, urls, base) { return tv('pdfl', { html: S(html), rule: S(rule), list: S(texts), url: S(urls), base: S(base) }) || []; };
  g.joinUrl = function (base, ref) { return tv('joinUrl', { base: S(base), ref: S(ref) }); };
  g.local = {
    get: function (ns, k, def) { var v = tv('local.get', { ns: S(ns), k: S(k) }); return v === null || v === undefined || v === '' ? (def === undefined ? '' : def) : v; },
    set: function (ns, k, v) { return tv('local.set', { ns: S(ns), k: S(k), v: S(v) }); },
    delete: function (ns, k) { return tv('local.delete', { ns: S(ns), k: S(k) }); },
  };
  g.md5X = function (s) { return tv('hash', { alg: 'md5', b64: b64e(utf8(S(s))) }); };
  function pad(bytes, n) { if (bytes.length >= n) return bytes; var o = new Uint8Array(n); o.set(bytes); return o; }
  function cipherX(alg, spec, encrypt, input, inB64, key, iv, outB64) {
    try {
      var p = String(spec).split('/'), padName = String(p[2] || 'PKCS7').toLowerCase();
      var k = utf8(S(key)), block = alg === 'aes' ? 16 : 8;
      k = pad(k, block);
      var name = alg === 'des' && /(desede|3des|tripledes)/i.test(p[0]) ? '3des' : alg;
      if (name === '3des') k = pad(k, 24);
      var args = {
        alg: name, mode: String(p[1] || 'ECB').toLowerCase(), pad: padName.indexOf('no') === 0 ? 'none' : padName.indexOf('zero') === 0 ? 'zero' : 'pkcs7',
        encrypt: !!encrypt, keyB64: b64e(k), dataB64: inB64 ? S(input) : b64e(utf8(S(input))),
      };
      if (iv !== undefined && iv !== null && iv !== '' && args.mode !== 'ecb') args.ivB64 = b64e(pad(utf8(S(iv)), block).slice(0, block));
      else if (args.mode !== 'ecb') args.ivB64 = b64e(new Uint8Array(block));
      var r = tv('cipher', args);
      return outB64 ? r : unutf8(b64d(r));
    } catch (e) { log(alg + 'X: ' + e.message); return ''; }
  }
  g.aesX = function (mode, encrypt, input, inB64, key, iv, outB64) { return cipherX('aes', mode, encrypt, input, inB64, key, iv, outB64); };
  g.desX = function (mode, encrypt, input, inB64, key, iv, outB64) { return cipherX('des', mode, encrypt, input, inB64, key, iv, outB64); };
  g.rsaX = function (mode, pub, encrypt, input, inB64, key, outB64) {
    try {
      var m = String(mode).toLowerCase();
      var r = tv('rsa', {
        op: encrypt ? 'encrypt' : 'decrypt', key: S(key), public: !!pub, pad: m.indexOf('oaep') >= 0 ? 'oaep' : m.indexOf('nopad') >= 0 ? 'none' : 'pkcs1',
        dataB64: inB64 ? S(input) : b64e(utf8(S(input))),
      });
      return outB64 ? r : unutf8(b64d(r));
    } catch (e) { log('rsaX: ' + e.message); return ''; }
  };
  g.s2t = function (s) { return tv('s2t', { s: S(s) }); };
  g.t2s = function (s) { return tv('t2s', { s: S(s) }); };
  g.getProxy = function (local) { return tv('proxyUrl', { local: local !== false, kind: 'js' }); };
  g.js2Proxy = function (dynamic, siteType, siteKey, url, headers) {
    return g.getProxy(!dynamic) + '&from=catvod&siteType=' + siteType + '&header=' + encodeURIComponent(JSON.stringify(headers || {})) + '&url=' + encodeURIComponent(S(url));
  };
  g.ungzip = function (b64) { return unutf8(b64d(tv('inflate', { b64: S(b64), kind: 'gzip' }))); };
  var CRC;
  function crc32(b) {
    if (!CRC) { CRC = []; for (var n = 0; n < 256; n++) { var c = n; for (var k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; CRC[n] = c >>> 0; } }
    var r = 0xffffffff;
    for (var i = 0; i < b.length; i++) r = CRC[(r ^ b[i]) & 255] ^ (r >>> 8);
    return (r ^ 0xffffffff) >>> 0;
  }
  /** Valid (stored-block) deflate stream: scripts only need a stream the server can inflate. */
  function stored(b) {
    var out = [], i = 0;
    do {
      var n = Math.min(65535, b.length - i), last = i + n >= b.length ? 1 : 0;
      out.push(last, n & 255, n >> 8, ~n & 255, (~n >> 8) & 255);
      for (var j = 0; j < n; j++) out.push(b[i + j]);
      i += n;
    } while (i < b.length);
    return out;
  }
  function gzipBytes(v) {
    var b = toBytes(v), c = crc32(b), n = b.length;
    return Uint8Array.from([31, 139, 8, 0, 0, 0, 0, 0, 0, 255].concat(stored(b), [c & 255, (c >>> 8) & 255, (c >>> 16) & 255, c >>> 24, n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24]));
  }
  function zlibBytes(v) {
    var b = toBytes(v), x = 1, y = 0;
    for (var i = 0; i < b.length; i++) { x = (x + b[i]) % 65521; y = (y + x) % 65521; }
    return Uint8Array.from([120, 1].concat(stored(b), [y >> 8, y & 255, x >> 8, x & 255]));
  }
  g.gzip = function (s) { return b64e(gzipBytes(s)); };
  Object.defineProperty(g, '__idjZip', { value: { gzip: gzipBytes, zlib: zlibBytes, raw: function (v) { return Uint8Array.from(stored(toBytes(v))); } }, enumerable: false });

  // ---------------------------------------------------------------- driver
  var spider = null, cat = false, loadError = null, state = { done: true, v: '' }, idle = 0;
  var NAMES = {
    init: 'init', homeContent: 'home', homeVideoContent: 'homeVod', categoryContent: 'category', detailContent: 'detail', searchContent: 'search',
    playerContent: 'play', liveContent: 'live', proxyLocal: 'proxy', action: 'action', isVideoFormat: 'isVideo', manualVideoCheck: 'sniffer', destroy: 'destroy',
  };
  function usable(o) { return !!o && (typeof o === 'object' || typeof o === 'function') && !!(o.home || o.homeVod || o.category || o.detail || o.search || o.play || o.live); }
  function attach(mod) {
    try { bind(mod); loadError = null; } catch (e) { spider = null; loadError = message(e); }
  }
  function bind(mod) {
    cat = typeof mod.__jsEvalReturn === 'function' || typeof g.__jsEvalReturn === 'function';
    if (cat) { g.req = http; spider = (mod.__jsEvalReturn || g.__jsEvalReturn)(); }
    else if (g.__JS_SPIDER__) spider = typeof g.__JS_SPIDER__ === 'function' ? g.__JS_SPIDER__() : g.__JS_SPIDER__;
    else if (mod.default !== undefined && mod.default !== null) spider = typeof mod.default === 'function' && !usable(mod.default) ? mod.default() : mod.default;
    if (!usable(spider)) spider = mod;
    if (!usable(spider)) throw new Error('脚本没有导出 home / category / detail 等方法');
  }
  function parseExt(ext) {
    if (typeof ext !== 'string') return ext === undefined || ext === null ? '' : ext;
    var t = ext.trim();
    if (t[0] === '{' || t[0] === '[') { try { return JSON.parse(t); } catch (e) { /* keep the raw text */ } }
    return ext;
  }
  function proxyArgs(p) {
    var params = p || {};
    if (params.from !== 'catvod') return [params];
    var header = {};
    try { header = JSON.parse(params.header || '{}'); } catch (e) { /* no headers */ }
    return [String(params.url || '').split('/'), header];
  }
  function callArgs(method, a) {
    switch (method) {
      case 'init': return [cat ? { stype: Number(a[2]) || 3, skey: a[1] || '', ext: parseExt(a[0]) } : parseExt(a[0])];
      case 'detailContent': return [Array.isArray(a[0]) ? a[0][0] : a[0]];
      case 'proxyLocal': return proxyArgs(a[0]);
      default: return a;
    }
  }
  function proxyOut(r) {
    if (typeof r === 'string') { try { r = JSON.parse(r); } catch (e) { r = [200, 'text/plain; charset=utf-8', r]; } }
    if (!r) return '';
    var code, type, body, headers, isB64;
    if (Array.isArray(r)) { code = r[0]; type = r[1]; body = r[2]; headers = r[3]; isB64 = r[4] === 1 || r[4] === true; }
    else {
      code = r.code; body = r.content === undefined ? r.body : r.content; headers = r.headers || {};
      type = r.type || headerGet(headers, 'content-type') || 'application/octet-stream';
      isB64 = r.buffer === 2;
    }
    if (typeof headers === 'string') { try { headers = JSON.parse(headers); } catch (e) { headers = {}; } }
    var b64 = isB64 ? String(body).replace(/^data:[^,]*base64,/, '') : b64e(toBytes(body));
    return JSON.stringify({ code: Number(code) || 200, type: String(type || 'application/octet-stream'), b64: b64, headers: headerMap(headers) });
  }
  function settle(method, r) {
    if (method === 'proxyLocal') return proxyOut(r);
    if (r === undefined || r === null) return '';
    if (typeof r === 'string') return r;
    if (typeof r === 'boolean' || typeof r === 'number') return String(r);
    return JSON.stringify(r);
  }
  function message(e) {
    if (e === undefined || e === null) return '脚本出错';
    var m = e.message || String(e);
    var at = e.stack ? (/([^\s()\/]+:\d+(?::\d+)?)\)?\s*$/.exec(String(e.stack).trim().split('\n')[0] || '') || [])[1] : '';
    return at ? m + ' @ ' + at : m;
  }
  function start(method, argsJson) {
    state = { done: false }; idle = 0;
    var mine = state;
    var ok = function (r) { if (mine.done) return; try { mine.v = settle(method, r); } catch (e) { mine.e = message(e); } mine.done = true; };
    var fail = function (e) { if (mine.done) return; mine.e = message(e); mine.done = true; };
    try {
      if (!spider) throw new Error('脚本还没有加载');
      var fn = spider[NAMES[method] || method];
      if (typeof fn !== 'function') { ok(''); return; }
      var r = fn.apply(spider, callArgs(method, JSON.parse(argsJson || '[]')));
      if (r && typeof r.then === 'function') r.then(ok, fail); else ok(r);
    } catch (e) { fail(e); }
  }
  function poll() {
    if (!state.done) {
      var fired = runTimers();
      if (!state.done) {
        var next = nextTimer();
        if (fired) { idle = 0; return '{"wait":0}'; }
        if (next >= 0) { idle = 0; return '{"wait":' + Math.ceil(next) + '}'; }
        if (++idle < 3) return '{"wait":0}';
        state.e = '脚本没有返回结果'; state.done = true;
      }
    }
    return JSON.stringify(state.e !== undefined ? { done: true, e: state.e } : { done: true, v: state.v });
  }
  Object.defineProperty(g, '__idj', {
    value: {
      attach: attach, start: start, poll: poll,
      fail: function (e) { loadError = message(e); },
      status: function () { return JSON.stringify(spider ? { ok: true } : loadError ? { e: loadError } : {}); },
      has: function (method) { return !!spider && typeof spider[NAMES[method] || method] === 'function'; },
    },
    enumerable: false,
  });
})();
