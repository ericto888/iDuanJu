"""Helpers scripts import from requests.utils (original implementation for i短剧, GPL-3.0)."""

from __future__ import annotations

import codecs
import os
import re
from urllib.parse import quote, unquote, urlparse, urlsplit, urlunparse, urlunsplit

from .__version__ import __version__
from .compat import getproxies, proxy_bypass
from .cookies import RequestsCookieJar, cookiejar_from_dict
from .exceptions import InvalidHeader, InvalidURL
from .structures import CaseInsensitiveDict

DEFAULT_ACCEPT_ENCODING = "gzip, deflate"
DEFAULT_CA_BUNDLE_PATH = ""
DEFAULT_PORTS = {"http": 80, "https": 443}

_UNRESERVED = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")


def default_user_agent(name="python-requests"):
    return "%s/%s" % (name, __version__)


def default_headers():
    return CaseInsensitiveDict({
        "User-Agent": default_user_agent(),
        "Accept-Encoding": DEFAULT_ACCEPT_ENCODING,
        "Accept": "*/*",
        "Connection": "keep-alive",
    })


# --- key/value helpers ----------------------------------------------------------------------------------------------


def to_key_val_list(value):
    if value is None:
        return None
    if isinstance(value, (str, bytes, bool, int)):
        raise ValueError("cannot encode objects that are not 2-tuples")
    return list(value.items() if hasattr(value, "items") else value)


def from_key_val_list(value):
    if value is None:
        return None
    if isinstance(value, (str, bytes, bool, int)):
        raise ValueError("cannot encode objects that are not 2-tuples")
    return dict(value)


def to_native_string(string, encoding="ascii"):
    return string if isinstance(string, str) else string.decode(encoding)


def dict_to_sequence(d):
    return d.items() if hasattr(d, "items") else d


def super_len(o):
    if o is None:
        return 0
    if isinstance(o, str):
        return len(o.encode("utf-8"))
    if hasattr(o, "__len__"):
        return len(o)
    if hasattr(o, "len"):
        return o.len
    if hasattr(o, "seek") and hasattr(o, "tell"):
        at = o.tell()
        o.seek(0, 2)
        end = o.tell()
        o.seek(at)
        return end - at
    return 0


def guess_filename(obj):
    name = getattr(obj, "name", None)
    if name and isinstance(name, (str, bytes)) and name[0] not in ("<", 60) and name[-1] not in (">", 62):
        return os.path.basename(name)
    return None


def iter_slices(string, slice_length):
    if slice_length is None or slice_length <= 0:
        slice_length = len(string) or 1
    for pos in range(0, len(string), slice_length):
        yield string[pos:pos + slice_length]


# --- cookies --------------------------------------------------------------------------------------------------------


def dict_from_cookiejar(cj):
    return {cookie.name: cookie.value for cookie in cj}


def add_dict_to_cookiejar(cj, cookie_dict):
    return cookiejar_from_dict(cookie_dict, cj)


# --- encodings ------------------------------------------------------------------------------------------------------


def _parse_content_type_header(header):
    kind, *params = header.split(";")
    out = {}
    for item in params:
        item = item.strip()
        if item:
            key, sep, value = item.partition("=")
            out[key.strip("\"' ").lower()] = value.strip("\"' ") if sep else True
    return kind.strip(), out


def get_encoding_from_headers(headers):
    content_type = headers.get("content-type")
    if not content_type:
        return None
    content_type, params = _parse_content_type_header(content_type)
    charset = params.get("charset")
    if isinstance(charset, str):
        return charset
    if "text" in content_type:
        return "ISO-8859-1"
    if "application/json" in content_type:
        return "utf-8"
    return None


def get_encodings_from_content(content):
    if isinstance(content, bytes):
        content = content.decode("latin-1")
    return (
        re.findall(r"""<meta.*?charset=["']*(.+?)["'>]""", content, re.I)
        + re.findall(r"""<meta.*?content=["']*;?charset=(.+?)["'>]""", content, re.I)
        + re.findall(r"""^<\?xml.*?encoding=["']*(.+?)["'>]""", content)
    )


