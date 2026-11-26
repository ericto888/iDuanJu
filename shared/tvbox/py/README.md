# Python spider libraries

Bundled into both apps as `tvbox/py` and put on `sys.path`. Contract: `../HOST_ABI.md`.

- `idj_runner.py`: `load(key, source, ext)`, `call(key, method, args_json) -> str`, `unload(key)`
- `base/spider.py`: `Spider` base class of the scripts
- `ios_site/`: modules only iOS needs (`requests`, `lxml`, `Crypto`, … over `_idj_host`), plus the optional
  `idj_compat.install()`, which runs once right after the interpreter starts. `ios_site/tests` is not shipped.
