"""Block cipher modes on top of the host's `cipher` function (original implementation for i短剧, GPL-3.0).

The host is stateless; everything that has to survive between calls (chaining value, unused keystream, counters) is kept
here, so data may be fed in several pieces as with pycryptodome.
"""

from __future__ import annotations

from os import urandom

from _idj_bridge import b64d, b64e, call

MODE_ECB = 1
MODE_CBC = 2
MODE_CFB = 3
MODE_OFB = 5
MODE_CTR = 6
MODE_OPENPGP = 7
MODE_CCM = 8
MODE_EAX = 9
MODE_SIV = 10
MODE_GCM = 11
MODE_OCB = 12
MODE_KW = 13
MODE_KWP = 14

_NAMES = {
    MODE_OPENPGP: "OPENPGP", MODE_CCM: "CCM", MODE_EAX: "EAX", MODE_SIV: "SIV", MODE_OCB: "OCB", MODE_KW: "KW",
    MODE_KWP: "KWP",
}


def to_bytes(value, what="data"):
    if isinstance(value, bytes):
        return value
    if isinstance(value, (bytearray, memoryview)):
        return bytes(value)
    raise TypeError("Object type %s cannot be passed to C code (%s)" % (type(value), what))


def xor(a, b):
    size = len(a)
    if not size:
        return b""
    return (int.from_bytes(a, "big") ^ int.from_bytes(b[:size], "big")).to_bytes(size, "big")


class BlockPrimitive:
    """One keyed block cipher in the host."""

    __slots__ = ("alg", "key64", "block_size")

    def __init__(self, alg, key, block_size):
        self.alg = alg
        self.key64 = b64e(key)
        self.block_size = block_size

    def run(self, mode, encrypt, data, iv=None, **extra):
        args = {
            "alg": self.alg, "mode": mode, "pad": "none", "encrypt": encrypt, "keyB64": self.key64,
            "dataB64": b64e(data),
        }
        if iv is not None:
            args["ivB64"] = b64e(iv)
        args.update(extra)
        return b64d(call("cipher", **args))

    def blocks(self, data):
        """Raw (ECB) encryption of whole blocks."""
        return self.run("ecb", True, data) if data else b""


def _emit(result, output):
    if output is None:
        return result
    if len(output) != len(result):
        raise ValueError("output must have the same length as the input (%d bytes)" % len(result))
    output[:] = result
    return None


class _Directed:
    """Refuses to mix encrypt() and decrypt() on one object, as pycryptodome does."""

    _used = None

    def _enter(self, name):
        if self._used not in (None, name):
            other = "encrypt" if name == "decrypt" else "decrypt"
            raise TypeError("%s() cannot be called after %s()" % (name, other))
        self._used = name


class EcbMode:
    def __init__(self, primitive):
        self._primitive = primitive
        self.block_size = primitive.block_size

    def _run(self, data, encrypt, output):
        data = to_bytes(data)
        if len(data) % self.block_size:
            raise ValueError("Data must be aligned to block boundary in ECB mode")
        return _emit(self._primitive.run("ecb", encrypt, data) if data else b"", output)

    def encrypt(self, plaintext, output=None):
        return self._run(plaintext, True, output)

    def decrypt(self, ciphertext, output=None):
        return self._run(ciphertext, False, output)


class CbcMode(_Directed):
    def __init__(self, primitive, iv):
        self._primitive = primitive
        self.block_size = primitive.block_size
        self.iv = self.IV = iv
        self._last = iv

    def _run(self, name, data, output):
        self._enter(name)
        data = to_bytes(data)
        if len(data) % self.block_size:
            raise ValueError(
                "Data must be padded to %d byte boundary in CBC mode" % self.block_size
            )
        if not data:
            return _emit(b"", output)
        result = self._primitive.run("cbc", name == "encrypt", data, self._last)
        self._last = (result if name == "encrypt" else data)[-self.block_size:]
        return _emit(result, output)

    def encrypt(self, plaintext, output=None):
        return self._run("encrypt", plaintext, output)

    def decrypt(self, ciphertext, output=None):
        return self._run("decrypt", ciphertext, output)


