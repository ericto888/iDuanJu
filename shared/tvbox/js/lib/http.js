// `import http from 'assets://js/lib/http.js'` — the bootstrap's request helpers as a module.
export const http = globalThis.http;
export const req = (url, options) => globalThis.req(url, options);
export default globalThis.http;
