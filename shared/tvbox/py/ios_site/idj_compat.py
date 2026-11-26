"""Makes the embedded interpreter look like the desktop Python the spiders were written for (i短剧, GPL-3.0).

`install()` is idempotent and:
  * registers stub `ssl` / `socket` modules when the real ones cannot be imported;
  * provides gbk/gb2312/gb18030 codecs and missing hashlib algorithms from the host when the C extensions are absent;
  * routes urllib through the host;
  * lets child threads (also thread pool workers) inherit the key of the spider that started them.
"""

from __future__ import annotations

import sys
import types

__all__ = ["install", "ssl_module", "socket_module"]

_installed = False


def _unavailable(what):
    raise NotImplementedError("iOS 版 Python 不支持 %s，请改用 requests 或 urllib" % what)


# --- ssl ------------------------------------------------------------------------------------------------------------


def _build_ssl():
    import enum

    ssl = types.ModuleType("ssl", "Stub: TLS is done by the host (i短剧).")
    ssl.__idj_stub__ = True

    class SSLError(OSError):
        library = reason = None

    class SSLCertVerificationError(SSLError, ValueError):
        pass

    class SSLZeroReturnError(SSLError):
        pass

    class SSLWantReadError(SSLError):
        pass

    class SSLWantWriteError(SSLError):
        pass

    class SSLSyscallError(SSLError):
        pass

    class SSLEOFError(SSLError):
        pass

    class VerifyMode(enum.IntEnum):
        CERT_NONE = 0
        CERT_OPTIONAL = 1
        CERT_REQUIRED = 2

    class TLSVersion(enum.IntEnum):
        MINIMUM_SUPPORTED = -2
        SSLv3 = 768
        TLSv1 = 769
        TLSv1_1 = 770
        TLSv1_2 = 771
        TLSv1_3 = 772
        MAXIMUM_SUPPORTED = -1

    class _SSLMethod(enum.IntEnum):
        PROTOCOL_SSLv23 = 2
        PROTOCOL_TLS = 2
        PROTOCOL_TLSv1 = 3
        PROTOCOL_TLSv1_1 = 4
        PROTOCOL_TLSv1_2 = 5
        PROTOCOL_TLS_CLIENT = 16
        PROTOCOL_TLS_SERVER = 17

    class VerifyFlags(enum.IntFlag):
        VERIFY_DEFAULT = 0
        VERIFY_CRL_CHECK_LEAF = 4
        VERIFY_X509_STRICT = 32
        VERIFY_X509_PARTIAL_CHAIN = 0x80000

    class Options(enum.IntFlag):
        OP_ALL = 0x80000050
        OP_LEGACY_SERVER_CONNECT = 0x4
        OP_NO_SSLv2 = 0
        OP_NO_SSLv3 = 0x2000000
        OP_NO_TLSv1 = 0x4000000
        OP_NO_TLSv1_1 = 0x10000000
        OP_NO_TLSv1_2 = 0x8000000
        OP_NO_TLSv1_3 = 0x20000000
        OP_NO_COMPRESSION = 0x20000
        OP_NO_TICKET = 0x4000
        OP_NO_RENEGOTIATION = 0x40000000
        OP_CIPHER_SERVER_PREFERENCE = 0x400000
        OP_SINGLE_DH_USE = 0
        OP_SINGLE_ECDH_USE = 0
        OP_IGNORE_UNEXPECTED_EOF = 0x80

    class SSLContext:
        """Accepts every setting; only verify_mode is looked at (by the urllib and urllib3 replacements)."""

        def __init__(self, protocol=2, *args, **kwargs):
            self.protocol = protocol
            self.verify_mode = VerifyMode.CERT_REQUIRED if protocol == 16 else VerifyMode.CERT_NONE
            self.check_hostname = protocol == 16
            self.options = Options.OP_ALL
            self.verify_flags = VerifyFlags.VERIFY_DEFAULT
            self.minimum_version = TLSVersion.MINIMUM_SUPPORTED
            self.maximum_version = TLSVersion.MAXIMUM_SUPPORTED
            self.post_handshake_auth = False
            self.keylog_filename = None
            self.sni_callback = None
            self.security_level = 1

        def _accept(self, *args, **kwargs):
            return None

        load_default_certs = load_verify_locations = load_cert_chain = set_ciphers = set_alpn_protocols = _accept
        set_npn_protocols = set_default_verify_paths = set_ecdh_curve = load_dh_params = set_servername_callback = _accept

        def get_ciphers(self):
            return []

        def get_ca_certs(self, binary_form=False):
            return []

        def cert_store_stats(self):
            return {"x509": 0, "crl": 0, "x509_ca": 0}

        def wrap_socket(self, *args, **kwargs):
            _unavailable("ssl.SSLContext.wrap_socket()")

        wrap_bio = wrap_socket

    class SSLSocket:
        def __init__(self, *args, **kwargs):
            _unavailable("ssl.SSLSocket")

    class Purpose(enum.Enum):
        SERVER_AUTH = "1.3.6.1.5.5.7.3.1"
        CLIENT_AUTH = "1.3.6.1.5.5.7.3.2"

    def create_default_context(purpose=Purpose.SERVER_AUTH, *, cafile=None, capath=None, cadata=None):
        return SSLContext(_SSLMethod.PROTOCOL_TLS_CLIENT)

    def _create_unverified_context(protocol=None, *, cert_reqs=VerifyMode.CERT_NONE, check_hostname=False, **kwargs):
        context = SSLContext(_SSLMethod.PROTOCOL_TLS_CLIENT)
        context.check_hostname = check_hostname
        context.verify_mode = cert_reqs if cert_reqs is not None else VerifyMode.CERT_NONE
        return context

    def get_server_certificate(*args, **kwargs):
        _unavailable("ssl.get_server_certificate()")

    def wrap_socket(*args, **kwargs):
        _unavailable("ssl.wrap_socket()")

    for item in (
        SSLError, SSLCertVerificationError, SSLZeroReturnError, SSLWantReadError, SSLWantWriteError, SSLSyscallError,
        SSLEOFError, VerifyMode, TLSVersion, _SSLMethod, VerifyFlags, Options, SSLContext, SSLSocket, Purpose,
        create_default_context, _create_unverified_context, get_server_certificate, wrap_socket,
    ):
        item.__module__ = "ssl"
        setattr(ssl, item.__name__, item)
    for group in (VerifyMode, _SSLMethod, VerifyFlags, Options):
        for name, value in group.__members__.items():
            setattr(ssl, name, value)
    ssl.CertificateError = SSLCertVerificationError
    ssl.SSLObject = SSLSocket
    ssl._create_default_https_context = create_default_context
    ssl._create_stdlib_context = _create_unverified_context
    ssl.OPENSSL_VERSION = "OpenSSL 3.0.0 (stub)"
    ssl.OPENSSL_VERSION_INFO = (3, 0, 0, 0, 0)
    ssl.OPENSSL_VERSION_NUMBER = 0x30000000
    ssl.HAS_SNI = ssl.HAS_ALPN = ssl.HAS_TLSv1_2 = ssl.HAS_TLSv1_3 = ssl.HAS_ECDH = True
    ssl.HAS_NPN = ssl.HAS_SSLv2 = ssl.HAS_SSLv3 = ssl.HAS_TLSv1 = ssl.HAS_TLSv1_1 = False
    ssl.PEM_HEADER, ssl.PEM_FOOTER = "-----BEGIN CERTIFICATE-----", "-----END CERTIFICATE-----"
    return ssl


