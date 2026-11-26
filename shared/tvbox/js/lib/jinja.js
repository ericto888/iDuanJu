// Small Jinja2-style renderer (variables, filters, if / elif / else, for) used by drpy `filter_url` templates. Own code, GPL-3.0.

const TOKEN = /\s*(?:(\d+(?:\.\d+)?)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|([A-Za-z_\u4e00-\u9fff][\w\u4e00-\u9fff]*)|(==|!=|>=|<=|\|\||&&|[-+*\/%~<>()[\]{}.,|:!]))/y;

function lex(src) {
  const out = [];
  TOKEN.lastIndex = 0;
  let at = 0;
  while (at < src.length) {
    if (/^\s*$/.test(src.slice(at))) break;
    TOKEN.lastIndex = at;
    const m = TOKEN.exec(src);
    if (!m) throw new Error('模板表达式无法识别：' + src.slice(at, at + 20));
    at = TOKEN.lastIndex;
    if (m[1] !== undefined) out.push({ t: 'lit', v: Number(m[1]) });
    else if (m[2] !== undefined) out.push({ t: 'lit', v: m[2].slice(1, -1).replace(/\\n/g, '\n').replace(/\\(.)/g, '$1') });
    else if (m[3] !== undefined) out.push({ t: 'id', v: m[3] });
    else out.push({ t: 'op', v: m[4] });
  }
  return out;
}

const FILTERS = {
  default: (v, d, falsy) => (v === undefined || v === null || (falsy && !v) || v === '' ? d : v),
  d: (v, d) => (v === undefined || v === null || v === '' ? d : v),
  join: (v, sep) => (Array.isArray(v) ? v.join(sep === undefined ? '' : sep) : v),
  upper: v => String(v).toUpperCase(),
  lower: v => String(v).toLowerCase(),
  trim: v => String(v).trim(),
  string: v => String(v),
  int: v => parseInt(v, 10) || 0,
  float: v => parseFloat(v) || 0,
  length: v => (v === undefined || v === null ? 0 : v.length || Object.keys(v).length),
  first: v => v && v[0],
  last: v => v && v[v.length - 1],
  replace: (v, a, b) => String(v).split(a).join(b),
  urlencode: v => encodeURIComponent(String(v)),
  tojson: v => JSON.stringify(v),
  abs: v => Math.abs(v),
  split: (v, sep) => String(v).split(sep),
};

/** Recursive-descent evaluator over the token list. */
function evaluate(src, scope) {
  const tk = lex(src);
  let p = 0;
  const peek = v => tk[p] && tk[p].v === v && tk[p].t !== 'lit';
  const take = v => (peek(v) ? (p++, true) : false);
  const need = v => { if (!take(v)) throw new Error('模板表达式缺少 ' + v); };

  function ternary() {
    const a = or();
    if (take('if')) {
      const c = or();
      const b = take('else') ? ternary() : '';
      return c ? a : b;
    }
    return a;
  }
  function or() { let a = and(); while (take('or') || take('||')) { const b = and(); a = a || b; } return a; }
  function and() { let a = not(); while (take('and') || take('&&')) { const b = not(); a = a && b; } return a; }
  function not() { return take('not') || take('!') ? !not() : compare(); }
  function compare() {
    let a = add();
    for (;;) {
      if (take('==')) { const b = add(); a = a == b; } // eslint-disable-line eqeqeq
      else if (take('!=')) { const b = add(); a = a != b; } // eslint-disable-line eqeqeq
      else if (take('>=')) a = a >= add();
      else if (take('<=')) a = a <= add();
      else if (take('>')) a = a > add();
      else if (take('<')) a = a < add();
      else if (take('in')) { const b = add(); a = !!b && (Array.isArray(b) || typeof b === 'string' ? b.includes(a) : a in b); }
      else return a;
    }
  }
  function add() {
    let a = mul();
    for (;;) {
      if (take('+')) a = a + mul();
      else if (take('-')) a = a - mul();
      else if (take('~')) a = String(a === undefined || a === null ? '' : a) + String(mul());
      else return a;
    }
  }
  function mul() {
    let a = pipe();
    for (;;) {
      if (take('*')) a = a * pipe();
      else if (take('/')) a = a / pipe();
      else if (take('%')) a = a % pipe();
      else return a;
    }
  }
  function args() {
    const list = [];
    if (take(')')) return list;
    do { list.push(ternary()); } while (take(','));
    need(')');
    return list;
  }
  function pipe() {
    let v = postfix();
    while (take('|')) {
      const name = tk[p] && tk[p].v; p++;
      const list = take('(') ? args() : [];
      const f = FILTERS[name];
      if (f) v = f(v, ...list);
    }
    return v;
  }
  function postfix() {
    let v = primary();
    for (;;) {
      if (take('.')) { const k = tk[p] && tk[p].v; p++; v = v === undefined || v === null ? undefined : v[k]; if (take('(')) { const list = args(); v = typeof v === 'function' ? v(...list) : v; } }
      else if (take('[')) { const k = ternary(); need(']'); v = v === undefined || v === null ? undefined : v[k < 0 ? v.length + k : k]; }
      else return v;
    }
  }
  function primary() {
    const t = tk[p];
    if (!t) return undefined;
    if (t.t === 'lit') { p++; return t.v; }
    if (take('-')) return -postfix();
    if (take('(')) { const v = ternary(); need(')'); return v; }
    if (take('[')) { const list = []; if (take(']')) return list; do { list.push(ternary()); } while (take(',')); need(']'); return list; }
    if (t.t === 'id') {
      p++;
      if (t.v === 'true' || t.v === 'True') return true;
      if (t.v === 'false' || t.v === 'False') return false;
      if (t.v === 'none' || t.v === 'None' || t.v === 'null') return null;
      return scope[t.v];
    }
    throw new Error('模板表达式有误：' + t.v);
  }
  return ternary();
}

