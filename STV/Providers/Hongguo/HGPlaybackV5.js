const siteBaseUrl = "https://hongguoduanju.com";
const appBaseUrl = "https://api5-normal-sinfonlineb.fqnovel.com";
const rankBaseUrl = "https://api5-normal-sinfonlinec.fqnovel.com";
const playbackBaseUrl = "https://api5-normal-sinfonlinea.fqnovel.com";
const appVersionCode = "74532";
const appVersionName = "7.4.5.32";
const playbackUserAgent = "com.phoenix.read/" + appVersionCode + " (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)";
const appUserAgent = "com.phoenix.read/" + appVersionCode + " (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)";
const webUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1";
const deviceRegisterUrl = "https://log.snssdk.com/service/2/device_register/";
const mediaReferer = "https://novel.snssdk.com/";
const responseLimit = 20 * 1024 * 1024;
const cencScheme = "hongguo-cenc://";
const playUrlSalts = ["4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58"];
const playUrlHeaderSize = 4;
const playUrlPattern = /^https?:\/\/\S+$/;
const fallbackCodecTypes = ["1", "3"];
const audioScheme = "hongguo-audio://";
const bookPrefix = "book-";
const legacySeriesPrefix = "hg-series-v1:";
const tagPrefix = "tag:";
const tagPattern = /^tag:cate_[0-9]{1,9}$/;
const numericIdPattern = /^[0-9]{1,32}$/;
const rankingMetricPattern = /^[0-9]+(?:\.[0-9]+)?[万亿]?热度$/;
const seasonSuffixPattern = /第\s*([0-9零〇一二两兩三四五六七八九十百]+)\s*([季部])[\p{P}\s]*$/u;
const secondMs = 1000;
const minuteMs = 60 * secondMs;
const danmakuMaxDurationMs = 24 * 60 * minuteMs;
const defaultMaxPages = 50;
const deviceRotations = 3;
const registerPauseMs = 10 * minuteMs;
const appRequestTimeoutMs = 20 * secondMs;
const searchTimeoutMs = 40 * secondMs;
const searchPageTimeoutMs = 12 * secondMs;
const searchSeasonTimeoutMs = 25 * secondMs;
const audioSearchTimeoutMs = 10 * secondMs;
const suggestionTimeoutMs = 5 * secondMs;
const seasonTimeoutMs = 25 * secondMs;
const rankingTimeoutMs = 18 * secondMs;
const searchPageSize = 10;
const searchNameCount = 50;
const suggestionLimit = 10;
const seasonLimit = 200;
const searchSeasonQueries = 32;
const seriesSeasonLimit = 60;
const tagPageSize = 12;
const cellPageSize = 6;
const audioSearchSize = 10;
const doubleColumnShowType = "506";
const searchSeriesTab = "29";
const audioSearchTab = "2";
const tagPanelCategory = "5000";

const paths = {
  videoDetail: "/novel/player/video_detail/v1/",
  videoModel: "/novel/player/multi_video_model/player/v1",
  videoTab: "/reading/bookapi/video_tab/multi_video_model/v1/",
  landpage: "/reading/distribution/category/landpage/v/",
  seriesPack: "/reading/distribution/book_pack_fields/inner_feed_detail/v1/",
  searchTab: "/reading/bookapi/search/tab/v/",
  tagLanding: "/reading/bookapi/new_category/landing/v/",
  bookmallTab: "/reading/bookapi/bookmall/tab/v1/",
  bookmallCellChange: "/reading/bookapi/bookmall/cell/change/v1/",
  rankCell: "/reading/bookapi/bookmall/cell/change/v:version/",
  audioDetail: "/reading/bookapi/detail/v1/",
  audioTone: "/reading/bookapi/audio/toneinfo/",
  audioDirectory: "/reading/bookapi/directory/all_items/v1/",
  audioPlayInfo: "/reading/reader/audio/playinfo/",
  audioSearch: "/reading/bookapi/search/tab/v1/",
};

const genres = [
  { key: "short_play", scene: "default", name: "真人剧" },
  { key: "comic_series", scene: "comic_series", name: "漫剧" },
  { key: "ai_series", scene: "ai_series", name: "AI剧" },
];

const audioCategories = [
  { key: "listen", tab: "5", name: "听书" },
  { key: "novel", tab: "2", name: "小说" },
];

const recommendationFeeds = [
  { key: "home_feed", tabType: "16", bottomTab: "7" },
  { key: "find_drama", tabType: "8", bottomTab: "" },
];

const rankingBoards = {
  "hongguo-hot": { path: "hot-drama", upstreamKey: "hongguo" },
  "hongguo-real": { path: "hot-real-drama", upstreamKey: "real" },
  "hongguo-comic": { path: "hot-comic-drama", upstreamKey: "comic" },
  "hongguo-ai": { path: "hot-ai-drama", upstreamKey: "ai" },
};

const nativeRankGenres = {
  all: { selected: "all", label: "全部" },
  human: { selected: "human", label: "真人剧" },
  comic: { selected: "comic_series_rank", label: "漫剧" },
  ai: { selected: "ai_playlet", label: "AI剧" },
};
const nativeRankSubs = {
  subscribe: { label: "预约", ids: { all: "ranklist_subscribe" } },
  recommend: { label: "推荐", ids: { all: "ranklist_hot_sc", human: "human_hot_sc", comic: "comic_series_hot_rank", ai: "ai_playlet_hot_sc" } },
  hot: { label: "热播", ids: { all: "ranklist_hot_play_sc", human: "human_hot_play", comic: "comic_series_hot_play", ai: "ai_playlet_hot_play" } },
  zhenguo: { label: "臻果", ids: { all: "ranklist_prestige" } },
  new: { label: "新剧", ids: { all: "ranklist_new_rank_sc", human: "human_new_rank", comic: "comic_series_new_rank", ai: "ai_playlet_new_rank" } },
  must_watch: { label: "必看", ids: { all: "ranklist_must_watch", human: "human_must_watch", ai: "ai_playlet_must_watch" } },
  followed: { label: "收藏", ids: { all: "ranklist_followed", human: "human_followed", ai: "ai_playlet_followed" } },
  hot_search: { label: "热搜", ids: { all: "ranklist_hot_search_sc", human: "human_hot_search", comic: "comic_series_hot_search", ai: "ai_playlet_hot_search" } },
};

