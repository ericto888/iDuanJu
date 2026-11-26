# QuickJS (vendored) + idj sandbox

- `Sources/CQuickJS/*.c|h` except `idj_sandbox.*`: quickjs-ng **v0.10.1** (commit `3c9afc9`), unmodified, MIT — see `LICENSE-quickjs-ng.txt`.
- `idj_sandbox.c` / `include/idj_sandbox.h`: i短剧 plugin sandbox. One `JSRuntime` per plugin (own heap, memory cap,
  stack cap, interrupt deadline). The sandbox context is created **without** the Eval intrinsic, so `eval`, `new Function`,
  `AsyncFunction`/`GeneratorFunction` constructors all throw "eval is not supported". Plugin source is compiled in a
  throw-away compiler context, serialized to bytecode and loaded into the sandbox context. No module loader is installed,
  so `import` of anything fails. The only native entry point is `__host(name, argsJSON)`, captured by the trusted prelude
  and deleted from the global object before plugin code runs.
- `idj_tv_*` in the same files: TVBox spiders (shared/tvbox/HOST_ABI.md), unrelated to the sandbox. A full context per spider
  with eval, an ES-module loader supplied by the app, `__tv(name, argsJSON)`, memory / stack caps and a stop flag that any
  thread may set. Only code of a config the user trusts runs there.
