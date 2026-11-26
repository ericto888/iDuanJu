// See idj_python.h. Own code; the declarations below mirror CPython 3.13's public headers (PSF-2.0).
#include "idj_python.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
#include <wchar.h>

#include "idj_boot.h"

// MARK: - CPython 3.13 ABI (64-bit, GIL build; checked at run time before anything below is used)

typedef struct pyobj pyobj;
typedef struct pyts pyts;
typedef pyobj *(*pycfunc)(pyobj *, pyobj *);

typedef struct { const char *name; pycfunc meth; int flags; const char *doc; } pymethod;
enum { METH_ARGS = 1, METH_NONE = 4 };
typedef struct { int slot; void *value; } pyslot;
enum { SLOT_EXEC = 2, FILE_INPUT = 257 };
typedef struct {
    ssize_t refcnt; void *type;                 // PyObject_HEAD
    pyobj *(*m_init)(void); ssize_t m_index; pyobj *m_copy;
    const char *m_name; const char *m_doc; ssize_t m_size; pymethod *m_methods; pyslot *m_slots;
    void *m_traverse; void *m_clear; void *m_free;
} pymoddef;

typedef struct { int type; const char *func; const char *msg; int exitcode; } pystatus;
typedef struct { ssize_t length; wchar_t **items; } pywlist;

typedef struct {
    int _config_init, parse_argv, isolated, use_environment, configure_locale, coerce_c_locale, coerce_c_locale_warn,
        utf8_mode, dev_mode, allocator;
} pypreconfig;

typedef struct {
    int _config_init;
    int isolated, use_environment, dev_mode, install_signal_handlers, use_hash_seed;
    unsigned long hash_seed;
    int faulthandler, tracemalloc, perf_profiling, import_time, code_debug_ranges, show_ref_count, dump_refs;
    wchar_t *dump_refs_file;
    int malloc_stats;
    wchar_t *filesystem_encoding, *filesystem_errors, *pycache_prefix;
    int parse_argv;
    pywlist orig_argv, argv, xoptions, warnoptions;
    int site_import, bytes_warning, warn_default_encoding, inspect, interactive, optimization_level, parser_debug,
        write_bytecode, verbose, quiet, user_site_directory, configure_c_stdio, buffered_stdio;
    wchar_t *stdio_encoding, *stdio_errors, *check_hash_pycs_mode;
    int use_frozen_modules, safe_path, int_max_str_digits, cpu_count, pathconfig_warnings;
    wchar_t *program_name, *pythonpath_env, *home, *platlibdir;
    int module_search_paths_set;
    pywlist module_search_paths;
    wchar_t *stdlib_dir, *executable, *base_executable, *prefix, *base_prefix, *exec_prefix, *base_exec_prefix;
    int skip_source_first_line;
    wchar_t *run_command, *run_module, *run_filename, *sys_path_0;
    int _install_importlib, _init_main, _is_python_build;
} pyconfig;

