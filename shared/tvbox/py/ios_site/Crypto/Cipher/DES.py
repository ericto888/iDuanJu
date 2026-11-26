"""DES (original implementation for i短剧, GPL-3.0)."""

from . import _modes
from ._modes import MODE_CBC, MODE_CFB, MODE_CTR, MODE_EAX, MODE_ECB, MODE_OFB, MODE_OPENPGP

block_size = 8
key_size = 8


def new(key, mode, *args, **kwargs):
    key = _modes.to_bytes(key, "key")
    if len(key) != key_size:
        raise ValueError("Incorrect DES key length (%d bytes)" % len(key))
    return _modes.create(_modes.BlockPrimitive("des", key, block_size), mode, args, dict(kwargs))
