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
const SITE = 'https://www.xvideos.com';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15';
function cats() {
  const m = lastMonth();
  return [
    { id: 'new', name: '最新', path: '/|/new/{p0}' },
    { id: 'best', name: '上月最佳', path: '/best/' + m + '|/best/' + m + '/{p0}', isRank: true },
  ];
}
async function get(path) {
  const url = /^https?:\/\//i.test(path) ? path : SITE + path;
  const res = await host.http.request({ url, headers: { 'User-Agent': UA, 'Referer': SITE + '/' }, timeout: 15000 });
  if (res.status < 200 || res.status >= 300) throw host.error('E_HTTP', 'HTTP ' + res.status);
  return { body: res.body, url: res.url || url };
}
function parseList(h, page) {
  const items = [], seen = {};
  for (const chunk of h.split('thumb-block').slice(1)) {
    const card = chunk.slice(0, 5000);
    const lm = card.match(/href="(\/video[.-]([a-z0-9]+)\/[^"]*)"/i);
    if (!lm || seen[lm[2]]) continue;
    const tm = card.match(/<p class="title">\s*<a[^>]*title="([^"]+)"/i) || card.match(/\balt="([^"]+)"/i) || card.match(/<a[^>]*href="\/video[.-][a-z0-9]+\/[^"]*"[^>]*\btitle="([^"]+)"/i);
    const title = tm ? unescapeHtml(tm[1]).trim() : '';
    if (!title || !safeTitle(title)) continue;
    seen[lm[2]] = 1;
    const cm = card.match(/data-src="(https:\/\/[^"]+\.jpg[^"]*)"/i);
    const dm = card.match(/class="duration">([^<]+)</i);
    items.push({ id: lm[1], title, cover: cm ? cm[1] : '', remarks: dm ? cleanText(dm[1]) : '' });
  }
  return { items, page, hasMore: items.length > 0 };
}
function h5(fn, h) {
  const m = h.match(new RegExp('html5player\\.' + fn + "\\('([^']*)'\\)"));
  return m ? unescapeHtml(m[1]) : '';
}
export default {
  async home() {
    const cs = cats();
    const r = await get(fmtPage(cs[0].path, 1));
    const p = parseList(r.body, 1);
    return { categories: cs.map(c => ({ id: c.id, name: c.name, isRank: !!c.isRank })), items: p.items, hasMore: p.hasMore };
  },
  async category({ id, page }) {
    const p = pageNum(page), cs = cats();
    const cat = cs.find(c => c.id === id) || cs[0];
    const r = await get(fmtPage(cat.path, p));
    return parseList(r.body, p);
  },
  async search({ keyword, page }) {
    const p = pageNum(page), q = encodeURIComponent(String(keyword || '').trim());
    const r = await get(fmtPage('/?k=' + q + '|/?k=' + q + '&p={p0}', p));
    return parseList(r.body, p);
  },
  async detail({ id }) {
    const r = await get(id);
    const title = h5('setVideoTitle', r.body) || id;
    const cover = h5('setThumbUrl169', r.body) || (r.body.match(/property="og:image"[^>]*content="([^"]+)"/i) || [])[1] || '';
    return { title, cover, lines: [{ name: 'XVideos', episodes: [{ id: r.url, name: title }] }] };
  },
  async play({ episodeId, id }) {
    const r = await get(episodeId || id);
    const hdr = { 'Referer': r.url, 'User-Agent': UA };
    const streams = [], seen = {};
    const hls = h5('setVideoHLS', r.body);
    if (hls.startsWith('https://')) { seen[hls] = 1; streams.push({ name: '自动 · HLS', url: hls, format: 'hls', headers: hdr }); }
    for (const [fn, q] of [['setVideoUrlHigh', '高清 MP4'], ['setVideoUrlLow', '标清 MP4']]) {
      const u = h5(fn, r.body);
      if (u.startsWith('https://') && !seen[u]) { seen[u] = 1; streams.push({ name: q, url: u, format: 'mp4', headers: hdr }); }
    }
    if (!streams.length) throw host.error('E_PARSE', 'XVideos 页面里没有播放地址');
    return { streams };
  }
};