# --- socket ---------------------------------------------------------------------------------------------------------


def _build_socket():
    socket = types.ModuleType("socket", "Stub: networking is done by the host (i短剧).")
    socket.__idj_stub__ = True
    state = {"timeout": None}

    class herror(OSError):
        pass

    class gaierror(OSError):
        pass

    class _Socket:
        def __init__(self, *args, **kwargs):
            _unavailable("socket.socket")

    def missing(name):
        def function(*args, **kwargs):
            _unavailable("socket.%s()" % name)

        function.__name__ = name
        return function

    def setdefaulttimeout(value):
        state["timeout"] = value

    def getdefaulttimeout():
        return state["timeout"]

    socket.error = OSError
    socket.timeout = TimeoutError
    socket.herror, socket.gaierror = herror, gaierror
    _Socket.__name__ = "socket"
    socket.socket = socket.SocketType = _Socket
    socket._GLOBAL_DEFAULT_TIMEOUT = object()
    socket.setdefaulttimeout, socket.getdefaulttimeout = setdefaulttimeout, getdefaulttimeout
    socket.gethostname = lambda: "localhost"
    socket.getfqdn = lambda name="": name or "localhost"
    for name in (
        "create_connection", "create_server", "socketpair", "fromfd", "getaddrinfo", "gethostbyname",
        "gethostbyname_ex", "gethostbyaddr", "getnameinfo", "getservbyname", "getprotobyname", "if_nameindex",
    ):
        setattr(socket, name, missing(name))
    constants = {
        "AF_UNSPEC": 0, "AF_UNIX": 1, "AF_INET": 2, "AF_INET6": 30, "SOCK_STREAM": 1, "SOCK_DGRAM": 2, "SOCK_RAW": 3,
        "SOL_SOCKET": 0xFFFF, "SO_REUSEADDR": 4, "SO_KEEPALIVE": 8, "SO_BROADCAST": 32, "SO_RCVBUF": 0x1002,
        "SO_SNDBUF": 0x1001, "SO_ERROR": 0x1007, "SOMAXCONN": 128, "IPPROTO_IP": 0, "IPPROTO_ICMP": 1, "IPPROTO_TCP": 6,
        "IPPROTO_UDP": 17, "IPPROTO_IPV6": 41, "TCP_NODELAY": 1, "SHUT_RD": 0, "SHUT_WR": 1, "SHUT_RDWR": 2,
        "AI_PASSIVE": 1, "AI_CANONNAME": 2, "EAI_NONAME": 8, "NI_NUMERICHOST": 2, "INADDR_ANY": 0, "MSG_PEEK": 2,
        "MSG_WAITALL": 64, "MSG_DONTWAIT": 128,
    }
    for name, value in constants.items():
        setattr(socket, name, value)
    socket.has_ipv6 = True
    socket.has_dualstack_ipv6 = lambda: False
    socket.EBADF, socket.EAGAIN, socket.EWOULDBLOCK = 9, 35, 35

    class AddressFamily(int):
        pass

    socket.AddressFamily = socket.SocketKind = AddressFamily

    def inet_aton(text):
        parts = [int(p) for p in text.split(".")]
        if len(parts) != 4 or any(not 0 <= p < 256 for p in parts):
            raise OSError("illegal IP address string passed to inet_aton")
        return bytes(parts)

    def inet_ntoa(data):
        if len(data) != 4:
            raise ValueError("packed IP wrong length")
        return ".".join(str(b) for b in data)

    def inet_pton(family, text):
        if family == 2:
            return inet_aton(text)
        import ipaddress

        try:
            return ipaddress.IPv6Address(text).packed
        except ValueError as exc:
            raise OSError("illegal IP address string passed to inet_pton") from exc

    def inet_ntop(family, data):
        if family == 2:
            return inet_ntoa(data)
        import ipaddress

        return str(ipaddress.IPv6Address(bytes(data)))

    socket.inet_aton, socket.inet_ntoa, socket.inet_pton, socket.inet_ntop = inet_aton, inet_ntoa, inet_pton, inet_ntop
    socket.htons = socket.ntohs = lambda x: ((x & 0xFF) << 8) | (x >> 8 & 0xFF)
    socket.htonl = socket.ntohl = lambda x: int.from_bytes((x & 0xFFFFFFFF).to_bytes(4, "little"), "big")
    return socket