#define PY_FUNCTIONS(X) \
    X(const char *, Py_GetVersion, (void)) \
    X(void, PyPreConfig_InitIsolatedConfig, (pypreconfig *)) \
    X(pystatus, Py_PreInitialize, (const pypreconfig *)) \
    X(void, PyConfig_InitIsolatedConfig, (pyconfig *)) \
    X(pystatus, PyConfig_SetBytesString, (pyconfig *, wchar_t **, const char *)) \
    X(pystatus, PyWideStringList_Append, (pywlist *, const wchar_t *)) \
    X(void, PyConfig_Clear, (pyconfig *)) \
    X(pystatus, Py_InitializeFromConfig, (const pyconfig *)) \
    X(wchar_t *, Py_DecodeLocale, (const char *, size_t *)) \
    X(void, PyMem_RawFree, (void *)) \
    X(int, PyImport_AppendInittab, (const char *, pyobj *(*)(void))) \
    X(pyobj *, PyImport_ImportModule, (const char *)) \
    X(pyobj *, PyImport_AddModule, (const char *)) \
    X(pyobj *, PyModuleDef_Init, (pymoddef *)) \
    X(int, PyModule_AddObjectRef, (pyobj *, const char *, pyobj *)) \
    X(pyobj *, PyModule_GetDict, (pyobj *)) \
    X(pyobj *, PyDict_GetItemString, (pyobj *, const char *)) \
    X(int, PyDict_SetItemString, (pyobj *, const char *, pyobj *)) \
    X(pyobj *, PyEval_GetBuiltins, (void)) \
    X(pyobj *, Py_CompileString, (const char *, const char *, int)) \
    X(pyobj *, PyEval_EvalCode, (pyobj *, pyobj *, pyobj *)) \
    X(pyobj *, PyObject_GetAttrString, (pyobj *, const char *)) \
    X(pyobj *, PyObject_Str, (pyobj *)) \
    X(pyobj *, PyObject_CallObject, (pyobj *, pyobj *)) \
    X(pyobj *, PyTuple_New, (ssize_t)) \
    X(ssize_t, PyTuple_Size, (pyobj *)) \
    X(pyobj *, PyTuple_GetItem, (pyobj *, ssize_t)) \
    X(int, PyTuple_SetItem, (pyobj *, ssize_t, pyobj *)) \
    X(pyobj *, PyUnicode_FromString, (const char *)) \
    X(pyobj *, PyUnicode_DecodeUTF8, (const char *, ssize_t, const char *)) \
    X(const char *, PyUnicode_AsUTF8AndSize, (pyobj *, ssize_t *)) \
    X(pyobj *, PyUnicode_AsEncodedString, (pyobj *, const char *, const char *)) \
    X(int, PyBytes_AsStringAndSize, (pyobj *, char **, ssize_t *)) \
    X(pyobj *, PyLong_FromUnsignedLongLong, (unsigned long long)) \
    X(unsigned long long, PyLong_AsUnsignedLongLong, (pyobj *)) \
    X(pyobj *, PyErr_NewException, (const char *, pyobj *, pyobj *)) \
    X(pyobj *, PyErr_GetRaisedException, (void)) \
    X(pyobj *, PyErr_Occurred, (void)) \
    X(void, PyErr_SetString, (pyobj *, const char *)) \
    X(void, PyErr_Clear, (void)) \
    X(void, Py_IncRef, (pyobj *)) \
    X(void, Py_DecRef, (pyobj *)) \
    X(ssize_t, PyGC_Collect, (void)) \
    X(int, PyGILState_Ensure, (void)) \
    X(void, PyGILState_Release, (int)) \
    X(pyts *, PyEval_SaveThread, (void)) \
    X(void, PyEval_RestoreThread, (pyts *)) \
    X(unsigned long, PyThread_get_thread_ident, (void)) \
    X(int, PyThreadState_SetAsyncExc, (unsigned long, pyobj *))

#define PY_POINTERS(X) X(PyExc_BaseException) X(PyExc_RuntimeError) X(PyExc_TypeError) X(PyExc_ValueError)

static struct {
#define X(ret, name, args) ret (*name) args;
    PY_FUNCTIONS(X)
#undef X
#define X(name) pyobj *name;
    PY_POINTERS(X)
#undef X
    pyobj *None;
} py;

static idjpy_host_fn g_host;
static _Atomic int g_state;          // 0 = not started, 1 = starting or failed, 2 = running
static char g_version[24];
static pyobj *g_interrupted;         // _idj_host.Interrupted
static pyobj *g_boot;                // dict of the boot module

// MARK: - Small helpers

static char *fmt(const char *f, ...) __attribute__((format(printf, 1, 2)));
static char *fmt(const char *f, ...) {
    va_list ap;
    va_start(ap, f);
    char *s = NULL;
    if (vasprintf(&s, f, ap) < 0) s = NULL;
    va_end(ap);
    return s;
}

static char *dup_n(const char *s, size_t n) {
    char *r = malloc(n + 1);
    if (!r) return NULL;
    memcpy(r, s, n);
    r[n] = 0;
    return r;
}

static void decref(pyobj *o) { if (o) py.Py_DecRef(o); }

