"""RSASSA-PKCS1-v1_5 (original implementation for i短剧, GPL-3.0)."""


def _oid_der(dotted):
    numbers = [int(x) for x in dotted.split(".")]
    out = bytearray((numbers[0] * 40 + numbers[1],))
    for number in numbers[2:]:
        chunk = [number & 0x7F]
        number >>= 7
        while number:
            chunk.append(0x80 | (number & 0x7F))
            number >>= 7
        out += bytes(reversed(chunk))
    return bytes((0x06, len(out))) + bytes(out)


def _encode(msg_hash, size, with_null=True):
    digest = msg_hash.digest()
    algorithm = _oid_der(msg_hash.oid) + (b"\x05\x00" if with_null else b"")
    info = bytes((0x30, len(algorithm))) + algorithm + bytes((0x04, len(digest))) + digest
    info = bytes((0x30, len(info))) + info
    if size < len(info) + 11:
        raise TypeError("Selected hash algorithm has a too long digest (%d bytes)." % len(digest))
    return b"\x00\x01" + b"\xff" * (size - len(info) - 3) + b"\x00" + info


class PKCS115_SigScheme:
    def __init__(self, rsa_key):
        self._key = rsa_key

    def can_sign(self):
        return self._key.has_private()

    def sign(self, msg_hash):
        size = self._key.size_in_bytes()
        block = _encode(msg_hash, size)
        return self._key._private(int.from_bytes(block, "big")).to_bytes(size, "big")

    def verify(self, msg_hash, signature):
        """Returns None; raises ValueError when the signature is wrong."""
        size = self._key.size_in_bytes()
        signature = bytes(signature)
        if len(signature) != size:
            raise ValueError("Invalid signature")
        number = int.from_bytes(signature, "big")
        if number >= self._key.n:
            raise ValueError("Invalid signature")
        block = self._key._public(number).to_bytes(size, "big")
        if block != _encode(msg_hash, size) and block != _encode(msg_hash, size, with_null=False):
            raise ValueError("Invalid signature")


def new(rsa_key):
    return PKCS115_SigScheme(rsa_key)
