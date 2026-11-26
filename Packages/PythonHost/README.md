# PythonHost

C shim that runs an embedded CPython 3.13 for TVBox Python spiders. It links nothing: `Python.framework` is opened with
`dlopen` and the C API is resolved with `dlsym`, so the app builds and runs without the runtime.

- `scripts/fetch-ios-python.sh` (XcodeGen `preGenCommand`) downloads the pinned BeeWare Python-Apple-support package.
- `scripts/embed-ios-python.sh` (build phase) puts the interpreter, the extension modules (one framework each) and the
  trimmed standard library into the app.
- `STV/TVBox/Engine/Python/PythonRuntime.swift` is the Swift side: threads, timeouts, errors.

`idj_python.c` mirrors a few CPython 3.13 structs (`PyConfig`, `PyModuleDef`, `PyMethodDef`; 64-bit, with GIL). The version,
the size of `PyConfig` and its default values are checked before the interpreter starts; any other version is refused. When
moving to another minor version, update the mirror, `check_version`, the `python3.13` paths in the two scripts and in
`PythonRuntime.swift`.

Scripts see the built-in module `_idj_host`: `call(name, args_json)`, `get_key()`, `set_key(key)`, `Interrupted` (raised in a
script that exceeded its time limit). Threads started with `threading` inherit the key. `print` goes to the host `log`.
