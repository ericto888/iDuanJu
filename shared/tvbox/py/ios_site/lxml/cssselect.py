"""lxml.cssselect-compatible API (original implementation for i短剧, GPL-3.0).

Searching is done by the host's `html.select`; single elements are tested with the Python engine `_idj_css`.
"""

from __future__ import annotations

import _idj_css as _css
import _idj_dom as _dom
from _idj_bridge import HostError as _HostError


class SelectorError(Exception):
    pass


class SelectorSyntaxError(SelectorError, SyntaxError):
    pass


class ExpressionError(SelectorError, RuntimeError):
    pass


class ElementAdapter:
    """Lets `_idj_css` walk lxml elements."""

    __slots__ = ("xml",)

    def __init__(self, xml=False):
        self.xml = xml

    @staticmethod
    def tag(node):
        tag = node.tag
        if not isinstance(tag, str):
            return ""
        return tag.rpartition("}")[2] if tag.startswith("{") else tag

    @staticmethod
    def attr(node, name):
        return node.get(name)

    @staticmethod
    def parent(node):
        return node.getparent()

    container = parent

    @staticmethod
    def children(node):
        return node.getchildren()

    @staticmethod
    def descendants(node):
        return node._nodes("descendant::*")

    @staticmethod
    def text(node):
        return _dom.string(node._id)

    @staticmethod
    def own_text(node):
        return "".join(r.get("s") or "" for r in node._raw_xpath("text()") if "s" in r)

    @staticmethod
    def empty(node):
        return not len(node) and not node.text

    @staticmethod
    def key(node):
        return node._id


_HTML, _XML = ElementAdapter(False), ElementAdapter(True)


def adapter_for(element):
    return _XML if element._doc.xml else _HTML


def host_select(elements, css):
    """Descendants of `elements` that match, as returned by the host (document order, no duplicates)."""
    if not elements:
        return []
    first = elements[0]
    try:
        ids = _dom.select([e._id for e in elements], css)
    except _HostError as exc:
        raise SelectorSyntaxError("%s（CSS: %s）" % (exc.message, css)) from exc
    cls, doc, seen, out = type(first), first._doc, set(), []
    for node in ids:
        if node not in seen:
            seen.add(node)
            out.append(cls(node, doc))
    return out


def self_matches(element, css):
    """Does the element itself match? Selectors only the host understands count as "no"."""
    try:
        return _css.matches(adapter_for(element), element, css)
    except (_css.SelectorSyntaxError, NotImplementedError):
        return False


def filter_elements(elements, css):
    """Elements of a list that match the selector."""
    if not elements:
        return []
    try:
        return _css.filter_nodes(adapter_for(elements[0]), list(elements), css)
    except _css.SelectorSyntaxError as exc:
        raise SelectorSyntaxError(str(exc)) from exc


def css_select(element, css):
    """lxml's element.cssselect(): the element itself and its descendants."""
    found = [e for e in host_select([element], css) if e != element]
    if not _positional(css) and self_matches(element, css):
        found.insert(0, element)
    return found


def _positional(css):
    try:
        return _css.is_positional(css)
    except _css.SelectorSyntaxError:
        return False


class CSSSelector:
    """Compiled selector: CSSSelector('a.x')(element)."""

    def __init__(self, css, namespaces=None, translator="xml"):
        self.css = css
        try:
            _css.parse(css)
        except _css.SelectorSyntaxError as exc:
            raise SelectorSyntaxError(str(exc)) from exc

    def __call__(self, element):
        root = element.getroot() if hasattr(element, "getroot") else element
        return css_select(root, self.css)

    def __repr__(self):
        return "<%s %x for %r>" % (type(self).__name__, abs(id(self)), self.css)


class LxmlTranslator:
    def css_to_xpath(self, css, prefix="descendant-or-self::"):
        raise NotImplementedError("lxml（iOS 版）不支持把 CSS 转换成 XPath")


LxmlHTMLTranslator = LxmlTranslator
