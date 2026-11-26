// GBK percent-encoding helper (drpy `gbkTool`) over the host codec. Own code, GPL-3.0.
const T = globalThis.__tvCall, B = globalThis.__idjBytes;

export function gbkTool() {
  return {
    encode(text) {
      const bytes = B.b64d(T('gbk', { op: 'encode', s: String(text) }));
      let out = '';
      for (let i = 0; i < bytes.length; i++) {
        const c = bytes[i], ch = String.fromCharCode(c);
        out += c < 128 && /[A-Za-z0-9_.~!*'()-]/.test(ch) ? ch : '%' + (c < 16 ? '0' : '') + c.toString(16).toUpperCase();
      }
      return out;
    },
    decode(text) {
      const s = String(text), bytes = [];
      for (let i = 0; i < s.length; i++) {
        const hex = s[i] === '%' ? /^[0-9a-fA-F]{2}/.exec(s.slice(i + 1)) : null;
        if (hex) { bytes.push(parseInt(hex[0], 16)); i += 2; } else bytes.push(s[i] === '+' ? 32 : s.charCodeAt(i) & 255);
      }
      return T('gbk', { op: 'decode', b64: B.b64e(Uint8Array.from(bytes)) });
    },
  };
}
globalThis.gbkTool = gbkTool;
export default gbkTool;