def _present(*names):
    """Are these C extension modules part of the interpreter? Looks without loading them."""
    from importlib.util import find_spec

    for name in names:
        try:
            if find_spec(name) is None:
                return False
        except (ImportError, ValueError):
            return False
    return True


def ssl_module():
    """The real `ssl` when it works, else the stub (registered on first use)."""
    if sys.modules.get("ssl") is None:
        try:
            import ssl
        except ImportError:
            sys.modules["ssl"] = ssl = _build_ssl()
        return ssl
    return sys.modules["ssl"]


def socket_module():
    """The real `socket` when it works, else the stub (registered on first use)."""
    if sys.modules.get("socket") is None:
        try:
            import socket
        except ImportError:
            sys.modules["socket"] = socket = _build_socket()
        return socket
    return sys.modules["socket"]


# --- codecs and hashes ----------------------------------------------------------------------------------------------


def _install_codecs():
    import codecs

    try:
        codecs.lookup("gb18030")
        return
    except LookupError:
        pass
    from _idj_bridge import b64d, b64e, call

    def encode(text, errors="strict"):
        return b64d(call("gbk", op="encode", s=text)), len(text)

    def decode(data, errors="strict"):
        data = bytes(data)
        return call("gbk", op="decode", b64=b64e(data)), len(data)

    class IncrementalEncoder(codecs.IncrementalEncoder):
        def encode(self, text, final=False):
            return encode(text)[0]

    class IncrementalDecoder(codecs.BufferedIncrementalDecoder):
        def _buffer_decode(self, data, errors, final):
            size = len(data)
            if not final and size:
                # Keep a lead byte (or an incomplete four-byte sequence) for the next call.
                tail = 0
                at = 0
                while at < size:
                    if data[at] < 0x81:
                        at += 1
                        continue
                    wide = 4 if at + 1 < size and 0x30 <= data[at + 1] <= 0x39 else 2
                    if at + wide > size:
                        tail = size - at
                        break
                    at += wide
                size -= tail
            return (decode(data[:size])[0] if size else ""), size

    class StreamWriter(codecs.StreamWriter):
        def encode(self, text, errors="strict"):
            return encode(text, errors)

    class StreamReader(codecs.StreamReader):
        def decode(self, data, errors="strict"):
            return decode(data, errors)

    names = {"gbk", "gb2312", "gb18030", "cp936", "936", "ms936", "gb18030_2000", "euc_cn", "chinese"}

    def search(name):
        if name.lower().replace("-", "_") not in names:
            return None
        return codecs.CodecInfo(
            name=name, encode=encode, decode=decode, incrementalencoder=IncrementalEncoder,
            incrementaldecoder=IncrementalDecoder, streamreader=StreamReader, streamwriter=StreamWriter,
        )

    codecs.register(search)


