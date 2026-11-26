// JSON5 facade over the host's lenient parser. Own code, GPL-3.0.
const JSON5 = {
  parse: s => globalThis.__tvCall('json5', { s: String(s) }),
  stringify: (v, r, i) => JSON.stringify(v, r, i),
};
globalThis.JSON5 = JSON5;
export default JSON5;
