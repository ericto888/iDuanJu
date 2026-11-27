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
const SITE = 'https://hanime1.me';
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1';
const CATS = [
  { id: 'new-release', name: '最新上市', path: '/search?sort=' + encodeURIComponent('最新上市') },
  { id: 'new-upload', name: '最新上传', path: '/search?sort=' + encodeURIComponent('最新上傳') },
  { id: 'day', name: '本日排行', path: '/search?sort=' + encodeURIComponent('本日排行'), isRank: true },
  { id: 'week', name: '本周排行', path: '/search?sort=' + encodeURIComponent('本週排行'), isRank: true },
  { id: 'month', name: '本月排行', path: '/search?sort=' + encodeURIComponent('本月排行'), isRank: true },
  { id: 'hentai', name: '里番', path: '/search?genre=' + encodeURIComponent('裏番') + '&sort=' + encodeURIComponent('最新上市') },
  { id: 'short', name: '泡面番', path: '/search?genre=' + encodeURIComponent('泡麵番') + '&sort=' + encodeURIComponent('最新上市') },
  { id: '3dcg', name: '3DCG', path: '/search?genre=3DCG&sort=' + encodeURIComponent('最新上市') },
  { id: 'zh-sub', name: '中文字幕', path: '/search?tags%5B%5D=' + encodeURIComponent('中文字幕') + '&sort=' + encodeURIComponent('最新上市') },
];
let primed = false;
async function getPage(path) {
  if (!primed) { primed = true; try { await host.http.request({ url: SITE + '/', headers: { 'User-Agent': UA }, timeout: 10000 }); } catch (_) {} }
  const url = /^https?:\/\//i.test(path) ? path : SITE + path;
  const res = await host.http.request({ url, headers: { 'User-Agent': UA, 'Referer': SITE + '/' }, timeout: 15000 });
  if (res.status < 200 || res.status >= 300) throw host.error('E_HTTP', 'HTTP ' + res.status);
  return { body: res.body, url: res.url || url };
}
function pagePath(path, p) { return p > 1 ? path + (path.indexOf('?') >= 0 ? '&' : '?') + 'page=' + p : path; }
function parseList(h, page) {
  const items = [], seen = {};
  for (const chunk of h.split('class="video-item-container"').slice(1)) {
    const card = chunk.slice(0, 4000);
    const lm = card.match(/href="([^"]*\/watch\?v=(\d+))"/i);
    if (!lm || seen[lm[2]]) continue;
    seen[lm[2]] = 1;
    const tm = card.match(/<div class="title">([\s\S]*?)<\/div>/i);
    const title = tm ? cleanText(tm[1]) : '#' + lm[2];
    if (!safeTitle(title)) continue;
    const cm = card.match(/<img[^>]*class="main-thumb"[^>]*src="([^"]+)"/i);
    const dm = card.match(/<div class="duration">\s*([0-9:]+)/i);
    items.push({ id: lm[2], title, cover: cm ? absUrl(SITE, cm[1]) : '', remarks: dm ? dm[1] : '' });
  }
  const re = /<a[^>]*href="([^"]*\/watch\?v=(\d+))"[^>]*>\s*<div class="home-rows-videos-div search-videos[^"]*"([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = re.exec(h)) !== null) {
    if (seen[m[2]]) continue;
    const tm = m[3].match(/home-rows-videos-title"[^>]*>([\s\S]*?)<\/div>/i);
    const title = tm ? cleanText(tm[1]) : '';
    if (!title || !safeTitle(title)) continue;
    seen[m[2]] = 1;
    const cm = m[3].match(/<img[^>]*?(?:data-src|src)="([^"]+)"/i);
    items.push({ id: m[2], title, cover: cm ? absUrl(SITE, cm[1]) : '', orientation: 'portrait' });
  }
  return { items, page, hasMore: items.length > 0 && h.indexOf('page=' + (page + 1)) >= 0 };
}
export default {
  async home() {
    const r = await getPage(CATS[0].path);
    const p = parseList(r.body, 1);
    return { categories: CATS.map(c => ({ id: c.id, name: c.name, isRank: !!c.isRank })), items: p.items, hasMore: p.hasMore };
  },
  async category({ id, page }) {
    const p = pageNum(page);
    const cat = CATS.find(c => c.id === id) || CATS[0];
    const r = await getPage(pagePath(cat.path, p));
    return parseList(r.body, p);
  },
  async search({ keyword, page }) {
    const p = pageNum(page);
    const r = await getPage(pagePath('/search?query=' + encodeURIComponent(String(keyword || '').trim()), p));
    return parseList(r.body, p);
  },
  async detail({ id }) {
    const r = await getPage('/watch?v=' + encodeURIComponent(id));
    const h = r.body;
    const tm = h.match(/<h3[^>]*class="video-details-wrapper"[^>]*>([\s\S]*?)<\/h3>/i) || h.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
    const title = tm ? cleanText(tm[1]).replace(/\s+-\s+Hanime1\.me\s*$/i, '') : '#' + id;
    const om = h.match(/property="og:image"[^>]*content="([^"]+)"/i) || h.match(/<video[^>]*poster="([^"]+)"/i);
    return { title, cover: om ? absUrl(SITE, om[1]) : '', lines: [{ name: 'Hanime1', episodes: [{ id, name: title }] }] };
  },
  async play({ episodeId, id }) {
    const vid = episodeId || id;
    const r = await getPage('/watch?v=' + encodeURIComponent(vid));
    const hdr = { 'Referer': r.url, 'User-Agent': UA };
    const out = [], seen = {};
    const re = /<source\b([^>]*)>/gi;
    let m;
    while ((m = re.exec(r.body)) !== null) {
      const tag = m[1];
      const sm = tag.match(/\bsrc=["']([^"']+)["']/i);
      if (!sm) continue;
      const src = unescapeHtml(sm[1]).trim();
      if (!src.startsWith('https://') || src.toLowerCase().indexOf('.mp4') < 0 || seen[src]) continue;
      seen[src] = 1;
      const sz = tag.match(/\bsize=["'](\d+)["']/i) || src.match(/(\d{3,4})p/i);
      const height = sz ? parseInt(sz[1], 10) : 0;
      out.push({ h: height, s: { name: height > 0 ? height + 'p' : 'MP4', url: src, format: 'mp4', headers: hdr } });
    }
    out.sort((a, b) => b.h - a.h);
    if (!out.length) throw host.error('E_PARSE', 'Hanime1 页面里没有找到 MP4 源');
    return { streams: out.map(x => x.s) };
  }
};
