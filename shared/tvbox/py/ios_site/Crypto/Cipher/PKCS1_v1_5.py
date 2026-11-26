"""RSAES-PKCS1-v1_5 (original implementation for i短剧, GPL-3.0)."""

from os import urandom

from ._modes import to_bytes


def _nonzero(count, source):
    out = b""
    while len(out) < count:
        out += source(count - len(out)).replace(b"\x00", b"")
    return out


class PKCS115_Cipher:
    def __init__(self, key, randfunc=None):
        self._key = key
        self._randfunc = randfunc or urandom

    def can_encrypt(self):
        return self._key.can_encrypt()

    def can_decrypt(self):
        return self._key.can_decrypt()

    def encrypt(self, message):
        message = to_bytes(message)
        k = self._key.size_in_bytes()
        if len(message) > k - 11:
            raise ValueError("Plaintext is too long.")
        block = b"\x00\x02" + _nonzero(k - len(message) - 3, self._randfunc) + b"\x00" + message
        return self._key._public(int.from_bytes(block, "big")).to_bytes(k, "big")

    def decrypt(self, ciphertext, sentinel, expected_pt_len=0):
        """Plaintext, or `sentinel` when the padding is wrong."""
        ciphertext = to_bytes(ciphertext)
        k = self._key.size_in_bytes()
        if len(ciphertext) != k:
            raise ValueError("Ciphertext with incorrect length (not %d bytes)" % k)
        block = self._key._private(int.from_bytes(ciphertext, "big")).to_bytes(k, "big")
        end = block.find(b"\x00", 2)
        if block[:2] != b"\x00\x02" or end < 10 or (expected_pt_len and k - end - 1 != expected_pt_len):
            return sentinel
        return block[end + 1:]


def new(key, randfunc=None):
    return PKCS115_Cipher(key, randfunc)
