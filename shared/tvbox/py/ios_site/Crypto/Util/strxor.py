"""XOR of byte strings (original implementation for i短剧, GPL-3.0)."""


def strxor(term1, term2, output=None):
    if len(term1) != len(term2):
        raise ValueError("Only byte strings of equal length can be xored")
    result = (int.from_bytes(term1, "big") ^ int.from_bytes(term2, "big")).to_bytes(len(term1), "big")
    if output is None:
        return result
    output[:] = result
    return None


def strxor_c(term, c, output=None):
    if not 0 <= c < 256:
        raise ValueError("c must be in range(256)")
    result = bytes(b ^ c for b in term)
    if output is None:
        return result
    output[:] = result
    return None