/// UTF-8 view of a str (lone surrogates become '?'). *hold must be released after use; NULL with an exception set.
static const char *utf8(pyobj *s, ssize_t *n, pyobj **hold) {
    *hold = NULL;
    const char *p = py.PyUnicode_AsUTF8AndSize(s, n);
    if (p) return p;
    py.PyErr_Clear();
    pyobj *b = py.PyUnicode_AsEncodedString(s, "utf-8", "replace");
    if (!b) return NULL;
    char *q = NULL;
    if (py.PyBytes_AsStringAndSize(b, &q, n) != 0) { decref(b); return NULL; }
    *hold = b;
    return q;
}

static char *copy_str(pyobj *s) {
    ssize_t n = 0;
    pyobj *hold = NULL;
    const char *p = utf8(s, &n, &hold);
    char *r = p ? dup_n(p, (size_t)n) : NULL;
    decref(hold);
    return r;
}

// MARK: - Per native thread: spider key + owner

typedef struct { char *key; uint64_t owner; } context;
static pthread_key_t g_context_key;
static pthread_once_t g_context_once = PTHREAD_ONCE_INIT;
static void context_free(void *p) {
    context *c = p;
    if (c) { free(c->key); free(c); }
}
static void context_init(void) { pthread_key_create(&g_context_key, context_free); }
static context *context_get(void) {
    pthread_once(&g_context_once, context_init);
    context *c = pthread_getspecific(g_context_key);
    if (!c && (c = calloc(1, sizeof *c))) pthread_setspecific(g_context_key, c);
    return c;
}
static void context_set_key(const char *key) {
    context *c = context_get();
    if (!c) return;
    char *k = strdup(key);
    free(c->key);
    c->key = k;
}

/// Python threads started by scripts (threading.Thread), so an interrupt reaches them too. Guarded by the GIL.
typedef struct child { unsigned long tid; uint64_t owner; struct child *next; } child;
static child *g_children;
static void child_add(unsigned long tid, uint64_t owner) {
    child *c = malloc(sizeof *c);
    if (!c) return;
    *c = (child){ tid, owner, g_children };
    g_children = c;
}
static void child_remove(unsigned long tid) {
    for (child **p = &g_children; *p; p = &(*p)->next) {
        if ((*p)->tid == tid) { child *c = *p; *p = c->next; free(c); return; }
    }
}
static void children_interrupt(uint64_t owner) {
    for (child *c = g_children; c; c = c->next) if (c->owner == owner) py.PyThreadState_SetAsyncExc(c->tid, g_interrupted);
}

// MARK: - _idj_host

static pyobj *none(void) { py.Py_IncRef(py.None); return py.None; }

/// Argument i as a C string without embedded NULs.
static const char *arg_str(pyobj *args, ssize_t i, pyobj **hold) {
    ssize_t n = 0;
    pyobj *o = py.PyTuple_GetItem(args, i);
    const char *s = o ? utf8(o, &n, hold) : NULL;
    if (s && strlen(s) != (size_t)n) { py.PyErr_SetString(py.PyExc_ValueError, "embedded null character"); return NULL; }
    return s;
}

static bool want(pyobj *args, ssize_t n, const char *what) {
    if (py.PyTuple_Size(args) == n) return true;
    py.PyErr_SetString(py.PyExc_TypeError, what);
    return false;
}

static pyobj *host_call(pyobj *self, pyobj *args) {
    (void)self;
    if (!want(args, 2, "call(name, args_json)")) return NULL;
    pyobj *h0 = NULL, *h1 = NULL, *out = NULL;
    const char *name = arg_str(args, 0, &h0), *json = name ? arg_str(args, 1, &h1) : NULL;
    if (json) {
        context *c = context_get();
        char *key = strdup(c && c->key ? c->key : "");
        pyts *ts = py.PyEval_SaveThread();
        char *r = key ? g_host(key, name, json) : NULL;
        py.PyEval_RestoreThread(ts);
        free(key);
        if (r) out = py.PyUnicode_DecodeUTF8(r, (ssize_t)strlen(r), "replace");
        else py.PyErr_SetString(py.PyExc_RuntimeError, "host call failed");
        free(r);
    }
    decref(h0);
    decref(h1);
    return out;
}

