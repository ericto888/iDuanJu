"""Request and response objects (original implementation for i短剧, GPL-3.0)."""

from __future__ import annotations

import json as _json
import re
from urllib.parse import quote, urlencode, urlsplit, urlunsplit

import _idj_text
from _idj_http import multipart

from .auth import HTTPBasicAuth
from .cookies import RequestsCookieJar, _is_std_jar, cookiejar_from_dict, get_cookie_header
from .exceptions import HTTPError, InvalidURL, JSONDecodeError, MissingSchema
from .hooks import default_hooks
from .status_codes import codes
from .structures import CaseInsensitiveDict
from .utils import (
    _UNRESERVED, check_header_validity, get_auth_from_url, get_encoding_from_headers, guess_filename, guess_json_utf,
    iter_slices, parse_header_links, requote_uri, super_len, to_key_val_list,
)

REDIRECT_STATI = (codes.moved, codes.found, codes.other, codes.temporary_redirect, codes.permanent_redirect)
DEFAULT_REDIRECT_LIMIT = 30
CONTENT_CHUNK_SIZE = 10 * 1024
ITER_CHUNK_SIZE = 512

_PATH_SAFE = "".join(sorted(_UNRESERVED)) + "!$&'()*+,;=:@/"
_PERCENT = re.compile(r"%[0-9a-fA-F]{2}")


def _encode_component(text, safe):
    """Percent-encode illegal characters; existing escapes survive when every `%` starts a valid one."""
    if not text:
        return text
    valid = len(_PERCENT.findall(text)) == text.count("%")
    if valid:
        text = _PERCENT.sub(lambda m: m.group().upper(), text)
    return quote(text, safe=safe + ("%" if valid else ""), errors="surrogatepass")


def _drop_dots(path):
    """Remove `.` and `..` path segments."""
    if "/." not in path:
        return path
    out = []
    for segment in path.split("/"):
        if segment == ".":
            continue
        if segment != "..":
            out.append(segment)
        elif out:
            out.pop()
    if path.startswith("/") and (not out or out[0]):
        out.insert(0, "")
    if path.endswith(("/.", "/..")):
        out.append("")
    return "/".join(out)


def _idna(host):
    if host.isascii():
        return host.lower()
    try:
        return host.encode("idna").decode("ascii")
    except (UnicodeError, LookupError) as exc:
        raise InvalidURL("URL has an invalid label.") from exc


class RequestEncodingMixin:
    @property
    def path_url(self):
        parts = urlsplit(self.url)
        return (parts.path or "/") + ("?" + parts.query if parts.query else "")

    @staticmethod
    def _encode_params(data):
        if isinstance(data, (str, bytes)):
            return data
        if hasattr(data, "read"):
            return data
        if hasattr(data, "__iter__"):
            out = []
            for key, values in to_key_val_list(data):
                if isinstance(values, (str, bytes)) or not hasattr(values, "__iter__"):
                    values = [values]
                for value in values:
                    if value is not None:
                        out.append((
                            key.encode("utf-8") if isinstance(key, str) else key,
                            value.encode("utf-8") if isinstance(value, str) else value,
                        ))
            return urlencode(out, doseq=True)
        return data

    @staticmethod
    def _encode_files(files, data):
        if not files:
            raise ValueError("Files must be provided.")
        if isinstance(data, (str, bytes)):
            raise ValueError("Data must not be a string.")
        fields = []
        for name, values in to_key_val_list(data or {}):
            if isinstance(values, (str, bytes)) or not hasattr(values, "__iter__"):
                values = [values]
            for value in values:
                if value is not None:
                    if not isinstance(value, bytes):
                        value = str(value).encode("utf-8")
                    fields.append((name.decode("utf-8") if isinstance(name, bytes) else name, None, value, None, None))
        for name, value in to_key_val_list(files or {}):
            content_type = extra = None
            if isinstance(value, (tuple, list)):
                if len(value) == 2:
                    filename, content = value
                elif len(value) == 3:
                    filename, content, content_type = value
                else:
                    filename, content, content_type, extra = value
            else:
                filename, content = guess_filename(value) or name, value
            if content is None:
                continue
            if hasattr(content, "read"):
                content = content.read()
            if isinstance(content, str):
                content = content.encode("utf-8")
            fields.append((name, filename, bytes(content), content_type, extra))
        return multipart(fields)


