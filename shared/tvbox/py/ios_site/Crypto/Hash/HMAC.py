"""HMAC (original implementation for i短剧, GPL-3.0)."""

from ._base import check


class HMAC:
    def __init__(self, key, msg=b"", digestmod=None, _parts=None):
        if digestmod is None:
            from . import MD5 as digestmod
        self._digestmod = digestmod
        if _parts is not None:
            self._inner, self._outer, self.digest_size = _parts
            return
        key = check(key)
        size = digestmod.block_size
        if len(key) > size:
            key = digestmod.new(key).digest()
        key = key.ljust(size, b"\x00")
        self._inner = digestmod.new(bytes(b ^ 0x36 for b in key))
        self._outer = digestmod.new(bytes(b ^ 0x5C for b in key))
        self.digest_size = digestmod.digest_size
        if msg:
            self.update(msg)

    def update(self, msg):
        self._inner.update(check(msg))
        return self

    def copy(self):
        return HMAC(b"", digestmod=self._digestmod, _parts=(self._inner.copy(), self._outer.copy(), self.digest_size))

    def digest(self):
        outer = self._outer.copy()
        outer.update(self._inner.digest())
        return outer.digest()

    def hexdigest(self):
        return self.digest().hex()

    def verify(self, mac_tag):
        from hmac import compare_digest

        if not compare_digest(self.digest(), check(mac_tag)):
            raise ValueError("MAC check failed")

    def hexverify(self, hex_mac_tag):
        self.verify(bytes.fromhex(hex_mac_tag))


def new(key, msg=b"", digestmod=None):
    return HMAC(key, msg, digestmod)