static pyobj *host_get_key(pyobj *self, pyobj *args) {
    (void)self; (void)args;
    context *c = context_get();
    return py.PyUnicode_FromString(c && c->key ? c->key : "");
}

static pyobj *host_set_key(pyobj *self, pyobj *args) {
    (void)self;
    if (!want(args, 1, "set_key(key)")) return NULL;
    pyobj *h = NULL;
    const char *k = arg_str(args, 0, &h);
    if (k) context_set_key(k);
    decref(h);
    return k ? none() : NULL;
}

/// (key, owner) of this thread, for a thread it starts.
static pyobj *host_context(pyobj *self, pyobj *args) {
    (void)args;
    context *c = context_get();
    pyobj *t = py.PyTuple_New(2), *k = host_get_key(self, NULL), *o = py.PyLong_FromUnsignedLongLong(c ? c->owner : 0);
    if (!t || !k || !o) { decref(t); decref(k); decref(o); return NULL; }
    py.PyTuple_SetItem(t, 0, k);   // steals
    py.PyTuple_SetItem(t, 1, o);
    return t;
}

static pyobj *host_enter(pyobj *self, pyobj *args) {
    (void)self;
    if (!want(args, 2, "enter(key, owner)")) return NULL;
    pyobj *h = NULL;
    const char *k = arg_str(args, 0, &h);
    unsigned long long owner = k ? py.PyLong_AsUnsignedLongLong(py.PyTuple_GetItem(args, 1)) : 0;
    bool ok = k && !(owner == (unsigned long long)-1 && py.PyErr_Occurred());
    if (ok) {
        context_set_key(k);
        context *c = context_get();
        if (c) c->owner = owner;
        if (owner) child_add(py.PyThread_get_thread_ident(), owner);
    }
    decref(h);
    return ok ? none() : NULL;
}

static pyobj *host_leave(pyobj *self, pyobj *args) {
    (void)self; (void)args;
    child_remove(py.PyThread_get_thread_ident());
    return none();
}

static pymethod g_methods[] = {
    { "call", host_call, METH_ARGS, "call(name, args_json) -> str" },
    { "get_key", host_get_key, METH_NONE, "spider key of this thread" },
    { "set_key", host_set_key, METH_ARGS, "set_key(key)" },
    { "context", host_context, METH_NONE, NULL },
    { "enter", host_enter, METH_ARGS, NULL },
    { "leave", host_leave, METH_NONE, NULL },
    { NULL, NULL, 0, NULL },
};

static int host_exec(pyobj *m) {
    if (!g_interrupted) g_interrupted = py.PyErr_NewException("_idj_host.Interrupted", py.PyExc_BaseException, NULL);
    return g_interrupted ? py.PyModule_AddObjectRef(m, "Interrupted", g_interrupted) : -1;
}

static pyslot g_slots[] = { { SLOT_EXEC, (void *)host_exec }, { 0, NULL } };
static pymoddef g_module = { .refcnt = 1, .m_name = "_idj_host", .m_size = 0, .m_methods = g_methods, .m_slots = g_slots };
static pyobj *init_host_module(void) { return py.PyModuleDef_Init(&g_module); }

// MARK: - Errors

/// Takes the current exception: one line + full traceback, both malloc'ed.
static void take_error(char **err, char **trace) {
    pyobj *e = py.PyErr_GetRaisedException();
    pyobj *fn = g_boot ? py.PyDict_GetItemString(g_boot, "describe") : NULL;   // borrowed
    pyobj *args = e && fn ? py.PyTuple_New(1) : NULL, *r = NULL;
    if (args) {
        py.PyTuple_SetItem(args, 0, e);   // steals
        r = py.PyObject_CallObject(fn, args);
        py.Py_DecRef(args);
    } else {
        decref(e);
    }
    if (r) {
        pyobj *a = py.PyTuple_GetItem(r, 0), *b = py.PyTuple_GetItem(r, 1);
        if (a) *err = copy_str(a);
        if (b) *trace = copy_str(b);
        py.Py_DecRef(r);
    }
    py.PyErr_Clear();
    if (!*err) *err = strdup("Python error");
    if (!*trace) *trace = strdup(*err ? *err : "");
}

