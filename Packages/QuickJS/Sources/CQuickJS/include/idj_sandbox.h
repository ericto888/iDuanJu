#ifndef IDJ_SANDBOX_H
#define IDJ_SANDBOX_H
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque per-plugin sandbox (one QuickJS runtime + one eval-less context).
typedef struct IDJBox IDJBox;

/// Host callback. `name` = capability ("http.request", "html.select", …), `args` = JSON text.
/// Return a malloc'd UTF-8 string (JSON text) or NULL for `undefined`. Set *is_error = 1 and return
/// JSON `{"code":"E_…","message":"…"}` to throw inside JS.
typedef char *(*idj_host_fn)(void *opaque, const char *name, const char *args, int *is_error);

IDJBox *idj_new(size_t mem_limit, size_t stack_limit, idj_host_fn fn, void *opaque);
/// idj_new with eval / Function enabled (book-source scripts only; plugins use idj_new).
IDJBox *idj_new_with_eval(size_t mem_limit, size_t stack_limit, idj_host_fn fn, void *opaque);
/// Runs the trusted prelude (script) and then the plugin (ES module). Returns 0 on success; on failure *err
/// receives a malloc'd JSON error ({"code","message"}).
int idj_load(IDJBox *b, const char *prelude, const char *src, const char *filename, double timeout_sec, char **err);
/// 1 when the plugin's default export has a function named `fn`.
int idj_has(IDJBox *b, const char *fn);
/// Calls `default[fn](arg)`, awaits the returned promise, returns malloc'd JSON text of the result
/// (or "null"). On failure returns NULL and *err receives malloc'd JSON {"code","message"}.
char *idj_call(IDJBox *b, const char *fn, const char *arg_json, double timeout_sec, char **err);
/// Evaluates a trusted snippet in the sandbox context (tests only; still eval-less for the snippet's own code).
char *idj_eval_script(IDJBox *b, const char *src, double timeout_sec, char **err);
/// Same as idj_eval_script, compiled without strict mode (Legado scripts).
char *idj_eval_sloppy(IDJBox *b, const char *src, double timeout_sec, char **err);
/// Bytes currently allocated by this runtime.
size_t idj_memory_used(IDJBox *b);
void idj_free(IDJBox *b);
void idj_str_free(char *s);

// TVBox scripts (shared/tvbox/HOST_ABI.md): a full context with eval and ES modules, unrelated to the plugin sandbox above.
// A context belongs to one thread; only idj_tv_interrupt may be called from another one.
typedef struct IDJTv IDJTv;

/// `__tv(name, args)`; returns malloc'd UTF-8 text or NULL for `undefined`.
typedef char *(*idj_tv_call_fn)(void *opaque, const char *name, const char *args);
/// Resolves an import; returns the malloc'd module name, or NULL with a malloc'd message in *err.
typedef char *(*idj_tv_normalize_fn)(void *opaque, const char *base, const char *name, char **err);
/// Returns the malloc'd source of a module, or NULL with a malloc'd message in *err.
typedef char *(*idj_tv_load_fn)(void *opaque, const char *name, char **err);

IDJTv *idj_tv_new(size_t mem_limit, size_t stack_limit, idj_tv_call_fn call, idj_tv_normalize_fn normalize, idj_tv_load_fn load, void *opaque);
/// Evaluates a (sloppy) global script and drains the job queue. `src[len]` must be 0. *out receives the completion value as
/// a malloc'd string, NULL for undefined / null. Returns 0, -1 (error: malloc'd "message\x01stack" in *err) or -2 (interrupted).
int idj_tv_script(IDJTv *t, const char *src, size_t len, const char *filename, char **out, char **err);
/// Evaluates an ES module and drains the job queue; a rejected module is an error.
int idj_tv_module(IDJTv *t, const char *src, size_t len, const char *filename, char **err);
/// Any thread: stops the running script (and every later one) until idj_tv_resume.
void idj_tv_interrupt(IDJTv *t);
void idj_tv_resume(IDJTv *t);
void idj_tv_free(IDJTv *t);

#ifdef __cplusplus
}
#endif
#endif