class _HostHash:
    """hashlib-style object computed by the host."""

    _SIZES = {"md5": (16, 64), "sha1": (20, 64), "sha256": (32, 64), "sha512": (64, 128)}

    def __init__(self, name, data=b""):
        self.name = name
        self.digest_size, self.block_size = self._SIZES[name]
        self._data = bytearray(data)

    def update(self, data):
        self._data += data

    def hexdigest(self):
        from _idj_bridge import b64e, call

        return call("hash", alg=self.name, b64=b64e(self._data))

    def digest(self):
        return bytes.fromhex(self.hexdigest())

    def copy(self):
        return _HostHash(self.name, self._data)


def _install_hashes():
    if _present("_hashlib") or _present("_md5", "_sha1", "_sha2") or _present("_md5", "_sha1", "_sha256", "_sha512"):
        return
    import hashlib

    missing = [n for n in ("md5", "sha1", "sha256", "sha512") if not _works(hashlib, n)]
    if not missing:
        return
    original = getattr(hashlib, "new", None)

    def constructor(name):
        def make(data=b"", *, usedforsecurity=True):
            return _HostHash(name, data)

        make.__name__ = "openssl_" + name
        return make

    for name in missing:
        setattr(hashlib, name, constructor(name))

    def new(name, data=b"", **kwargs):
        key = name.lower().replace("-", "")
        if key in missing:
            return _HostHash(key, data)
        if original is None:
            raise ValueError("unsupported hash type " + name)
        return original(name, data, **kwargs)

    hashlib.new = new


def _works(hashlib, name):
    try:
        getattr(hashlib, name)(b"")
        return True
    except (AttributeError, ValueError):
        return False


# --- threads --------------------------------------------------------------------------------------------------------


class _Keyed:
    """Runs a callable under the spider key that was current when it was submitted."""

    __slots__ = ("key", "func")

    def __init__(self, key, func):
        self.key = key
        self.func = func

    def __call__(self, *args, **kwargs):
        import _idj_host

        before = _idj_host.get_key()
        if before == self.key:
            return self.func(*args, **kwargs)
        _idj_host.set_key(self.key)
        try:
            return self.func(*args, **kwargs)
        finally:
            _idj_host.set_key(before if before is not None else "")


def _install_threads():
    try:
        import _idj_host
    except ImportError:
        return
    if not (hasattr(_idj_host, "get_key") and hasattr(_idj_host, "set_key")):
        return
    import threading

    original_start = threading.Thread.start
    if getattr(original_start, "__idj__", False):
        return

    def start(self):
        key = _idj_host.get_key()
        inner = self.run  # bound method, so subclasses that override run() are covered

        def run():
            _idj_host.set_key(key if key is not None else "")
            try:
                inner()
            finally:
                self.__dict__.pop("run", None)

        self.run = run
        try:
            original_start(self)
        except BaseException:
            self.__dict__.pop("run", None)
            raise
        _patch_executor()

    start.__idj__ = True
    start.__wrapped__ = original_start
    threading.Thread.start = start
    _patch_executor()


def _patch_executor():
    """A pool may be shared by several spiders: each task carries the key of its submitter."""
    module = sys.modules.get("concurrent.futures.thread")
    executor = getattr(module, "ThreadPoolExecutor", None)
    if executor is None or getattr(executor.submit, "__idj__", False):
        return
    import _idj_host

    original = executor.submit

    def submit(self, fn, /, *args, **kwargs):
        key = _idj_host.get_key()
        return original(self, _Keyed(key if key is not None else "", fn), *args, **kwargs)

    submit.__idj__ = True
    submit.__wrapped__ = original
    submit.__doc__ = original.__doc__
    executor.submit = submit


# --- entry point ----------------------------------------------------------------------------------------------------


def install():
    """Apply everything once per interpreter."""
    global _installed
    if _installed:
        return
    # Only stubs are registered eagerly: the real modules are slow to load and most scripts never need them.
    if not _present("_socket"):
        socket_module()
    if not _present("_ssl"):
        ssl_module()
    _install_codecs()
    _install_hashes()
    import idj_urllib

    idj_urllib.install()
    _install_threads()
    _installed = True
