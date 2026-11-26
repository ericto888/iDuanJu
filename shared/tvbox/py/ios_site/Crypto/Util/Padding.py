"""Block padding (original implementation for i短剧, GPL-3.0)."""

__all__ = ["pad", "unpad"]


def pad(data_to_pad, block_size, style="pkcs7"):
    size = block_size - len(data_to_pad) % block_size
    if style == "pkcs7":
        tail = bytes((size,)) * size
    elif style == "x923":
        tail = bytes(size - 1) + bytes((size,))
    elif style == "iso7816":
        tail = b"\x80" + bytes(size - 1)
    else:
        raise ValueError("Unknown padding style")
    return data_to_pad + tail


def unpad(padded_data, block_size, style="pkcs7"):
    length = len(padded_data)
    if length == 0:
        raise ValueError("Zero-length input cannot be unpadded")
    if length % block_size:
        raise ValueError("Input data is not padded")
    if style in ("pkcs7", "x923"):
        size = padded_data[-1]
        if size < 1 or size > min(block_size, length):
            raise ValueError("Padding is incorrect.")
        if style == "pkcs7":
            if padded_data[-size:] != bytes((size,)) * size:
                raise ValueError("PKCS#7 padding is incorrect.")
        elif padded_data[-size:-1] != bytes(size - 1):
            raise ValueError("ANSI X.923 padding is incorrect.")
    elif style == "iso7816":
        size = length - bytes(padded_data).rfind(b"\x80")
        if size < 1 or size > min(block_size, length):
            raise ValueError("Padding is incorrect.")
        if size > 1 and padded_data[1 - size:] != bytes(size - 1):
            raise ValueError("ISO 7816-4 padding is incorrect.")
    else:
        raise ValueError("Unknown padding style")
    return padded_data[:-size]
