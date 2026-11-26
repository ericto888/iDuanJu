// CatVod script toolbox: one import for the helpers CatVod-style spiders expect. Own code, GPL-3.0.
import CryptoJS from 'assets://js/lib/crypto-js.js';
import { load, jinja2 } from 'assets://js/lib/cheerio.min.js';
import { Uri } from 'assets://js/lib/uri.min.js';
import { dayjs } from 'assets://js/lib/dayjs.min.js';
import { _ } from 'assets://js/lib/underscore-esm.min.js';

const ALPHA = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
export function randStr(len, chars) {
  const set = chars || ALPHA;
  let s = '';
  for (let i = 0; i < (len || 32); i++) s += set[Math.floor(Math.random() * set.length)];
  return s;
}
export function formatPlayUrl(title, name) { return String(name).trim().replace(title, '').replace(/<|>|《|》/g, '').replace(/\$|#/g, ' ').trim(); }
export function stripHtmlTag(s) { return String(s).replace(/<\/?[^>]+(>|$)/g, '').replace(/&.{1,5};/g, '').replace(/\s{2,}/g, ' '); }
export { CryptoJS as Crypto, CryptoJS, load, jinja2, Uri, dayjs, _ };