static void call_boot(const char *name) {
    pyobj *fn = g_boot ? py.PyDict_GetItemString(g_boot, name) : NULL;
    if (fn) decref(py.PyObject_CallObject(fn, NULL));
    py.PyErr_Clear();
}

// MARK: - Start

static char *resolve(void *lib) {
#define X(ret, name, args) \
    if (!(py.name = (ret (*) args)dlsym(lib, #name))) return fmt("missing symbol %s", #name);
    PY_FUNCTIONS(X)
#undef X
#define X(name) if (!dlsym(lib, #name)) return fmt("missing symbol %s", #name);
    PY_POINTERS(X)
#undef X
    if (!(py.None = (pyobj *)dlsym(lib, "_Py_NoneStruct"))) return fmt("missing symbol _Py_NoneStruct");
    return NULL;
}

/// The PyExc_* variables are filled in during initialisation.
static void resolve_exceptions(void *lib) {
#define X(name) py.name = *(pyobj **)dlsym(lib, #name);
    PY_POINTERS(X)
#undef X
}

static char *check_version(void) {
    const char *v = py.Py_GetVersion();
    int major = 0, minor = 0, micro = 0;
    sscanf(v, "%d.%d.%d", &major, &minor, &micro);
    if (major != 3 || minor != 13 || strstr(v, "free-threading")) return fmt("unsupported Python %s", v);
    snprintf(g_version, sizeof g_version, "%d.%d.%d", major, minor, micro);
    return NULL;
}

static char *status_error(pystatus s) {
    return s.type == 0 ? NULL : fmt("%s%s%s", s.func ? s.func : "", s.func ? ": " : "", s.msg ? s.msg : "initialisation failed");
}

/// Isolated configuration: no environment, no site, no signal handlers, no .pyc writing, explicit sys.path.
static char *initialise(const char *home, const char *paths, const char *executable) {
    pypreconfig pre;
    memset(&pre, 0, sizeof pre);
    py.PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;
    char *e = status_error(py.Py_PreInitialize(&pre));
    if (e) return e;

    // Canary bytes after the struct prove that this header and the framework agree on its size.
    enum { EXTRA = 1024 };
    unsigned char *raw = malloc(sizeof(pyconfig) + EXTRA);
    if (!raw) return fmt("out of memory");
    memset(raw, 0xA5, sizeof(pyconfig) + EXTRA);
    pyconfig *c = (pyconfig *)raw;
    py.PyConfig_InitIsolatedConfig(c);
    bool sane = raw[sizeof(pyconfig)] == 0xA5 && c->_config_init == 3 && c->isolated == 1 && c->use_environment == 0
        && c->install_signal_handlers == 0 && c->site_import == 1 && c->write_bytecode == 1 && c->user_site_directory == 0
        && c->buffered_stdio == 1 && c->use_frozen_modules == 1 && c->safe_path == 1 && c->int_max_str_digits == 4300
        && c->cpu_count == -1 && c->pathconfig_warnings == 0 && c->home == NULL && c->executable == NULL
        && c->_install_importlib == 1 && c->_init_main == 1 && c->_is_python_build == 0;
    if (!sane) { free(raw); return fmt("unexpected PyConfig layout in Python %s", g_version); }

    c->site_import = 0;
    c->write_bytecode = 0;
    c->module_search_paths_set = 1;
    char *lib = fmt("%s/lib/python3.13", home);
    pystatus s = py.PyConfig_SetBytesString(c, &c->home, home);
    if (s.type == 0) s = py.PyConfig_SetBytesString(c, &c->stdlib_dir, lib ? lib : home);
    if (s.type == 0) s = py.PyConfig_SetBytesString(c, &c->program_name, executable);
    if (s.type == 0) s = py.PyConfig_SetBytesString(c, &c->executable, executable);
    if (s.type == 0) s = py.PyConfig_SetBytesString(c, &c->base_executable, executable);
    free(lib);
    char *copy = strdup(paths), *cursor = copy, *item;
    while (copy && s.type == 0 && (item = strsep(&cursor, ":"))) {
        if (!*item) continue;
        wchar_t *w = py.Py_DecodeLocale(item, NULL);
        if (!w) break;
        s = py.PyWideStringList_Append(&c->module_search_paths, w);
        py.PyMem_RawFree(w);
    }
    free(copy);
    if (s.type == 0) s = py.Py_InitializeFromConfig(c);
    e = status_error(s);
    py.PyConfig_Clear(c);
    free(raw);
    return e;
}

/// Standard streams, thread bookkeeping and error formatting (idj_boot.h), then idj_compat.install() if it exists.
static char *run_boot(void) {
    pyobj *mod = py.PyImport_AddModule("_idj_boot");   // borrowed
    pyobj *dict = mod ? py.PyModule_GetDict(mod) : NULL;
    pyobj *code = NULL, *r = NULL;
    if (dict && py.PyDict_SetItemString(dict, "__builtins__", py.PyEval_GetBuiltins()) == 0)
        code = py.Py_CompileString(idj_boot_source, "<idj_boot>", FILE_INPUT);
    if (code) r = py.PyEval_EvalCode(code, dict, dict);
    decref(code);
    if (!r) {   // the traceback helper is what failed to load
        pyobj *e = py.PyErr_GetRaisedException(), *text = e ? py.PyObject_Str(e) : NULL;
        char *detail = text ? copy_str(text) : NULL;
        py.PyErr_Clear();
        decref(text);
        decref(e);
        char *m = fmt("bootstrap failed: %s", detail ? detail : "?");
        free(detail);
        return m;
    }
    decref(r);
    py.Py_IncRef(dict);
    g_boot = dict;
    call_boot("compat");
    return NULL;
}

int idjpy_start(const char *library, const char *home, const char *paths, const char *executable, idjpy_host_fn host,
                char **err) {
    *err = NULL;
    int expected = 0;
    if (!atomic_compare_exchange_strong(&g_state, &expected, 1)) {
        if (expected == 2) return 0;
        *err = strdup("the interpreter failed to start earlier");
        return -1;
    }
    g_host = host;
    context_get();
    // RTLD_GLOBAL: ctypes.pythonapi looks symbols up in the global scope.
    void *lib = dlopen(library, RTLD_NOW | RTLD_GLOBAL);
    if (!lib) {
        const char *m = dlerror();
        *err = strdup(m ? m : "dlopen failed");
        return -1;
    }
    // Python sockets rely on SIGPIPE being ignored; CPython only does that when it may install signal handlers.
    struct sigaction sa;
    if (sigaction(SIGPIPE, NULL, &sa) == 0 && sa.sa_handler == SIG_DFL) signal(SIGPIPE, SIG_IGN);
    // Stream setup expects descriptors 0-2 to exist.
    for (int fd = 0; fd < 3; fd++) {
        if (fcntl(fd, F_GETFD) == -1 && errno == EBADF) (void)open("/dev/null", O_RDWR);
    }
    if ((*err = resolve(lib)) || (*err = check_version())) return -1;
    if (py.PyImport_AppendInittab("_idj_host", init_host_module) != 0) { *err = strdup("PyImport_AppendInittab failed"); return -1; }
    if ((*err = initialise(home, paths, executable))) return -1;
    resolve_exceptions(lib);
    *err = run_boot();
    (void)py.PyEval_SaveThread();   // release the GIL; this thread keeps its state for PyGILState_Ensure
    if (*err) return -1;
    atomic_store(&g_state, 2);
    return 0;
}

const char *idjpy_version(void) { return atomic_load(&g_state) == 2 ? g_version : NULL; }

int idjpy_add_path(const char *path) {
    if (atomic_load(&g_state) != 2) return -1;
    int gil = py.PyGILState_Ensure();
    pyobj *fn = py.PyDict_GetItemString(g_boot, "add_path"), *args = py.PyTuple_New(1), *s = py.PyUnicode_FromString(path);
    pyobj *r = NULL;
    if (fn && args && s) {
        py.PyTuple_SetItem(args, 0, s);   // steals
        s = NULL;
        r = py.PyObject_CallObject(fn, args);
    }
    int rc = r ? 0 : -1;
    decref(r);
    decref(s);
    decref(args);
    py.PyErr_Clear();
    py.PyGILState_Release(gil);
    return rc;
}

// MARK: - Spider threads

struct idjpy_thread {
    char *key;
    uint64_t owner;
    bool attached;
    int gil;
    pyts *ts;
    // Guarded by the GIL:
    uint64_t serial;      // running call, 0 = none
    unsigned long tid;
};

idjpy_thread *idjpy_thread_new(const char *key) {
    static _Atomic uint64_t owners;
    idjpy_thread *t = calloc(1, sizeof *t);
    if (!t) abort();
    t->key = strdup(key);
    t->owner = atomic_fetch_add(&owners, 1) + 1;
    return t;
}

void idjpy_thread_free(idjpy_thread *t) {
    free(t->key);
    free(t);
}

void idjpy_thread_attach(idjpy_thread *t) {
    if (t->attached || atomic_load(&g_state) != 2) return;
    t->gil = py.PyGILState_Ensure();
    t->ts = py.PyEval_SaveThread();
    t->attached = true;
}

void idjpy_thread_detach(idjpy_thread *t) {
    if (!t->attached) return;
    t->attached = false;
    py.PyEval_RestoreThread(t->ts);
    children_interrupt(t->owner);
    py.PyGC_Collect();
    py.PyErr_Clear();
    py.PyGILState_Release(t->gil);   // last reference: deletes the thread state and releases the GIL
}

char *idjpy_call(idjpy_thread *t, uint64_t serial, const char *module, const char *func, const char *const *args, int nargs,
                 char **err, char **trace) {
    *err = *trace = NULL;
    if (atomic_load(&g_state) != 2) {
        *err = strdup("Python is not running");
        *trace = strdup("");
        return NULL;
    }
    int gil = py.PyGILState_Ensure();
    context_set_key(t->key ? t->key : "");
    context *c = context_get();
    if (c) c->owner = t->owner;
    t->tid = py.PyThread_get_thread_ident();
    t->serial = serial;

    pyobj *mod = py.PyImport_ImportModule(module), *fn = mod ? py.PyObject_GetAttrString(mod, func) : NULL;
    pyobj *tuple = fn ? py.PyTuple_New(nargs) : NULL, *res = NULL;
    bool ok = tuple != NULL;
    for (int i = 0; ok && i < nargs; i++) {
        pyobj *s = py.PyUnicode_DecodeUTF8(args[i], (ssize_t)strlen(args[i]), "replace");
        ok = s && py.PyTuple_SetItem(tuple, i, s) == 0;
    }
    if (ok) res = py.PyObject_CallObject(fn, tuple);

    // No bytecode runs between the return above and here: an interrupt that came too late is dropped, not left to hit
    // the next call on this thread.
    t->serial = 0;
    py.PyThreadState_SetAsyncExc(t->tid, NULL);

    char *out = NULL;
    if (res) out = res == py.None ? strdup("") : copy_str(res);
    if (!out) take_error(err, trace);
    decref(res);
    decref(tuple);
    decref(fn);
    decref(mod);
    call_boot("flush");
    py.PyGILState_Release(gil);
    return out;
}

int idjpy_interrupt(idjpy_thread *t, uint64_t serial) {
    if (!serial || atomic_load(&g_state) != 2) return 0;
    int gil = py.PyGILState_Ensure(), hit = 0;
    if (t->serial == serial) {
        hit = py.PyThreadState_SetAsyncExc(t->tid, g_interrupted) > 0;
        children_interrupt(t->owner);
    }
    py.PyGILState_Release(gil);
    return hit;
}

void idjpy_free(char *s) { free(s); }
