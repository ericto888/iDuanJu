// 91Porn · iDuanJu idj1 video plugin
const SITE = 'https://91porn.com';
const USER_AGENT = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1';
const MEDIA_CACHE = {};

const CATEGORIES = [
  { id: 'rf', name: '最近加精' },
  { id: 'hot', name: '当前最热' },
  { id: 'top', name: '本月最热' },
  { id: 'tf', name: '本月收藏' },
  { id: 'md', name: '本月讨论' },
  { id: 'top&m=-1', name: '上月最热' },
  { id: 'ori', name: '91原创' },
  { id: 'long', name: '10 分钟以上' },
  { id: 'longer', name: '20 分钟以上' },
  { id: 'hd', name: '高清' },
  { id: 'mf', name: '收藏最多' }
];

function pageNumber(value) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 1;
}

function cleanText(value) {
  return String(value == null ? '' : value).replace(/\s+/g, ' ').trim();
}

function absoluteUrl(value) {
  let url = cleanText(value).replace(/&amp;/g, '&').replace(/\\\//g, '/');
  if (!url || /^(?:data|javascript|about):/i.test(url)) return '';
  if (url.startsWith('//')) url = 'https:' + url;
  if (/^http:\/\//i.test(url)) url = 'https://' + url.slice(7);
  return host.url.resolve(SITE + '/', url);
}

function requestHeaders(referer) {
  return {
    'User-Agent': USER_AGENT,
    'Referer': referer || SITE + '/',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.7'
  };
}

async function requestPage(url, referer) {
  const res = await host.http.request({
    url: url,
    headers: requestHeaders(referer),
    timeout: 15000
  });
  if (res.status === 404) throw host.error('E_NOT_FOUND', '页面不存在：' + url);
  if (res.status < 200 || res.status >= 300) {
    throw host.error('E_HTTP', 'HTTP ' + res.status + '：' + url);
  }
  const body = String(res.body == null ? '' : res.body);
  if (!body.trim()) throw host.error('E_PARSE', '页面正文为空：' + url);
  return {
    body: body,
    url: res.url || url,
    doc: host.html.parse(body, res.url || url)
  };
}

function viewKey(value) {
  const m = String(value == null ? '' : value).match(/[?&]viewkey=([^&#]+)/i);
  if (!m) return '';
  try {
    return decodeURIComponent(m[1]);
  } catch (_) {
    return m[1];
  }
}

function detailUrl(value) {
  const raw = String(value == null ? '' : value).trim();
  if (/^https?:\/\//i.test(raw)) return absoluteUrl(raw);
  const key = viewKey(raw);
  if (key) return SITE + '/view_video.php?viewkey=' + encodeURIComponent(key);
  if (raw.indexOf('/') >= 0 || raw.indexOf('?') >= 0) return absoluteUrl(raw);
  return raw ? SITE + '/view_video.php?viewkey=' + encodeURIComponent(raw) : '';
}

function isVideoLink(href) {
  const value = String(href == null ? '' : href).replace(/&amp;/g, '&');
  return value.indexOf('view_video') >= 0 && !/[?&]c=acvqqa(?:&|$)/i.test(value);
}

function categoryQuery(value) {
  const raw = cleanText(value) || 'rf';
  return raw.split('&').map(function (part) {
    return part.split('=').map(function (segment) {
      return encodeURIComponent(segment);
    }).join('=');
  }).join('&');
}

function listUrl(category, page) {
  const id = category === '__home' || category === '_home' || !category ? 'rf' : category;
  return SITE + '/v.php?category=' + categoryQuery(id) + '&viewtype=basic&page=' + pageNumber(page);
}

function searchUrl(keyword, page) {
  return SITE + '/search_result.php?search_id=' + encodeURIComponent(cleanText(keyword))
    + '&search_type=search_videos&page=' + pageNumber(page);
}

function firstText(root, selectors) {
  for (const selector of selectors) {
    const node = root.selectFirst(selector);
    const text = node ? cleanText(node.text()) : '';
    if (text) return text;
  }
  return '';
}

function firstAttr(root, selectors, name) {
  for (const selector of selectors) {
    const node = root.selectFirst(selector);
    const value = node ? node.attr(name) : '';
    if (value) return value;
  }
  return '';
}

function imageUrl(value) {
  const url = absoluteUrl(value);
  if (!url || /(?:loading|spacer|blank|transparent)\.(?:gif|png|svg)(?:\?|$)/i.test(url)) return '';
  return url;
}

function cardItems(doc) {
  let cards = doc.select('article.vitem');
  if (!cards.length) cards = doc.select('.vitem');
  if (!cards.length) cards = doc.select('.well-sm');
  return cards;
}

function parseItems(doc) {
  const items = [];
  const seen = {};
  for (const card of cardItems(doc)) {
    let linkNode = card.selectFirst('a[href*="view_video"]');
    if (!linkNode) linkNode = card.selectFirst('a[href*="view_video_hd"]');
    if (!linkNode) continue;

    const href = linkNode.attr('href');
    if (!isVideoLink(href)) continue;
    const link = absoluteUrl(href);
    const key = viewKey(link) || link;
    if (!link || !key || seen[key]) continue;
    seen[key] = true;

    const title = firstText(card, ['bdi', '.video-title', '.title-truncate'])
      || cleanText(linkNode.attr('title'));
    if (!title) continue;

    const coverRaw = firstAttr(card, ['img.img-responsive', 'img'], 'src')
      || firstAttr(card, ['img.img-responsive', 'img'], 'data-src')
      || firstAttr(card, ['img.img-responsive', 'img'], 'data-original');
    const cover = imageUrl(coverRaw);
    const duration = firstText(card, ['.duration']);
    const tags = [];
    if (card.selectFirst('.hd-text-icon')) tags.push('HD');

    // Keep the exact detail URL (including the list's category/page/view mode) so the media
    // Referer stays identical from detail parsing through playback.
    const item = { id: link, title: title };
    if (cover) {
      item.cover = cover;
      item.coverHeaders = requestHeaders(link);
    }
    if (duration) item.remarks = duration;
    if (tags.length) item.tags = tags;
    items.push(item);
  }
  return items;
}

function hasNextPage(doc, page) {
  const next = pageNumber(page) + 1;
  const pattern = new RegExp('(?:[?&])page=' + next + '(?:[&#]|$)');
  return doc.select('a').some(function (node) {
    return pattern.test(String(node.attr('href') == null ? '' : node.attr('href')).replace(/&amp;/g, '&'));
  });
}

async function loadList(url, referer) {
  const page = await requestPage(url, referer || SITE + '/');
  const items = parseItems(page.doc);
  if (!items.length) {
    throw host.error('E_PARSE', '列表页没有可用视频，站点结构可能已变化');
  }
  return { page: page, items: items };
}

function decodeEncodedSource(value) {
  const encoded = String(value == null ? '' : value);
  try {
    return decodeURIComponent(encoded);
  } catch (_) {
    return encoded;
  }
}

function cleanVideoUrl(value) {
  let url = String(value == null ? '' : value).trim()
    .replace(/\\\//g, '/')
    .replace(/\\u0026/gi, '&')
    .replace(/&amp;/g, '&');
  if (!url) return '';

  const source = url.match(/<source\b[^>]*\bsrc\s*=\s*(["'])(.*?)\1/i);
  if (source) url = source[2];
  if (url.startsWith('//')) url = 'https:' + url;
  if (/^http:\/\//i.test(url)) url = 'https://' + url.slice(7);
  return /^https:\/\//i.test(url) ? url : '';
}

function extractVideoUrls(body, doc) {
  const urls = [];
  const seen = {};
  function add(value) {
    const url = cleanVideoUrl(value);
    if (!url || seen[url]) return;
    seen[url] = true;
    urls.push(url);
  }

  const encodedPattern = /strencode2\s*\(\s*(["'])([\s\S]*?)\1\s*\)/gi;
  let match;
  while ((match = encodedPattern.exec(body)) !== null) {
    add(decodeEncodedSource(match[2]));
  }

  const domSource = firstAttr(doc, [
    '#player_one source',
    '#player_one video',
    'video#player_one source',
    'video#player_one',
    'video source'
  ], 'src');
  add(domSource);

  const visible = String(body == null ? '' : body).replace(/<!--[\s\S]*?-->/g, '');
  const source = visible.match(/<source\b[^>]*\bsrc\s*=\s*(["'])(.*?)\1/i);
  if (source) add(source[2]);

  const directPattern = /https?:\/\/[^"'<>\\\s]+\.mp4(?:\?[^"'<>\\\s]*)?/gi;
  const directText = visible.replace(/\\\//g, '/');
  while ((match = directPattern.exec(directText)) !== null) add(match[0]);
  return urls;
}

function preferredVideo(urls) {
  const trusted = /^https:\/\/(?:[^/]+\.)?(?:btc620\.com|91p52\.com|killcovid2021\.com)\//i;
  return urls.find(function (url) { return trusted.test(url); }) || urls[0] || '';
}

function cachedMedia(key) {
  if (!key) return '';
  const item = MEDIA_CACHE[key];
  if (!item) return '';
  if (item.expiresAt <= Date.now()) {
    delete MEDIA_CACHE[key];
    return '';
  }
  return item.url || '';
}

function rememberMedia(key, url) {
  if (!key || !url) return;
  let expiresAt = Date.now() + 120000;
  const expiry = url.match(/[?&]e=(\d+)/i);
  if (expiry) {
    let tokenExpiry = Number(expiry[1]);
    if (tokenExpiry > 0 && tokenExpiry < 100000000000) tokenExpiry *= 1000;
    if (tokenExpiry > Date.now()) expiresAt = Math.min(expiresAt, tokenExpiry - 10000);
  }
  MEDIA_CACHE[key] = { url: url, expiresAt: expiresAt };
}

function detailPoster(doc) {
  const candidates = [
    firstAttr(doc, ['#player_one'], 'poster'),
    firstAttr(doc, ['meta[property="og:image"]'], 'content'),
    firstAttr(doc, ['meta[name="twitter:image"]'], 'content'),
    firstAttr(doc, ['#player_one img', '.video-container img', 'img.img-responsive'], 'src')
  ];
  for (const candidate of candidates) {
    const url = imageUrl(candidate);
    if (url) return url;
  }
  return '';
}

function detailTitle(doc, id) {
  return firstText(doc, ['#videodetails h4', '.video-title', 'h1'])
    || cleanText(firstAttr(doc, ['meta[property="og:title"]', 'meta[name="twitter:title"]'], 'content'))
    || cleanText(doc.selectFirst('title') ? doc.selectFirst('title').text() : '')
    || viewKey(id)
    || '91Porn';
}

export default {
  async home() {
    const loaded = await loadList(listUrl('rf', 1), SITE + '/');
    return {
      categories: CATEGORIES,
      items: loaded.items,
      hasMore: hasNextPage(loaded.page.doc, 1)
    };
  },

  async category({ id, page }) {
    const current = pageNumber(page);
    const url = listUrl(id, current);
    const loaded = await loadList(url, SITE + '/');
    return {
      items: loaded.items,
      page: current,
      hasMore: hasNextPage(loaded.page.doc, current)
    };
  },

  async search({ keyword, page }) {
    const query = cleanText(keyword);
    if (!query) {
      const loadedHome = await loadList(listUrl('rf', 1), SITE + '/');
      return {
        categories: CATEGORIES,
        items: loadedHome.items,
        hasMore: hasNextPage(loadedHome.page.doc, 1)
      };
    }
    const current = pageNumber(page);
    const loaded = await loadList(searchUrl(query, current), SITE + '/');
    return {
      items: loaded.items,
      page: current,
      hasMore: hasNextPage(loaded.page.doc, current)
    };
  },

  async detail({ id }) {
    const url = detailUrl(id);
    if (!url) throw host.error('E_NOT_FOUND', '视频 id 无效');
    const loaded = await requestPage(url, SITE + '/');
    const title = detailTitle(loaded.doc, id);
    const cover = detailPoster(loaded.doc);
    const desc = firstText(loaded.doc, ['#v_desc', '#videodetails .description']);
    const result = {
      title: title,
      desc: desc,
      tags: [],
      lines: [{
        name: '91Porn',
        episodes: [{ id: loaded.url, name: title }]
      }]
    };
    if (cover) {
      result.cover = cover;
      result.coverHeaders = requestHeaders(loaded.url);
    }
    return result;
  },

  async play({ episodeId, id }) {
    const key = episodeId || id;
    const mediaKey = viewKey(key);
    const url = detailUrl(key);
    if (!url) throw host.error('E_NOT_FOUND', '播放 id 无效');
    const loaded = await requestPage(url, SITE + '/');
    // No preflight media request: this CDN rate-limits back-to-back requests and the player
    // must be the only consumer of the freshly signed URL.
    const video = preferredVideo(extractVideoUrls(loaded.body, loaded.doc));
    if (!video) {
      throw host.error('E_PARSE', '详情页没有找到可播放的视频地址');
    }
    const hostName = (video.match(/^https:\/\/([^/]+)/i) || [])[1] || 'unknown';
    host.log('[91Porn] 播放地址已解析', { host: hostName, urlLength: video.length });
    rememberMedia(mediaKey, video);
    return {
      streams: [{
        name: 'MP4',
        url: video,
        format: 'mp4',
        headers: { 'User-Agent': USER_AGENT, 'Referer': loaded.url || SITE + '/' }
      }]
    };
  }
};
