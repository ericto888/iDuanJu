// JSEncrypt-compatible facade over the host RSA implementation. Own code, GPL-3.0 — not the jsencrypt package.
const T = globalThis.__tvCall, B = globalThis.__idjBytes;

/** Modulus size in bytes: the first large INTEGER of the DER structure (PKCS#1 and PKCS#8 / X.509). */
export function modulus(key) {
  const b = B.b64d(String(key).replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''));
  const walk = (at, end) => {
    while (at + 1 < end) {
      const tag = b[at++];
      let n = b[at++];
      if (n & 128) { let c = n & 127; n = 0; while (c-- > 0) n = n * 256 + b[at++]; }
      if (tag === 2) { if (n >= 32) return b[at] === 0 ? n - 1 : n; } else if (tag === 48 || tag === 4 || tag === 3) {
        const r = walk(at + (tag === 3 ? 1 : 0), Math.min(end, at + n));
        if (r) return r;
      }
      at += n;
    }
    return 0;
  };
  return walk(0, b.length) || 128;
}
const hexBytes = h => Uint8Array.from((h.match(/../g) || []).map(x => parseInt(x, 16)));

export class JSEncrypt {
  constructor() { this.key = ''; this.isPublic = true; }
  setKey(k) { this.key = String(k || ''); this.isPublic = !/PRIVATE KEY/.test(this.key); }
  setPublicKey(k) { this.key = String(k || ''); this.isPublic = true; }
  setPrivateKey(k) { this.key = String(k || ''); this.isPublic = false; }
  getPublicKey() { return this.key; }
  getPrivateKey() { return this.key; }
  _run(op, bytes, extra) { return T('rsa', Object.assign({ op, key: this.key, public: this.isPublic, pad: 'pkcs1', dataB64: B.b64e(bytes) }, extra || {})); }
  _chunks(op, bytes, size) {
    const out = [];
    for (let i = 0; i < bytes.length; i += size) B.b64d(this._run(op, bytes.slice(i, i + size))).forEach(x => out.push(x));
    return Uint8Array.from(out);
  }
  encrypt(text) { try { return this._run('encrypt', B.utf8(text)); } catch (e) { return false; } }
  decrypt(b64) { try { return B.unutf8(B.b64d(this._run('decrypt', B.b64d(b64)))); } catch (e) { return null; } }
  encryptLong(text) { try { return B.b64e(this._chunks('encrypt', B.utf8(text), modulus(this.key) - 11)); } catch (e) { return false; } }
  decryptLong(b64) { try { return B.unutf8(this._chunks('decrypt', B.b64d(b64), modulus(this.key))); } catch (e) { return null; } }
  encryptUnicodeLong(text) { return this.encryptLong(text); }
  decryptUnicodeLong(data) {
    const s = String(data);
    try { return B.unutf8(this._chunks('decrypt', s.length % 2 === 0 && /^[0-9a-fA-F]+$/.test(s) ? hexBytes(s) : B.b64d(s), modulus(this.key))); } catch (e) { return null; }
  }
  sign(text, digest, hash) { try { return this._run('sign', B.utf8(text), { hash: hash || 'sha1' }); } catch (e) { return false; } }
  verify(text, sig, digest, hash) { try { return !!this._run('verify', B.utf8(text), { hash: hash || 'sha1', sigB64: sig }); } catch (e) { return false; } }
}
globalThis.JSEncrypt = JSEncrypt;
export default JSEncrypt;
