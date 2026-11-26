"""Alias of the `Crypto` package under its other PyPI name (i短剧, GPL-3.0)."""

import Crypto as _crypto

# Submodules are found in the Crypto directory; they only use relative imports, so each name is self-consistent.
__path__ = list(_crypto.__path__)
__all__ = _crypto.__all__
__version__ = _crypto.__version__
version_info = _crypto.version_info