class CfbMode(_Directed):
    """segment_size 8 and full-block segments use the host modes; other sizes are chained here block by block."""

    def __init__(self, primitive, iv, segment_size):
        block = primitive.block_size
        if segment_size % 8 or not 8 <= segment_size <= block * 8:
            raise ValueError("'segment_size' must be positive and multiple of 8 bits")
        self._primitive = primitive
        self.block_size = block
        self.iv = self.IV = iv
        self._segment = segment_size // 8
        self._register = iv

    def _run(self, name, data, output):
        self._enter(name)
        data = to_bytes(data)
        if len(data) % self._segment:
            raise ValueError("Data must be a multiple of %d bytes in CFB mode (segment_size)" % self._segment)
        if not data:
            return _emit(b"", output)
        encrypt = name == "encrypt"
        if self._segment == self.block_size or self._segment == 1:
            mode = "cfb8" if self._segment == 1 else "cfb"
            result = self._primitive.run(mode, encrypt, data, self._register)
            cipher = result if encrypt else data
            self._register = (self._register + cipher)[-self.block_size:]
            return _emit(result, output)
        out = []
        step = self._segment
        for at in range(0, len(data), step):
            piece = data[at:at + step]
            mixed = xor(piece, self._primitive.blocks(self._register))
            out.append(mixed)
            self._register = (self._register + (mixed if encrypt else piece))[-self.block_size:]
        return _emit(b"".join(out), output)

    def encrypt(self, plaintext, output=None):
        return self._run("encrypt", plaintext, output)

    def decrypt(self, ciphertext, output=None):
        return self._run("decrypt", ciphertext, output)


