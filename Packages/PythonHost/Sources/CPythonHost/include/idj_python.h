// Hosts CPython 3.13 without linking against it: Python.framework is opened with dlopen and the C API is resolved with
// dlsym, so the app builds, links and runs when the framework is not bundled.
//
// Threads: idjpy_start once, on a thread that lives as long as the process. Everything else on any thread. One
// idjpy_thread = one spider thread; its calls must be serial.
#ifndef IDJ_PYTHON_H
#define IDJ_PYTHON_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
#pragma clang assume_nonnull begin

/// Host ABI (shared/tvbox/HOST_ABI.md): `_idj_host.call(name, args_json)` from any Python thread. Runs without the GIL on
/// the calling thread. `key` is the spider key of that thread ("" if none). Returns a malloc'ed UTF-8 string which the
/// shim frees, or NULL (raises RuntimeError in the script).
typedef char *_Nullable (*idjpy_host_fn)(const char *key, const char *name, const char *args_json);

/// Loads Python.framework and initialises the interpreter. Returns 0, or -1 with a malloc'ed message in *err. Never
/// retried: CPython cannot be initialised again after a failure, so later calls fail with the same kind of message.
/// - library:    <app>/Frameworks/Python.framework/Python
/// - home:       <app>/python (contains lib/python3.13)
/// - paths:      sys.path, separated by ':'
/// - executable: a file directly inside <app>; CPython resolves .fwork placeholders relative to its directory
int idjpy_start(const char *library, const char *home, const char *paths, const char *executable, idjpy_host_fn host,
                char *_Nullable *_Nonnull err);

/// "3.13.18", NULL before a successful idjpy_start.
const char *_Nullable idjpy_version(void);

/// Appends a directory to sys.path (once). Returns 0 on success.
int idjpy_add_path(const char *path);

typedef struct idjpy_thread idjpy_thread;

/// `key` is what the host callback receives for calls made by this thread and by threads its scripts start.
idjpy_thread *idjpy_thread_new(const char *key);
/// Optional, on the spider's own native thread: keeps one Python thread state (threading.local data) until detach.
void idjpy_thread_attach(idjpy_thread *t);
/// On the same native thread: interrupts Python threads the scripts left behind, collects garbage, drops the thread state.
void idjpy_thread_detach(idjpy_thread *t);
/// After detach (or if never attached), when no other thread uses `t` any more.
void idjpy_thread_free(idjpy_thread *t);

/// Takes the GIL and runs `module.func(*args)` (str arguments, str or None result). `serial` identifies the call for
/// idjpy_interrupt and must not be 0. Returns a malloc'ed UTF-8 string ("" for None), or NULL with malloc'ed *err (one
/// line, "Type: message") and *trace (full traceback). Free all three with idjpy_free.
char *_Nullable idjpy_call(idjpy_thread *t, uint64_t serial, const char *module, const char *func,
                           const char *const _Nullable *_Nonnull args, int nargs, char *_Nullable *_Nonnull err,
                           char *_Nullable *_Nonnull trace);

/// Raises `_idj_host.Interrupted` in the script that runs call `serial` and in the Python threads it started. No-op
/// (returns 0) when that call is not running. Blocks until it gets the GIL: never call it on the main thread.
int idjpy_interrupt(idjpy_thread *t, uint64_t serial);

void idjpy_free(char *_Nullable s);

#pragma clang assume_nonnull end
#ifdef __cplusplus
}
#endif
#endif
