"""Hash objects over hashlib, or over the host where hashlib lacks an algorithm (original, GPL-3.0)."""

from __future__ import annotations

_HOST = ("md5", "sha1", "sha256", "sha512")


class _HostDigest:
    """hashlib-like object that hashes in the host."""

    def __init__(self, name, data=b""):
        self._name = name
        self._data = bytearray(data)

    def update(self, data):
        self._data += data

    def digest(self):
        from _idj_bridge import b64e, call

        return bytes.fromhex(call("hash", alg=self._name, b64=b64e(self._data)))

    def copy(self):
        return _HostDigest(self._name, self._data)


def engine(name):
    """Fresh hashlib-like object."""
    try:
        import hashlib

        return getattr(hashlib, name)()
    except (ImportError, AttributeError, ValueError):
        if name not in _HOST:
            raise NotImplementedError("Crypto（iOS 版）不支持哈希算法 %s" % name) from None
        return _HostDigest(name)


def check(data):
    if isinstance(data, (bytes, bytearray, memoryview)):
        return bytes(data)
    raise TypeError("Object type %s cannot be passed to C code" % type(data))


class HashObject:
    """One running hash; subclasses fix the algorithm."""

    algorithm = ""
    digest_size = 0
    block_size = 64
    oid = ""
    name = ""

    def __init__(self, data=None, _state=None):
        self._state = engine(self.algorithm) if _state is None else _state
        if data:
            self.update(data)

    def update(self, data):
        self._state.update(check(data))

    def digest(self):
        return self._state.digest()

    def hexdigest(self):
        return self.digest().hex()

    def copy(self):
        return type(self)(_state=self._state.copy())

    def new(self, data=None):
        return type(self)(data)


def define(module, name, algorithm, digest_size, block_size, oid):
    """Fill a Crypto.Hash module namespace."""
    cls = type(name + "Hash", (HashObject,), {
        "algorithm": algorithm, "digest_size": digest_size, "block_size": block_size, "oid": oid, "name": name,
        "__module__": module["__name__"], "__doc__": name + " hash object",
    })

    def new(data=None, truncate=None):
        if truncate:
            raise NotImplementedError("Crypto（iOS 版）不支持截断的 %s" % name)
        return cls(data)

    new.__module__ = module["__name__"]
    module.update({
        cls.__name__: cls, "new": new, "digest_size": digest_size, "block_size": block_size, "oid": oid,
    })
