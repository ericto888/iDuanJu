const BLOCKED = [
  'underage','under age','minor ','minors','preteen','pre-teen','child','kid ','kids','loli','shota',
  'schoolgirl','school girl','jailbait','rape','raped','forced','non-consensual','nonconsensual','non consent',
  'drugged','unconscious','sleeping','passed out','hidden cam','hidden camera','spy cam','upskirt',
  '未成年','幼女','萝莉','蘿莉','中学生','中學生','小学生','小學生','强奸','強姦','强暴','迷奸','迷姦','偷拍','下药','下藥'
];
function safeTitle(t) {
  const s = ' ' + String(t || '').toLowerCase() + ' ';
  for (let i = 0; i < BLOCKED.length; i++) if (s.indexOf(BLOCKED[i]) >= 0) return false;
  return true;
}
function unescapeHtml(s) {
  return String(s || '')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#0?39;/g, "'").replace(/&#x27;/gi, "'")
    .replace(/&nbsp;/g, ' ').replace(/\\\//g, '/');
}
function cleanText(s) {
  return unescapeHtml(String(s || '').replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim();
}
function absUrl(base, u) {
  u = unescapeHtml(u).trim();
  if (!u || /^(?:data|javascript|about):/i.test(u)) return '';
  if (u.startsWith('//')) return 'https:' + u;
  if (/^http:\/\//i.test(u)) return 'https://' + u.slice(7);
  if (/^https:\/\//i.test(u)) return u;
  return host.url.resolve(base.endsWith('/') ? base : base + '/', u);
}
function pageNum(p) { const n = Number(p); return Number.isFinite(n) && n > 0 ? Math.floor(n) : 1; }
function balancedArray(marker, h) {
  const idx = h.indexOf(marker);
  if (idx < 0) return null;
  const open = h.indexOf('[', idx + marker.length);
  if (open < 0) return null;
  let depth = 0, inStr = false, esc = false;
  for (let i = open; i < h.length; i++) {
    const c = h[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === '\\') esc = true;
      else if (c === '"') inStr = false;
    } else if (c === '"') inStr = true;
    else if (c === '[') depth++;
    else if (c === ']') { depth--; if (depth === 0) return h.slice(open, i + 1); }
  }
  return null;
}
function fmtPage(tpl, page) {
  const parts = tpl.split('|');
  const s = page <= 1 ? parts[0] : (parts.length > 1 ? parts[1] : parts[0]);
  return s.replace(/\{p0\}/g, String(Math.max(0, page - 1))).replace(/\{p\}/g, String(Math.max(1, page)));
}
function lastMonth() {
  const d = new Date();
  d.setUTCMonth(d.getUTCMonth() - 1);
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  return d.getUTCFullYear() + '-' + m;
}
function toBase(n, base) {
  const digits = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
  if (n === 0) return '0';
  let s = '';
  while (n > 0) { s = digits[n % base] + s; n = Math.floor(n / base); }
  return s;
}
function unpackOne(script) {
  const m = script.match(/eval\(function\(p,a,c,k,e,d\)\{[\s\S]*?\}\('([\s\S]*?)',\s*(\d+),\s*(\d+),\s*'([^']*)'\s*\.split\('\|'\)/);
  if (!m) return null;
  const a = parseInt(m[2], 10), c = parseInt(m[3], 10);
  if (!(a > 1 && a <= 62 && c >= 0 && c <= 200000)) return null;
  const keys = m[4].split('|');
  const lookup = {};
  for (let i = 0; i < c; i++) {
    const k = toBase(i, a);
    lookup[k] = (i < keys.length && keys[i]) ? keys[i] : k;
  }
  return m[1].replace(/\b(\w+)\b/g, (w) => lookup[w] || w).replace(/\\'/g, "'");
}
function unpackedScripts(html) {
  const out = [];
  const re = /<script[^>]*>([\s\S]*?)<\/script>/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    if (m[1].indexOf('eval(function(p,a,c,k,e,d)') >= 0) {
      const u = unpackOne(m[1]);
      if (u) out.push(u);
    }
  }
  return out;
}
const MIRRORS = ['https://missav.live', 'https://missav.ai', 'https://missav.ws', 'https://missav.fans', 'https://missav.media'];
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1';
const FALLBACK_VIDEO_HOSTS = ['c.surrit.com', 'surrit.mrstcdn.store'];
const COVER_HOST = 'fourhoi.mrstcdn.store';
const CATS = [
  { id: 'today-hot', name: '今日热门', path: '/dm298/cn/today-hot', isRank: true },
  { id: 'weekly-hot', name: '本周热门', path: '/dm170/cn/weekly-hot', isRank: true },
  { id: 'monthly-hot', name: '月度热门', path: '/dm266/cn/monthly-hot', isRank: true },
  { id: 'chinese-subtitle', name: '中文字幕', path: '/dm278/cn/chinese-subtitle?sort=released_at' },
  { id: 'release', name: '最新发布', path: '/dm632/cn/release?sort=released_at' },
  { id: 'new', name: '最近更新', path: '/dm539/cn/new' },
  { id: 'uncensored-leak', name: '无码流出', path: '/dm816/cn/uncensored-leak?sort=released_at' },
  { id: 'fc2', name: 'FC2', path: '/dm473/cn/fc2?sort=released_at' },
  { id: 'siro', name: 'SIRO 素人', path: '/dm36/cn/siro?sort=released_at' },
  { id: 'madou', name: '麻豆', path: '/dm63/cn/madou?sort=released_at' },
];
let activeMirror = MIRRORS[0];

async function getPage(path) {
  const order = [activeMirror].concat(MIRRORS.filter(m => m !== activeMirror));
  let lastErr = null;
  for (const base of order) {
    try {
      const url = /^https?:\/\//i.test(path) ? path : base + path;
      const res = await host.http.request({ url, headers: { 'User-Agent': UA, 'Referer': base + '/', 'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.6' }, timeout: 15000 });
      if (res.status >= 200 && res.status < 300 && res.body && res.body.length > 2000) {
        activeMirror = base;
        return { body: res.body, base, url: res.url || url };
      }
      lastErr = host.error('E_HTTP', 'HTTP ' + res.status);
    } catch (e) { lastErr = e; }
  }
  throw lastErr || host.error('E_NETWORK', 'MissAV 所有镜像均不可达');
}
function fixCover(raw, id, kind) {
  let u = String(raw || '').trim();
  if (!u || u.startsWith('data:') || u.endsWith('.mp4')) u = '';
  if (u.indexOf('//fourhoi.com/') >= 0) u = u.replace('//fourhoi.com/', '//' + COVER_HOST + '/');
  if (!u && id) u = 'https://' + COVER_HOST + '/' + id.toLowerCase() + '/' + (kind || 'cover-t') + '.jpg';
  return u;
}
function pagePath(path, p) { return p > 1 ? path + (path.indexOf('?') >= 0 ? '&' : '?') + 'page=' + p : path; }
function parseList(h, base, page) {
  const items = [], seen = {};
  const chunks = h.split('class="thumbnail').slice(1);
  for (const chunk of chunks) {
    const card = chunk.slice(0, 6000);
    const hm = card.match(/<a\s+href="([^"]+)"/i);
    if (!hm) continue;
    const url = absUrl(base, hm[1]);
    if (url.indexOf('/search/') >= 0) continue;
    const slug = url.replace(/\/+$/, '').split('/').pop().split('?')[0];
    if (!slug || !/\d/.test(slug) || seen[slug]) continue;
    seen[slug] = 1;
    const im = card.match(/<img[^>]*?data-src="([^"]+)"/i) || card.match(/<img[^>]*?\ssrc="(https?:[^"]+)"/i);
    const tm = card.match(/<div class="my-2[^"]*">\s*<a[^>]*>([\s\S]*?)<\/a>/i) || card.match(/<img[^>]*?alt="([^"]*)"/i);
    const title = tm ? cleanText(tm[1]) : slug.toUpperCase();
    if (!safeTitle(title)) continue;
    const dm = card.match(/bottom-1 right-1[^"]*">\s*([0-9:]+)\s*</i);
    items.push({ id: slug, title: title || slug.toUpperCase(), cover: fixCover(im ? im[1] : '', slug, 'cover-t'), remarks: dm ? dm[1] : '' });
  }
  return { items, page, hasMore: items.length > 0 && h.indexOf('page=' + (page + 1)) >= 0 };
}
function extractSource(h) {
  const re = /https?:\/\/([a-z0-9.-]*surrit\.[a-z0-9.]+)\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\//i;
  for (const js of unpackedScripts(h)) { const m = js.match(re); if (m) return { host: m[1].toLowerCase(), uuid: m[2].toLowerCase() }; }
  const m = h.match(re);
  return m ? { host: m[1].toLowerCase(), uuid: m[2].toLowerCase() } : null;
}
function candidateVideoHosts(extracted) {
  const out = [];
  if (extracted && extracted.endsWith('.surrit.com')) out.push(extracted);
  for (const h of FALLBACK_VIDEO_HOSTS) if (out.indexOf(h) < 0) out.push(h);
  if (extracted && out.indexOf(extracted) < 0) out.push(extracted);
  return out;
}
export default {
  async home() {
    const r = await getPage(CATS[0].path);
    const p = parseList(r.body, r.base, 1);
    return { categories: CATS.map(c => ({ id: c.id, name: c.name, isRank: !!c.isRank })), items: p.items, hasMore: p.hasMore };
  },
  async category({ id, page }) {
    const p = pageNum(page);
    const cat = CATS.find(c => c.id === id) || CATS[0];
    const r = await getPage(pagePath(cat.path, p));
    return parseList(r.body, r.base, p);
  },
  async search({ keyword, page }) {
    const p = pageNum(page);
    const r = await getPage(pagePath('/cn/search/' + encodeURIComponent(String(keyword || '').trim()), p));
    return parseList(r.body, r.base, p);
  },
  async detail({ id }) {
    const r = await getPage('/cn/' + encodeURIComponent(id));
    const h = r.body;
    const tm = h.match(/og:title"\s+content="([^"]+)"/i);
    const om = h.match(/og:image"\s+content="([^"]+)"/i);
    const dm = h.match(/og:description"\s+content="([^"]*)"/i);
    const title = tm ? cleanText(tm[1]) : id.toUpperCase();
    return { title, cover: fixCover(om ? om[1] : '', id, 'cover-n'), desc: dm ? cleanText(dm[1]) : '', lines: [{ name: 'MissAV', episodes: [{ id, name: title }] }] };
  },
  async play({ episodeId, id }) {
    const slug = episodeId || id;
    const r = await getPage('/cn/' + encodeURIComponent(slug));
    const src = extractSource(r.body);
    if (!src) throw host.error('E_PARSE', 'MissAV 页面里没有找到视频 ID');
    const streamOrigin = (r.base.indexOf('missav.fans') >= 0 || r.base.indexOf('missav.media') >= 0) ? 'https://missav.live' : r.base;
    const hdr = { 'Referer': streamOrigin + '/', 'Origin': streamOrigin, 'User-Agent': UA };
    const hosts = candidateVideoHosts(src.host);
    for (const vhost of hosts) {
      const root = 'https://' + vhost + '/' + src.uuid;
      const streams = [];
      let masterOk = false;
      try {
        const mr = await host.http.request({ url: root + '/playlist.m3u8', headers: hdr, timeout: 6000 });
        if (mr.status >= 200 && mr.status < 300 && mr.body && mr.body.indexOf('#EXTM3U') >= 0) masterOk = true;
      } catch (_) {}
      for (const q of [1080, 720, 480, 360]) {
        const u = root + '/' + q + 'p/video.m3u8';
        try {
          const pr = await host.http.request({ url: u, headers: hdr, timeout: 6000 });
          if (pr.status >= 200 && pr.status < 300 && pr.body && pr.body.indexOf('#EXTM3U') >= 0) {
            streams.push({ name: q + 'P', url: u, format: 'hls', headers: hdr });
          }
        } catch (_) {}
      }
      if (masterOk) streams.push({ name: '自动 · HLS', url: root + '/playlist.m3u8', format: 'hls', headers: hdr });
      if (streams.length > 0) return { streams };
    }
    return { streams: [{ name: '自动 · HLS', url: 'https://' + hosts[0] + '/' + src.uuid + '/playlist.m3u8', format: 'hls', headers: hdr }] };
  }
};