class RequestHooksMixin:
    def register_hook(self, event, hook):
        if event not in self.hooks:
            raise ValueError('Unsupported event specified, with event name "%s"' % event)
        if callable(hook):
            self.hooks[event].append(hook)
        elif hasattr(hook, "__iter__"):
            self.hooks[event].extend(h for h in hook if callable(h))

    def deregister_hook(self, event, hook):
        try:
            self.hooks[event].remove(hook)
            return True
        except ValueError:
            return False


class Request(RequestHooksMixin):
    """A request as the user described it."""

    def __init__(self, method=None, url=None, headers=None, files=None, data=None, params=None, auth=None, cookies=None,
                 hooks=None, json=None):
        self.method = method
        self.url = url
        self.headers = {} if headers is None else headers
        self.files = [] if files is None else files
        self.data = [] if data is None else data
        self.json = json
        self.params = {} if params is None else params
        self.auth = auth
        self.cookies = cookies
        self.hooks = default_hooks()
        for event, hook in (hooks or {}).items():
            self.register_hook(event, hook)

    def __repr__(self):
        return "<Request [%s]>" % self.method

    def prepare(self):
        p = PreparedRequest()
        p.prepare(
            method=self.method, url=self.url, headers=self.headers, files=self.files, data=self.data, json=self.json,
            params=self.params, auth=self.auth, cookies=self.cookies, hooks=self.hooks,
        )
        return p


class PreparedRequest(RequestEncodingMixin, RequestHooksMixin):
    """A request with the exact URL, headers and body that go to the host."""

    def __init__(self):
        self.method = None
        self.url = None
        self.headers = None
        self._cookies = None
        self.body = None
        self.hooks = default_hooks()

    def prepare(self, method=None, url=None, headers=None, files=None, data=None, params=None, auth=None, cookies=None,
                hooks=None, json=None):
        self.prepare_method(method)
        self.prepare_url(url, params)
        self.prepare_headers(headers)
        self.prepare_cookies(cookies)
        self.prepare_body(data, files, json)
        self.prepare_auth(auth, url)
        self.prepare_hooks(hooks)

    def __repr__(self):
        return "<PreparedRequest [%s]>" % self.method

    def copy(self):
        p = PreparedRequest()
        p.method = self.method
        p.url = self.url
        p.headers = self.headers.copy() if self.headers is not None else None
        p._cookies = self._cookies.copy() if isinstance(self._cookies, RequestsCookieJar) else self._cookies
        p.body = self.body
        p.hooks = self.hooks
        return p

    def prepare_method(self, method):
        if method is not None:
            method = method.decode("ascii") if isinstance(method, bytes) else str(method)
            self.method = method.upper()

    def prepare_url(self, url, params):
        url = url.decode("utf-8") if isinstance(url, bytes) else str(url)
        url = url.lstrip()
        if ":" in url and not url.lower().startswith("http"):
            self.url = url
            return
        # urlsplit would drop these silently; Requests sends them percent-encoded.
        for char in "\t\r\n":
            if char in url:
                url = url.replace(char, quote(char))
        try:
            parts = urlsplit(url)
            port = parts.port
        except ValueError as exc:
            raise InvalidURL("Failed to parse: %s (%s)" % (url, exc)) from None
        if not parts.scheme:
            raise MissingSchema("Invalid URL %r: No scheme supplied. Perhaps you meant https://%s?" % (url, url))
        host = parts.hostname
        if not host:
            raise InvalidURL("Invalid URL %r: No host supplied" % url)
        if host.startswith(("*", ".")):
            raise InvalidURL("URL has an invalid label.")
        netloc = "[%s]" % host if ":" in host else _idna(host)
        if port is not None:
            netloc += ":%d" % port
        userinfo, at, _ = parts.netloc.rpartition("@")
        if at:
            netloc = userinfo + "@" + netloc
        path = _encode_component(_drop_dots(parts.path or "/"), _PATH_SAFE)
        query = _encode_component(parts.query, _PATH_SAFE + "?")
        fragment = _encode_component(parts.fragment, _PATH_SAFE + "?")
        extra = self._encode_params(params)
        if isinstance(extra, bytes):
            extra = extra.decode("utf-8")
        if extra:
            query = "%s&%s" % (query, extra) if query else extra
        self.url = requote_uri(urlunsplit((parts.scheme.lower(), netloc, path, query, fragment)))

    def prepare_headers(self, headers):
        self.headers = CaseInsensitiveDict()
        for name, value in dict(headers or {}).items():
            if value is None:
                continue
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                value = str(value)
            if isinstance(value, str):
                value = value.strip(" \t")
            check_header_validity((name, value))
            self.headers[name.decode("latin-1") if isinstance(name, bytes) else name] = value

    def prepare_body(self, data, files, json=None):
        body = content_type = None
        if not data and json is not None:
            content_type = "application/json"
            try:
                body = _json.dumps(json, allow_nan=False).encode("utf-8")
            except ValueError as exc:
                from .exceptions import InvalidJSONError

                raise InvalidJSONError(exc, request=self) from exc
        stream = hasattr(data, "__iter__") and not isinstance(data, (str, bytes, bytearray, list, tuple, dict)) and \
            not hasattr(data, "items")
        if stream:
            if files:
                raise NotImplementedError("Streamed bodies and files are mutually exclusive.")
            if hasattr(data, "read"):
                body = data.read()
            else:
                body = b"".join(c.encode("utf-8") if isinstance(c, str) else bytes(c) for c in data)
        elif files:
            body, content_type = self._encode_files(files, data)
        elif data:
            if isinstance(data, bytearray):
                data = bytes(data)
            body = self._encode_params(data)
            content_type = None if isinstance(data, (str, bytes)) or hasattr(data, "read") else \
                "application/x-www-form-urlencoded"
            if hasattr(body, "read"):
                body = body.read()
        if content_type and "content-type" not in self.headers:
            self.headers["Content-Type"] = content_type
        self.prepare_content_length(body)
        self.body = body

    def prepare_content_length(self, body):
        if body is not None:
            length = super_len(body)
            if length:
                self.headers["Content-Length"] = str(length)
        elif self.method not in ("GET", "HEAD") and self.headers.get("Content-Length") is None:
            self.headers["Content-Length"] = "0"

    def prepare_auth(self, auth, url=""):
        if auth is None:
            pair = get_auth_from_url(self.url)
            auth = pair if any(pair) else None
        if auth:
            if isinstance(auth, tuple) and len(auth) == 2:
                auth = HTTPBasicAuth(*auth)
            result = auth(self)
            self.__dict__.update(result.__dict__)
            self.prepare_content_length(self.body)

    def prepare_cookies(self, cookies):
        if isinstance(cookies, RequestsCookieJar) or _is_std_jar(cookies):
            self._cookies = cookies
        else:
            self._cookies = cookiejar_from_dict(cookies)
        # An explicit Cookie header wins over the jar.
        if "Cookie" not in self.headers:
            value = get_cookie_header(self._cookies, self)
            if value is not None:
                self.headers["Cookie"] = value

    def prepare_hooks(self, hooks):
        for event in hooks or ():
            self.register_hook(event, hooks[event])

    def body_bytes(self):
        """Body as the host gets it."""
        body = self.body
        if body is None or isinstance(body, bytes):
            return body
        if isinstance(body, str):
            return body.encode("utf-8", "surrogatepass")
        if hasattr(body, "read"):
            body = body.read()
            return body.encode("utf-8") if isinstance(body, str) else body
        return bytes(body)