def guess_json_utf(data):
    sample = data[:4]
    if sample in (codecs.BOM_UTF32_LE, codecs.BOM_UTF32_BE):
        return "utf-32"
    if sample[:3] == codecs.BOM_UTF8:
        return "utf-8-sig"
    if sample[:2] in (codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE):
        return "utf-16"
    nulls = sample.count(b"\x00")
    if nulls == 0:
        return "utf-8"
    if nulls == 2:
        if sample[::2] == b"\x00\x00":
            return "utf-16-be"
        if sample[1::2] == b"\x00\x00":
            return "utf-16-le"
    if nulls == 3:
        if sample[:3] == b"\x00\x00\x00":
            return "utf-32-be"
        if sample[1:] == b"\x00\x00\x00":
            return "utf-32-le"
    return None


def get_unicode_from_response(r):
    return r.text


# --- URLs -----------------------------------------------------------------------------------------------------------


def unquote_unreserved(uri):
    parts = uri.split("%")
    for i in range(1, len(parts)):
        code = parts[i][:2]
        if len(code) == 2 and code.isalnum():
            try:
                char = chr(int(code, 16))
            except ValueError:
                raise InvalidURL("Invalid percent-escape sequence: '%s'" % code) from None
            parts[i] = char + parts[i][2:] if char in _UNRESERVED else "%" + parts[i]
        else:
            parts[i] = "%" + parts[i]
    return "".join(parts)


def requote_uri(uri):
    safe_with_percent = "!#$%&'()*+,/:;=?@[]~"
    try:
        return quote(unquote_unreserved(uri), safe=safe_with_percent)
    except InvalidURL:
        return quote(uri, safe="!#$&'()*+,/:;=?@[]~")


def get_auth_from_url(url):
    parts = urlsplit(url)
    try:
        return unquote(parts.username or ""), unquote(parts.password or "")
    except (AttributeError, TypeError):
        return "", ""


def urldefragauth(url):
    scheme, netloc, path, query, _ = urlsplit(url)
    if not netloc:
        netloc, path = path, netloc
    return urlunsplit((scheme, netloc.rsplit("@", 1)[-1], path, query, ""))


def prepend_scheme_if_needed(url, new_scheme):
    return url if re.match(r"[a-zA-Z][\w+.\-]*://", url) else "%s://%s" % (new_scheme, url.lstrip("/"))


def is_ipv4_address(string_ip):
    parts = string_ip.split(".")
    return len(parts) == 4 and all(p.isdigit() and int(p) < 256 for p in parts)


def select_proxy(url, proxies):
    return None


def should_bypass_proxies(url, no_proxy=None):
    return True


def get_environ_proxies(url, no_proxy=None):
    return {}


def get_netrc_auth(url, raise_errors=False):
    return None


# --- headers --------------------------------------------------------------------------------------------------------


def check_header_validity(header):
    name, value = header
    for part in (name, value):
        if isinstance(part, (bytes, str)):
            bad = (b"\r", b"\n") if isinstance(part, bytes) else ("\r", "\n")
            if any(b in part for b in bad):
                raise InvalidHeader(
                    "Invalid leading whitespace, reserved character(s), or return character(s) in header %s: %r"
                    % ("name" if part is name else "value", part)
                )
        else:
            raise InvalidHeader(
                "Header part (%r) from (%r, %r) must be of type str or bytes, not %s"
                % (part, name, value, type(part))
            )


def unquote_header_value(value, is_filename=False):
    if value and value[0] == value[-1] == '"':
        value = value[1:-1]
        if not is_filename or value[:2] != "\\\\":
            return value.replace("\\\\", "\\").replace('\\"', '"')
    return value


def parse_list_header(value):
    return [unquote_header_value(v.strip()) for v in re.findall(r'(?:[^,"]|"(?:\\.|[^"])*")+', value) if v.strip()]


def parse_dict_header(value):
    out = {}
    for item in re.findall(r'(?:[^,"]|"(?:\\.|[^"])*")+', value):
        key, sep, data = item.strip().partition("=")
        if key:
            out[key] = unquote_header_value(data) if sep else None
    return out


def parse_header_links(value):
    links = []
    for part in re.split(r", *<", value.strip(" '\"")):
        url, _, params = part.partition(";")
        link = {"url": url.strip("<> '\"")}
        for param in params.split(";"):
            key, sep, data = param.partition("=")
            if not sep:
                break
            link[key.strip(" '\"")] = data.strip(" '\"")
        links.append(link)
    return links


def stream_decode_response_unicode(iterator, r):
    if r.encoding is None:
        yield from iterator
        return
    decoder = codecs.getincrementaldecoder(r.encoding)(errors="replace")
    for chunk in iterator:
        text = decoder.decode(chunk)
        if text:
            yield text
    text = decoder.decode(b"", final=True)
    if text:
        yield text
