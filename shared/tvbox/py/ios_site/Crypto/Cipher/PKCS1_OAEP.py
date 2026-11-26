"""RSAES-OAEP (original implementation for i短剧, GPL-3.0)."""

from os import urandom

from ._modes import to_bytes, xor


def _digest(algo, data):
    return algo.new(data).digest()


def _size(algo):
    size = getattr(algo, "digest_size", None)
    return size if isinstance(size, int) else len(algo.new().digest())


def mgf1(seed, length, algo):
    out = b""
    counter = 0
    while len(out) < length:
        out += _digest(algo, seed + counter.to_bytes(4, "big"))
        counter += 1
    return out[:length]


class PKCS1OAEP_Cipher:
    def __init__(self, key, hashAlgo=None, mgfunc=None, label=b"", randfunc=None):
        if hashAlgo is None:
            from ..Hash import SHA1 as hashAlgo
        self._key = key
        self._hashObj = hashAlgo
        self._mgf = mgfunc or (lambda seed, length: mgf1(seed, length, hashAlgo))
        self._label = to_bytes(label)
        self._randfunc = randfunc or urandom

    def can_encrypt(self):
        return self._key.can_encrypt()

    def can_decrypt(self):
        return self._key.can_decrypt()

    def encrypt(self, message):
        message = to_bytes(message)
        k, h = self._key.size_in_bytes(), _size(self._hashObj)
        gap = k - len(message) - 2 * h - 2
        if gap < 0:
            raise ValueError("Plaintext is too long.")
        block = _digest(self._hashObj, self._label) + bytes(gap) + b"\x01" + message
        seed = self._randfunc(h)
        masked = xor(block, self._mgf(seed, k - h - 1))
        masked_seed = xor(seed, self._mgf(masked, h))
        number = int.from_bytes(b"\x00" + masked_seed + masked, "big")
        return self._key._public(number).to_bytes(k, "big")

    def decrypt(self, ciphertext):
        ciphertext = to_bytes(ciphertext)
        k, h = self._key.size_in_bytes(), _size(self._hashObj)
        if len(ciphertext) != k or k < h + 2:
            raise ValueError("Ciphertext with incorrect length.")
        block = self._key._private(int.from_bytes(ciphertext, "big")).to_bytes(k, "big")
        masked_seed, masked = block[1:h + 1], block[h + 1:]
        seed = xor(masked_seed, self._mgf(masked, h))
        data = xor(masked, self._mgf(seed, k - h - 1))
        one = data.find(b"\x01", h)
        if block[0] or data[:h] != _digest(self._hashObj, self._label) or one < 0 or data[h:one].strip(b"\x00"):
            raise ValueError("Incorrect decryption.")
        return data[one + 1:]


def new(key, hashAlgo=None, mgfunc=None, label=b"", randfunc=None):
    return PKCS1OAEP_Cipher(key, hashAlgo, mgfunc, label, randfunc)
