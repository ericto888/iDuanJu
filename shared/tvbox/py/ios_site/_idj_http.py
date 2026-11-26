"""HTTP exchange through the host, shared by requests, urllib3 and the urllib patch (original code, GPL-3.0)."""

from __future__ import annotations

import re

from _idj_bridge import HostError, b64d, b64e, call

__all__ = ["exchange", "split_set_cookie", "is_timeout", "is_tls", "HostError", "multipart", "DEFAULT_TIMEOUT"]

DEFAULT_TIMEOUT = 10.0
# "a=1; expires=Wed, 21 Oct 2025 07:28:00 GMT, b=2": a new cookie starts after a comma followed by "name=".
_COOKIE_GAP = re.compile(r",(?=\s*[^\s;,=]+=)")
_TIMEOUT = re.compile(r"超时|time[d\s-]*out", re.I)
_TLS = re.compile(r"\bssl\b|\btls\b|certificate|证书|handshake", re.I)


def is_timeout(message):
    return bool(_TIMEOUT.search(message))


def is_tls(message):
    return bool(_TLS.search(message))


def split_set_cookie(value):
    """Undo the comma-joining some HTTP stacks apply to repeated Set-Cookie headers."""
    return [part.strip() for part in _COOKIE_GAP.split(value) if part.strip()]


def timeout_ms(timeout, default=DEFAULT_TIMEOUT):
    """requests-style timeout (None, number or (connect, read)) -> milliseconds."""
    if isinstance(timeout, (tuple, list)):
        values = [float(t) for t in timeout if t is not None]
        seconds = max(values) if values else default
    elif timeout is None:
        seconds = default
    else:
        seconds = float(timeout)
    if seconds <= 0:
        raise ValueError(
            "Attempted to set timeout to %s, but the timeout cannot be set to a value less than or equal to 0." % timeout
        )
    return max(1, int(seconds * 1000))


def _wire_headers(headers):
    out = {}
    for key, value in headers.items():
        if value is None:
            continue
        key = key.decode("latin-1") if isinstance(key, bytes) else str(key)
        if isinstance(value, bytes):
            try:
                value = value.decode("utf-8")
            except UnicodeDecodeError:
                value = value.decode("latin-1")
        low = key.lower()
        if low == "content-length":
            continue  # the host knows the real length
        if low == "accept-encoding" and str(value).strip().lower() != "identity":
            continue  # only the host knows which codings it can undo
        out[key] = str(value)
    return out


def _gunzip(data):
    try:
        import zlib
    except ImportError:
        return b64d(call("inflate", b64=b64e(data), kind="gzip"))
    return zlib.decompress(data, 31)


def exchange(method, url, headers, body=None, timeout=None, verify=True, redirect=False):
    """One request. Returns (status, final url, [(name, value)…], body bytes); raises HostError."""
    args = {
        "url": url,
        "method": method,
        "headers": _wire_headers(headers),
        "timeout": timeout_ms(timeout),
        "redirect": bool(redirect),
        "verify": bool(verify),
        "out": "b64",
    }
    if body is not None:
        args["bodyB64"] = b64e(body)
    reply = call("http", **args)
    if not isinstance(reply, dict):
        raise HostError("宿主返回了无效的 HTTP 结果", "http")
    pairs = []
    for key, values in (reply.get("headers") or {}).items():
        for value in values if isinstance(values, (list, tuple)) else [values]:
            if key.lower() == "set-cookie":
                pairs.extend((key, v) for v in split_set_cookie(str(value)))
            else:
                pairs.append((key, str(value)))
    content = b64d(reply.get("body"))
    if content[:3] == b"\x1f\x8b\x08" and any(
        k.lower() == "content-encoding" and "gzip" in v.lower() for k, v in pairs
    ):
        # A host that hands over the raw coding; leave the bytes alone if they are not what the header says.
        try:
            content = _gunzip(content)
        except Exception:
            pass
    return int(reply.get("code") or 0), reply.get("url") or url, pairs, content


def _quote_param(name, value):
    escaped = value.replace("\\", "\\\\").replace('"', "%22").replace("\r", "%0D").replace("\n", "%0A")
    return '%s="%s"' % (name, escaped)


def multipart(fields, boundary=None):
    """fields: iterable of (name, filename or None, data bytes, content type or None, extra headers dict).

    Returns (body bytes, content type).
    """
    if boundary is None:
        from os import urandom

        boundary = urandom(16).hex()
    out = []
    for name, filename, data, content_type, extra in fields:
        head = ["Content-Disposition: form-data; " + _quote_param("name", name)]
        if filename is not None:
            head[0] += "; " + _quote_param("filename", filename)
        if content_type:
            head.append("Content-Type: " + content_type)
        for key, value in (extra or {}).items():
            head.append("%s: %s" % (key, value))
        out.append(("--%s\r\n%s\r\n\r\n" % (boundary, "\r\n".join(head))).encode("utf-8"))
        out.append(data)
        out.append(b"\r\n")
    out.append(("--%s--\r\n" % boundary).encode("ascii"))
    return b"".join(out), "multipart/form-data; boundary=" + boundary
