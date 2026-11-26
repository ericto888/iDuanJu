"""PBKDF1 and PBKDF2 (original implementation for i短剧, GPL-3.0)."""

from ..Hash import HMAC


def _bytes(value):
    return value.encode("utf-8") if isinstance(value, str) else bytes(value)


def PBKDF1(password, salt, dkLen, count=1000, hashAlgo=None):
    if hashAlgo is None:
        from ..Hash import SHA1 as hashAlgo
    if len(salt) != 8:
        raise ValueError("Salt is not 8 bytes long (%d bytes instead)." % len(salt))
    value = hashAlgo.new(_bytes(password) + bytes(salt)).digest()
    if dkLen > len(value):
        raise TypeError("Selected hash algorithm has a too short digest (%d bytes)." % len(value))
    for _ in range(count - 1):
        value = hashAlgo.new(value).digest()
    return value[:dkLen]


def PBKDF2(password, salt, dkLen=16, count=1000, prf=None, hmac_hash_module=None):
    password, salt = _bytes(password), _bytes(salt)
    if prf is not None and hmac_hash_module is not None:
        raise ValueError("'prf' and 'hmac_hash_module' are mutually exlusive")
    if prf is None:
        if hmac_hash_module is None:
            from ..Hash import SHA1 as hmac_hash_module
        base = HMAC.new(password, digestmod=hmac_hash_module)

        def prf(_, data):
            mac = base.copy()
            mac.update(data)
            return mac.digest()

    out, index = b"", 1
    while len(out) < dkLen:
        block = prf(password, salt + index.to_bytes(4, "big"))
        total = int.from_bytes(block, "big")
        for _ in range(count - 1):
            block = prf(password, block)
            total ^= int.from_bytes(block, "big")
        out += total.to_bytes(len(block), "big")
        index += 1
    return out[:dkLen]


def scrypt(*args, **kwargs):
    raise NotImplementedError("Crypto（iOS 版）不支持 scrypt")


def HKDF(*args, **kwargs):
    raise NotImplementedError("Crypto（iOS 版）不支持 HKDF")


def bcrypt(*args, **kwargs):
    raise NotImplementedError("Crypto（iOS 版）不支持 bcrypt")
