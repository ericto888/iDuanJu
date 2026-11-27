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
const SITE = 'https://www.eporner.com';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15';
function apiPath(q, order, p) {
  return '/api/v2/video/search/?query=' + encodeURIComponent(q) + '&order=' + order + '&per_page=30&page=' + p + '&thumbsize=big&format=json';
}
const CATS = [
  { id: 'latest', name: '最新上传', q: 'all', order: 'latest' },
  { id: 'week', name: '本周热门', q: 'all', order: 'top-weekly', isRank: true },
  { id: 'month', name: '本月热门', q: 'all', order: 'top-monthly', isRank: true },
  { id: 'popular', name: '最受欢迎', q: 'all', order: 'most-popular', isRank: true },
  { id: 'rated', name: '好评最多', q: 'all', order: 'top-rated' },
  { id: 'hd', name: '高清 1080P', q: '1080p', order: 'latest' },
];
async function get(path) {
  const url = /^https?:\/\//i.test(path) ? path : SITE + path;
  const res = await host.http.request({ url, headers: { 'User-Agent': UA, 'Referer': SITE + '/' }, timeout: 15000 });
  if (res.status < 200 || res.status >= 300) throw host.error('E_HTTP', 'HTTP ' + res.status);
  return res.body;
}
function mapItem(v) {
  const id = String(v.id || '').trim();
  const title = unescapeHtml(v.title || '').trim();
  if (!id || !/^[a-z0-9]+$/i.test(id) || !title || !safeTitle(title)) return null;
  const cover = v.default_thumb && v.default_thumb.src ? String(v.default_thumb.src) : '';
  const tags = String(v.keywords || '').split(',').map(s => s.trim()).filter(Boolean).slice(0, 8);
  return { id, title, cover, remarks: v.length_min || '', tags };
}
function parseList(text, page) {
  const o = JSON.parse(text);
  const items = (o.videos || []).map(mapItem).filter(Boolean);
  return { items, page, hasMore: page < (Number(o.total_pages) || 0) };
}
function xhrHash(h) {
  if (!h || h.length !== 32) return '';
  let out = '';
  for (let i = 0; i < 32; i += 8) out += parseInt(h.slice(i, i + 8), 16).toString(36);
  return out;
}
export default {
  async home() {
    const p = parseList(await get(apiPath('all', 'latest', 1)), 1);
    return { categories: CATS.map(c => ({ id: c.id, name: c.name, isRank: !!c.isRank })), items: p.items, hasMore: p.hasMore };
  },
  async category({ id, page }) {
    const p = pageNum(page);
    const cat = CATS.find(c => c.id === id) || CATS[0];
    return parseList(await get(apiPath(cat.q, cat.order, p)), p);
  },
  async search({ keyword, page }) {
    const p = pageNum(page);
    return parseList(await get(apiPath(String(keyword || '').trim() || 'all', 'latest', p)), p);
  },
  async detail({ id }) {
    const v = JSON.parse(await get('/api/v2/video/id/?id=' + encodeURIComponent(id) + '&thumbsize=big&format=json'));
    const it = mapItem(v) || { id, title: id, cover: '', tags: [] };
    return { title: it.title, cover: it.cover, tags: it.tags || [], lines: [{ name: 'Eporner', episodes: [{ id: v.url || (SITE + '/video-' + id + '/'), name: it.title }] }] };
  },
  async play({ episodeId, id }) {
    const pageUrl = /^https?:\/\//i.test(episodeId || '') ? episodeId : (SITE + '/video-' + encodeURIComponent(id) + '/');
    const html = await get(pageUrl);
    const hm = html.match(/EP\.video\.player\.hash\s*=\s*'([0-9a-f]{32})'/i) || html.match(/hash\s*:\s*'([0-9a-f]{32})'/i);
    if (!hm) throw host.error('E_PARSE', 'Eporner 页面里没有播放器 hash');
    const vm = html.match(/EP\.video\.player\.vid\s*=\s*'([^']+)'/i);
    const vid = vm ? vm[1] : id;
    const x = JSON.parse(await get('/xhr/video/' + encodeURIComponent(vid) + '?hash=' + xhrHash(hm[1]) + '&device=generic&domain=www.eporner.com&fallback=false&embed=false&supportedFormats=hls,mp4&tech=Html5&_=' + Date.now()));
    const hdr = { 'Referer': SITE + '/', 'User-Agent': UA };
    const src = x.sources || {};
    const streams = [];
    for (const k in (src.hls || {})) {
      const u = src.hls[k] && src.hls[k].src;
      if (u && u.startsWith('https://')) streams.push({ name: '自动 · HLS', url: u, format: 'hls', headers: hdr });
    }
    const mp4 = [];
    for (const k in (src.mp4 || {})) {
      const u = src.mp4[k] && src.mp4[k].src;
      if (!u || !u.startsWith('https://')) continue;
      const qm = k.match(/(\d{3,4})p/i);
      const h = qm ? parseInt(qm[1], 10) : 0;
      mp4.push({ h, s: { name: (h > 0 ? h + 'p · ' : '') + 'MP4', url: u, format: 'mp4', headers: hdr } });
    }
    mp4.sort((a, b) => b.h - a.h);
    const all = streams.concat(mp4.map(x => x.s));
    if (!all.length) throw host.error('E_PARSE', 'Eporner 未返回播放源');
    return { streams: all };
  }
};
