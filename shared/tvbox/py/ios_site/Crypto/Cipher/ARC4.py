"""RC4 stream cipher in Python, because its state has to continue across calls (original, GPL-3.0)."""

from ._modes import _emit, to_bytes, xor

block_size = 1
key_size = range(1, 257)


class ARC4Cipher:
    def __init__(self, key, *args, **kwargs):
        if args:
            ndrop = args[0]
            args = args[1:]
        else:
            ndrop = kwargs.pop("drop", 0)
        if args or kwargs:
            raise TypeError("Unknown parameters for ARC4")
        key = to_bytes(key, "key")
        if len(key) not in key_size:
            raise ValueError("Incorrect ARC4 key length (%d bytes)" % len(key))
        self.block_size = 1
        self.key_size = len(key)
        state = list(range(256))
        j, size = 0, len(key)
        for i in range(256):
            j = (j + state[i] + key[i % size]) & 255
            state[i], state[j] = state[j], state[i]
        self._state, self._i, self._j = state, 0, 0
        if ndrop:
            self._stream(ndrop)

    def _stream(self, count):
        state, i, j = self._state, self._i, self._j
        out = bytearray(count)
        for at in range(count):
            i = (i + 1) & 255
            a = state[i]
            j = (j + a) & 255
            b = state[j]
            state[i], state[j] = b, a
            out[at] = state[(a + b) & 255]
        self._i, self._j = i, j
        return bytes(out)

    def encrypt(self, plaintext, output=None):
        data = to_bytes(plaintext)
        return _emit(xor(data, self._stream(len(data))), output)

    def decrypt(self, ciphertext, output=None):
        return self.encrypt(ciphertext, output)


def new(key, *args, **kwargs):
    return ARC4Cipher(key, *args, **kwargs)
