"""Small pure-Python reference ciphers for the fake host (tests only, GPL-3.0). Slow and not side-channel safe."""

# --- AES ------------------------------------------------------------------------------------------------------------


def _xtime(a):
    a <<= 1
    return (a ^ 0x11B) if a & 0x100 else a


def _mul(a, b):
    out = 0
    while b:
        if b & 1:
            out ^= a
        a = _xtime(a)
        b >>= 1
    return out


def _make_sbox():
    sbox = [0] * 256
    p = q = 1
    while True:
        p = p ^ _xtime(p)  # multiply by 3
        q ^= q << 1  # divide by 3
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ (q << 1 | q >> 7) ^ (q << 2 | q >> 6) ^ (q << 3 | q >> 5) ^ (q << 4 | q >> 4)
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    sbox[0] = 0x63
    return sbox


_SBOX = _make_sbox()
_INV = [0] * 256
for _i, _v in enumerate(_SBOX):
    _INV[_v] = _i
_M = {k: [_mul(x, k) for x in range(256)] for k in (2, 3, 9, 11, 13, 14)}


class AES:
    block_size = 16

    def __init__(self, key):
        nk = len(key) // 4
        assert nk in (4, 6, 8)
        self.rounds = nk + 6
        words = [list(key[4 * i:4 * i + 4]) for i in range(nk)]
        rcon = 1
        for i in range(nk, 4 * (self.rounds + 1)):
            word = list(words[i - 1])
            if i % nk == 0:
                word = [_SBOX[b] for b in word[1:] + word[:1]]
                word[0] ^= rcon
                rcon = _xtime(rcon)
            elif nk > 6 and i % nk == 4:
                word = [_SBOX[b] for b in word]
            words.append([a ^ b for a, b in zip(words[i - nk], word)])
        self.keys = [sum(words[4 * r:4 * r + 4], []) for r in range(self.rounds + 1)]

    def encrypt(self, block):
        s = [a ^ b for a, b in zip(block, self.keys[0])]
        for r in range(1, self.rounds + 1):
            s = [_SBOX[s[(i + 4 * (i % 4)) % 16]] for i in range(16)]
            if r < self.rounds:
                out = []
                for c in range(0, 16, 4):
                    a, b, d, e = s[c:c + 4]
                    out += [
                        _M[2][a] ^ _M[3][b] ^ d ^ e, a ^ _M[2][b] ^ _M[3][d] ^ e, a ^ b ^ _M[2][d] ^ _M[3][e],
                        _M[3][a] ^ b ^ d ^ _M[2][e],
                    ]
                s = out
            s = [a ^ b for a, b in zip(s, self.keys[r])]
        return bytes(s)

    def decrypt(self, block):
        s = [a ^ b for a, b in zip(block, self.keys[self.rounds])]
        for r in range(self.rounds - 1, -1, -1):
            s = [_INV[s[(i - 4 * (i % 4)) % 16]] for i in range(16)]
            s = [a ^ b for a, b in zip(s, self.keys[r])]
            if r:
                out = []
                for c in range(0, 16, 4):
                    a, b, d, e = s[c:c + 4]
                    out += [
                        _M[14][a] ^ _M[11][b] ^ _M[13][d] ^ _M[9][e], _M[9][a] ^ _M[14][b] ^ _M[11][d] ^ _M[13][e],
                        _M[13][a] ^ _M[9][b] ^ _M[14][d] ^ _M[11][e], _M[11][a] ^ _M[13][b] ^ _M[9][d] ^ _M[14][e],
                    ]
                s = out
        return bytes(s)


# --- DES ------------------------------------------------------------------------------------------------------------

_IP = [58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32,
       24, 16, 8, 57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55,
       47, 39, 31, 23, 15, 7]
_FP = [40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53,
       21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1,
       41, 9, 49, 17, 57, 25]
_E = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21,
      22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1]
_P = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4,
      25]
_PC1 = [57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36, 63,
        55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4]
_PC2 = [14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2, 41, 52, 31, 37, 47, 55,
        30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32]
_SHIFTS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
_SBOXES = [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1,
     14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14,
     7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6,
     4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6,
     9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2,
     1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14,
     15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4,
     11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11,
     4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
]


def _bits(data):
    return [(byte >> (7 - i)) & 1 for byte in data for i in range(8)]


