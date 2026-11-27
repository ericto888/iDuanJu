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
const SITE = 'https://www.redtube.com';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15';
const CATS = [
  { id: 'hot', name: '热门', path: '/hot|/hot?page={p}', isRank: true },
  { id: 'viewed', name: '最多观看', path: '/mostviewed|/mostviewed?page={p}', isRank: true },
  { id: 'top', name: '高分', path: '/top|/top?page={p}', isRank: true },
];
async function get(path) {
  const url = /^https?:\/\//i.test(path) ? path : SITE + path;
  const res = await host.http.request({ url, headers: { 'User-Agent': UA, 'Referer': SITE + '/' }, timeout: 15000 });
  if (res.status < 200 || res.status >= 300) throw host.error('E_HTTP', 'HTTP ' + res.status);
  return { body: res.body, url: res.url || url };
}
function parseList(h, page) {
  const items = [], seen = {};
  for (const chunk of h.split('video_block_wrapper').slice(1)) {
    const card = chunk.slice(0, 8000);
    const idm = card.match(/href="\/(\d{5,})"/);
    if (!idm || seen[idm[1]]) continue;
    const tm = card.match(/title="([^"]+)"[^>]*video-title-text/i) || card.match(/class="[^"]*video-title-text[^"]*"[^>]*>([^<]+)/i) || card.match(/\balt="([^"]+)"/i);
    const title = tm ? unescapeHtml(tm[1]).trim() : '';
    if (!title || !safeTitle(title)) continue;
    seen[idm[1]] = 1;
    const cm = card.match(/data-src="(https:\/\/[^\s"]+)/i) || card.match(/data-srcset="(https:\/\/[^\s"]+)/i) || card.match(/data-(?:poster|thumb|image)="(https:\/\/[^\s"]+)/i);
    const dm = card.match(/tm_video_duration">\s*([0-9:]+)/i);
    items.push({ id: idm[1], title, cover: cm ? unescapeHtml(cm[1]) : '', remarks: dm ? dm[1] : '' });
  }
  return { items, page, hasMore: items.length > 0 && h.indexOf('page=' + (page + 1)) >= 0 };
}
async function resolveAylo(html, pageUrl) {
  const raw = balancedArray('"mediaDefinitions"', html);
  if (!raw) return [];
  const defs = JSON.parse(raw);
  const hdr = { 'Referer': SITE + '/', 'User-Agent': UA };
  const out = [], seen = {};
  function add(url, fmt, height) {
    url = absUrl(pageUrl, url);
    if (!url.startsWith('https://') || url.indexOf('premium') >= 0 || seen[url]) return;
    if (url.indexOf('.m3u8') < 0 && url.indexOf('.mp4') < 0) return;
    seen[url] = 1;
    const hls = fmt === 'hls' || url.indexOf('.m3u8') >= 0;
    const h = Number(height) || 0;
    out.push({ hls: hls ? 1 : 0, h, s: { name: (h > 0 ? h + 'p · ' : '自动 · ') + (hls ? 'HLS' : 'MP4'), url, format: hls ? 'hls' : 'mp4', headers: hdr } });
  }
  for (const d of defs) {
    if (d.format !== 'hls' && d.format !== 'mp4') continue;
    const u = absUrl(pageUrl, d.videoUrl || '');
    if (!u.startsWith('https://') || u.indexOf('premium') >= 0) continue;
    const remote = !!d.remote || (u.indexOf('.m3u8') < 0 && u.indexOf('.mp4') < 0);
    if (!remote) { add(u, d.format, d.height); continue; }
    try {
      const r = await host.http.request({ url: u, headers: { 'User-Agent': UA, 'Referer': SITE + '/', 'Accept': 'application/json' }, timeout: 12000 });
      if (r.status >= 200 && r.status < 300 && r.body) {
        const parsed = JSON.parse(r.body);
        const rows = Array.isArray(parsed) ? parsed : [parsed];
        for (const row of rows) if (row && (row.format === 'hls' || row.format === 'mp4')) add(row.videoUrl, row.format, row.height);
      }
    } catch (_) {}
  }
  out.sort((a, b) => (b.hls - a.hls) || (b.h - a.h));
  return out.map(x => x.s);
}
export default {
  async home() {
    const r = await get(fmtPage(CATS[0].path, 1));
    const p = parseList(r.body, 1);
    return { categories: CATS.map(c => ({ id: c.id, name: c.name, isRank: !!c.isRank })), items: p.items, hasMore: p.hasMore };
  },
  async category({ id, page }) {
    const p = pageNum(page);
    const cat = CATS.find(c => c.id === id) || CATS[0];
    const r = await get(fmtPage(cat.path, p));
    return parseList(r.body, p);
  },
  async search({ keyword, page }) {
    const p = pageNum(page), q = encodeURIComponent(String(keyword || '').trim());
    const r = await get(fmtPage('/?search=' + q + '|/?search=' + q + '&page={p}', p));
    return parseList(r.body, p);
  },
  async detail({ id }) {
    const r = await get('/' + encodeURIComponent(id));
    const tm = r.body.match(/property="og:title"[^>]*content="([^"]+)"/i);
    const om = r.body.match(/property="og:image"[^>]*content="([^"]+)"/i);
    const title = tm ? unescapeHtml(tm[1]).trim() : id;
    return { title, cover: om ? unescapeHtml(om[1]) : '', lines: [{ name: 'RedTube', episodes: [{ id, name: title }] }] };
  },
  async play({ episodeId, id }) {
    const r = await get('/' + encodeURIComponent(episodeId || id));
    const streams = await resolveAylo(r.body, r.url);
    if (!streams.length) throw host.error('E_PARSE', 'RedTube 页面里没有播放源（可能需要验证或地区受限）');
    return { streams };
  }
};