function parse(src) {
  const nodes = [];
  const re = /\{\{-?([\s\S]*?)-?\}\}|\{%-?([\s\S]*?)-?%\}|\{#[\s\S]*?#\}/g;
  let at = 0, m;
  while ((m = re.exec(src))) {
    if (m.index > at) nodes.push({ k: 'text', v: src.slice(at, m.index) });
    if (m[1] !== undefined) nodes.push({ k: 'out', v: m[1].trim() });
    else if (m[2] !== undefined) nodes.push({ k: 'tag', v: m[2].trim() });
    at = re.lastIndex;
  }
  if (at < src.length) nodes.push({ k: 'text', v: src.slice(at) });
  let i = 0;
  function block(stops) {
    const out = [];
    while (i < nodes.length) {
      const n = nodes[i];
      if (n.k !== 'tag') { out.push(n); i++; continue; }
      const word = n.v.split(/\s+/)[0];
      if (stops.includes(word)) return out;
      i++;
      if (word === 'if') {
        const arms = [];
        let cond = n.v.slice(2).trim();
        for (;;) {
          const body = block(['elif', 'else', 'endif']);
          arms.push({ cond, body });
          const stop = nodes[i] ? nodes[i].v : 'endif';
          i++;
          if (/^elif\b/.test(stop)) cond = stop.slice(4).trim();
          else if (/^else\b/.test(stop)) cond = null;
          else break;
        }
        out.push({ k: 'if', arms });
      } else if (word === 'for') {
        const h = /^for\s+([\w,\s]+?)\s+in\s+([\s\S]+)$/.exec(n.v);
        const body = block(['endfor']);
        i++;
        if (h) out.push({ k: 'for', vars: h[1].split(',').map(x => x.trim()), list: h[2], body });
      } else if (word === 'set') {
        const h = /^set\s+(\w+)\s*=\s*([\s\S]+)$/.exec(n.v);
        if (h) out.push({ k: 'set', name: h[1], v: h[2] });
      }
    }
    return out;
  }
  return block([]);
}

function run(nodes, scope) {
  let s = '';
  for (const n of nodes) {
    if (n.k === 'text') s += n.v;
    else if (n.k === 'out') { const v = evaluate(n.v, scope); s += v === undefined || v === null ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v); }
    else if (n.k === 'set') scope[n.name] = evaluate(n.v, scope);
    else if (n.k === 'if') { const arm = n.arms.find(a => a.cond === null || evaluate(a.cond, scope)); if (arm) s += run(arm.body, scope); }
    else if (n.k === 'for') {
      const list = evaluate(n.list, scope);
      const rows = Array.isArray(list) ? list.map(v => [v]) : Object.entries(list || {});
      rows.forEach((row, index) => {
        const inner = Object.create(scope);
        if (n.vars.length > 1) n.vars.forEach((name, k) => { inner[name] = Array.isArray(row[0]) ? row[0][k] : row[k]; });
        else inner[n.vars[0]] = row[0];
        inner.loop = { index: index + 1, index0: index, first: index === 0, last: index === rows.length - 1, length: rows.length };
        s += run(n.body, inner);
      });
    }
  }
  return s;
}

export function jinja2(template, data) { return run(parse(String(template)), Object.assign({}, data || {})); }
export function render(template, data) { return jinja2(template, data); }
const jinja = { render, jinja2 };
globalThis.jinja = jinja;
export default jinja;