function failure(text, flags) {
  const error = new Error(text);
  if (flags) {
    Object.assign(error, flags);
  }
  return error;
}

function message(error) {
  return error !== null && typeof error === "object" && error.message !== undefined ? String(error.message) : String(error);
}

function joinErrors(...errors) {
  return new Error(errors.filter((error) => error).map(message).join("\n"));
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isEmptyRecord(value) {
  return !isRecord(value) || Object.keys(value).length === 0;
}

function numericId(value) {
  return typeof value === "string" && numericIdPattern.test(value);
}

function recommendationNumericId(value) {
  if (typeof value !== "string") {
    return "";
  }
  let id = value.trim();
  const prefixes = [String(host.source || "") + ":", "hongguo:"];
  for (const prefix of prefixes) {
    if (prefix !== ":" && id.startsWith(prefix)) {
      id = id.slice(prefix.length);
      break;
    }
  }
  return numericId(id) ? id : "";
}

function mapString(row, ...keys) {
  if (!isRecord(row)) {
    return "";
  }
  for (const key of keys) {
    const value = row[key];
    if (typeof value === "string") {
      const trimmed = value.trim();
      if (trimmed !== "") {
        return trimmed;
      }
    } else if (typeof value === "boolean" || typeof value === "number") {
      return String(value);
    }
  }
  return "";
}

function mapStringList(row, ...keys) {
  const found = [];
  const add = (value) => {
    value = value.trim();
    if (value !== "" && !found.includes(value)) {
      found.push(value);
    }
  };
  if (!isRecord(row)) {
    return found;
  }
  for (const key of keys) {
    const value = row[key];
    if (typeof value === "string") {
      value.split(/[,/，、]/).forEach(add);
    } else if (Array.isArray(value)) {
      for (const item of value) {
        if (isRecord(item)) {
          add(mapString(item, "name", "title", "label", "tag"));
        } else if (item !== null && item !== undefined) {
          add(String(item));
        }
      }
    }
  }
  return found;
}

function firstNonEmpty(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim() !== "") {
      return value.trim();
    }
  }
  return "";
}

function nested(value, ...keys) {
  let current = isRecord(value) ? value : null;
  for (const key of keys) {
    if (current === null) {
      break;
    }
    current = isRecord(current[key]) ? current[key] : null;
  }
  return current === null ? {} : current;
}

function anyList(value) {
  if (Array.isArray(value)) {
    return value;
  }
  if (isRecord(value)) {
    for (const key of ["list", "items", "data"]) {
      const found = anyList(value[key]);
      if (found.length > 0) {
        return found;
      }
    }
  }
  return [];
}

function parseInteger(text) {
  return typeof text === "string" && /^[+-]?\d+$/.test(text) ? parseInt(text, 10) : NaN;
}

function parseNumber(text) {
  return typeof text === "string" && /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(text) ? Number(text) : NaN;
}

function runeCount(text) {
  return Array.from(text).length;
}

function truncate(text, limit) {
  const trimmed = text.trim();
  const characters = Array.from(trimmed);
  return characters.length <= limit ? trimmed : characters.slice(0, limit).join("") + "...";
}

function displayTitle(drama) {
  if (typeof drama.title === "string" && drama.title.trim() !== "") {
    return drama.title;
  }
  if (typeof drama.name === "string" && drama.name.trim() !== "") {
    return drama.name;
  }
  return "短剧";
}

function stableSort(list, less) {
  return list
    .map((value, index) => ({ value, index }))
    .sort((left, right) => (less(left.value, right.value) ? -1 : less(right.value, left.value) ? 1 : left.index - right.index))
    .map((entry) => entry.value);
}

function cacheRead(key) {
  const raw = host.cacheGet(key);
  return raw === null ? null : JSON.parse(raw);
}

function cacheWrite(key, value, ttlMs) {
  host.cacheSet(key, JSON.stringify(value), ttlMs);
}

function parseJson(text) {
  return JSON.parse(host.preserveIntegers(text));
}

function pad2(value) {
  return value < 10 ? "0" + value : String(value);
}

function chinaDate(ms) {
  const date = new Date(ms + 8 * 60 * minuteMs);
  return date.getUTCFullYear() + "-" + pad2(date.getUTCMonth() + 1) + "-" + pad2(date.getUTCDate());
}

function timestampDate(value) {
  let stamp = parseInteger(String(value).trim());
  if (!(stamp > 0)) {
    return "";
  }
  if (stamp > 100000000000) {
    stamp = Math.trunc(stamp / 1000);
  }
  const date = chinaDate(stamp * secondMs);
  const year = parseInt(date.slice(0, 4), 10);
  return year < 2000 || year > 2100 ? "" : date;
}

function validDate(year, month, day) {
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
}

function normalizeDate(text) {
  const matches = String(text).trim().match(/\d{4}-\d{1,2}-\d{1,2}/g) || [];
  for (const match of matches) {
    const [year, month, day] = match.split("-").map((part) => parseInt(part, 10));
    if (year >= 2000 && year <= 2100 && month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      return year + "-" + pad2(month) + "-" + pad2(day);
    }
  }
  return "";
}

function parseTime(text) {
  return typeof text === "string" ? Date.parse(text.replace(/(\.\d{3})\d+/, "$1")) : NaN;
}

function releaseStatusFromRemark(remark) {
  if (remark.includes("未完结") || remark.includes("更新至") || remark.includes("连载")) {
    return "ongoing";
  }
  if (/(?:全\s*\d+\s*集|\d+\s*集全|已完结|大结局)/.test(remark) || remark.includes("完结")) {
    return "finished";
  }
  return "unknown";
}

function nativeScore(score) {
  const trimmed = String(score || "").trim().replace(/^评分/, "").replace(/分$/, "").trim();
  const value = parseNumber(trimmed);
  return value > 0 && value <= 10 ? value.toFixed(1) : "";
}

function parseAddress(raw) {
  try {
    return host.parseUrl(raw);
  } catch (error) {
    return null;
  }
}

function httpAddress(raw) {
  const parsed = parseAddress(String(raw).trim());
  return parsed !== null && (parsed.scheme === "http" || parsed.scheme === "https") && parsed.hostname !== "" && !parsed.userInfo;
}

