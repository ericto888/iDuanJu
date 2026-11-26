"""CA bundle location; certificates are checked by the host (original implementation for i短剧, GPL-3.0)."""

from certifi import where

__all__ = ["where"]
