// Small NodeRSA-compatible facade (encrypt / decrypt / sign / verify). Own code, GPL-3.0 — not the node-rsa package.
import { modulus } from 'assets://js/lib/jsencrypt.js';

const T = globalThis.__tvCall, B = globalThis.__idjBytes;

export class NodeRSA {
  constructor(key, format, options) {
    this.opt = Object.assign({}, (typeof format === 'object' ? format : options) || {});
    this.publicKey = '';
    this.privateKey = '';
    if (key) this.importKey(key, typeof format === 'string' ? format : undefined);
  }
  importKey(key, format) {
    const k = String(key);
    if (/private/i.test(format || '') || /PRIVATE KEY/.test(k)) this.privateKey = k; else this.publicKey = k;
    return this;
  }
  setOptions(o) { Object.assign(this.opt, o || {}); return this; }
  _pad() {
    const s = this.opt.encryptionScheme;
    if (s && typeof s === 'object') return s.padding === 3 ? 'none' : /oaep/i.test(s.scheme || '') ? 'oaep' : 'pkcs1';
    return /pkcs1_oaep/i.test(s || 'pkcs1_oaep') ? 'oaep' : s === 'none' ? 'none' : 'pkcs1';
  }
  _chunk(op, pub, bytes) {
    const key = pub ? this.publicKey : this.privateKey, pad = this._pad(), size = modulus(key);
    const step = op === 'decrypt' || pad === 'none' ? size : size - (pad === 'oaep' ? 42 : 11), out = [];
    for (let i = 0; i < bytes.length; i += step) B.b64d(T('rsa', { op, key, public: pub, pad, dataB64: B.b64e(bytes.slice(i, i + step)) })).forEach(x => out.push(x));
    return Uint8Array.from(out);
  }
  _in(v, enc) { return typeof v === 'string' ? (enc === 'base64' ? B.b64d(v) : B.utf8(v)) : v instanceof Uint8Array || Array.isArray(v) ? B.toBytes(v) : B.utf8(JSON.stringify(v)); }
  _out(bytes, enc) {
    if (enc === 'base64') return B.b64e(bytes);
    if (enc === 'hex') return Array.from(bytes, x => (x < 16 ? '0' : '') + x.toString(16)).join('');
    if (enc === 'utf8' || enc === 'utf-8') return B.unutf8(bytes);
    return enc === 'json' ? JSON.parse(B.unutf8(bytes)) : bytes;
  }
  encrypt(v, enc, src) { return this._out(this._chunk('encrypt', true, this._in(v, src)), enc); }
  decrypt(v, enc) { return this._out(this._chunk('decrypt', false, this._in(v, 'base64')), enc); }
  encryptPrivate(v, enc, src) { return this._out(this._chunk('encrypt', false, this._in(v, src)), enc); }
  decryptPublic(v, enc) { return this._out(this._chunk('decrypt', true, this._in(v, 'base64')), enc); }
  sign(v, enc, src) { return this._out(B.b64d(T('rsa', { op: 'sign', key: this.privateKey, public: false, hash: 'sha256', dataB64: B.b64e(this._in(v, src)) })), enc); }
  verify(v, sig, src, enc) { return !!T('rsa', { op: 'verify', key: this.publicKey, public: true, hash: 'sha256', dataB64: B.b64e(this._in(v, src)), sigB64: B.b64e(this._in(sig, enc || 'base64')) }); }
}
globalThis.NODERSA = globalThis.NodeRSA = NodeRSA;
export default NodeRSA;
