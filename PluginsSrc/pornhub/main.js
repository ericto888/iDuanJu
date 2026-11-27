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
const SITE = 'https://www.pornhub.com';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15';
const CATS = [
  { id: 'hot', name: '热门', path: '/video?o=ht|/video?o=ht&page={p}', isRank: true },
  { id: 'new', name: '最新', path: '/video?o=mr|/video?o=mr&page={p}' },
  { id: 'week', name: '本周最多观看', path: '/video?o=mv&t=w|/video?o=mv&t=w&page={p}', isRank: true },
  { id: 'rated', name: '本月好评', path: '/video?o=tr&t=m|/video?o=tr&t=m&page={p}' },
];
async function get(path) {
  const url = /^https?:\/\//i.test(path) ? path : SITE + path;
  const res = await host.http.request({ url, headers: { 'User-Agent': UA, 'Referer': SITE + '/' }, timeout: 15000 });
  if (res.status < 200 || res.status >= 300) throw host.error('E_HTTP', 'HTTP ' + res.status);
  return { body: res.body, url: res.url || url };
}
function cardCover(card) {
  const tm = card.match(/(<img\b[^>]*videoThumb[^>]*>)/i);
  if (!tm) {
    const m = card.match(/data-mediumthumb="(https:\/\/[^"]+)"/i);
    return m ? unescapeHtml(m[1]) : '';
  }
  const tag = tm[1];
  for (const a of ['src', 'data-image', 'data-mediumthumb', 'data-src', 'data-thumb_url']) {
    const m = tag.match(new RegExp('\\s' + a + '="(https://[^"]+)"', 'i'));
    if (m && m[1].indexOf('blank.gif') < 0) return unescapeHtml(m[1]);
  }
  return '';
}
function parseList(h, page) {
  const items = [], seen = {};
  for (const chunk of h.split('data-video-vkey="').slice(1)) {
    const km = chunk.match(/^([a-z0-9]+)"/i);
    if (!km || seen[km[1]]) continue;
    const card = chunk.slice(0, 6000);
    const thumbTag = (card.match(/(<img\b[^>]*videoThumb[^>]*>)/i) || [])[1] || '';
    const tm = thumbTag.match(/\salt="([^"]+)"/i) || card.match(/title="([^"]+)"/i);
    const title = tm ? unescapeHtml(tm[1]).trim() : '';
    if (!title || !safeTitle(title)) continue;
    seen[km[1]] = 1;
    const dm = card.match(/<span class="time">([0-9:]+)<\/span>/i) || card.match(/<var class="duration">([0-9:]+)<\/var>/i);
    items.push({ id: km[1], title, cover: cardCover(card), remarks: dm ? dm[1] : '' });
  }
  return { items, page, hasMore: items.length > 0 && h.indexOf('page=' + (page + 1)) >= 0 };
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
    const r = await get(fmtPage('/video/search?search=' + q + '|/video/search?search=' + q + '&page={p}', p));
    return parseList(r.body, p);
  },
  async detail({ id }) {
    const r = await get('/view_video.php?viewkey=' + encodeURIComponent(id));
    const tm = r.body.match(/property="og:title"[^>]*content="([^"]+)"/i);
    const om = r.body.match(/property="og:image"[^>]*content="([^"]+)"/i);
    const title = tm ? unescapeHtml(tm[1]).trim() : id;
    return { title, cover: om ? unescapeHtml(om[1]) : '', lines: [{ name: 'Pornhub', episodes: [{ id, name: title }] }] };
  },
  async play({ episodeId, id }) {
    const r = await get('/view_video.php?viewkey=' + encodeURIComponent(episodeId || id));
    const raw = balancedArray('"mediaDefinitions"', r.body);
    if (!raw) throw host.error('E_PARSE', 'Pornhub 页面里没有播放源（可能需要验证或地区受限）');
    const arr = JSON.parse(raw);
    const hdr = { 'Referer': SITE + '/', 'User-Agent': UA };
    const out = [];
    for (const d of arr) {
      if (d.format !== 'hls' || !d.videoUrl || !String(d.videoUrl).startsWith('https://')) continue;
      const q = Number(d.height) || parseInt(String(d.quality || ''), 10) || 0;
      out.push({ q, s: { name: q > 0 ? q + 'p · HLS' : 'HLS', url: String(d.videoUrl), format: 'hls', headers: hdr } });
    }
    out.sort((a, b) => b.q - a.q);
    if (!out.length) throw host.error('E_PARSE', 'Pornhub 页面里没有 HLS 播放源');
    return { streams: out.map(x => x.s) };
  }
};
