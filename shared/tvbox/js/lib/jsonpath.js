// JSONPath subset used by drpy rules: $, .key, ['key'], [n], [a,b], [s:e:step], [*], ..key, [?(@.x == 'y' && …)]. Own code, GPL-3.0.

function split(path) {
  const steps = [];
  let s = String(path).trim().replace(/^\$/, ''), m;
  while (s) {
    if ((m = /^\.\.(\*|[^.[]+)?/.exec(s))) { steps.push({ k: 'deep', v: m[1] }); s = s.slice(m[0].length); }
    else if ((m = /^\.?(\*|[^.[\]]+)/.exec(s))) { steps.push(m[1] === '*' ? { k: 'all' } : { k: 'key', v: m[1] }); s = s.slice(m[0].length); }
    else if (s[0] === '[') {
      let depth = 0, i = 0, quote = '';
      for (; i < s.length; i++) {
        const c = s[i];
        if (quote) { if (c === quote) quote = ''; } else if (c === '"' || c === "'") quote = c;
        else if (c === '[') depth++; else if (c === ']' && --depth === 0) break;
      }
      steps.push(bracket(s.slice(1, i).trim()));
      s = s.slice(i + 1);
    } else s = s.slice(1);
  }
  return steps;
}

function bracket(t) {
  if (t === '*') return { k: 'all' };
  if (/^\?\(/.test(t)) return { k: 'filter', v: t.slice(2, -1) };
  if (/^-?\d*:-?\d*(:-?\d+)?$/.test(t)) { const p = t.split(':').map(x => (x === '' ? undefined : Number(x))); return { k: 'slice', a: p[0], b: p[1], c: p[2] }; }
  if (/^\(@\.length-(\d+)\)$/.test(t)) return { k: 'index', v: -Number(/(\d+)\)$/.exec(t)[1]) };
  const parts = t.match(/'[^']*'|"[^"]*"|[^,]+/g) || [];
  const keys = parts.map(p => p.trim()).filter(Boolean).map(p => (/^-?\d+$/.test(p) ? Number(p) : p.replace(/^['"]|['"]$/g, '')));
  return keys.length === 1 ? (typeof keys[0] === 'number' ? { k: 'index', v: keys[0] } : { k: 'key', v: keys[0] }) : { k: 'union', v: keys };
}

function pick(v, key) {
  if (v === null || v === undefined || typeof v !== 'object') return undefined;
  if (typeof key === 'number' && Array.isArray(v)) return v[key < 0 ? v.length + key : key];
  return v[key];
}

function operand(t, cur) {
  const s = t.trim();
  if (/^['"]/.test(s)) return s.slice(1, -1);
  if (/^-?\d+(\.\d+)?$/.test(s)) return Number(s);
  if (s === 'true' || s === 'false') return s === 'true';
  if (s === 'null') return null;
  if (s[0] === '@') { const r = query('$' + s.slice(1), cur); return r[0]; }
  return s;
}

function test(expr, cur) {
  return expr.split('||').some(or => or.split('&&').every(and => {
    const m = /^(.*?)\s*(==|!=|>=|<=|=~|>|<)\s*(.*)$/.exec(and.trim());
    if (!m) { const neg = /^!/.test(and.trim()); const v = operand(and.trim().replace(/^!/, ''), cur); return neg ? !v : v !== undefined && v !== null && v !== false && v !== ''; }
    const a = operand(m[1], cur);
    if (m[2] === '=~') { const r = /^\/(.*)\/(\w*)$/.exec(m[3].trim()); return r ? new RegExp(r[1], r[2]).test(String(a)) : false; }
    const b = operand(m[3], cur);
    switch (m[2]) { case '==': return a == b; case '!=': return a != b; case '>=': return a >= b; case '<=': return a <= b; case '>': return a > b; default: return a < b; } // eslint-disable-line eqeqeq
  }));
}

function values(v) { return Array.isArray(v) ? v : v && typeof v === 'object' ? Object.keys(v).map(k => v[k]) : []; }

function deep(v, key, out) {
  if (v === null || typeof v !== 'object') return;
  if (key === undefined) out.push(v);
  else if (key === '*') out.push(...values(v));
  else if (!Array.isArray(v) && Object.prototype.hasOwnProperty.call(v, key)) out.push(v[key]);
  values(v).forEach(x => deep(x, key, out));
}

export function query(path, data) {
  let cur = [data];
  for (const s of split(path)) {
    const next = [];
    for (const v of cur) {
      if (s.k === 'key') { const r = pick(v, s.v); if (r !== undefined) next.push(r); else if (Array.isArray(v)) v.forEach(x => { const y = pick(x, s.v); if (y !== undefined) next.push(y); }); }
      else if (s.k === 'index') { const r = pick(v, s.v); if (r !== undefined) next.push(r); }
      else if (s.k === 'all') next.push(...values(v));
      else if (s.k === 'deep') deep(v, s.v, next);
      else if (s.k === 'union') s.v.forEach(k => { const r = pick(v, k); if (r !== undefined) next.push(r); });
      else if (s.k === 'slice') {
        if (!Array.isArray(v)) continue;
        const n = v.length, step = s.c || 1, from = s.a === undefined ? 0 : s.a < 0 ? Math.max(0, n + s.a) : s.a, to = s.b === undefined ? n : s.b < 0 ? n + s.b : Math.min(n, s.b);
        for (let i = from; i < to; i += step) next.push(v[i]);
      } else if (s.k === 'filter') values(v).forEach(x => { if (test(s.v, x)) next.push(x); });
    }
    cur = next;
  }
  return cur;
}

/** jsonpath-style entry: `jp(path, objectOrJson)`. */
export function jp(path, data) { return query(path, typeof data === 'string' ? JSON.parse(data) : data); }
export const JSONPath = { query: (data, path) => query(path, data) };
export default jp;
