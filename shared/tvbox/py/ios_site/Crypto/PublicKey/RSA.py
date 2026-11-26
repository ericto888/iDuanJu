"""RSA keys (original implementation for i短剧, GPL-3.0).

Parsing, exporting and the modular arithmetic are plain Python (any key size, any key without CRT values); only key
generation is left to the host.
"""

from __future__ import annotations

import re
from binascii import Error as _B64Error
from binascii import a2b_base64, b2a_base64
from math import gcd

_OID_RSA = bytes.fromhex("2a864886f70d010101")
_OID_PSS = bytes.fromhex("2a864886f70d01010a")


# --- minimal DER ----------------------------------------------------------------------------------------------------


class _Der:
    """Reader over DER bytes."""

    def __init__(self, data):
        self.data = data
        self.pos = 0

    def more(self):
        return self.pos < len(self.data)

    def next(self, *expected):
        """(tag, content bytes) of the next element."""
        data, pos = self.data, self.pos
        if pos + 2 > len(data):
            raise ValueError("DER 数据不完整")
        tag, size = data[pos], data[pos + 1]
        pos += 2
        if size & 0x80:
            count = size & 0x7F
            if not 1 <= count <= 4 or pos + count > len(data):
                raise ValueError("DER 长度无效")
            size = int.from_bytes(data[pos:pos + count], "big")
            pos += count
        if pos + size > len(data):
            raise ValueError("DER 数据不完整")
        if expected and tag not in expected:
            raise ValueError("DER 结构不符")
        self.pos = pos + size
        return tag, data[pos:pos + size]

    def sequence(self):
        return _Der(self.next(0x30)[1])

    def integer(self):
        return int.from_bytes(self.next(0x02)[1], "big", signed=True)


