"""Retry settings holder (original implementation for i短剧, GPL-3.0). The host decides about reconnecting."""


class Retry:
    DEFAULT_ALLOWED_METHODS = frozenset(("HEAD", "GET", "PUT", "DELETE", "OPTIONS", "TRACE"))
    RETRY_AFTER_STATUS_CODES = frozenset((413, 429, 503))
    DEFAULT_REMOVE_HEADERS_ON_REDIRECT = frozenset(("Cookie", "Authorization", "Proxy-Authorization"))
    DEFAULT_BACKOFF_MAX = 120
    DEFAULT = None

    def __init__(self, total=10, connect=None, read=None, redirect=None, status=None, other=None,
                 allowed_methods=DEFAULT_ALLOWED_METHODS, status_forcelist=None, backoff_factor=0,
                 backoff_max=DEFAULT_BACKOFF_MAX, raise_on_redirect=True, raise_on_status=True, history=None,
                 respect_retry_after_header=True, remove_headers_on_redirect=DEFAULT_REMOVE_HEADERS_ON_REDIRECT,
                 backoff_jitter=0.0, method_whitelist=None):
        self.total = total
        self.connect = connect
        self.read = read
        self.redirect = redirect
        self.status = status
        self.other = other
        self.allowed_methods = method_whitelist if method_whitelist is not None else allowed_methods
        self.status_forcelist = status_forcelist or set()
        self.backoff_factor = backoff_factor
        self.backoff_max = backoff_max
        self.raise_on_redirect = raise_on_redirect
        self.raise_on_status = raise_on_status
        self.history = history or ()
        self.respect_retry_after_header = respect_retry_after_header
        self.remove_headers_on_redirect = remove_headers_on_redirect
        self.backoff_jitter = backoff_jitter

    def new(self, **kw):
        fields = {k: v for k, v in self.__dict__.items()}
        fields.update(kw)
        return type(self)(**fields)

    @classmethod
    def from_int(cls, retries, redirect=True, default=None):
        if retries is None:
            retries = default if default is not None else 3
        return retries if isinstance(retries, Retry) else cls(retries, redirect=None if redirect else False)

    def is_exhausted(self):
        return isinstance(self.total, int) and self.total < 0

    def get_backoff_time(self):
        return 0

    def __repr__(self):
        return "Retry(total=%r, connect=%r, read=%r, redirect=%r, status=%r)" % (
            self.total, self.connect, self.read, self.redirect, self.status,
        )
