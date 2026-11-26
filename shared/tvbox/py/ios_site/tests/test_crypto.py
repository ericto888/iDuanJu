import base64
import hashlib
import hmac as std_hmac
import json
import os
import unittest

import fake_crypto
from fake_host import host

H = bytes.fromhex

# NIST SP 800-38A
KEY = H("2b7e151628aed2a6abf7158809cf4f3c")
IV = H("000102030405060708090a0b0c0d0e0f")
PLAIN = H(
    "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
    "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710"
)
# McGrew & Viega GCM test cases 3-5
GCM_KEY = H("feffe9928665731c6d6a8f9467308308")
GCM_IV = H("cafebabefacedbaddecaf888")
GCM_PLAIN = H(
    "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72"
    "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255"
)
GCM_AAD = H("feedfacedeadbeeffeedfacedeadbeefabaddad2")


class ReferenceTests(unittest.TestCase):
    """The fake host's ciphers against published vectors, so that round trips below prove something."""

    def test_fips197(self):
        block = H("00112233445566778899aabbccddeeff")
        for size, expect in (
            (16, "69c4e0d86a7b0430d8cdb78070b4c55a"), (24, "dda97ca4864cdfe06eaf70a0ec0d7191"),
            (32, "8ea2b7ca516745bfeafc49904b496089"),
        ):
            core = fake_crypto.AES(bytes(range(size)))
            self.assertEqual(core.encrypt(block).hex(), expect)
            self.assertEqual(core.decrypt(H(expect)), block)

    def test_des(self):
        core = fake_crypto.DES(H("133457799bbcdff1"))
        self.assertEqual(core.encrypt(H("0123456789abcdef")).hex(), "85e813540f0ab405")
        self.assertEqual(core.decrypt(H("85e813540f0ab405")).hex(), "0123456789abcdef")


