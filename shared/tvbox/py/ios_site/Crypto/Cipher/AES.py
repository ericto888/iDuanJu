"""AES (original implementation for i短剧, GPL-3.0)."""

from . import _modes
from ._modes import (
    MODE_CBC, MODE_CCM, MODE_CFB, MODE_CTR, MODE_EAX, MODE_ECB, MODE_GCM, MODE_KW, MODE_KWP, MODE_OCB, MODE_OFB,
    MODE_OPENPGP, MODE_SIV,
)

block_size = 16
key_size = (16, 24, 32)


def new(key, mode, *args, **kwargs):
    """new(key, mode[, iv or nonce], …) -> cipher object."""
    key = _modes.to_bytes(key, "key")
    if len(key) not in key_size:
        raise ValueError("Incorrect AES key length (%d bytes)" % len(key))
    cipher = _modes.create(_modes.BlockPrimitive("aes", key, block_size), mode, args, dict(kwargs))
    cipher.key_size = len(key)
    return cipher
