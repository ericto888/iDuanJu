"""fake_useragent-compatible API with a small built-in list (original implementation for i短剧, GPL-3.0)."""

import random as _random

__version__ = "1.5.1"

_WIN = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
_AGENTS = {
    "chrome": [
        (_WIN if i % 2 else _MAC) + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%d.0.0.0 Safari/537.36" % v
        for i, v in enumerate((120, 122, 124, 125, 126, 127, 128, 131))
    ],
    "edge": [
        _WIN + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%d.0.0.0 Safari/537.36 Edg/%d.0.0.0" % (v, v)
        for v in (122, 124, 126, 131)
    ],
    "firefox": [
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:%d.0) Gecko/20100101 Firefox/%d.0" % (v, v)
        for v in (121, 124, 126, 128, 132)
    ],
    "safari": [
        _MAC + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/%s Safari/605.1.15" % v for v in ("16.6", "17.4", "17.6")
    ],
    "mobile": [
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
        "Version/17.5 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 "
        "Mobile Safari/537.36",
    ],
}
_ALIASES = {"google": "chrome", "googlechrome": "chrome", "ff": "firefox", "msie": "edge", "ie": "edge",
            "internetexplorer": "edge", "opera": "chrome", "android": "mobile", "ios": "mobile", "iphone": "mobile"}


class FakeUserAgentError(Exception):
    pass


UserAgentError = FakeUserAgentError


class FakeUserAgent:
    def __init__(self, browsers=None, os=None, platforms=None, fallback=None, **kwargs):
        if isinstance(browsers, str):
            browsers = [browsers]
        picked = [_ALIASES.get(b.lower(), b.lower()) for b in browsers or ()]
        self.browsers = [b for b in picked if b in _AGENTS] or ["chrome", "edge", "firefox", "safari"]
        if platforms and set([platforms] if isinstance(platforms, str) else platforms) == {"mobile"}:
            self.browsers = ["mobile"]
        self.fallback = fallback or _AGENTS["chrome"][0]

    def update(self, *args, **kwargs):
        pass

    def getBrowser(self, request):
        text = self[request]
        return {"useragent": text, "percent": 100.0, "type": "desktop", "system": "", "browser": request, "os": ""}

    @property
    def random(self):
        return _random.choice([ua for b in self.browsers for ua in _AGENTS[b]])

    @property
    def getRandom(self):
        return self.getBrowser("random")

    def __getitem__(self, name):
        key = str(name).lower().replace(" ", "").replace("_", "")
        if key == "random":
            return self.random
        return _random.choice(_AGENTS.get(_ALIASES.get(key, key), [self.fallback]))

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        return self[name]


UserAgent = FakeUserAgent
__all__ = ["FakeUserAgent", "UserAgent", "FakeUserAgentError", "UserAgentError"]