class _Keystream(_Directed):
    """Stream modes: XOR with a keystream whose unused tail is kept for the next call."""

    _rest = b""

    def _generate(self, blocks):
        raise NotImplementedError

    def _run(self, name, data, output):
        self._enter(name)
        return _emit(self._mix(to_bytes(data)), output)

    def _mix(self, data):
        need = len(data) - len(self._rest)
        if need > 0:
            self._rest += self._generate(-(-need // self.block_size))
        result = xor(data, self._rest)
        self._rest = self._rest[len(data):]
        return result

    def encrypt(self, plaintext, output=None):
        return self._run("encrypt", plaintext, output)

    def decrypt(self, ciphertext, output=None):
        return self._run("decrypt", ciphertext, output)


class OfbMode(_Keystream):
    def __init__(self, primitive, iv):
        self._primitive = primitive
        self.block_size = primitive.block_size
        self.iv = self.IV = iv
        self._feedback = iv

    def _generate(self, blocks):
        stream = self._primitive.run("ofb", True, bytes(blocks * self.block_size), self._feedback)
        self._feedback = stream[-self.block_size:]
        return stream


class CounterBlocks:
    """Counter layout: prefix | counter | suffix."""

    def __init__(self, width, prefix, suffix, value, little_endian=False):
        self.width, self.prefix, self.suffix = width, prefix, suffix
        self.little = little_endian
        self.limit = 1 << (8 * width)
        if value >= self.limit:
            raise ValueError("Initial counter value is too large")
        self.value = value
        self.used = 0

    def take(self, count, wrap=False):
        """Next `count` counter blocks as one byte string."""
        if not wrap and self.used + count > self.limit:
            raise OverflowError("Counter wrapped around")
        self.used += count
        order = "little" if self.little else "big"
        out = []
        for i in range(count):
            value = (self.value + i) % self.limit
            out.append(self.prefix + value.to_bytes(self.width, order) + self.suffix)
        self.value = (self.value + count) % self.limit
        return b"".join(out)


class CtrMode(_Keystream):
    def __init__(self, primitive, counter, nonce=None):
        self._primitive = primitive
        self.block_size = primitive.block_size
        self._counter = counter
        if nonce is not None:
            self.nonce = nonce

    def _generate(self, blocks):
        counter = self._counter
        if blocks > 64 and not counter.suffix and not counter.little and counter.value + blocks < counter.limit:
            # Plain big-endian counter without wrap-around: the host's CTR mode counts the same way.
            first = counter.prefix + counter.value.to_bytes(counter.width, "big")
            if counter.used + blocks > counter.limit:
                raise OverflowError("Counter wrapped around")
            counter.used += blocks
            counter.value += blocks
            return self._primitive.run("ctr", True, bytes(blocks * self.block_size), first)
        return self._primitive.blocks(counter.take(blocks))


# --- GCM ------------------------------------------------------------------------------------------------------------

_R = 0xE1000000000000000000000000000000


def _table(h):
    """h*x^0 … h*x^127 in GCM bit order, folded into 32 tables of 16 entries."""
    powers = []
    value = h
    for _ in range(128):
        powers.append(value)
        value = (value >> 1) ^ _R if value & 1 else value >> 1
    tables = []
    for nibble in range(32):
        base = powers[nibble * 4:nibble * 4 + 4]
        row = [0] * 16
        for bits in range(16):
            acc = 0
            for k in range(4):
                if bits & (8 >> k):
                    acc ^= base[k]
            row[bits] = acc
        tables.append(row)
    return tables


def ghash(tables, data, state=0):
    """GHASH of data whose length is a multiple of 16."""
    for at in range(0, len(data), 16):
        x = state ^ int.from_bytes(data[at:at + 16], "big")
        state = 0
        shift = 124
        for row in tables:
            state ^= row[(x >> shift) & 15]
            shift -= 4
    return state


def _pad16(data):
    return data + bytes(-len(data) % 16)


class GcmMode:
    def __init__(self, primitive, nonce, mac_len):
        if primitive.block_size != 16:
            raise ValueError("GCM mode is only available for ciphers that operate on 128 bits blocks")
        if not nonce:
            raise ValueError("Nonce cannot be empty")
        if not 4 <= mac_len <= 16:
            raise ValueError("Parameter 'mac_len' must be in the range 4..16")
        self._primitive = primitive
        self.block_size = 16
        self.nonce = nonce
        self._mac_len = mac_len
        self._aad = bytearray()
        self._data = bytearray()  # ciphertext seen so far
        self._plain = bytearray()
        self._state = "new"
        self._stream = None
        self._tag = None
        self._hash = None

    # -- internals ---------------------------------------------------------------------------------------------------
    def _tables(self):
        if self._hash is None:
            self._hash = _table(int.from_bytes(self._primitive.blocks(bytes(16)), "big"))
        return self._hash

    def _j0(self):
        if len(self.nonce) == 12:
            return self.nonce + b"\x00\x00\x00\x01"
        data = _pad16(self.nonce) + bytes(8) + (len(self.nonce) * 8).to_bytes(8, "big")
        return ghash(self._tables(), data).to_bytes(16, "big")

    def _xor(self, data):
        if self._stream is None:
            j0 = self._j0()
            start = (int.from_bytes(j0[12:], "big") + 1) & 0xFFFFFFFF
            self._stream = _GcmStream(self._primitive, j0[:12], start)
        return self._stream._mix(data)

    def _go(self, name, allowed):
        if self._state not in allowed:
            raise TypeError("%s() cannot be called after %s()" % (name, self._state))

    def _compute_tag(self):
        if self._tag is None:
            tables = self._tables()
            state = ghash(tables, _pad16(bytes(self._aad)))
            state = ghash(tables, _pad16(bytes(self._data)), state)
            sizes = (len(self._aad) * 8).to_bytes(8, "big") + (len(self._data) * 8).to_bytes(8, "big")
            state = ghash(tables, sizes, state)
            mask = int.from_bytes(self._primitive.blocks(self._j0()), "big")
            self._tag = (state ^ mask).to_bytes(16, "big")[:self._mac_len]
        return self._tag

    def _native(self):
        """The host's GCM takes 12-byte nonces and whole messages."""
        return len(self.nonce) == 12 and self._mac_len == 16 and self._state in ("new", "update") and not self._data

    # -- API ---------------------------------------------------------------------------------------------------------
    def update(self, assoc_data):
        self._go("update", ("new", "update"))
        self._state = "update"
        self._aad += to_bytes(assoc_data)
        return self

    def encrypt(self, plaintext, output=None):
        self._go("encrypt", ("new", "update", "encrypt"))
        self._state = "encrypt"
        result = self._xor(to_bytes(plaintext))
        self._data += result
        return _emit(result, output)

    def decrypt(self, ciphertext, output=None):
        self._go("decrypt", ("new", "update", "decrypt"))
        self._state = "decrypt"
        data = to_bytes(ciphertext)
        self._data += data
        return _emit(self._xor(data), output)

    def digest(self):
        self._go("digest", ("new", "update", "encrypt", "digest"))
        self._state = "digest"
        return self._compute_tag()

    def hexdigest(self):
        return self.digest().hex()

    def verify(self, received_mac_tag):
        self._go("verify", ("new", "update", "decrypt", "verify"))
        self._state = "verify"
        import hmac

        if not hmac.compare_digest(self._compute_tag(), to_bytes(received_mac_tag)):
            raise ValueError("MAC check failed")

    def hexverify(self, hex_mac_tag):
        self.verify(bytes.fromhex(hex_mac_tag))

    def encrypt_and_digest(self, plaintext, output=None):
        data = to_bytes(plaintext)
        if self._native():
            self._state = "encrypt"
            extra = {"aadB64": b64e(self._aad)} if self._aad else {}
            joined = self._primitive.run("gcm", True, data, self.nonce, **extra)
            result, self._tag = joined[:-16], joined[-16:]
            self._data += result
        else:
            result = self.encrypt(data)
        return _emit(result, output), self.digest()

    def decrypt_and_verify(self, ciphertext, received_mac_tag, output=None):
        data = to_bytes(ciphertext)
        result = self.decrypt(data)
        self.verify(received_mac_tag)
        return _emit(result, output)


class _GcmStream(_Keystream):
    """32-bit counter that wraps inside its field."""

    def __init__(self, primitive, prefix, start):
        self._primitive = primitive
        self.block_size = 16
        self._counter = CounterBlocks(4, prefix, b"", start)

    def _generate(self, blocks):
        counter = self._counter
        if blocks > 64 and counter.value + blocks < counter.limit:
            first = counter.prefix + counter.value.to_bytes(4, "big")
            counter.value += blocks
            return self._primitive.run("ctr", True, bytes(blocks * 16), first)
        return self._primitive.blocks(counter.take(blocks, wrap=True))


# --- factory --------------------------------------------------------------------------------------------------------


def _take_iv(kwargs, block_size):
    iv, upper = kwargs.pop("iv", None), kwargs.pop("IV", None)
    if iv is not None and upper is not None:
        raise TypeError("You must either use 'iv' or 'IV', not both")
    iv = iv if iv is not None else upper
    if iv is None:
        return urandom(block_size)
    iv = to_bytes(iv, "iv")
    if len(iv) != block_size:
        raise ValueError("Incorrect IV length (it must be %d bytes long)" % block_size)
    return iv


def _ctr(primitive, kwargs):
    block = primitive.block_size
    counter = kwargs.pop("counter", None)
    nonce, initial = kwargs.pop("nonce", None), kwargs.pop("initial_value", None)
    if counter is not None:
        if nonce is not None or initial is not None:
            raise TypeError("'counter' and 'nonce'/'initial_value' are mutually exclusive")
        if not isinstance(counter, dict):
            raise TypeError("counter 必须来自 Crypto.Util.Counter.new()")
        width = counter["counter_len"]
        prefix, suffix = counter.get("prefix", b""), counter.get("suffix", b"")
        if len(prefix) + width + len(suffix) != block:
            raise ValueError(
                "Size of the counter block (%d bytes) must match block size (%d)" % (
                    len(prefix) + width + len(suffix), block)
            )
        blocks = CounterBlocks(width, prefix, suffix, counter["initial_value"], counter.get("little_endian", False))
        return CtrMode(primitive, blocks, None)
    if nonce is None:
        if block < 16:
            raise TypeError("Impossible to create a safe nonce for short block sizes")
        nonce = urandom(block // 2)
    else:
        nonce = to_bytes(nonce, "nonce")
        if len(nonce) >= block:
            raise ValueError("Nonce is too long")
    width = block - len(nonce)
    if initial is None:
        value = 0
    elif isinstance(initial, int):
        value = initial
        if value >= 1 << (8 * width):
            raise ValueError("Initial counter value is too large")
    else:
        initial = to_bytes(initial, "initial_value")
        if len(initial) != width:
            raise ValueError(
                "Incorrect length for counter byte string (%d bytes, expected %d)" % (len(initial), width)
            )
        value = int.from_bytes(initial, "big")
    return CtrMode(primitive, CounterBlocks(width, nonce, b"", value), nonce)


def create(primitive, mode, args, kwargs):
    """Shared by AES.new, DES.new and DES3.new."""
    block = primitive.block_size
    if args:
        if mode == MODE_ECB:
            raise TypeError("IV is not meaningful for the ECB mode")
        if mode == MODE_CTR or len(args) > 1:
            raise TypeError("Too many arguments for this mode")
        kwargs["nonce" if mode in (MODE_CCM, MODE_EAX, MODE_SIV, MODE_GCM, MODE_OCB) else "IV"] = args[0]
    if mode == MODE_ECB:
        cipher = EcbMode(primitive)
        kwargs.pop("use_aesni", None)
    elif mode == MODE_CBC:
        cipher = CbcMode(primitive, _take_iv(kwargs, block))
    elif mode == MODE_CFB:
        cipher = CfbMode(primitive, _take_iv(kwargs, block), kwargs.pop("segment_size", 8))
    elif mode == MODE_OFB:
        cipher = OfbMode(primitive, _take_iv(kwargs, block))
    elif mode == MODE_CTR:
        cipher = _ctr(primitive, kwargs)
    elif mode == MODE_GCM:
        nonce = kwargs.pop("nonce", None)
        nonce = urandom(16) if nonce is None else to_bytes(nonce, "nonce")
        cipher = GcmMode(primitive, nonce, kwargs.pop("mac_len", 16))
    elif mode in _NAMES:
        raise NotImplementedError("Crypto（iOS 版）不支持 MODE_%s" % _NAMES[mode])
    else:
        raise ValueError("Mode not supported")
    kwargs.pop("use_aesni", None)
    kwargs.pop("use_clmul", None)
    if kwargs:
        raise TypeError("Unknown parameters: %s" % ", ".join(sorted(kwargs)))
    return cipher
