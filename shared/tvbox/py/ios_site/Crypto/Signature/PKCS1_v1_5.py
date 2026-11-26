"""Legacy name of pkcs1_15: verify() returns a bool (original implementation for i短剧, GPL-3.0)."""

from .pkcs1_15 import PKCS115_SigScheme


class _LegacyScheme(PKCS115_SigScheme):
    def verify(self, msg_hash, signature):
        try:
            super().verify(msg_hash, signature)
            return True
        except (ValueError, TypeError):
            return False


def new(rsa_key):
    return _LegacyScheme(rsa_key)
