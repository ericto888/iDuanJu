"""bs4-compatible API for i短剧 spiders on iOS.

Original implementation (GPL-3.0); not a copy of Beautiful Soup. `html.parser` markup is parsed in Python with the same
loose nesting rules; for `lxml`/`html5lib`/`xml` the host's parser repairs the page first and the tree is built from its
serialisation, so a soup never depends on host node ids.
"""

from __future__ import annotations

import re

import _idj_markup as _markup
from _idj_css import SelectorSyntaxError

from .element import (
    CSS, BaseSoup, CData, Comment, Declaration, Doctype, NavigableString, PageElement, ProcessingInstruction, ResultSet,
    Script, SoupStrainer, Stylesheet, Tag, TemplateString, XMLProcessingInstruction, _CONTAINERS, _KEEP_SPACE,
)

__version__ = "4.12.3"
__all__ = [
    "BeautifulSoup", "Tag", "NavigableString", "Comment", "CData", "Doctype", "Declaration", "ProcessingInstruction",
    "ResultSet", "SoupStrainer", "PageElement", "FeatureNotFound", "UnicodeDammit", "SelectorSyntaxError",
]


class FeatureNotFound(ValueError):
    pass


class StopParsing(Exception):
    pass


class ParserRejectedMarkup(Exception):
    pass


class GuessedAtParserWarning(UserWarning):
    pass


class UnusualUsageWarning(UserWarning):
    pass


class MarkupResemblesLocatorWarning(UnusualUsageWarning):
    pass


class XMLParsedAsHTMLWarning(UnusualUsageWarning):
    pass


class AttributeResemblesVariableWarning(UnusualUsageWarning):
    pass


_MULTI_VALUED = {
    "*": frozenset(("class", "accesskey", "dropzone")),
    "a": frozenset(("rel", "rev")),
    "link": frozenset(("rel", "rev")),
    "td": frozenset(("headers",)),
    "th": frozenset(("headers",)),
    "form": frozenset(("accept-charset",)),
    "object": frozenset(("archive",)),
    "area": frozenset(("rel",)),
    "icon": frozenset(("sizes",)),
    "iframe": frozenset(("sandbox",)),
    "output": frozenset(("for",)),
}
_NONE = frozenset()
_NONSPACE = re.compile(r"\S+")
_DOCTYPE = re.compile(r"^\s*(?:<!--.*?-->\s*)*<!doctype\s+([^>]*)>", re.I | re.S)


def _kind(features):
    """Parser family: 'python', 'host' or 'xml'."""
    if features is None:
        return "host"
    names = [features] if isinstance(features, str) else list(features)
    for name in names:
        key = name.lower()
        if key in ("html.parser", "htmlparser"):
            return "python"
        if key in ("lxml", "lxml-html", "html5lib", "html5", "html", "fast", "permissive"):
            return "host"
        if key in ("xml", "lxml-xml"):
            return "xml"
    raise FeatureNotFound(
        "Couldn't find a tree builder with the features you requested: %s. Do you need to install a parser library?"
        % ",".join(names)
    )


