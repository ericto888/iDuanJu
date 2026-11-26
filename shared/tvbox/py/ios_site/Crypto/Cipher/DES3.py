"""Triple DES (original implementation for i短剧, GPL-3.0)."""

from . import _modes
from ._modes import MODE_CBC, MODE_CFB, MODE_CTR, MODE_EAX, MODE_ECB, MODE_OFB, MODE_OPENPGP

block_size = 8
key_size = (16, 24)


def adjust_key_parity(key_in):
    """Set the parity bit of every key byte; rejects keys that degenerate to single DES."""
    key_in = _modes.to_bytes(key_in, "key")
    if len(key_in) not in key_size:
        raise ValueError("Not a valid TDES key")
    out = bytes((b & 0xFE) | (bin(b >> 1).count("1") % 2 ^ 1) for b in key_in)
    if out[:8] == out[8:16] or out[-16:-8] == out[-8:]:
        raise ValueError("Triple DES key degenerates to single DES")
    return out


def new(key, mode, *args, **kwargs):
    key = adjust_key_parity(key)
    # Two-key form: K1 K2 K1.
    full = key + key[:8] if len(key) == 16 else key
    return _modes.create(_modes.BlockPrimitive("3des", full, block_size), mode, args, dict(kwargs))