function coverAddress(...values) {
  for (let value of values) {
    value = typeof value === "string" ? value.trim() : "";
    if (value === "" || value.length > 8192) {
      continue;
    }
    if (value.startsWith("//")) {
      value = "https:" + value;
    }
    if (httpAddress(value)) {
      return value;
    }
  }
  return "";
}

function coverPathFromAny(value) {
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (trimmed === "") {
      return "";
    }
    if (trimmed.startsWith("//")) {
      return "https:" + trimmed;
    }
    if (trimmed.startsWith("/api/ui/image")) {
      const parsed = parseAddress(trimmed);
      const nestedUrl = parsed === null ? "" : queryValue(parsed.query, "url").trim();
      if (nestedUrl !== "") {
        return nestedUrl;
      }
    }
    const parsed = parseAddress(trimmed);
    if (parsed !== null && parsed.scheme !== "") {
      return trimmed;
    }
    return trimmed.replace(/^\/+/, "");
  }
  if (isRecord(value)) {
    for (const key of ["url", "src", "path", "cover", "coverUrl", "cover_url", "image", "pic", "poster"]) {
      const found = coverPathFromAny(value[key]);
      if (found !== "") {
        return found;
      }
    }
  } else if (Array.isArray(value)) {
    for (const entry of value) {
      const found = coverPathFromAny(entry);
      if (found !== "") {
        return found;
      }
    }
  }
  return "";
}

function decodeQueryComponent(text) {
  try {
    return decodeURIComponent(text.replace(/\+/g, " "));
  } catch (error) {
    return null;
  }
}

function queryValue(query, name) {
  for (const part of String(query || "").split("&")) {
    if (part === "") {
      continue;
    }
    const separator = part.indexOf("=");
    const key = decodeQueryComponent(separator < 0 ? part : part.slice(0, separator));
    if (key === name) {
      const value = decodeQueryComponent(separator < 0 ? "" : part.slice(separator + 1));
      return value === null ? "" : value;
    }
  }
  return "";
}

function queryEscape(text) {
  return encodeURIComponent(text)
    .replace(/[!'()*]/g, (character) => "%" + character.charCodeAt(0).toString(16).toUpperCase())
    .replace(/%20/g, "+");
}

function encodeQuery(params) {
  return Object.keys(params)
    .sort()
    .map((key) => queryEscape(key) + "=" + queryEscape(String(params[key])))
    .join("&");
}

function htmlUnescape(text) {
  const named = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: "\u00a0" };
  return text.replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/g, (entity, body) => {
    if (body[0] === "#") {
      const code = body[1] === "x" || body[1] === "X" ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity;
    }
    return Object.prototype.hasOwnProperty.call(named, body) ? named[body] : entity;
  });
}

function extractAttr(block, name) {
  const match = new RegExp("\\b" + name.replace(/[.*+?^${}()|[\]\\-]/g, "\\$&") + "\\s*=\\s*[\"']([^\"']+)[\"']", "i").exec(block);
  return match ? htmlUnescape(match[1]).trim() : "";
}

function searchText(text) {
  const normalized = text.normalize("NFKC").replace(/[\s\p{P}]/gu, "").toLowerCase();
  return normalized === "" ? text.trim().toLowerCase() : normalized;
}

function searchKeyword(keyword) {
  keyword = String(keyword).trim().normalize("NFKC");
  if (keyword === "" || runeCount(keyword) > 80 || /\p{Cc}/u.test(keyword)) {
    throw new Error("请输入 1 至 80 个字符的搜索词");
  }
  return keyword;
}

function splitDramaId(id) {
  const trimmed = String(id || "").trim();
  const separator = trimmed.indexOf(":");
  if (separator < 0) {
    return ["", ""];
  }
  return [trimmed.slice(0, separator).trim().toLowerCase(), trimmed.slice(separator + 1).trim()];
}

function concatBytes(...parts) {
  let length = 0;
  for (const part of parts) {
    length += part.length;
  }
  const out = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    for (let index = 0; index < part.length; index++) {
      out[offset++] = part[index];
    }
  }
  return out;
}

function pad16(data) {
  const padding = 16 - (data.length % 16);
  const out = new Uint8Array(data.length + padding);
  for (let index = 0; index < out.length; index++) {
    out[index] = index < data.length ? data[index] : padding;
  }
  return out;
}

function sliceBytes(data, start, end) {
  const out = [];
  for (let index = start; index < end; index++) {
    out.push(data[index]);
  }
  return out;
}

function appendUvarint(out, value) {
  while (value >= 128) {
    out.push((value % 128) | 128);
    value = Math.floor(value / 128);
  }
  out.push(value);
}

function varintField(out, field, value) {
  appendUvarint(out, field * 8);
  appendUvarint(out, value);
}

function bytesField(out, field, value) {
  appendUvarint(out, field * 8 + 2);
  appendUvarint(out, value.length);
  for (let index = 0; index < value.length; index++) {
    out.push(value[index]);
  }
}