def _bytes(bits):
    return bytes(sum(b << (7 - j) for j, b in enumerate(bits[i:i + 8])) for i in range(0, len(bits), 8))


class DES:
    block_size = 8

    def __init__(self, key):
        bits = [_bits(key)[i - 1] for i in _PC1]
        c, d = bits[:28], bits[28:]
        self.keys = []
        for shift in _SHIFTS:
            c, d = c[shift:] + c[:shift], d[shift:] + d[:shift]
            both = c + d
            self.keys.append([both[i - 1] for i in _PC2])

    def _run(self, block, keys):
        bits = _bits(block)
        bits = [bits[i - 1] for i in _IP]
        left, right = bits[:32], bits[32:]
        for key in keys:
            mixed = [right[i - 1] ^ k for i, k in zip(_E, key)]
            out = []
            for n in range(8):
                six = mixed[6 * n:6 * n + 6]
                row, col = six[0] * 2 + six[5], six[1] * 8 + six[2] * 4 + six[3] * 2 + six[4]
                value = _SBOXES[n][row * 16 + col]
                out += [(value >> (3 - j)) & 1 for j in range(4)]
            out = [out[i - 1] for i in _P]
            left, right = right, [a ^ b for a, b in zip(left, out)]
        both = right + left
        return _bytes([both[i - 1] for i in _FP])

    def encrypt(self, block):
        return self._run(block, self.keys)

    def decrypt(self, block):
        return self._run(block, self.keys[::-1])


class DES3:
    block_size = 8

    def __init__(self, key):
        if len(key) == 16:
            key += key[:8]
        assert len(key) == 24
        self.parts = [DES(key[i:i + 8]) for i in (0, 8, 16)]

    def encrypt(self, block):
        a, b, c = self.parts
        return c.encrypt(b.decrypt(a.encrypt(block)))

    def decrypt(self, block):
        a, b, c = self.parts
        return a.decrypt(b.encrypt(c.decrypt(block)))


# --- modes ----------------------------------------------------------------------------------------------------------


def xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b))


def _blocks(data, size):
    return [data[i:i + size] for i in range(0, len(data), size)]


def gf_mult(x, y):
    """Bitwise GCM multiplication (independent of the table version under test)."""
    z = 0
    for i in range(127, -1, -1):
        if (x >> i) & 1:
            z ^= y
        y = (y >> 1) ^ (0xE1 << 120) if y & 1 else y >> 1
    return z


def ghash(h, data):
    y = 0
    for block in _blocks(data, 16):
        y = gf_mult(y ^ int.from_bytes(block, "big"), h)
    return y


def _pad16(data):
    return data + bytes(-len(data) % 16)


def gcm(core, encrypt, data, iv, aad=b""):
    h = int.from_bytes(core.encrypt(bytes(16)), "big")
    if len(iv) == 12:
        j0 = iv + b"\x00\x00\x00\x01"
    else:
        j0 = ghash(h, _pad16(iv) + bytes(8) + (8 * len(iv)).to_bytes(8, "big")).to_bytes(16, "big")
    if not encrypt:
        data, tag = data[:-16], data[-16:]
    count = int.from_bytes(j0[12:], "big")
    out = []
    for i, block in enumerate(_blocks(data, 16)):
        counter = j0[:12] + ((count + 1 + i) & 0xFFFFFFFF).to_bytes(4, "big")
        out.append(xor(block, core.encrypt(counter)))
    out = b"".join(out)
    cipher = out if encrypt else data
    s = ghash(h, _pad16(aad) + _pad16(cipher) + (8 * len(aad)).to_bytes(8, "big") + (8 * len(cipher)).to_bytes(8, "big"))
    mine = xor(s.to_bytes(16, "big"), core.encrypt(j0))
    if encrypt:
        return out + mine
    if mine != tag:
        raise ValueError("GCM 校验失败")
    return out


def rc4(key, data):
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) & 255
        s[i], s[j] = s[j], s[i]
    i = j = 0
    out = bytearray()
    for byte in data:
        i = (i + 1) & 255
        j = (j + s[i]) & 255
        s[i], s[j] = s[j], s[i]
        out.append(byte ^ s[(s[i] + s[j]) & 255])
    return bytes(out)


_CORES = {"aes": AES, "des": DES, "3des": DES3}