def _tlv(tag, content):
    size = len(content)
    if size < 0x80:
        head = bytes((tag, size))
    else:
        raw = size.to_bytes((size.bit_length() + 7) // 8, "big")
        head = bytes((tag, 0x80 | len(raw))) + raw
    return head + content


def _int(value):
    return _tlv(0x02, value.to_bytes(value.bit_length() // 8 + 1, "big"))


def _seq(*parts):
    return _tlv(0x30, b"".join(parts))


_ALGORITHM = _seq(_tlv(0x06, _OID_RSA), b"\x05\x00")


# --- key object -----------------------------------------------------------------------------------------------------


def _lcm(a, b):
    return a // gcd(a, b) * b


def _factor(n, e, d):
    """p and q from n, e, d."""
    k = d * e - 1
    t, s = k, 0
    while t % 2 == 0:
        t //= 2
        s += 1
    for a in range(2, 200):
        cand = pow(a, t, n)
        for _ in range(s):
            if cand in (1, n - 1):
                break
            square = pow(cand, 2, n)
            if square == 1:
                p = gcd(cand - 1, n)
                if 1 < p < n:
                    return p, n // p
                break
            cand = square
    raise ValueError("Unable to compute factors p and q from exponent d.")


class RsaKey:
    """RSA public or private key."""

    def __init__(self, **kwargs):
        self._n = int(kwargs["n"])
        self._e = int(kwargs["e"])
        self._d = int(kwargs["d"]) if kwargs.get("d") is not None else None
        self._p = int(kwargs["p"]) if kwargs.get("p") else None
        self._q = int(kwargs["q"]) if kwargs.get("q") else None
        self._crt = None

    # -- numbers -----------------------------------------------------------------------------------------------------
    @property
    def n(self):
        return self._n

    @property
    def e(self):
        return self._e

    @property
    def d(self):
        if self._d is None:
            raise AttributeError("No private exponent available for public keys")
        return self._d

    def _primes(self):
        if self._d is None:
            raise AttributeError("No CRT component 'p' available for public keys")
        if self._p is None or self._q is None:
            self._p, self._q = _factor(self._n, self._e, self._d)
        return self._p, self._q

    @property
    def p(self):
        return self._primes()[0]

    @property
    def q(self):
        return self._primes()[1]

    @property
    def dp(self):
        return self.d % (self.p - 1)

    @property
    def dq(self):
        return self.d % (self.q - 1)

    @property
    def u(self):
        return pow(self.p, -1, self.q)

    @property
    def invp(self):
        return self.u

    @property
    def invq(self):
        return pow(self.q, -1, self.p)

    def size_in_bits(self):
        return self._n.bit_length()

    def size_in_bytes(self):
        return (self._n.bit_length() + 7) // 8

    def size(self):
        return self._n.bit_length() - 1

    # -- capabilities ------------------------------------------------------------------------------------------------
    def has_private(self):
        return self._d is not None

    def can_encrypt(self):
        return True

    def can_decrypt(self):
        return True

    def can_sign(self):
        return True

    def public_key(self):
        return RsaKey(n=self._n, e=self._e)

    publickey = public_key

    def __eq__(self, other):
        if not isinstance(other, RsaKey) or self.has_private() != other.has_private():
            return False
        return (self._n, self._e, self._d) == (other._n, other._e, other._d)

    def __ne__(self, other):
        return not self == other

    def __hash__(self):
        return hash((self._n, self._e, self._d))

    def __getstate__(self):
        from pickle import PicklingError

        raise PicklingError

    def __repr__(self):
        kind = "Private" if self.has_private() else "Public"
        return "<%s RSA key at 0x%X, %d bits>" % (kind, id(self), self.size_in_bits())

    # -- arithmetic --------------------------------------------------------------------------------------------------
    def _public(self, number):
        if not 0 <= number < self._n:
            raise ValueError("Plaintext too large")
        return pow(number, self._e, self._n)

    def _private(self, number):
        if not 0 <= number < self._n:
            raise ValueError("Ciphertext too large")
        if self._d is None:
            raise TypeError("This is not a private key")
        if self._crt is None:
            try:
                p, q = self._primes()
                self._crt = (p, q, self.dp, self.dq, pow(q, -1, p)) if p * q == self._n else ()
            except ValueError:
                self._crt = ()
        if not self._crt:
            return pow(number, self._d, self._n)
        p, q, dp, dq, inverse = self._crt
        m1, m2 = pow(number % p, dp, p), pow(number % q, dq, q)
        result = m2 + q * ((m1 - m2) * inverse % p)
        if pow(result, self._e, self._n) != number:
            # CRT values that do not belong to this key: use the plain exponent.
            self._crt = ()
            return pow(number, self._d, self._n)
        return result

    _encrypt = _public
    _decrypt = _private

    def encrypt(self, plaintext, K=None):
        raise NotImplementedError("Use module Crypto.Cipher.PKCS1_OAEP instead")

    def decrypt(self, ciphertext):
        raise NotImplementedError("Use module Crypto.Cipher.PKCS1_OAEP instead")

    def sign(self, M, K=None):
        raise NotImplementedError("Use module Crypto.Signature.pkcs1_15 instead")

    def verify(self, M, signature):
        raise NotImplementedError("Use module Crypto.Signature.pkcs1_15 instead")

    # -- export ------------------------------------------------------------------------------------------------------
    def _pkcs1_public(self):
        return _seq(_int(self._n), _int(self._e))

    def _spki(self):
        return _seq(_ALGORITHM, _tlv(0x03, b"\x00" + self._pkcs1_public()))

    def _pkcs1_private(self):
        p, q = self._primes()
        return _seq(
            _int(0), _int(self._n), _int(self._e), _int(self.d), _int(p), _int(q), _int(self.dp), _int(self.dq),
            _int(pow(q, -1, p)),
        )

    def _pkcs8(self):
        return _seq(_int(0), _ALGORITHM, _tlv(0x04, self._pkcs1_private()))

    def export_key(self, format="PEM", passphrase=None, pkcs=1, protection=None, randfunc=None, prot_params=None):
        """PEM or DER bytes; OpenSSH for public keys."""
        if passphrase is not None:
            raise NotImplementedError("Crypto（iOS 版）不支持导出加密的 RSA 私钥")
        if format == "OpenSSH":
            e = self._e.to_bytes((self._e.bit_length() + 7) // 8, "big")
            n = self._n.to_bytes((self._n.bit_length() + 7) // 8, "big")
            blob = b""
            for part in (b"ssh-rsa", e if e[0] < 0x80 else b"\x00" + e, n if n[0] < 0x80 else b"\x00" + n):
                blob += len(part).to_bytes(4, "big") + part
            return b"ssh-rsa " + b2a_base64(blob, newline=False)
        if self.has_private():
            der, label = (self._pkcs1_private(), "RSA PRIVATE KEY") if pkcs == 1 else (self._pkcs8(), "PRIVATE KEY")
        else:
            der, label = self._spki(), "PUBLIC KEY"
        if format == "DER":
            return der
        if format == "PEM":
            return _pem(der, label).encode("ascii")
        raise ValueError("Unknown key format '%s'. Cannot export the RSA key." % format)

    exportKey = export_key


def _pem(der, label):
    text = b2a_base64(der, newline=False).decode("ascii")
    lines = [text[i:i + 64] for i in range(0, len(text), 64)]
    return "-----BEGIN %s-----\n%s\n-----END %s-----" % (label, "\n".join(lines), label)


# --- import ---------------------------------------------------------------------------------------------------------


def _build(numbers):
    return construct(numbers, consistency_check=False)


def _pkcs1_private(der):
    body = _Der(der).sequence()
    if body.integer() != 0:
        raise ValueError("不支持的 RSA 私钥版本")
    n, e, d, p, q = (body.integer() for _ in range(5))
    return _build((n, e, d, p, q) if p and q else (n, e, d))


def _pkcs1_public(der):
    body = _Der(der).sequence()
    n, e = body.integer(), body.integer()
    if body.more():
        raise ValueError("DER 结构不符")
    return _build((n, e))


def _algorithm(body):
    oid = body.sequence().next(0x06)[1]
    if oid not in (_OID_RSA, _OID_PSS):
        raise ValueError("不是 RSA 密钥")


def _spki(der):
    body = _Der(der).sequence()
    _algorithm(body)
    bits = body.next(0x03)[1]
    return _pkcs1_public(bits[1:])


def _pkcs8(der):
    body = _Der(der).sequence()
    body.integer()
    _algorithm(body)
    return _pkcs1_private(body.next(0x04)[1])


def _certificate(der):
    tbs = _Der(der).sequence().sequence()
    tag, _ = tbs.next()
    if tag == 0xA0:
        tbs.next(0x02)
    for _ in range(4):  # signature, issuer, validity, subject
        tbs.next(0x30)
    return _spki(_tlv(0x30, tbs.next(0x30)[1]))


def _import_der(der):
    for reader in (_pkcs1_private, _pkcs8, _spki, _pkcs1_public, _certificate):
        try:
            return reader(der)
        except (ValueError, IndexError):
            continue
    raise ValueError("RSA key format is not supported")


def _import_openssh(text):
    blob = a2b_base64(text.split()[1])
    parts = []
    while blob:
        size = int.from_bytes(blob[:4], "big")
        parts.append(blob[4:4 + size])
        blob = blob[4 + size:]
    if len(parts) != 3 or parts[0] != b"ssh-rsa":
        raise ValueError("RSA key format is not supported")
    return _build((int.from_bytes(parts[2], "big"), int.from_bytes(parts[1], "big")))


_PEM = re.compile(rb"-----BEGIN ([A-Z0-9 ]+)-----(.*?)-----END [A-Z0-9 ]+-----", re.S)


def import_key(extern_key, passphrase=None):
    """PEM, DER, Base64 of DER or OpenSSH public key (str or bytes)."""
    if isinstance(extern_key, str):
        extern_key = extern_key.encode("utf-8")
    extern_key = bytes(extern_key)
    found = _PEM.search(extern_key)
    if found:
        label, body = found.group(1), found.group(2)
        if label == b"OPENSSH PRIVATE KEY":
            raise NotImplementedError("Crypto（iOS 版）不支持 OpenSSH 私钥")
        if b"ENCRYPTED" in label or b"Proc-Type" in body:
            raise NotImplementedError("Crypto（iOS 版）不支持加密的 RSA 私钥")
        try:
            return _import_der(a2b_base64(re.sub(rb"\s+", b"", body)))
        except _B64Error as exc:
            raise ValueError("RSA key format is not supported") from exc
    stripped = extern_key.strip()
    if stripped.startswith(b"ssh-rsa "):
        return _import_openssh(stripped.decode("ascii"))
    if extern_key[:1] == b"\x30":
        try:
            return _import_der(extern_key)
        except ValueError:
            pass
    # Bare Base64, possibly with the PEM lines stripped off by hand or escaped newlines.
    compact = re.sub(rb"\s+|\\n|-----[^-]*-----", b"", stripped)
    if compact and re.fullmatch(rb"[A-Za-z0-9+/_\-]+=*", compact):
        compact = compact.replace(b"-", b"+").replace(b"_", b"/").rstrip(b"=")
        try:
            return _import_der(a2b_base64(compact + b"=" * (-len(compact) % 4)))
        except _B64Error:
            pass
    raise ValueError("RSA key format is not supported")


importKey = import_key


def construct(rsa_components, consistency_check=True):
    """Key from (n, e), (n, e, d), (n, e, d, p, q[, u])."""
    names = ("n", "e", "d", "p", "q", "u")
    if not 2 <= len(rsa_components) <= 6 or len(rsa_components) == 4:
        raise ValueError("RSA components: (n, e[, d[, p, q[, u]]])")
    key = RsaKey(**dict(zip(names, (int(x) for x in rsa_components))))
    if consistency_check:
        if key.e <= 1 or key.e >= key.n:
            raise ValueError("Invalid RSA public exponent")
        if gcd(key.n, key.e) != 1:
            raise ValueError("RSA public exponent is not coprime to modulus")
        if not key.n & 1:
            raise ValueError("RSA modulus is not odd")
        if key.has_private():
            if not 1 < key.d < key.n:
                raise ValueError("Invalid RSA private exponent")
            if len(rsa_components) >= 5:
                if key.p * key.q != key.n:
                    raise ValueError("RSA factors do not match modulus")
                if key.d * key.e % _lcm(key.p - 1, key.q - 1) != 1:
                    raise ValueError("Invalid RSA condition")
    return key


def generate(bits, randfunc=None, e=65537):
    """New key pair made by the host."""
    if bits < 1024:
        raise ValueError("RSA modulus length must be >= 1024")
    if e != 65537:
        raise NotImplementedError("Crypto（iOS 版）生成 RSA 密钥只支持 e=65537")
    from _idj_bridge import call

    return import_key(call("rsa", op="generate", bits=bits)["private"])


oid = "1.2.840.113549.1.1.1"
