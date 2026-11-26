"""TLS context factory; the context is accepted and ignored, the host does TLS (original, GPL-3.0)."""

try:
    import ssl
except ImportError:
    # The stub registered by idj_compat may not be installed yet.
    import idj_compat

    ssl = idj_compat.ssl_module()

SSLContext = ssl.SSLContext
PROTOCOL_TLS = getattr(ssl, "PROTOCOL_TLS", 2)
CERT_NONE, CERT_REQUIRED = ssl.CERT_NONE, ssl.CERT_REQUIRED
DEFAULT_CIPHERS = "DEFAULT"
HAS_SNI = True
IS_PYOPENSSL = False


def create_urllib3_context(ssl_version=None, cert_reqs=None, options=None, ciphers=None, ssl_minimum_version=None,
                           ssl_maximum_version=None, **_):
    context = ssl.SSLContext(getattr(ssl, "PROTOCOL_TLS_CLIENT", PROTOCOL_TLS))
    if ciphers:
        try:
            context.set_ciphers(ciphers)
        except ssl.SSLError:
            pass  # cipher choice is up to the host
    context.check_hostname = False
    if cert_reqs is not None:
        context.verify_mode = cert_reqs
    return context


def resolve_cert_reqs(candidate):
    if candidate is None:
        return CERT_REQUIRED
    if isinstance(candidate, str):
        return getattr(ssl, candidate if candidate.startswith("CERT_") else "CERT_" + candidate)
    return candidate


def ssl_wrap_socket(*args, **kwargs):
    raise NotImplementedError("urllib3（iOS 版）不支持 ssl_wrap_socket()")


def is_ipaddress(hostname):
    return bool(hostname) and (":" in hostname or hostname.replace(".", "").isdigit())
