"""Session: defaults, cookies and redirects (original implementation for i短剧, GPL-3.0)."""

from __future__ import annotations

from collections.abc import Mapping
from urllib.parse import urljoin, urlparse

from .adapters import HTTPAdapter
from .cookies import RequestsCookieJar, cookiejar_from_dict, extract_cookies_to_jar, is_jar, merge_cookies
from .exceptions import InvalidSchema, TooManyRedirects
from .hooks import default_hooks, dispatch_hook
from .models import DEFAULT_REDIRECT_LIMIT, REDIRECT_STATI, PreparedRequest, Request
from .status_codes import codes
from .structures import CaseInsensitiveDict
from .utils import DEFAULT_PORTS, default_headers, requote_uri, to_key_val_list


def merge_setting(request_setting, session_setting, dict_class=dict):
    """Combine a request value with the session default; None values remove a key."""
    if session_setting is None:
        return request_setting
    if request_setting is None:
        return session_setting
    if not (isinstance(session_setting, Mapping) and isinstance(request_setting, (Mapping, list, tuple))):
        return request_setting
    merged = dict_class(to_key_val_list(session_setting))
    merged.update(to_key_val_list(request_setting))
    for key in [k for k, v in merged.items() if v is None]:
        del merged[key]
    return merged


def merge_hooks(request_hooks, session_hooks, dict_class=dict):
    if session_hooks is None or session_hooks.get("response") == []:
        return request_hooks
    if request_hooks is None or request_hooks.get("response") == []:
        return session_hooks
    return merge_setting(request_hooks, session_hooks, dict_class)


def _params(request_params, session_params):
    """Like merge_setting, but keeps repeated keys of a list of pairs and string parameters."""
    if not session_params:
        return request_params
    if not request_params:
        return session_params
    if isinstance(request_params, (str, bytes)) or isinstance(session_params, (str, bytes)):
        return request_params
    if isinstance(request_params, (list, tuple)):
        mine = {k for k, _ in request_params}
        return [(k, v) for k, v in to_key_val_list(session_params) if k not in mine] + list(request_params)
    return merge_setting(request_params, session_params)


class SessionRedirectMixin:
    def get_redirect_target(self, resp):
        if not resp.is_redirect:
            return None
        location = resp.headers["location"]
        try:
            # Raw UTF-8 bytes that were read as Latin-1.
            return location.encode("latin-1").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            return location

    def should_strip_auth(self, old_url, new_url):
        old, new = urlparse(old_url), urlparse(new_url)
        if old.hostname != new.hostname:
            return True
        if old.scheme == "http" and old.port in (80, None) and new.scheme == "https" and new.port in (443, None):
            return False
        same_scheme = old.scheme == new.scheme
        if same_scheme and {old.port, new.port} <= {DEFAULT_PORTS.get(old.scheme), None}:
            return False
        return old.port != new.port or not same_scheme

    def resolve_redirects(self, resp, req, stream=False, timeout=None, verify=True, cert=None, proxies=None,
                          yield_requests=False, **adapter_kwargs):
        history = []
        target = self.get_redirect_target(resp)
        fragment = urlparse(req.url).fragment
        while target:
            following = req.copy()
            history.append(resp)
            resp.history = history[1:]
            resp.content
            if len(resp.history) >= self.max_redirects:
                raise TooManyRedirects("Exceeded %s redirects." % self.max_redirects, response=resp)
            if target.startswith("//"):
                target = "%s:%s" % (urlparse(resp.url).scheme, target)
            parts = urlparse(target)
            if parts.fragment == "" and fragment:
                parts = parts._replace(fragment=fragment)
            elif parts.fragment:
                fragment = parts.fragment
            target = parts.geturl()
            target = urljoin(resp.url, requote_uri(target)) if not parts.netloc else requote_uri(target)
            following.prepare_url(target, None)
            self.rebuild_method(following, resp)
            if resp.status_code not in (codes.temporary_redirect, codes.permanent_redirect):
                for name in ("Content-Length", "Content-Type", "Transfer-Encoding"):
                    following.headers.pop(name, None)
                following.body = None
            following.headers.pop("Cookie", None)
            jar = RequestsCookieJar()
            merge_cookies(jar, following._cookies)
            extract_cookies_to_jar(jar, req, resp.raw)
            merge_cookies(jar, self.cookies)
            following.prepare_cookies(jar)
            if "Authorization" in following.headers and self.should_strip_auth(resp.request.url, following.url):
                del following.headers["Authorization"]
            req = following
            if yield_requests:
                yield req
                return
            resp = self.send(
                req, stream=stream, timeout=timeout, verify=verify, cert=cert, proxies=proxies, allow_redirects=False,
                **adapter_kwargs,
            )
            extract_cookies_to_jar(self.cookies, req, resp.raw)
            target = self.get_redirect_target(resp)
            yield resp

    def rebuild_method(self, prepared_request, response):
        method = prepared_request.method
        if response.status_code in (codes.see_other, codes.found) and method != "HEAD":
            method = "GET"
        elif response.status_code == codes.moved and method == "POST":
            method = "GET"
        prepared_request.method = method

    def rebuild_proxies(self, prepared_request, proxies):
        return {}

    def rebuild_auth(self, prepared_request, response):
        if "Authorization" in prepared_request.headers and self.should_strip_auth(
            response.request.url, prepared_request.url
        ):
            del prepared_request.headers["Authorization"]


