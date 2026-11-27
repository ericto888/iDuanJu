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
const MIRRORS = ['https://jable.tv', 'https://fs1.app'];
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1';
const CATS = [
  { id: 'latest', name: '最近更新', path: '/latest-updates/' },
  { id: 'new', name: '新片上架', path: '/new-release/' },
  { id: 'hot-today', name: '今日热门', path: '/hot/?sort_by=video_viewed_today', isRank: true },
  { id: 'hot-week', name: '本周热门', path: '/hot/?sort_by=video_viewed_week', isRank: true },
  { id: 'hot-month', name: '本月热门', path: '/hot/?sort_by=video_viewed_month', isRank: true },
  { id: 'hot', name: '热门总榜', path: '/hot/', isRank: true },
  { id: 'zh-sub', name: '中文字幕', path: '/categories/chinese-subtitle/' },
  { id: 'uncensored', name: '无码', path: '/categories/uncensored/' },
];
let activeMirror = MIRRORS[0];

async function getPage(path) {
  const order = [activeMirror].concat(MIRRORS.filter(m => m !== activeMirror));
  let lastErr = null;
  for (const base of order) {
    try {
      const url = /^https?:\/\//i.test(path) ? path : base + path;
      const res = await host.http.request({ url, headers: { 'User-Agent': UA, 'Referer': base + '/', 'Accept-Language': 'zh-CN,zh;q=0.9' }, timeout: 15000 });
      if (res.status >= 200 && res.status < 300 && res.body) { activeMirror = base; return { body: res.body, base, url: res.url || url }; }
      lastErr = host.error('E_HTTP', 'HTTP ' + res.status);
    } catch (e) { lastErr = e; }
  }
  throw lastErr || host.error('E_NETWORK', 'Jable 所有镜像均不可达');
}
function pagePath(path, p) { return p > 1 ? path + (path.indexOf('?') >= 0 ? '&' : '?') + 'from=' + p : path; }
function parseList(h, base, page) {
  const items = [], seen = {};
  const re = /<div class="video-img-box[^"]*">([\s\S]*?)<p class="sub-title">([\s\S]*?)<\/p>/gi;
  let m;
  while ((m = re.exec(h)) !== null) {
    const block = m[1];
    const link = block.match(/href="([^"]*\/videos\/([^/"]+)\/?)"/i);
    if (!link || seen[link[2]]) continue;
    seen[link[2]] = 1;
    const tm = block.match(/<h6[^>]*>([\s\S]*?)<\/h6>/i);
    const title = tm ? cleanText(tm[1]) : link[2].toUpperCase();
    if (!safeTitle(title)) continue;
    const cm = block.match(/data-src="([^"]+)"/i) || block.match(/\ssrc="(https?:[^"]+)"/i);
    const dm = block.match(/<span class="label">([^<]+)<\/span>/i);
    items.push({ id: link[2], title: title || link[2].toUpperCase(), cover: cm ? absUrl(base, cm[1]) : '', remarks: dm ? cleanText(dm[1]) : '' });
  }
  let maxFrom = 0;
  const fr = /from(?:_videos)?[:=]0*(\d+)/gi;
  while ((m = fr.exec(h)) !== null) { const n = parseInt(m[1], 10); if (n > maxFrom) maxFrom = n; }
  return { items, page, hasMore: items.length > 0 && maxFrom > page };
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
    const r = await getPage(pagePath('/search/?q=' + encodeURIComponent(String(keyword || '').trim()), p));
    return parseList(r.body, r.base, p);
  },
  async detail({ id }) {
    const r = await getPage('/videos/' + encodeURIComponent(id) + '/');
    const h = r.body;
    const tm = h.match(/<h4[^>]*>([\s\S]*?)<\/h4>/i) || h.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
    const title = tm ? cleanText(tm[1]) : id;
    const og = h.match(/property="og:image"[^>]*content="([^"]+)"/i);
    const tags = [], tre = /<a class="tag[^"]*" href="[^"]*\/tags\/[^"]*">([^<]+)<\/a>/gi;
    let m; while ((m = tre.exec(h)) !== null && tags.length < 16) tags.push(cleanText(m[1]));
    return { title, cover: og ? absUrl(r.base, og[1]) : '', tags, lines: [{ name: 'Jable', episodes: [{ id, name: title }] }] };
  },
  async play({ episodeId, id }) {
    const vid = episodeId || id;
    const r = await getPage('/videos/' + encodeURIComponent(vid) + '/');
    const m = r.body.match(/hlsUrl\s*=\s*['"]([^'"]+\.m3u8[^'"]*)['"]/i);
    if (!m) throw host.error('E_PARSE', 'Jable 页面里没有找到 hlsUrl');
    return { streams: [{ name: 'HLS', url: m[1], format: 'hls', headers: { 'Referer': r.base + '/', 'Origin': r.base, 'User-Agent': UA } }] };
  }
};
