"""Runs every test against the shims and a fake `_idj_host` (i短剧, GPL-3.0).

    python -I shared/tvbox/py/ios_site/tests/run_tests.py [-v] [test_module ...]
"""

import os
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [os.path.dirname(HERE), HERE]


def main(argv):
    import unittest
    import warnings

    import fake_host  # noqa: F401  (registers _idj_host before any shim is imported)

    warnings.simplefilter("error", SyntaxWarning)
    verbosity = 2 if "-v" in argv else 1
    names = [a for a in argv if not a.startswith("-")]
    loader = unittest.TestLoader()
    if names:
        suite = loader.loadTestsFromNames(names)
    else:
        suite = loader.discover(HERE, pattern="test_*.py", top_level_dir=HERE)
    result = unittest.TextTestRunner(verbosity=verbosity).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main(sys.argv[1:]))
