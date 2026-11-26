"""Charset detection and decoding shared by requests, lxml, bs4 and chardet (original code, GPL-3.0).

Only the encodings that matter for Chinese video sites are told apart: UTF-8/16, GB18030 and Big5.
"""

from __future__ import annotations

import codecs
import re

_GB = "gb18030"
# Declared "gb2312" is GBK in practice, and GB18030 is a superset of both: same result, fewer replacement characters.
_GB_NAMES = {
    "gb2312", "gbk", "gb18030", "gb_2312", "gb_2312_80", "gb2312_80", "x_gbk", "cp936", "ms936", "windows_936",
    "936", "csgb2312", "euc_cn", "euccn", "gb", "chinese", "hz_gb_2312",
}
_META = re.compile(rb"""<meta\b[^>]*?charset\s*=\s*["']?\s*([A-Za-z0-9_:.\-]+)""", re.I)
_XML_DECL = re.compile(rb"""^\s*<\?xml\b[^>]*?encoding\s*=\s*["']([A-Za-z0-9_:.\-]+)["']""", re.I)

_BOMS = (
    (codecs.BOM_UTF8, "utf-8-sig"),
    (codecs.BOM_UTF32_LE, "utf-32"),
    (codecs.BOM_UTF32_BE, "utf-32"),
    (codecs.BOM_UTF16_LE, "utf-16"),
    (codecs.BOM_UTF16_BE, "utf-16"),
)
_SIMPLIFIED = frozenset("的一是不了在人有我他这个们中来上大为和国地到以说时要就出会可也你对生能而子那得于着下自之年过发后作里播放视频剧集电影更新")
_TRADITIONAL = frozenset("的一是不了在人有我他這個們中來上大為和國地到以說時要就出會可也你對生能而子那得於著下自之年過發後作裡播放視頻劇集電影更新")


def _norm(name):
    return name.strip().strip("\"'").lower().replace("-", "_").replace(" ", "_")


def canonical(name):
    """Canonical codec name, or None when the name is unknown."""
    if not name:
        return None
    key = _norm(name)
    if key in _GB_NAMES:
        return _GB
    try:
        return codecs.lookup(key).name
    except (LookupError, ValueError):
        return None


def _host_gbk(data):
    from _idj_bridge import b64e, call

    return call("gbk", op="decode", b64=b64e(data))


def decode(data, encoding, errors="strict"):
    """bytes -> str; raises LookupError for unknown names, UnicodeDecodeError in strict mode."""
    key = _norm(encoding)
    if key in _GB_NAMES:
        try:
            return data.decode(_GB, errors)
        except LookupError:
            # The CJK codecs are an optional C extension; fall back to the host decoder.
            return _host_gbk(data)
    return data.decode(encoding, errors)


def declared(data, limit=4096):
    """Charset named by a BOM, an XML declaration or a <meta> tag, or None."""
    for bom, name in _BOMS:
        if data.startswith(bom):
            return name
    head = bytes(data[:limit])
    found = _XML_DECL.search(head) or _META.search(head)
    if not found:
        return None
    return canonical(found.group(1).decode("ascii"))


def _fits(data, name):
    """Strictly decodable, ignoring a multi-byte character cut off at the very end."""
    try:
        decoder = codecs.getincrementaldecoder(name)("strict")
        return decoder.decode(data, False)
    except (LookupError, UnicodeDecodeError):
        return None


def _score(text, common):
    return sum(1 for ch in text if ch in common)


def detect(data):
    """Best guess for undeclared bytes -> (encoding or None, confidence)."""
    if not data:
        return None, 0.0
    for bom, name in _BOMS:
        if data.startswith(bom):
            return name, 1.0
    if data.isascii():
        return "ascii", 1.0
    if _fits(data, "utf-8") is not None:
        return "utf-8", 0.99
    # Mostly valid UTF-8 with a few damaged bytes (truncated or mixed pages) is still UTF-8.
    loose = data.decode("utf-8", "replace")
    bad = loose.count("�")
    wide = sum(1 for ch in loose if ch > "\x7f") - bad
    if wide > 20 and bad * 20 < wide:
        return "utf-8", 0.8
    gb, big5 = _fits(data, _GB), _fits(data, "big5")
    if gb is not None and big5 is not None:
        sample_gb, sample_big5 = gb[:20000], big5[:20000]
        if _score(sample_big5, _TRADITIONAL) > _score(sample_gb, _SIMPLIFIED):
            return "big5", 0.7
        return _GB, 0.9
    if gb is not None:
        return _GB, 0.9
    if big5 is not None:
        return "big5", 0.8
    loose = None
    try:
        loose = data.decode(_GB, "replace")
    except LookupError:
        pass
    if loose is not None:
        bad = loose.count("�")
        wide = sum(1 for ch in loose if "一" <= ch <= "鿿")
        if wide > 20 and bad * 10 < wide:
            return _GB, 0.6
    return "ISO-8859-1", 0.3


def sniff(data):
    """Encoding for a web page without a transport charset: declaration first (if it fits), then detection."""
    name = declared(data)
    if name:
        if name in ("utf-16", "utf-32", "utf-8-sig"):
            return name
        if name.startswith("utf-16") or name.startswith("utf-32"):
            name = "utf-8"  # a <meta> that was readable as ASCII cannot really be UTF-16
        if name in ("iso8859-1", "ascii"):
            name = None
    if name and (_fits(data, name) is not None or name == _GB):
        if name == _GB and not data.isascii() and _fits(data, "utf-8") is not None:
            return "utf-8"  # stale GBK <meta> on a page that is clean UTF-8
        return name
    guess, _ = detect(data)
    if guess in (None, "ascii"):
        return name or "utf-8"
    if guess == "ISO-8859-1" and name:
        return name
    return guess


def decode_markup(data, encoding=None):
    """HTML/XML bytes -> (text, encoding used)."""
    data = bytes(data)
    if encoding:
        name = canonical(encoding)
        if name is None:
            raise LookupError("unknown encoding: '%s'" % encoding)
        if name == "utf-8" and data.startswith(codecs.BOM_UTF8):
            name = "utf-8-sig"
    else:
        name = sniff(data)
    return decode(data, name, "replace"), name