class BeautifulSoup(BaseSoup):
    """A parsed document."""

    ROOT_TAG_NAME = "[document]"

    def __init__(self, markup="", features=None, builder=None, parse_only=None, from_encoding=None,
                 exclude_encodings=None, element_classes=None, **kwargs):
        if builder is not None or element_classes:
            raise NotImplementedError("bs4（iOS 版）不支持自定义 builder / element_classes")
        self._multi = kwargs.pop("multi_valued_attributes", True) is not None
        kind = _kind(features)
        xml = kind == "xml"
        super().__init__(name=self.ROOT_TAG_NAME, is_xml=xml)
        self.hidden = True
        self.is_xml = xml
        self.parse_only = parse_only
        self.original_encoding = None
        self.declared_html_encoding = None
        self.contains_replacement_characters = False
        if hasattr(markup, "read"):
            markup = markup.read()
        if isinstance(markup, (bytes, bytearray, memoryview)):
            import _idj_text

            markup, self.original_encoding = _idj_text.decode_markup(markup, from_encoding)
            self.declared_html_encoding = self.original_encoding
        elif not isinstance(markup, str):
            if markup is None:
                raise TypeError("object of type 'NoneType' has no len()")
            markup = str(markup)
        markup = str(markup).lstrip("﻿")
        self.markup = None
        if markup.strip():
            if kind == "python":
                self._build(_markup.events(markup), False)
            elif kind == "host":
                self._build(_markup.events(self._repair(markup)), False)
            else:
                self._build(_markup.events(self._repair_xml(markup), xml=True), True)
        elif markup and kind == "python":
            self._build(iter((("t", markup),)), False)
        if parse_only is not None:
            self._keep_only(parse_only)

    # -- parsing -----------------------------------------------------------------------------------------------------
    def _repair(self, markup):
        """The page as the host's HTML parser understands it, with its doctype."""
        import _idj_dom

        doc = _idj_dom.load_html(markup)
        roots = _idj_dom.rel(doc, "children")
        if not roots:
            return ""
        found = _DOCTYPE.match(markup)
        head = "<!DOCTYPE %s>" % found.group(1) if found else ""
        return head + _idj_dom.outer(roots[0])

    def _repair_xml(self, markup):
        import _idj_dom

        found = re.match(r"\s*<\?xml\b[^>]*\?>", markup)
        doc = _idj_dom.load_xml(markup[found.end():] if found else markup)
        roots = _idj_dom.rel(doc, "children")
        if not roots:
            return ""
        return '<?xml version="1.0" encoding="utf-8"?>' + _idj_dom.outer(roots[0])

    def _build(self, events, xml):
        stack = [self]
        open_names = {}
        special = []  # open tags whose text gets its own string class (script, style, template…)
        keep_space = 0
        text = []

        def flush():
            if not text:
                return
            data = "".join(text)
            text.clear()
            if not keep_space and not data.strip(" \n\t\f\r"):
                data = "\n" if "\n" in data else " "
            add(_CONTAINERS[special[-1].name](data) if special else NavigableString(data))

        def add(node):
            parent = stack[-1]
            node.parent = parent
            parent.contents.append(node)

        for event in events:
            code = event[0]
            if code == "t" or code == "r":
                text.append(event[1])
                continue
            flush()
            if code == "s":
                name = event[1]
                tag = Tag(name=name, attrs=self._attributes(name, event[2], xml), is_xml=xml)
                if xml and ":" in name:
                    tag.prefix = name.partition(":")[0]
                add(tag)
                if event[3] or (not xml and tag.can_be_empty_element):
                    continue
                stack.append(tag)
                open_names[name] = open_names.get(name, 0) + 1
                if not xml:
                    if name in _KEEP_SPACE:
                        keep_space += 1
                    if name in _CONTAINERS:
                        special.append(tag)
            elif code == "e":
                name = event[1]
                if not open_names.get(name):
                    continue
                while True:
                    top = stack.pop()
                    open_names[top.name] -= 1
                    if not xml and top.name in _KEEP_SPACE:
                        keep_space -= 1
                    if special and special[-1] is top:
                        special.pop()
                    if top.name == name:
                        break
            elif code == "c":
                add(Comment(event[1]))
            elif code == "x":
                add(NavigableString(event[1]) if xml else CData(event[1]))
            elif code == "d":
                add(Doctype(re.sub(r"^doctype\s*", "", event[1], flags=re.I)))
            elif code == "p":
                if xml:
                    if not event[1].lower().startswith("xml "):
                        add(XMLProcessingInstruction(event[1]))
                else:
                    add(ProcessingInstruction(event[1]))
        flush()

    def _attributes(self, name, pairs, xml):
        out = {}
        for key, value in pairs:
            out[key] = "" if value is None else value
        if not xml and self._multi and out:
            special = _MULTI_VALUED.get(name, _NONE)
            for key in out:
                if key in _MULTI_VALUED["*"] or key in special:
                    out[key] = _NONSPACE.findall(out[key])
        return out

    def _keep_only(self, strainer):
        kept, skip = [], set()
        for node in self.descendants:
            if node.parent is not None and id(node.parent) in skip:
                if isinstance(node, Tag):
                    skip.add(id(node))
                continue
            if strainer.matches(node):
                kept.append(node)
                if isinstance(node, Tag):
                    skip.add(id(node))
        for node in kept:
            node.extract()
        self.contents = []
        for node in kept:
            self.append(node)

    # -- factories ---------------------------------------------------------------------------------------------------
    def new_tag(self, name, namespace=None, nsprefix=None, attrs=None, sourceline=None, sourcepos=None, string=None,
                **kwattrs):
        merged = dict(attrs or {})
        merged.update({"class" if k == "class_" else k: v for k, v in kwattrs.items()})
        tag = Tag(name=name, namespace=namespace, prefix=nsprefix, attrs=merged, is_xml=self.is_xml)
        if string is not None:
            tag.string = string
        return tag

    def new_string(self, s, subclass=None):
        return (subclass or NavigableString)(s)

    def insert_before(self, *args):
        raise NotImplementedError("BeautifulSoup objects don't support insert_before().")

    def insert_after(self, *args):
        raise NotImplementedError("BeautifulSoup objects don't support insert_after().")

    def reset(self):
        self.contents = []

    def _shallow(self):
        clone = BeautifulSoup("", "xml" if self.is_xml else "html.parser")
        clone.original_encoding = self.original_encoding
        return clone

    def decode(self, indent_level=None, eventual_encoding="utf-8", formatter="minimal", iterator=None):
        prefix = ""
        if self.is_xml:
            prefix = '<?xml version="1.0" encoding="%s"?>\n' % (eventual_encoding or "utf-8")
        return prefix + super().decode(indent_level, eventual_encoding, formatter)

    def prettify(self, encoding=None, formatter="minimal"):
        text = self.decode(0, encoding or "utf-8", formatter)
        return text if encoding is None else text.encode(encoding, "xmlcharrefreplace")

    def __str__(self):
        return self.decode()

    __unicode__ = __repr__ = __str__


class BeautifulStoneSoup(BeautifulSoup):
    def __init__(self, *args, **kwargs):
        kwargs["features"] = "xml"
        super().__init__(*args, **kwargs)


class UnicodeDammit:
    """Minimal: decode bytes of unknown encoding."""

    def __init__(self, markup, known_definite_encodings=(), smart_quotes_to=None, is_html=False, **kwargs):
        self.contains_replacement_characters = False
        if isinstance(markup, str):
            self.markup = self.unicode_markup = markup
            self.original_encoding = None
            return
        import _idj_text

        self.markup = markup
        self.unicode_markup, self.original_encoding = None, None
        for name in known_definite_encodings:
            try:
                self.unicode_markup, self.original_encoding = _idj_text.decode(markup, name), name
                return
            except (LookupError, UnicodeDecodeError):
                continue
        self.unicode_markup, self.original_encoding = _idj_text.decode_markup(markup)


_s = _soup = BeautifulSoup
