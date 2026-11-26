"""bs4.dammit-compatible names (original implementation for i短剧, GPL-3.0)."""

from . import UnicodeDammit
from .element import _html, _minimal

__all__ = ["UnicodeDammit", "EntitySubstitution"]


class EntitySubstitution:
    @classmethod
    def substitute_xml(cls, value, make_quoted_attribute=False):
        value = _minimal(value)
        return cls.quoted_attribute_value(value) if make_quoted_attribute else value

    @classmethod
    def substitute_html(cls, value):
        return _html(value)

    @classmethod
    def quoted_attribute_value(cls, value):
        from .element import _quoted

        return _quoted(value)