def cipher(alg, mode, pad, encrypt, key, iv, data, aad=b""):
    """The host's `cipher` function."""
    if alg == "rc4":
        return rc4(key, data)
    core = _CORES[alg](key)
    size = core.block_size
    if mode == "gcm":
        return gcm(core, encrypt, data, iv, aad)
    if mode in ("cbc", "cfb", "cfb8", "ofb", "ctr") and len(iv or b"") != size:
        raise ValueError("IV 长度错误: %d" % len(iv or b""))
    if encrypt and mode in ("ecb", "cbc"):
        if pad == "pkcs7":
            n = size - len(data) % size
            data += bytes([n]) * n
        elif pad == "zero":
            data += bytes(-len(data) % size)
        if len(data) % size:
            raise ValueError("数据长度不是分组的整数倍")
    out = []
    if mode == "ecb":
        out = [core.encrypt(b) if encrypt else core.decrypt(b) for b in _blocks(data, size)]
    elif mode == "cbc":
        last = iv
        for block in _blocks(data, size):
            if encrypt:
                last = core.encrypt(xor(block, last))
                out.append(last)
            else:
                out.append(xor(core.decrypt(block), last))
                last = block
    elif mode == "cfb":
        last = iv
        for block in _blocks(data, size):
            mixed = xor(block, core.encrypt(last))
            out.append(mixed)
            last = mixed if encrypt else block
    elif mode == "cfb8":
        register = iv
        for byte in data:
            mixed = byte ^ core.encrypt(register)[0]
            out.append(bytes([mixed]))
            register = register[1:] + bytes([mixed if encrypt else byte])
    elif mode == "ofb":
        last = iv
        for block in _blocks(data, size):
            last = core.encrypt(last)
            out.append(xor(block, last))
    elif mode == "ctr":
        count = int.from_bytes(iv, "big")
        for block in _blocks(data, size):
            out.append(xor(block, core.encrypt((count % (1 << (8 * size))).to_bytes(size, "big"))))
            count += 1
    else:
        raise ValueError("未知模式 " + mode)
    result = b"".join(out)
    if not encrypt and mode in ("ecb", "cbc") and pad == "pkcs7" and result:
        result = result[:-result[-1]]
    return result


# --- RSA ------------------------------------------------------------------------------------------------------------


def _is_prime(n, rounds=24):
    import random

    if n < 2:
        return False
    for p in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37):
        if n % p == 0:
            return n == p
    d, s = n - 1, 0
    while d % 2 == 0:
        d //= 2
        s += 1
    for _ in range(rounds):
        x = pow(random.randrange(2, n - 1), d, n)
        if x in (1, n - 1):
            continue
        for _ in range(s - 1):
            x = x * x % n
            if x == n - 1:
                break
        else:
            return False
    return True


def _prime(bits, e):
    import secrets

    while True:
        p = secrets.randbits(bits) | (3 << (bits - 2)) | 1
        if (p - 1) % e and _is_prime(p):
            return p


def _der(tag, content):
    size = len(content)
    if size < 128:
        return bytes([tag, size]) + content
    raw = size.to_bytes((size.bit_length() + 7) // 8, "big")
    return bytes([tag, 0x80 | len(raw)]) + raw + content


def _der_int(value):
    return _der(2, value.to_bytes(value.bit_length() // 8 + 1, "big"))


def _pem(der, label):
    import base64

    text = base64.b64encode(der).decode()
    body = "\n".join(text[i:i + 64] for i in range(0, len(text), 64))
    return "-----BEGIN %s-----\n%s\n-----END %s-----\n" % (label, body, label)


def rsa_generate(bits):
    e = 65537
    while True:
        p, q = _prime(bits // 2, e), _prime(bits - bits // 2, e)
        if p != q and (p * q).bit_length() == bits:
            break
    n, d = p * q, pow(e, -1, (p - 1) * (q - 1))
    algorithm = _der(0x30, bytes.fromhex("06092a864886f70d010101") + b"\x05\x00")
    private = _der(0x30, b"".join(_der_int(v) for v in (
        0, n, e, d, p, q, d % (p - 1), d % (q - 1), pow(q, -1, p))))
    pkcs8 = _der(0x30, _der_int(0) + algorithm + _der(4, private))
    spki = _der(0x30, algorithm + _der(3, b"\x00" + _der(0x30, _der_int(n) + _der_int(e))))
    return {"private": _pem(pkcs8, "PRIVATE KEY"), "public": _pem(spki, "PUBLIC KEY")}