function u32le(data, offset) {
  return (data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
}

function rotl32(value, bits) {
  bits &= 31;
  return bits === 0 ? value >>> 0 : ((value << bits) | (value >>> (32 - bits))) >>> 0;
}

const mask64 = (1n << 64n) - 1n;

function readU64(data, offset) {
  return BigInt(u32le(data, offset)) | (BigInt(u32le(data, offset + 4)) << 32n);
}

function writeU64(data, offset, value) {
  const low = Number(value & 0xffffffffn);
  const high = Number(value >> 32n);
  for (let index = 0; index < 4; index++) {
    data[offset + index] = (low >>> (8 * index)) & 255;
    data[offset + 4 + index] = (high >>> (8 * index)) & 255;
  }
}

function rotl64(value, bits) {
  const shift = ((bits % 64) + 64) % 64;
  return shift === 0 ? value : ((value << BigInt(shift)) | (value >> BigInt(64 - shift))) & mask64;
}

function rotl8(value, bits) {
  return ((value << bits) | (value >>> (8 - bits))) & 255;
}

function reverse8(value) {
  let out = 0;
  for (let bit = 0; bit < 8; bit++) {
    out = (out << 1) | ((value >>> bit) & 1);
  }
  return out;
}

function popCount(value) {
  let count = 0;
  for (; value > 0; value >>>= 1) {
    count += value & 1;
  }
  return count;
}

function sm3(input) {
  const length = input.length;
  const blocks = Math.ceil((length + 9) / 64);
  const data = new Uint8Array(blocks * 64);
  for (let index = 0; index < length; index++) {
    data[index] = input[index];
  }
  data[length] = 0x80;
  const bits = length * 8;
  const high = Math.floor(bits / 0x100000000);
  const low = bits >>> 0;
  for (let index = 0; index < 4; index++) {
    data[data.length - 8 + index] = (high >>> (24 - 8 * index)) & 255;
    data[data.length - 4 + index] = (low >>> (24 - 8 * index)) & 255;
  }
  const state = [0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, 0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e];
  const words = new Array(68);
  for (let offset = 0; offset < data.length; offset += 64) {
    for (let index = 0; index < 16; index++) {
      const at = offset + index * 4;
      words[index] = ((data[at] << 24) | (data[at + 1] << 16) | (data[at + 2] << 8) | data[at + 3]) >>> 0;
    }
    for (let index = 16; index < 68; index++) {
      const value = (words[index - 16] ^ words[index - 9] ^ rotl32(words[index - 3], 15)) >>> 0;
      words[index] = (value ^ rotl32(value, 15) ^ rotl32(value, 23) ^ rotl32(words[index - 13], 7) ^ words[index - 6]) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = state;
    for (let index = 0; index < 64; index++) {
      const early = index < 16;
      const constant = early ? 0x79cc4519 : 0x7a879d8a;
      const ff = (early ? a ^ b ^ c : (a & b) | (a & c) | (b & c)) >>> 0;
      const gg = (early ? e ^ f ^ g : (e & f) | (~e & g)) >>> 0;
      const rotated = rotl32(a, 12);
      const ss1 = rotl32((rotated + e + rotl32(constant, index)) >>> 0, 7);
      const tt1 = (ff + d + ((ss1 ^ rotated) >>> 0) + ((words[index] ^ words[index + 4]) >>> 0)) >>> 0;
      const tt2 = (gg + h + ss1 + words[index]) >>> 0;
      d = c;
      c = rotl32(b, 9);
      b = a;
      a = tt1;
      h = g;
      g = rotl32(f, 19);
      f = e;
      e = (tt2 ^ rotl32(tt2, 9) ^ rotl32(tt2, 17)) >>> 0;
    }
    [a, b, c, d, e, f, g, h].forEach((value, index) => {
      state[index] = (state[index] ^ value) >>> 0;
    });
  }
  const out = new Uint8Array(32);
  state.forEach((value, index) => {
    for (let shift = 0; shift < 4; shift++) {
      out[index * 4 + shift] = (value >>> (24 - 8 * shift)) & 255;
    }
  });
  return out;
}

let argusMaterial = null;

function argusSetup() {
  if (argusMaterial !== null) {
    return argusMaterial;
  }
  const key = host.hexDecode("ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c");
  const derived = sm3(concatBytes(key, [0x3c, 0xcc, 0x56, 0x7b], key));
  const rounds = [];
  for (let index = 0; index < 4; index++) {
    rounds.push(readU64(derived, index * 8));
  }
  for (let index = 4; index < 72; index++) {
    let mixed = rotl64(rounds[index - 1], -3) ^ rounds[index - 3];
    mixed ^= rotl64(mixed, -1);
    rounds.push((~rounds[index - 4] & mask64) ^ mixed ^ ((0x3dc94c3a046d678bn >> BigInt((index - 4) % 62)) & 1n) ^ 3n);
  }
  argusMaterial = { rounds, aesKey: host.md5(sliceBytes(key, 0, 16)), iv: host.md5(sliceBytes(key, 16, 32)) };
  return argusMaterial;
}

function argusSeal(message) {
  const { rounds, aesKey, iv } = argusSetup();
  const data = pad16(message);
  for (let offset = 0; offset < data.length; offset += 16) {
    let left = readU64(data, offset);
    let right = readU64(data, offset + 8);
    for (const round of rounds) {
      const next = left ^ (rotl64(right, 1) & rotl64(right, 8)) ^ rotl64(right, 2) ^ round;
      left = right;
      right = next;
    }
    writeU64(data, offset, left);
    writeU64(data, offset + 8, right);
  }
  const xor = [0xd0, 0x4f, 0xfd, 0xff, 0xd0, 0x4f, 0xfd, 0xff];
  for (let index = 0; index < data.length; index++) {
    data[index] ^= xor[index % 8];
  }
  const reversed = Array.from(concatBytes(xor, data)).reverse();
  const container = pad16(concatBytes([0xa6, 0xe7, 0x83, 0xee, 0x70, 0x01, 0x10, 0x09, 0x18], reversed, [0x56, 0x7b]));
  return host.base64Encode(concatBytes([0x3c, 0xcc], host.aesCbcEncrypt(aesKey, iv, container)));
}

function playerArgus(query, body, timestamp, deviceId, nonce) {
  const bodyHash = body === null ? sm3(new Uint8Array(16)) : sm3(host.md5(body));
  const queryHash = sm3(host.utf8Encode(query));
  const counters = [];
  varintField(counters, 1, 1);
  varintField(counters, 2, 1);
  varintField(counters, 3, 1);
  varintField(counters, 7, 3348294860);
  const environment = [];
  bytesField(environment, 1, host.utf8Encode("25053RT47C"));
  bytesField(environment, 2, host.utf8Encode("16"));
  bytesField(environment, 3, host.utf8Encode("update_64"));
  varintField(environment, 4, 2147483648);
  const message = [];
  varintField(message, 1, 0x20200929 * 2);
  varintField(message, 2, 2);
  varintField(message, 3, u32le(nonce, 6) & 0x7fffffff);
  bytesField(message, 4, host.utf8Encode("8662"));
  bytesField(message, 5, host.utf8Encode(deviceId));
  bytesField(message, 6, host.utf8Encode("1611921764"));
  bytesField(message, 7, host.utf8Encode(appVersionName));
  bytesField(message, 8, host.utf8Encode("v04.07.01-ml-android"));
  varintField(message, 9, 135135744);
  bytesField(message, 10, new Uint8Array(8));
  varintField(message, 11, 0);
  varintField(message, 12, timestamp * 2);
  bytesField(message, 13, sliceBytes(bodyHash, 0, 6));
  bytesField(message, 14, sliceBytes(queryHash, 0, 6));
  bytesField(message, 15, counters);
  bytesField(message, 16, []);
  bytesField(message, 20, host.utf8Encode("none"));
  varintField(message, 21, 738);
  bytesField(message, 23, environment);
  varintField(message, 25, 2);
  return argusSeal(message);
}

function commentArgus(query, timestamp, nonce) {
  const message = [];
  varintField(message, 1, 0x20200929 * 2);
  varintField(message, 2, 2);
  varintField(message, 3, u32le(nonce, 6));
  bytesField(message, 4, host.utf8Encode("3019"));
  bytesField(message, 6, host.utf8Encode("1611921764"));
  bytesField(message, 7, host.utf8Encode("6.8.1.32"));
  bytesField(message, 8, host.utf8Encode("v04.07.01-ml-android"));
  varintField(message, 9, 135135744);
  bytesField(message, 10, new Uint8Array(8));
  varintField(message, 12, timestamp * 2);
  bytesField(message, 13, sliceBytes(sm3(new Uint8Array(16)), 0, 6));
  bytesField(message, 14, sliceBytes(sm3(host.utf8Encode(query)), 0, 6));
  const counters = [8, 2 + (nonce[10] % 49) * 2];
  for (const field of [2, 3, 4]) {
    appendUvarint(counters, field * 8);
    appendUvarint(counters, 1388734);
  }
  bytesField(message, 15, counters);
  bytesField(message, 20, host.utf8Encode("none"));
  varintField(message, 21, 738);
  return argusSeal(message);
}

function ladon(aid, timestamp, prefix, suffix) {
  const digest = host.utf8Encode(host.hexEncode(host.md5(concatBytes(prefix, host.utf8Encode(aid)))));
  let left = readU64(digest, 0);
  let right = readU64(digest, 8);
  const queue = [readU64(digest, 16), readU64(digest, 24)];
  const keys = [];
  for (let index = 0; index < 34; index++) {
    keys.push(left);
    const mixed = ((rotl64(right, -8) + left) & mask64) ^ BigInt(index);
    queue.push(mixed);
    left = mixed ^ rotl64(left, 3);
    right = queue.shift();
  }
  const data = pad16(host.utf8Encode(timestamp + "-1611921764-" + suffix));
  for (let offset = 0; offset < data.length; offset += 16) {
    let blockLeft = readU64(data, offset);
    let blockRight = readU64(data, offset + 8);
    for (const key of keys) {
      blockRight = key ^ ((blockLeft + rotl64(blockRight, -8)) & mask64);
      blockLeft = blockRight ^ rotl64(blockLeft, 3);
    }
    writeU64(data, offset, blockLeft);
    writeU64(data, offset + 8, blockRight);
  }
  return host.base64Encode(concatBytes(prefix, data));
}

function putUint32BE(data, offset, value) {
  for (let index = 0; index < 4; index++) {
    data[offset + index] = (value >>> (24 - 8 * index)) & 255;
  }
}

function signPlayer(rawQuery, body, aid, deviceId, nowMs, nonce) {
  const stamp = Math.floor(nowMs / secondMs) >>> 0;
  const headers = {};
  const queryHash = host.md5(rawQuery);
  const payload = new Array(20).fill(0);
  for (let index = 0; index < 4; index++) {
    payload[index] = queryHash[index];
  }
  if (body !== null) {
    const bodyHash = host.md5(body);
    for (let index = 0; index < 4; index++) {
      payload[4 + index] = bodyHash[index];
    }
    headers["X-SS-STUB"] = host.hexEncode(bodyHash).toUpperCase();
  }
  [0, 6, 11, 28].forEach((value, index) => {
    payload[12 + index] = value;
  });
  putUint32BE(payload, 16, stamp);
  const key = [0x44, 0xb9, 0xb9, 0xd9, 0xa4, 0xae, 0xf9, 0xfc, 0xa4, 0x93, 0xaa, 0x75, 0x7c, 0xa3, 0xc2, 0xc4, 0xa4, 0x96, 0x93, 0x8f];
  for (let index = 0; index < 20; index++) {
    payload[index] ^= key[index];
  }
  for (let index = 0; index < 20; index++) {
    const mixed = rotl8(payload[index], 4) ^ payload[(index + 1) % 20];
    payload[index] = reverse8(mixed) ^ 0xff ^ 20;
  }
  headers["X-Khronos"] = String(stamp);
  headers["X-Gorgon"] = host.hexEncode([0x84, 0x04, 0x40, 0x1c, 0, 0].concat(payload));
  headers["X-SS-Req-Ticket"] = String(nowMs);
  headers["X-Argus"] = playerArgus(rawQuery, body, stamp, deviceId, nonce);
  headers["X-Ladon"] = ladon(aid, stamp, sliceBytes(nonce, 2, 6), aid);
  return headers;
}

function signComment(rawQuery, aid, nowMs, nonce) {
  const stamp = Math.floor(nowMs / secondMs) >>> 0;
  const head2 = ((nonce[0] % 7) + 1) << 5;
  const head3 = 0xe0 | (nonce[1] & 15);
  const seed = new Array(20).fill(0);
  const hash = host.md5(rawQuery);
  for (let index = 0; index < 4; index++) {
    seed[index] = hash[index];
  }
  [0, 1, 7, 4].forEach((value, index) => {
    seed[12 + index] = value;
  });
  putUint32BE(seed, 16, stamp);
  const key = [0x4a, 0, 0x16, head3, 0x47, 0x6c, 0, head2];
  const box = [];
  for (let index = 0; index < 256; index++) {
    box.push(index);
  }
  let j = 0;
  for (let index = 0; index < 256; index++) {
    j = (j + box[index] + key[index & 7]) & 255;
    box[index] = box[j];
  }
  j = 0;
  for (let offset = 0; offset < 20; offset++) {
    const index = (offset + 1) & 255;
    j = (j + box[index]) & 255;
    box[index] = box[j];
    seed[offset] ^= box[(box[index] + box[j]) & 255];
  }
  for (let index = 0; index < 20; index++) {
    seed[index] = reverse8(rotl8(seed[index], 4) ^ seed[(index + 1) % 20]) ^ 0xeb;
  }
  return {
    "X-Gorgon": host.hexEncode([0x84, 4, head2, head3, 0, 0].concat(seed)),
    "X-Khronos": String(stamp),
    "X-SS-Req-Ticket": String(nowMs),
    "X-SS-STUB": "",
    "X-Argus": commentArgus(rawQuery, stamp, nonce),
    "X-Ladon": ladon(aid, stamp, sliceBytes(nonce, 2, 6), "3019"),
  };
}

// Derived from N3urda/hongguoTV Signer/AesV3/V5Constants and drpys 22261ad; SPDX-License-Identifier: GPL-3.0-only.
const playbackV5Magic = host.hexDecode("2d4b4fca49750d433fb5ae2c226dcc56");
const playbackV5SignKey = host.hexDecode("b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d");
const playbackV5Sbox = host.hexDecode(
  "53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e2624a417ecd9151a7ff64f60730a87f9445ec6ada2f865d22b696c4188f24c0d" +
  "f37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a" +
  "80c594daaab19b6279fbd75070cb52eb2555c456e39e7839853874e2f0013ac0b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1d" +
  "d12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cdbc073b2dae11453304df00815476b2a13fccdb30b957a8acafe1274002485912" +
  "38922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55ba67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65" +
  "b7b3a881aa908cc74f0ad76bbbb58617c37012ca05a469fd44e62eecf1e4272ce860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe" +
  "1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a8891362fb14759ac32bab03b349aeb5a377c5156be4c8dfbe13a684bda39cf836697c8" +
  "94545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd951d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dcc" +
  "d759fb722789b08807cc0fda293f7e5e1819bb0353517020b31d3d00374952bea2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8d" +
  "e0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99eaa6fff15cec34acb98246639b918ab2851466a7cdfc4ad1b52c2ae95a58d3734e" +
  "47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd28" +
  "8fd2bc1fc7bd675412138169cb09249875ba3b68cfb11180afae104fc9789571c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5" +
  "d09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d58577cc241f3a2c655144f81aaf95a4e108da894b38970561ae9002619fbbac9" +
  "1fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46da6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443f" +
  "d830a4232e53da21a1f2d1bdfebc3a02c10a1b8ad31d04fd616590d272ac737e98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f4459168" +
  "1335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b850b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e"
);
const playbackV5HashTable = [
  0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
  0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
  0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
  0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
  0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
  0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
  0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
  0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x00284ba7, 0x08387cfa, 0x5fb37586
];
let playbackV5Process = null;

function playbackV5Le32(value) {
  return new Uint8Array([value & 255, (value >>> 8) & 255, (value >>> 16) & 255, (value >>> 24) & 255]);
}

function playbackV5IV(queryHashBytes, bodyMd5Bytes, ts) {
  let value = 0x20230928;
  for (const data of [queryHashBytes, bodyMd5Bytes, playbackV5Le32(ts)]) {
    for (let index = 0; index < data.length; index++) {
      value = (index & 1) === 0
        ? (value >>> 4) ^ value ^ (value << 6) ^ data[index]
        : ~((value >>> 7) ^ value ^ (data[index] | (value << 12)));
    }
  }
  return value;
}

function playbackV5Hash(queryHashBytes, bodyMd5Bytes, ts) {
  if (queryHashBytes.length !== 32 || bodyMd5Bytes.length !== 16) {
    throw new Error("V5 hash requires a 32-byte query hash and a 16-byte body hash");
  }
  if ((playbackV5IV(queryHashBytes, bodyMd5Bytes, ts) & 15) !== 12) {
    throw new Error("Unsupported V5 hash branch");
  }
  const iv = 0x9d4a97c2;
  const count = (iv + ts) | 0;
  const table = playbackV5HashTable.map((value) => rotl32(value, -((count + 1) & 255)));
  const shift = (count + 2) & 7;
  const padding = [0xfa, 0x45, 0x61, 0xd7].map((value) => ((value | (value << 8)) >>> shift) & 255);
  const data = concatBytes(queryHashBytes, bodyMd5Bytes, playbackV5Le32(ts), padding, [0, 0, 0, 0, 0, 0, 1, 0xa0]);
  const words = [];
  for (let index = 0; index < data.length; index += 4) {
    words.push((data[index] << 24) | (data[index + 1] << 16) | (data[index + 2] << 8) | data[index + 3]);
  }
  for (let index = 0; index < 112; index++) {
    const x = words[index + 1];
    const y = words[index + 14];
    words.push((words[index] + words[index + 9] +
      (rotl32(x, 14) ^ rotl32(x, 25) ^ (x >>> 3)) +
      (rotl32(y, 13) ^ rotl32(y, 15) ^ (y >>> 10))) | 0);
  }
  const initial = [0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f, 984304912, 3005047866, 2874125293, 2152413264]
    .map((value) => rotl32(value, -count));
  const state = initial.slice();
  for (let index = 0; index < 96; index++) {
    const base = (iv + index) | 0;
    const choose = ((state[4] ^ state[0]) & state[1]) ^ state[4];
    const sigma1 = rotl32(state[1], 26) ^ rotl32(state[1], 21) ^ rotl32(state[1], 7);
    const mixed = (words[base & 127] + choose + sigma1 + table[base & 63] + state[6]) | 0;
    const sigma0 = rotl32(state[3], 30) ^ rotl32(state[3], 19) ^ rotl32(state[3], 10);
    const majority = (state[3] & state[5]) | ((state[3] | state[5]) & state[2]);
    const old = state[7];
    state.unshift(state.pop());
    state[7] = (sigma0 + majority + mixed) | 0;
    state[0] = (old + mixed) | 0;
  }
  const digest = new Uint8Array(32);
  for (let index = 0; index < 8; index++) {
    putUint32BE(digest, index * 4, (state[index] + initial[index]) | 0);
  }
  const folded = new Uint8Array(16);
  for (let index = 0; index < 16; index++) {
    folded[index] = digest[index] ^ digest[index + 16];
  }
  let check = 0x20220420;
  for (let index = 0; index < 12; index++) {
    const even = (index & 1) === 0;
    const temp = (check >>> (even ? 3 : 5)) ^ check;
    check = (even ? folded[index] ^ (check << 7) : ~(folded[index] | (check << 11))) ^ temp;
  }
  return concatBytes(folded, playbackV5Le32(((check | 4) ^ 0x1000000) | 0x20));
}

function playbackV5Carrier(keyBytes, ivBytes, sourceBytes, ts) {
  if (keyBytes.length !== 16 || ivBytes.length !== 16 || sourceBytes.length < 248) {
    throw new Error("V5 carrier requires 16-byte key/IV and at least 248 source bytes");
  }
  const variant = ts & 3;
  const box = sliceBytes(playbackV5Sbox, variant * 256, (variant + 1) * 256);
  const con = [[2, 0, 3, 1], [1, 3, 2, 0], [3, 2, 1, 0], [2, 3, 1, 0]][variant];
  const order = [
    [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
    [0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7],
    [0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7],
    [0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7]
  ][variant];
  const initial = [0xbbb5de72, 0xd4638d5b, 0x92a5f73b, 0x89f8a1c9][variant];
  const initialBytes = playbackV5Le32(initial);
  const expanded = new Uint8Array(48);
  for (let index = 0; index < 16; index++) {
    expanded[index] = initialBytes[index & 3] ^ keyBytes[index];
  }
  let rounds = 8;
  for (let index = 4; index < 12; index++) {
    const at = 4 * (index - 1);
    let a = expanded[at];
    let b = expanded[at + 1];
    let c = expanded[at + 2];
    let d = expanded[at + 3];
    if ((index & 3) === 0) {
      const next = ((initial >> (rounds & 24)) ^ box[b]) & 255;
      b = box[c];
      c = box[d];
      d = box[a];
      a = next;
    }
    rounds += 2;
    expanded[at + 4] = a ^ expanded[at - 12];
    expanded[at + 5] = b ^ expanded[at - 11];
    expanded[at + 6] = c ^ expanded[at - 10];
    expanded[at + 7] = d ^ expanded[at - 9];
  }
  function xt(value) {
    return ((value << 1) ^ ((value & 128) !== 0 ? 0x1b : 0)) & 255;
  }
  function block(value) {
    let rows = [0, 1, 2, 3].map((index) => sliceBytes(value, index * 4, index * 4 + 4));
    function addCon(offset) {
      for (let i = 0; i < 4; i++) {
        for (let j = 0; j < 4; j++) {
          rows[i][j] ^= expanded[(offset + i) * 4 + con[j]];
        }
      }
    }
    addCon(0);
    for (let round = 1; round <= 2; round++) {
      for (let i = 0; i < 4; i++) {
        for (let j = 0; j < 4; j++) {
          rows[i][j] = box[rows[i][j]];
        }
      }
      const before = rows.map((row) => row.slice());
      rows = con.map((index) => before[index]);
      const flat = concatBytes(...rows);
      for (let index = 0; index < 16; index++) {
        rows[Math.floor(index / 4)][index % 4] = flat[order[index]];
      }
      if (round === 1) {
        rows = rows.map((row) => con.map((index) => row[index]));
        for (let index = 0; index < 4; index++) {
          const mixed = rows[0][index] ^ rows[1][index] ^ rows[2][index] ^ rows[3][index];
          const first = rows[0][index];
          rows[0][index] ^= mixed ^ xt(rows[0][index] ^ rows[1][index]);
          rows[1][index] ^= mixed ^ xt(rows[1][index] ^ rows[2][index]);
          rows[2][index] ^= mixed ^ xt(rows[2][index] ^ rows[3][index]);
          rows[3][index] ^= mixed ^ xt(rows[3][index] ^ first);
        }
      }
      addCon(round * 4);
    }
    for (let i = 0; i < 4; i++) {
      for (let j = 0; j < 4; j++) {
        rows[i][j] ^= expanded[(4 + i) * 4 + j];
      }
    }
    return concatBytes(...rows);
  }
  const wire = [6, 5, 3, 4, 2, 7, 1, 0];
  const compact = [1, 7, 3, 6, 2, 0, 4, 5];
  const plaintext = new Uint8Array(32);
  for (let i = 0; i < 31; i++) {
    for (let j = 0; j < 8; j++) {
      plaintext[i] |= ((sourceBytes[i * 8 + j] >>> wire[j]) & 1) << compact[j];
    }
  }
  plaintext[31] = 1;
  const input = new Uint8Array(16);
  for (let index = 0; index < 16; index++) {
    input[index] = plaintext[index] ^ ivBytes[index];
  }
  const first = block(input);
  for (let index = 0; index < 16; index++) {
    input[index] = plaintext[index + 16] ^ first[index];
  }
  const key = concatBytes(first, block(input));
  const out = concatBytes([key[31]], sourceBytes);
  for (let i = 0; i < 31; i++) {
    for (let j = 0; j < 8; j++) {
      const at = 1 + i * 8 + j;
      out[at] = (out[at] & ~(1 << wire[j])) | (((key[i] >>> compact[j]) & 1) << wire[j]);
    }
  }
  return out;
}

function playbackV5Proto(fields) {
  const out = [];
  for (const [tag, value] of fields) {
    if (typeof value === "number") {
      varintField(out, tag, value < 0 ? -value * 2 - 1 : value * 2);
    } else {
      const bytes = typeof value === "string" ? host.utf8Encode(value) : value;
      if (bytes.length !== 0) {
        bytesField(out, tag, bytes);
      }
    }
  }
  return new Uint8Array(out);
}

function playbackV5Xmxor(data, key) {
  const encoded = new Uint8Array(data.length);
  for (let index = 0; index < data.length; index++) {
    const at = (index * 4) & 28;
    const d0 = key[at];
    const d1 = key[at + 1];
    let mixed = rotl8(data[index], 4) + d0;
    mixed = ~mixed ^ d1;
    mixed = rotl8(mixed & 255, 3);
    mixed = (mixed + d1) & 255;
    mixed ^= d0;
    encoded[data.length - index - 1] = ~mixed & 255;
  }
  const lastIndex = encoded.length - 1;
  const last = encoded[lastIndex] ^ encoded[lastIndex - 1];
  const first = encoded[0];
  encoded[0] = (~last + first) & 255;
  encoded[1] = ((encoded[0] ^ encoded[lastIndex] ^ 254) + encoded[1]) & 255;
  encoded[2] = (encoded[2] + ((last - first) ^ rotl8(encoded[1], 3) ^ 2)) & 255;
  for (let index = 0; index < encoded.length - 4; index++) {
    const mixed = rotl8(encoded[index + 2], 3) ^ encoded[index + 1] ^ (index + 3);
    encoded[index + 3] = (~mixed + encoded[index + 3]) & 255;
  }
  encoded[lastIndex] ^= encoded[lastIndex - 1];
  let sum = 0;
  for (let index = 1; index < encoded.length; index++) {
    sum += encoded[index];
  }
  encoded[0] = ((encoded[0] ^ encoded[1]) + sum) & 255;
  return encoded;
}

function playbackV5Helios(ts) {
  const prefix = host.randomBytes(4);
  const ascii = host.utf8Encode(host.hexEncode(host.md5(concatBytes(prefix, host.utf8Encode("8662")))));
  let left = readU64(ascii, 0);
  let right = readU64(ascii, 8);
  const queue = [readU64(ascii, 16), readU64(ascii, 24)];
  const keys = [];
  for (let index = 0; index < 34; index++) {
    keys.push(left);
    const mixed = ((rotl64(right, -8) + left) & mask64) ^ BigInt(index);
    queue.push(mixed);
    left = mixed ^ rotl64(left, 3);
    right = queue.shift();
  }
  const data = pad16(host.utf8Encode(ts + "-646637794-8662"));
  for (let offset = 0; offset < data.length; offset += 16) {
    let a = readU64(data, offset);
    let b = readU64(data, offset + 8);
    for (const key of keys) {
      b = key ^ ((a + rotl64(b, -8)) & mask64);
      a = b ^ rotl64(a, 3);
    }
    writeU64(data, offset, a);
    writeU64(data, offset + 8, b);
  }
  return host.base64Encode(concatBytes(prefix, data));
}

function playbackV5Medusa(queryHash, f13, ts, who, nowMs) {
  if (playbackV5Process === null) {
    playbackV5Process = {
      nonce: host.base64Encode(host.randomBytes(18)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""),
      started: nowMs
    };
  }
  const flags = new Uint8Array(8);
  const deviceInfo = playbackV5Proto([
    [1, 1], [2, 2], [3, "8662"], [4, who.device_id], [5, playbackV5Process.nonce],
    [6, "!noperm!"], [12, "Asia/Shanghai,8"], [13, "zh_CN"], [22, who.os_version],
    [25, playbackV5Process.started], [30, who.device_type], [31, who.device_brand],
    [32, who.device_type], [34, who.device_brand]
  ]);
  const env = playbackV5Proto([
    [6, "v04.10.03.04-bugfix"], [8, who.channel], [12, deviceInfo], [14, who.version_name]
  ]);
  const message = playbackV5Proto([
    [1, playbackV5Magic], [2, 5], [3, u32le(host.randomBytes(4), 0)], [4, "8662"],
    [5, who.device_id], [6, "646637794"], [7, who.version_name], [8, "v04.10.03-ml-android"],
    [9, 0x040a0300], [10, flags], [12, ts], [13, f13], [14, sliceBytes(queryHash, 0, 6)],
    [15, playbackV5Proto([[1, 1], [2, 1], [3, 1], [5, 1]])], [17, ts], [20, "none"],
    [21, 377], [23, env],
    [24, '{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}']
  ]);
  const nonce = u32le(host.randomBytes(4), 0);
  const hash = sm3(concatBytes(playbackV5SignKey, playbackV5Le32(nonce), playbackV5SignKey));
  const high = (nonce >>> 16) & 255;
  const seed = playbackV5Le32(~(((high << 11) | (nonce >>> 24)) ^ (high >>> 5) ^ high));
  const transformed = concatBytes(flags, playbackV5Xmxor(message, hash)).reverse();
  for (let index = 0; index < transformed.length; index++) {
    transformed[index] ^= seed[(~index) & 3];
  }
  const check = 0x18000001 | ((queryHash[0] & 63) << 14) | ((f13[0] & 63) << 8);
  const packed = concatBytes([0xca], host.randomBytes(4), playbackV5Le32(check), transformed, [(nonce >>> 16) & 255, (nonce >>> 24) & 255]);
  const encrypted = playbackV5Carrier(
    host.md5(sliceBytes(playbackV5SignKey, 0, 16)),
    host.md5(sliceBytes(playbackV5SignKey, 16, 32)),
    packed,
    ts
  );
  const prefix = concatBytes(playbackV5Le32(5), playbackV5Magic);
  const stamp = playbackV5Le32(ts);
  for (let index = 0; index < prefix.length; index++) {
    prefix[index] ^= stamp[index & 3];
  }
  return host.base64Encode(concatBytes(prefix, [nonce & 255, (nonce >>> 8) & 255, 0, 1], encrypted));
}

function signPlaybackV5(base, values, bodyBytes, nowMs) {
  const ts = Math.floor(nowMs / 1000) | 0;
  const hasBody = bodyBytes !== null && bodyBytes !== undefined;
  const bodyMd5 = hasBody ? host.md5(bodyBytes) : new Uint8Array(16);
  const params = Object.assign({}, values);
  for (let offset = 0; offset < 1024; offset++) {
    params._rticket = String(nowMs + offset);
    const query = encodeQuery(params);
    const queryHash = sm3(host.utf8Encode(query));
    if ((playbackV5IV(queryHash, bodyMd5, ts) & 15) !== 12) {
      continue;
    }
    const who = {};
    for (const name of ["device_id", "version_name", "os_version", "device_type", "channel"]) {
      who[name] = queryValue(query, name);
      if (who[name] === "") {
        throw new Error("播放签名缺少设备字段：" + name);
      }
    }
    who.device_brand = queryValue(query, "device_brand") || "HONOR";
    const f13 = playbackV5Hash(queryHash, bodyMd5, ts);
    const headers = {
      "X-Khronos": String(ts),
      "X-Helios": playbackV5Helios(ts),
      "X-Medusa": playbackV5Medusa(queryHash, f13, ts, who, nowMs)
    };
    if (hasBody) {
      headers["X-SS-STUB"] = host.hexEncode(bodyMd5).toUpperCase();
      headers["Content-Type"] = "application/json; charset=utf-8";
    }
    return { url: base + "?" + query, headers };
  }
  throw new Error("无法在 1024 次 ticket 尝试内生成 V5 播放签名");

globalThis.__signPlaybackV5 = signPlaybackV5;