class AesTests(unittest.TestCase):
    def setUp(self):
        host.reset()
        from Crypto.Cipher import AES

        self.AES = AES

    def both(self, expect, mode, plain=PLAIN, **kwargs):
        self.assertEqual(self.AES.new(KEY, mode, **kwargs).encrypt(plain).hex(), expect)
        self.assertEqual(self.AES.new(KEY, mode, **kwargs).decrypt(H(expect)), plain)

    def test_fips197_through_the_shim(self):
        block = H("00112233445566778899aabbccddeeff")
        for size, expect in (
            (16, "69c4e0d86a7b0430d8cdb78070b4c55a"), (24, "dda97ca4864cdfe06eaf70a0ec0d7191"),
            (32, "8ea2b7ca516745bfeafc49904b496089"),
        ):
            cipher = self.AES.new(bytes(range(size)), self.AES.MODE_ECB)
            self.assertEqual(cipher.encrypt(block).hex(), expect)
            self.assertEqual(cipher.decrypt(H(expect)), block)
            self.assertEqual(cipher.key_size, size)

    def test_ecb(self):
        self.both(
            "3ad77bb40d7a3660a89ecaf32466ef97f5d3d58503b9699de785895a96fdbaaf"
            "43b1cd7f598ece23881b00e3ed0306887b0c785e27e8ad3f8223207104725dd4", self.AES.MODE_ECB)

    def test_cbc(self):
        expect = (
            "7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2"
            "73bed6b8e3c1743b7116e69e222295163ff1caa1681fac09120eca307586e1a7"
        )
        self.both(expect, self.AES.MODE_CBC, iv=IV)
        self.both(expect, self.AES.MODE_CBC, IV=IV)
        self.assertEqual(self.AES.new(KEY, self.AES.MODE_CBC, IV).encrypt(PLAIN).hex(), expect)
        cipher = self.AES.new(KEY, self.AES.MODE_CBC, IV)
        self.assertEqual((cipher.iv, cipher.IV, cipher.block_size), (IV, IV, 16))
        self.assertEqual((cipher.encrypt(PLAIN[:16]) + cipher.encrypt(PLAIN[16:])).hex(), expect)
        cipher = self.AES.new(KEY, self.AES.MODE_CBC, IV)
        self.assertEqual(cipher.decrypt(H(expect)[:32]) + cipher.decrypt(H(expect)[32:]), PLAIN)

    def test_cfb(self):
        self.both(
            "3b3fd92eb72dad20333449f8e83cfb4ac8a64537a0b3a93fcde3cdad9f1ce58b"
            "26751f67a3cbb140b1808cf187a4f4dfc04b05357c5d1c0eeac4c66f9ff7f2e6",
            self.AES.MODE_CFB, iv=IV, segment_size=128)
        # default segment size is 8 bits
        self.both("3b79424c9c0dd436bace9e0ed4586a4f32b9", self.AES.MODE_CFB, plain=PLAIN[:18], iv=IV)

    def test_cfb_streaming_and_odd_segments(self):
        for segment, pieces in ((8, (1, 5, 16, 3)), (64, (8, 16, 8)), (128, (16, 32))):
            data = os.urandom(sum(pieces))
            whole = self.AES.new(KEY, self.AES.MODE_CFB, IV, segment_size=segment).encrypt(data)
            cipher, at, out = self.AES.new(KEY, self.AES.MODE_CFB, IV, segment_size=segment), 0, b""
            for size in pieces:
                out += cipher.encrypt(data[at:at + size])
                at += size
            self.assertEqual(out, whole)
            plain = self.AES.new(KEY, self.AES.MODE_CFB, IV, segment_size=segment).decrypt(whole)
            self.assertEqual(plain, data)
        with self.assertRaises(ValueError):
            self.AES.new(KEY, self.AES.MODE_CFB, IV, segment_size=128).encrypt(b"short")

    def test_ofb(self):
        expect = (
            "3b3fd92eb72dad20333449f8e83cfb4a7789508d16918f03f53c52dac54ed825"
            "9740051e9c5fecf64344f7a82260edcc304c6528f659c77866a510d9c1d6ae5e"
        )
        self.both(expect, self.AES.MODE_OFB, iv=IV)
        cipher = self.AES.new(KEY, self.AES.MODE_OFB, IV)
        self.assertEqual(b"".join(cipher.encrypt(PLAIN[i:i + 7]) for i in range(0, 64, 7)).hex(), expect)

    def test_ctr(self):
        expect = (
            "874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff"
            "5ae4df3edbd5d35e5b4f09020db03eab1e031dda2fbe03d1792170a0f3009cee"
        )
        start = H("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        AES = self.AES
        self.both(expect, AES.MODE_CTR, nonce=b"", initial_value=start)
        self.both(expect, AES.MODE_CTR, nonce=start[:8], initial_value=int.from_bytes(start[8:], "big"))
        self.both(expect, AES.MODE_CTR, nonce=start[:8], initial_value=start[8:])
        from Crypto.Util import Counter

        counter = Counter.new(128, initial_value=int.from_bytes(start, "big"))
        self.both(expect, AES.MODE_CTR, counter=counter)
        counter = Counter.new(64, prefix=start[:8], initial_value=int.from_bytes(start[8:], "big"))
        self.both(expect, AES.MODE_CTR, counter=counter)
        cipher = AES.new(KEY, AES.MODE_CTR, nonce=b"", initial_value=start)
        self.assertEqual(b"".join(cipher.decrypt(H(expect)[i:i + 5]) for i in range(0, 64, 5)), PLAIN)
        self.assertEqual(cipher.nonce, b"")
        with self.assertRaises(OverflowError):
            AES.new(KEY, AES.MODE_CTR, counter=Counter.new(8, prefix=bytes(15), initial_value=0)).encrypt(bytes(16 * 257))

    def test_ctr_long_data_uses_the_native_mode(self):
        data = os.urandom(16 * 100 + 5)
        nonce = os.urandom(8)
        native = self.AES.new(KEY, self.AES.MODE_CTR, nonce=nonce).encrypt(data)
        self.assertIn("ctr", [a.get("mode") for n, a in host.calls if n == "cipher"])
        cipher = self.AES.new(KEY, self.AES.MODE_CTR, nonce=nonce)
        self.assertEqual(b"".join(cipher.encrypt(data[i:i + 160]) for i in range(0, len(data), 160)), native)
        self.assertEqual(self.AES.new(KEY, self.AES.MODE_CTR, nonce=nonce).decrypt(native), data)

    def test_little_endian_counter(self):
        from Crypto.Util import Counter

        counter = Counter.new(32, prefix=b"p" * 8, suffix=b"s" * 4, initial_value=255, little_endian=True)
        core = fake_crypto.AES(KEY)
        stream = b"".join(core.encrypt(b"p" * 8 + v.to_bytes(4, "little") + b"s" * 4) for v in (255, 256))
        self.assertEqual(self.AES.new(KEY, self.AES.MODE_CTR, counter=counter).encrypt(bytes(32)), stream)

    def test_gcm_vectors(self):
        AES = self.AES
        c3 = (
            "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e"
            "21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985"
        )
        t3 = "4d5c2af327cd64a62cf35abd2ba6fab4"
        ct, tag = AES.new(GCM_KEY, AES.MODE_GCM, nonce=GCM_IV).encrypt_and_digest(GCM_PLAIN)
        self.assertEqual((ct.hex(), tag.hex()), (c3, t3))
        self.assertIn("gcm", [a.get("mode") for n, a in host.calls if n == "cipher"])
        # streaming path, computed in Python
        cipher = AES.new(GCM_KEY, AES.MODE_GCM, GCM_IV)
        out = cipher.encrypt(GCM_PLAIN[:5]) + cipher.encrypt(GCM_PLAIN[5:40]) + cipher.encrypt(GCM_PLAIN[40:])
        self.assertEqual((out.hex(), cipher.hexdigest()), (c3, t3))
        self.assertEqual(AES.new(GCM_KEY, AES.MODE_GCM, GCM_IV).decrypt(H(c3)), GCM_PLAIN)
        self.assertEqual(AES.new(GCM_KEY, AES.MODE_GCM, GCM_IV).decrypt_and_verify(H(c3), H(t3)), GCM_PLAIN)
        bad = AES.new(GCM_KEY, AES.MODE_GCM, GCM_IV)
        with self.assertRaisesRegex(ValueError, "MAC check failed"):
            bad.decrypt_and_verify(H(c3), bytes(16))
        # case 4: associated data
        c4, t4 = c3[:120], "5bc94fbc3221a5db94fae95ae7121a47"
        for native in (True, False):
            cipher = AES.new(GCM_KEY, AES.MODE_GCM, nonce=GCM_IV)
            cipher.update(GCM_AAD)
            if native:
                got = cipher.encrypt_and_digest(GCM_PLAIN[:60])
            else:
                got = cipher.encrypt(GCM_PLAIN[:60]), cipher.digest()
            self.assertEqual((got[0].hex(), got[1].hex()), (c4, t4))
        # case 5: 8-byte nonce
        cipher = AES.new(GCM_KEY, AES.MODE_GCM, nonce=GCM_IV[:8])
        cipher.update(GCM_AAD[:7]).update(GCM_AAD[7:])
        ct, tag = cipher.encrypt_and_digest(GCM_PLAIN[:60])
        self.assertEqual(ct.hex(), (
            "61353b4c2806934a777ff51fa22a4755699b2a714fcdc6f83766e5f97b6c742373806900e49f24b22b097544d4896b424989b5e1"
            "ebac0f07c23f4598"))
        self.assertEqual(tag.hex(), "3612d2e79e3b0785561be14aaca2fccb")

    def test_gcm_nonce_and_state(self):
        AES = self.AES
        for size in (12, 16):
            nonce, data = os.urandom(size), os.urandom(2000)
            cipher = AES.new(GCM_KEY, AES.MODE_GCM, nonce=nonce)
            cipher.update(b"head")
            ct, tag = cipher.encrypt_and_digest(data)
            self.assertEqual(
                ct + tag, fake_crypto.gcm(fake_crypto.AES(GCM_KEY), True, data, nonce, b"head"))
            again = AES.new(GCM_KEY, AES.MODE_GCM, nonce=nonce)
            again.update(b"head")
            self.assertEqual(again.decrypt(ct), data)
            again.verify(tag)
        self.assertEqual(len(AES.new(GCM_KEY, AES.MODE_GCM).nonce), 16)
        short = AES.new(GCM_KEY, AES.MODE_GCM, nonce=GCM_IV, mac_len=8)
        self.assertEqual(short.encrypt_and_digest(GCM_PLAIN)[1].hex(), "4d5c2af327cd64a6")
        with self.assertRaises(TypeError):
            cipher.decrypt(b"x")

    def test_errors(self):
        AES = self.AES
        with self.assertRaisesRegex(ValueError, r"Incorrect AES key length \(5 bytes\)"):
            AES.new(b"short", AES.MODE_ECB)
        with self.assertRaisesRegex(ValueError, "Incorrect IV length"):
            AES.new(KEY, AES.MODE_CBC, b"1")
        with self.assertRaisesRegex(TypeError, "IV is not meaningful"):
            AES.new(KEY, AES.MODE_ECB, IV)
        with self.assertRaises(TypeError):
            AES.new("0123456789abcdef", AES.MODE_ECB)
        with self.assertRaisesRegex(ValueError, "16 byte boundary in CBC"):
            AES.new(KEY, AES.MODE_CBC, IV).encrypt(b"abc")
        with self.assertRaises(TypeError):
            AES.new(KEY, AES.MODE_ECB).encrypt("text")
        cipher = AES.new(KEY, AES.MODE_CBC, IV)
        cipher.encrypt(PLAIN)
        with self.assertRaisesRegex(TypeError, r"decrypt\(\) cannot be called after encrypt\(\)"):
            cipher.decrypt(PLAIN)
        with self.assertRaisesRegex(NotImplementedError, "MODE_EAX"):
            AES.new(KEY, AES.MODE_EAX)
        with self.assertRaises(TypeError):
            AES.new(KEY, AES.MODE_CBC, IV, bogus=1)
        self.assertEqual(len(AES.new(KEY, AES.MODE_CBC).iv), 16)

    def test_inputs_and_outputs(self):
        AES = self.AES
        cipher = AES.new(bytearray(KEY), AES.MODE_CBC, memoryview(IV))
        buffer = bytearray(64)
        self.assertIsNone(cipher.encrypt(memoryview(PLAIN), output=buffer))
        self.assertEqual(AES.new(KEY, AES.MODE_CBC, IV).decrypt(bytes(buffer)), PLAIN)
        self.assertEqual(AES.new(KEY, AES.MODE_CBC, IV).encrypt(b""), b"")

    def test_cryptojs_idiom(self):
        """decrypt(b64decode(s)) + unpad, as nearly every spider does it."""
        from base64 import b64decode, b64encode

        from Crypto.Cipher import AES
        from Crypto.Util.Padding import pad, unpad

        key, iv = b"ziISjqkXPsGUMRNGyWigxDGtJbfTdcGv", b"WonrnVkxeIxDcFbv"
        text = json.dumps({"url": "https://v.example/中文.m3u8"}, ensure_ascii=False)
        sealed = b64encode(AES.new(key, AES.MODE_CBC, iv).encrypt(pad(text.encode("utf-8"), AES.block_size))).decode()
        plain = unpad(AES.new(key, AES.MODE_CBC, iv).decrypt(b64decode(sealed)), AES.block_size).decode("utf-8")
        self.assertEqual(json.loads(plain)["url"], "https://v.example/中文.m3u8")


class OtherCipherTests(unittest.TestCase):
    def setUp(self):
        host.reset()

    def test_des(self):
        from Crypto.Cipher import DES

        key = H("133457799bbcdff1")
        self.assertEqual(DES.new(key, DES.MODE_ECB).encrypt(H("0123456789abcdef")).hex(), "85e813540f0ab405")
        data = os.urandom(24)
        for mode, extra in ((DES.MODE_CBC, {}), (DES.MODE_CFB, {}), (DES.MODE_OFB, {})):
            sealed = DES.new(key, mode, b"12345678", **extra).encrypt(data)
            self.assertEqual(DES.new(key, mode, b"12345678", **extra).decrypt(sealed), data)
        with self.assertRaises(ValueError):
            DES.new(b"short", DES.MODE_ECB)

    def test_des3(self):
        from Crypto.Cipher import DES3

        key = H("0123456789abcdef23456789abcdef01456789abcdef0123")
        plain = b"The qufck brown fox jump"
        sealed = DES3.new(key, DES3.MODE_ECB).encrypt(plain)
        self.assertEqual(sealed.hex(), "a826fd8ce53b855fcce21c8112256fe668d5c05dd9b6b900")
        two = os.urandom(16)
        data = os.urandom(16)
        sealed = DES3.new(two, DES3.MODE_CBC, b"abcdefgh").encrypt(data)
        self.assertEqual(DES3.new(two, DES3.MODE_CBC, b"abcdefgh").decrypt(sealed), data)
        self.assertEqual(sealed, fake_crypto.cipher("3des", "cbc", "none", True, two, b"abcdefgh", data))
        with self.assertRaisesRegex(ValueError, "degenerates"):
            DES3.new(b"12345678" * 2, DES3.MODE_ECB)

    def test_rc4(self):
        from Crypto.Cipher import ARC4

        # RFC 6229
        stream = ARC4.new(H("0102030405")).encrypt(bytes(256))
        self.assertEqual(stream[:32].hex(), "b2396305f03dc027ccc3524a0a1118a86982944f18fc82d589c403a47a0d0919")
        self.assertEqual(stream[240:].hex(), "28cb1132c96ce286421dcaadb8b69eae")
        stream = ARC4.new(H("0102030405060708090a0b0c0d0e0f10")).encrypt(bytes(16))
        self.assertEqual(stream.hex(), "9ac7cc9a609d1ef7b2932899cde41b97")
        cipher = ARC4.new(b"key")
        pieces = cipher.encrypt(b"abc") + cipher.encrypt(b"defgh")
        self.assertEqual(pieces, ARC4.new(b"key").encrypt(b"abcdefgh"))
        self.assertEqual(ARC4.new(b"key").decrypt(pieces), b"abcdefgh")
        self.assertEqual(ARC4.new(b"key", drop=3).encrypt(b"defgh"), pieces[3:])

    def test_cryptodome_alias(self):
        from Cryptodome.Cipher import AES
        from Cryptodome.Hash import SHA256
        from Cryptodome.PublicKey import RSA
        from Cryptodome.Util.Padding import pad

        self.assertEqual(len(AES.new(KEY, AES.MODE_ECB).encrypt(pad(b"x", 16))), 16)
        self.assertEqual(SHA256.new(b"abc").hexdigest(), hashlib.sha256(b"abc").hexdigest())
        self.assertTrue(callable(RSA.import_key))


class UtilTests(unittest.TestCase):
    def test_padding(self):
        from Crypto.Util.Padding import pad, unpad

        for style in ("pkcs7", "x923", "iso7816"):
            for size in range(0, 33):
                data = bytes(range(size))
                padded = pad(data, 16, style)
                self.assertEqual(len(padded) % 16, 0)
                self.assertEqual(unpad(padded, 16, style=style), data)
        self.assertEqual(pad(b"abc", 8), b"abc\x05\x05\x05\x05\x05")
        for bad, message in (
            (b"", "Zero-length input cannot be unpadded"), (b"abc", "Input data is not padded"),
            (bytes(16), "Padding is incorrect"), (b"a" * 14 + b"\x01\x02", "PKCS#7 padding is incorrect"),
        ):
            with self.assertRaisesRegex(ValueError, message):
                unpad(bad, 16)

    def test_numbers(self):
        from Crypto.Util import number
        from Crypto.Util.strxor import strxor

        self.assertEqual(number.bytes_to_long(b"\x01\x00"), 256)
        self.assertEqual(number.long_to_bytes(256), b"\x01\x00")
        self.assertEqual(number.long_to_bytes(256, 4), b"\x00\x00\x01\x00")
        self.assertEqual(number.long_to_bytes(0), b"\x00")
        self.assertEqual(number.inverse(3, 11), 4)
        self.assertTrue(number.isPrime(2 ** 61 - 1))
        self.assertFalse(number.isPrime(2 ** 61 + 1))
        self.assertTrue(number.isPrime(number.getPrime(64)))
        self.assertEqual(strxor(b"\x0f\xf0", b"\xff\xff"), b"\xf0\x0f")

    def test_random(self):
        from Crypto import Random
        from Crypto.Random import get_random_bytes, random

        self.assertEqual(len(get_random_bytes(16)), 16)
        self.assertEqual(len(Random.new().read(5)), 5)
        self.assertIn(random.choice("ab"), "ab")

    def test_kdf(self):
        from Crypto.Hash import SHA256
        from Crypto.Protocol.KDF import PBKDF2

        self.assertEqual(PBKDF2("password", b"salt", 20, 1).hex(), "0c60c80f961f0e71f3a9b524af6012062fe037a6")
        self.assertEqual(
            PBKDF2(b"pw", b"salt", 40, 50, hmac_hash_module=SHA256), hashlib.pbkdf2_hmac("sha256", b"pw", b"salt", 50, 40))


class HashTests(unittest.TestCase):
    def test_digests(self):
        import importlib

        for name, std in (("MD5", "md5"), ("SHA1", "sha1"), ("SHA", "sha1"), ("SHA224", "sha224"), ("SHA256", "sha256"),
                          ("SHA384", "sha384"), ("SHA512", "sha512")):
            module = importlib.import_module("Crypto.Hash." + name)
            value = module.new(b"ab")
            value.update(b"c")
            want = hashlib.new(std, b"abc")
            self.assertEqual((value.digest(), value.hexdigest()), (want.digest(), want.hexdigest()))
            self.assertEqual((module.digest_size, value.block_size), (want.digest_size, want.block_size))
            twin = value.copy()
            twin.update(b"d")
            self.assertEqual(value.digest(), want.digest())
            self.assertEqual(value.new(b"abc").digest(), want.digest())
        from Crypto.Hash import MD5

        self.assertEqual(MD5.new().hexdigest(), "d41d8cd98f00b204e9800998ecf8427e")
        with self.assertRaises(TypeError):
            MD5.new("text")

    def test_host_fallback(self):
        from Crypto.Hash import _base

        digest = _base._HostDigest("sha256", b"ab")
        digest.update(b"c")
        self.assertEqual(digest.copy().digest(), hashlib.sha256(b"abc").digest())

    def test_hmac(self):
        from Crypto.Hash import HMAC, MD5, SHA256

        # RFC 4231 case 1
        mac = HMAC.new(b"\x0b" * 20, b"Hi There", SHA256)
        self.assertEqual(mac.hexdigest(), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        mac = HMAC.new(b"k" * 100, digestmod=MD5)
        mac.update(b"a")
        mac.copy().update(b"zz")
        mac.update(b"b")
        self.assertEqual(mac.digest(), std_hmac.new(b"k" * 100, b"ab", "md5").digest())
        mac.hexverify(mac.hexdigest())
        with self.assertRaises(ValueError):
            mac.verify(bytes(16))
        self.assertEqual(HMAC.new(b"k", b"x").hexdigest(), std_hmac.new(b"k", b"x", "md5").hexdigest())


class RsaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from Crypto.PublicKey import RSA

        host.reset()
        cls.RSA = RSA
        cls.key = RSA.generate(1024)

    def test_key_numbers(self):
        key = self.key
        self.assertEqual((key.size_in_bits(), key.size_in_bytes(), key.e), (1024, 128, 65537))
        self.assertEqual(key.p * key.q, key.n)
        self.assertEqual(pow(pow(1234567, key.e, key.n), key.d, key.n), 1234567)
        public = key.publickey()
        self.assertFalse(public.has_private())
        with self.assertRaises(AttributeError):
            public.d
        self.assertEqual(public, key.public_key())
        self.assertNotEqual(public, key)

    def test_import_export(self):
        RSA, key = self.RSA, self.key
        for blob in (
            key.export_key(), key.exportKey("PEM"), key.export_key("DER"), key.export_key("PEM", pkcs=8),
            key.export_key("DER", pkcs=8), key.export_key().decode(), base64.b64encode(key.export_key("DER")),
            base64.b64encode(key.export_key("DER", pkcs=8)).decode(),
        ):
            self.assertEqual(RSA.import_key(blob), key)
        public = key.public_key()
        for blob in (
            public.export_key(), public.export_key("DER"), public.export_key("OpenSSH"), public._pkcs1_public(),
            base64.b64encode(public.export_key("DER")).decode(),
            "-----BEGIN PUBLIC KEY-----" + base64.b64encode(public.export_key("DER")).decode() + "-----END PUBLIC KEY-----",
        ):
            self.assertEqual(RSA.importKey(blob), public)
        self.assertTrue(public.export_key().startswith(b"-----BEGIN PUBLIC KEY-----\nMI"))
        self.assertTrue(key.export_key().startswith(b"-----BEGIN RSA PRIVATE KEY-----"))
        self.assertTrue(key.export_key(pkcs=8).startswith(b"-----BEGIN PRIVATE KEY-----"))
        with self.assertRaisesRegex(ValueError, "RSA key format is not supported"):
            RSA.import_key("not a key")
        with self.assertRaisesRegex(NotImplementedError, "加密"):
            RSA.import_key("-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----")

    def test_known_public_key(self):
        # SubjectPublicKeyInfo of a 1024-bit key as it appears in many scripts.
        text = (
            "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDlOJu6TyygqxfWT7eLtGDwajtNFOb9I5XRb6khyfD1Yt3YiCgQWMNW649887VGJiGr/L5i"
            "2osbl8C9+WJTeucF+S76xFxdU6jE0NQ+Z+zEdhUTooNRaY5nZiu5PgDB0ED/ZKBUSLKL7eibMxZtMlUDHjm4gwQco1KRMDSmXSMkDwIDAQAB"
        )
        key = self.RSA.import_key(text)
        self.assertEqual((key.size_in_bits(), key.e), (1024, 65537))
        self.assertEqual(base64.b64encode(key.export_key("DER")).decode(), text)

    def test_construct(self):
        RSA, key = self.RSA, self.key
        self.assertEqual(RSA.construct((key.n, key.e)), key.public_key())
        again = RSA.construct((key.n, key.e, key.d))
        self.assertEqual({again.p, again.q}, {key.p, key.q})
        self.assertEqual(RSA.construct((key.n, key.e, key.d, key.p, key.q)), key)
        with self.assertRaises(ValueError):
            RSA.construct((key.n, key.e, key.d, key.p + 2, key.q))

    def test_pkcs1_v1_5(self):
        from Crypto.Cipher import PKCS1_v1_5

        key = self.key
        sealed = PKCS1_v1_5.new(key.publickey()).encrypt(b"hello")
        self.assertEqual(len(sealed), 128)
        self.assertEqual(PKCS1_v1_5.new(key).decrypt(sealed, None), b"hello")
        sentinel = object()
        self.assertIs(PKCS1_v1_5.new(key).decrypt(b"\x01" * 128, sentinel), sentinel)
        with self.assertRaises(ValueError):
            PKCS1_v1_5.new(key).decrypt(b"short", sentinel)
        with self.assertRaisesRegex(ValueError, "too long"):
            PKCS1_v1_5.new(key).encrypt(bytes(118))
        with self.assertRaisesRegex(TypeError, "private"):
            PKCS1_v1_5.new(key.publickey()).decrypt(sealed, None)

    def test_multi_block_idiom(self):
        from Crypto.Cipher import PKCS1_v1_5

        data = os.urandom(500)
        seal, unseal = PKCS1_v1_5.new(self.key.publickey()), PKCS1_v1_5.new(self.key)
        joined = b"".join(seal.encrypt(data[i:i + 117]) for i in range(0, len(data), 117))
        plain = b"".join(unseal.decrypt(joined[i:i + 128], b"") for i in range(0, len(joined), 128))
        self.assertEqual(plain, data)

    def test_oaep(self):
        from Crypto.Cipher import PKCS1_OAEP
        from Crypto.Hash import SHA256

        for options in ({}, {"hashAlgo": SHA256}, {"label": b"x"}):
            sealed = PKCS1_OAEP.new(self.key.publickey(), **options).encrypt(b"secret")
            self.assertEqual(PKCS1_OAEP.new(self.key, **options).decrypt(sealed), b"secret")
        with self.assertRaisesRegex(ValueError, "Incorrect decryption"):
            PKCS1_OAEP.new(self.key).decrypt(sealed)

    def test_signatures(self):
        from Crypto.Hash import MD5, SHA1, SHA256, SHA512
        from Crypto.Signature import PKCS1_v1_5, pkcs1_15

        key = self.key
        for module in (MD5, SHA1, SHA256, SHA512):
            signature = pkcs1_15.new(key).sign(module.new(b"message"))
            pkcs1_15.new(key.publickey()).verify(module.new(b"message"), signature)
            with self.assertRaisesRegex(ValueError, "Invalid signature"):
                pkcs1_15.new(key.publickey()).verify(module.new(b"other"), signature)
            self.assertTrue(PKCS1_v1_5.new(key.publickey()).verify(module.new(b"message"), signature))
            self.assertFalse(PKCS1_v1_5.new(key.publickey()).verify(module.new(b"other"), signature))
        # EMSA-PKCS1-v1_5 block checked by hand
        block = pow(int.from_bytes(pkcs1_15.new(key).sign(SHA256.new(b"abc")), "big"), key.e, key.n).to_bytes(128, "big")
        info = H("3031300d060960864801650304020105000420") + hashlib.sha256(b"abc").digest()
        self.assertEqual(block, b"\x00\x01" + b"\xff" * (128 - len(info) - 3) + b"\x00" + info)

    def test_small_key_without_crt(self):
        # textbook key: n = 3233, e = 17, d = 2753
        key = self.RSA.construct((3233, 17, 2753))
        self.assertEqual(key._public(65), 2790)
        self.assertEqual(key._private(2790), 65)


if __name__ == "__main__":
    unittest.main()