class _SniffedText(str):
    """Text whose charset the server did not name.

    Real requests decodes such pages as ISO-8859-1, and scripts repair that with
    `r.text.encode('ISO-8859-1').decode('utf-8')`. The text is already right here, so that round trip must lead back to
    the original bytes.
    """

    def __new__(cls, text, raw):
        self = super().__new__(cls, text)
        self._raw = raw
        return self

    def __reduce__(self):
        return str, (str(self),)  # copies and pickles are ordinary strings

    def encode(self, encoding="utf-8", errors="strict"):
        if _idj_text.canonical(encoding) == "iso8859-1":
            return self._raw
        return str.encode(self, encoding, errors)


class Response:
    """A buffered response."""

    __attrs__ = [
        "_content", "status_code", "url", "headers", "history", "encoding", "reason", "cookies", "elapsed", "request",
    ]

    def __init__(self):
        self._content = False
        self._content_consumed = False
        self._next = None
        self._encoding = None
        self._encoding_by = None  # "header", "default" (guessed from the media type) or "user"
        self._text = None
        self.status_code = None
        self.headers = CaseInsensitiveDict()
        self.raw = None
        self.url = None
        self.history = []
        self.reason = None
        self.cookies = cookiejar_from_dict({})
        self._elapsed = 0.0
        self.request = None
        self.connection = None

    # -- encoding ----------------------------------------------------------------------------------------------------
    @property
    def encoding(self):
        return self._encoding

    @encoding.setter
    def encoding(self, value):
        self._encoding = value
        self._encoding_by = "user"
        self._text = None

    def _encoding_from_headers(self):
        self._encoding = get_encoding_from_headers(self.headers)
        named = "charset" in (self.headers.get("content-type") or "").lower()
        self._encoding_by = "header" if named and self._encoding else "default"
        self._text = None

    @property
    def apparent_encoding(self):
        return _idj_text.detect(self.content)[0] or "utf-8"

    @property
    def elapsed(self):
        from datetime import timedelta

        if isinstance(self._elapsed, timedelta):
            return self._elapsed
        return timedelta(seconds=self._elapsed)

    @elapsed.setter
    def elapsed(self, value):
        self._elapsed = value

    # -- body --------------------------------------------------------------------------------------------------------
    @property
    def content(self):
        if self._content is False:
            if self.raw is None:
                self._content = None
            else:
                self._content = self.raw.read() or b""
            self._content_consumed = True
        return self._content

    @property
    def text(self):
        if self._text is None:
            self._text = self._decode()
        return self._text

    def _decode(self):
        content = self.content
        if not content:
            return ""
        encoding = self._encoding
        if encoding and self._encoding_by != "default":
            try:
                return _idj_text.decode(content, encoding, "replace")
            except (LookupError, TypeError):
                return content.decode("utf-8", "replace")
        if encoding == "utf-8":  # application/json
            try:
                return content.decode("utf-8")
            except UnicodeDecodeError:
                return _idj_text.decode(content, _idj_text.sniff(content), "replace")
        if encoding is None and self._encoding_by == "user":
            return _idj_text.decode(content, self.apparent_encoding, "replace")
        text = _idj_text.decode(content, _idj_text.sniff(content), "replace")
        if encoding and not content.isascii():
            return _SniffedText(text, content)
        return text

    def json(self, **kwargs):
        content = self.content
        if content and len(content) > 3 and (not self._encoding or self._encoding_by == "default"):
            name = guess_json_utf(content)
            if name is not None:
                try:
                    return _json.loads(content.decode(name), **kwargs)
                except UnicodeDecodeError:
                    pass
                except _json.JSONDecodeError as exc:
                    raise JSONDecodeError(exc.msg, exc.doc, exc.pos) from exc
        try:
            text = self.text
            return _json.loads(text[1:] if text[:1] == "﻿" else text, **kwargs)
        except _json.JSONDecodeError as exc:
            raise JSONDecodeError(exc.msg, exc.doc, exc.pos) from exc

    def iter_content(self, chunk_size=1, decode_unicode=False):
        if chunk_size is not None and not isinstance(chunk_size, int):
            raise TypeError("chunk_size must be an int, it is instead a %s." % type(chunk_size))
        chunks = iter_slices(self.content or b"", chunk_size)
        if decode_unicode:
            from .utils import stream_decode_response_unicode

            return stream_decode_response_unicode(chunks, self)
        return chunks

    def iter_lines(self, chunk_size=ITER_CHUNK_SIZE, decode_unicode=False, delimiter=None):
        data = self.content or b""
        if decode_unicode and self.encoding:
            data = self.text
        if not data:
            return
        yield from (data.split(delimiter) if delimiter else data.splitlines())

    def __iter__(self):
        return self.iter_content(128)

    # -- status ------------------------------------------------------------------------------------------------------
    @property
    def ok(self):
        try:
            self.raise_for_status()
        except HTTPError:
            return False
        return True

    def __bool__(self):
        return self.ok

    def __repr__(self):
        return "<Response [%s]>" % self.status_code

    @property
    def is_redirect(self):
        return "location" in self.headers and self.status_code in REDIRECT_STATI

    @property
    def is_permanent_redirect(self):
        return "location" in self.headers and self.status_code in (codes.moved_permanently, codes.permanent_redirect)

    @property
    def next(self):
        return self._next

    @property
    def links(self):
        header = self.headers.get("link")
        out = {}
        for link in parse_header_links(header) if header else ():
            out[link.get("rel") or link.get("url")] = link
        return out

    def raise_for_status(self):
        kind = None
        if 400 <= self.status_code < 500:
            kind = "Client"
        elif 500 <= self.status_code < 600:
            kind = "Server"
        if kind:
            raise HTTPError("%s %s Error: %s for url: %s" % (self.status_code, kind, self.reason, self.url), response=self)

    # -- life cycle --------------------------------------------------------------------------------------------------
    def close(self):
        if self._content is False:
            self.content  # the body is already in memory; keep it readable
        if self.raw is not None and hasattr(self.raw, "close"):
            self.raw.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def __getstate__(self):
        self.content
        return {name: getattr(self, name, None) for name in self.__attrs__}

    def __setstate__(self, state):
        self.__init__()
        for name, value in state.items():
            setattr(self, name, value)
        self._content_consumed = True
