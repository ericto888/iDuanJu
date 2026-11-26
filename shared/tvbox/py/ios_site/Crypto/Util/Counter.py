"""Counter description for CTR mode (original implementation for i短剧, GPL-3.0)."""


def new(nbits, prefix=b"", suffix=b"", initial_value=1, little_endian=False, allow_wraparound=False):
    if nbits % 8:
        raise ValueError("'nbits' must be a multiple of 8")
    return {
        "counter_len": nbits // 8, "prefix": bytes(prefix), "suffix": bytes(suffix), "initial_value": initial_value,
        "little_endian": little_endian,
    }