class Session(SessionRedirectMixin):
    """Persistent headers, cookies and parameters across requests."""

    __attrs__ = [
        "headers", "cookies", "auth", "proxies", "hooks", "params", "verify", "cert", "adapters", "stream", "trust_env",
        "max_redirects",
    ]

    def __init__(self):
        self.headers = default_headers()
        self.auth = None
        self.proxies = {}
        self.hooks = default_hooks()
        self.params = {}
        self.stream = False
        self.verify = True
        self.cert = None
        self.max_redirects = DEFAULT_REDIRECT_LIMIT
        self.trust_env = True
        self.cookies = cookiejar_from_dict({})
        self.adapters = {}
        self.mount("https://", HTTPAdapter())
        self.mount("http://", HTTPAdapter())

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def prepare_request(self, request):
        cookies = request.cookies or {}
        if not is_jar(cookies):
            cookies = cookiejar_from_dict(cookies)
        session_cookies = self.cookies
        if not is_jar(session_cookies):
            session_cookies = cookiejar_from_dict(session_cookies)
        jar = merge_cookies(merge_cookies(RequestsCookieJar(), session_cookies), cookies)
        prepared = PreparedRequest()
        prepared.prepare(
            method=request.method.upper(),
            url=request.url,
            files=request.files,
            data=request.data,
            json=request.json,
            headers=merge_setting(request.headers, self.headers, dict_class=CaseInsensitiveDict),
            params=_params(request.params, self.params),
            auth=merge_setting(request.auth, self.auth),
            cookies=jar,
            hooks=merge_hooks(request.hooks, self.hooks),
        )
        return prepared

    def request(self, method, url, params=None, data=None, headers=None, cookies=None, files=None, auth=None,
                timeout=None, allow_redirects=True, proxies=None, hooks=None, stream=None, verify=None, cert=None,
                json=None):
        if isinstance(method, bytes):
            method = method.decode("ascii")
        prepared = self.prepare_request(Request(
            method=method.upper(), url=url, headers=headers, files=files, data=data or {}, json=json,
            params=params or {}, auth=auth, cookies=cookies, hooks=hooks,
        ))
        settings = self.merge_environment_settings(prepared.url, proxies or {}, stream, verify, cert)
        return self.send(prepared, timeout=timeout, allow_redirects=allow_redirects, **settings)

    def merge_environment_settings(self, url, proxies, stream, verify, cert):
        return {
            "proxies": {},
            "stream": merge_setting(stream, self.stream),
            "verify": merge_setting(verify, self.verify),
            "cert": merge_setting(cert, self.cert),
        }

    def send(self, request, **kwargs):
        kwargs.setdefault("stream", self.stream)
        kwargs.setdefault("verify", self.verify)
        kwargs.setdefault("cert", self.cert)
        kwargs.setdefault("proxies", {})
        if isinstance(request, Request):
            raise ValueError("You can only send PreparedRequests.")
        allow_redirects = kwargs.pop("allow_redirects", True)
        hooks = request.hooks
        response = self.get_adapter(url=request.url).send(request, **kwargs)
        response = dispatch_hook("response", hooks, response, **kwargs)
        if response.history:
            for past in response.history:
                extract_cookies_to_jar(self.cookies, past.request, past.raw)
        if not is_jar(self.cookies):
            self.cookies = cookiejar_from_dict(self.cookies)
        extract_cookies_to_jar(self.cookies, request, response.raw)
        if allow_redirects:
            history = list(self.resolve_redirects(response, request, **kwargs))
        else:
            history = []
            try:
                response._next = next(self.resolve_redirects(response, request, yield_requests=True, **kwargs))
            except (StopIteration, TooManyRedirects, ValueError):
                pass
        if history:
            history.insert(0, response)
            response = history.pop()
            response.history = history
        return response

    def get(self, url, **kwargs):
        kwargs.setdefault("allow_redirects", True)
        return self.request("GET", url, **kwargs)

    def options(self, url, **kwargs):
        kwargs.setdefault("allow_redirects", True)
        return self.request("OPTIONS", url, **kwargs)

    def head(self, url, **kwargs):
        kwargs.setdefault("allow_redirects", False)
        return self.request("HEAD", url, **kwargs)

    def post(self, url, data=None, json=None, **kwargs):
        return self.request("POST", url, data=data, json=json, **kwargs)

    def put(self, url, data=None, **kwargs):
        return self.request("PUT", url, data=data, **kwargs)

    def patch(self, url, data=None, **kwargs):
        return self.request("PATCH", url, data=data, **kwargs)

    def delete(self, url, **kwargs):
        return self.request("DELETE", url, **kwargs)

    def get_adapter(self, url):
        low = url.lower()
        for prefix, adapter in self.adapters.items():
            if low.startswith(prefix.lower()):
                return adapter
        raise InvalidSchema("No connection adapters were found for %r" % url)

    def mount(self, prefix, adapter):
        """Register an adapter; the longest matching prefix wins."""
        self.adapters[prefix] = adapter
        self.adapters = dict(sorted(self.adapters.items(), key=lambda item: -len(item[0])))

    def close(self):
        for adapter in self.adapters.values():
            adapter.close()

    def __getstate__(self):
        return {name: getattr(self, name, None) for name in self.__attrs__}

    def __setstate__(self, state):
        for name, value in state.items():
            setattr(self, name, value)


def session():
    return Session()


__all__ = ["Session", "session", "merge_setting", "merge_hooks", "SessionRedirectMixin", "REDIRECT_STATI"]
