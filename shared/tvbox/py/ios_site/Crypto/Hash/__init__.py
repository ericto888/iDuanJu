"""Hash functions (original implementation for i短剧, GPL-3.0)."""

__all__ = ["HMAC", "MD5", "SHA", "SHA1", "SHA224", "SHA256", "SHA384", "SHA512"]


def new(name, data=None):
    """Hash object by algorithm name ('SHA256', 'SHA-256', …)."""
    import importlib

    key = name.upper().replace("-", "")
    if key not in ("MD5", "SHA", "SHA1", "SHA224", "SHA256", "SHA384", "SHA512"):
        raise ValueError("Unknown hash " + str(name))
    return importlib.import_module("." + key, __name__).new(data)
