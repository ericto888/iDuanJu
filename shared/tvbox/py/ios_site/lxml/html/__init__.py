"""lxml.html-compatible API (original implementation for i短剧, GPL-3.0)."""

from __future__ import annotations

import re

import _idj_dom as _dom

from .. import etree
from ..etree import _Element, _load_html, _markup, _unsupported

__all__ = [
    "document_fromstring", "fragment_fromstring", "fragments_fromstring", "fromstring", "tostring", "parse",
    "HtmlElement", "HTMLParser", "XHTMLParser", "find_class", "find_rel_links", "make_links_absolute", "rewrite_links",
    "iterlinks",
]

_LINK_ATTRS = frozenset((
    "action", "archive", "background", "cite", "classid", "codebase", "data", "href", "longdesc", "profile", "src",
    "usemap", "dynsrc", "lowsrc", "formaction",
))
_BLOCK = frozenset(
    "address article aside blockquote center dir div dl fieldset figure footer form h1 h2 h3 h4 h5 h6 header hr "
    "isindex main menu nav noframes noscript ol p pre section table ul li dt dd tbody td tr th thead tfoot".split()
)
_FULL = re.compile(r"^\s*(?:<\?xml\b[^>]*\?>\s*)?(?:<!--.*?-->\s*)*<(?:html\b|!doctype\b)", re.I | re.S)
_STRUCTURE = re.compile(r"<(?:head|body|html|frameset)\b", re.I)


class HtmlMixin:
    """Methods lxml.html adds to elements."""

    __slots__ = ()

    @property
    def base_url(self):
        return self._doc.base

    @property
    def forms(self):
        return self._nodes("descendant-or-self::form")

    @property
    def body(self):
        found = self.getroottree().getroot()._nodes("body")
        return found[0] if found else None

    @property
    def head(self):
        found = self.getroottree().getroot()._nodes("head")
        return found[0] if found else None

    def find_class(self, class_name):
        want = etree._xp.literal(" %s " % class_name)
        return self._nodes(
            "descendant-or-self::*[@class and contains(concat(' ', normalize-space(@class), ' '), %s)]" % want
        )

    def find_rel_links(self, rel):
        rel = rel.lower()
        return [a for a in self._nodes("descendant-or-self::a[@rel]") if a.get("rel", "").lower() == rel]

    def get_element_by_id(self, id, *default):
        found = self._nodes("descendant-or-self::*[@id=%s]" % etree._xp.literal(id))
        if found:
            return found[0]
        if default:
            return default[0]
        raise KeyError(id)

    def drop_tag(self):
        """Keep the text, drop the tag. Only possible when the parent holds text alone beside this element."""
        parent = self.getparent()
        if parent is None or len(self) or len(parent) != 1:
            _unsupported("drop_tag()：父元素内还有其他标签")
        _dom.set_text(parent._id, _dom.string(parent._id))

    # -- links -------------------------------------------------------------------------------------------------------
    def iterlinks(self):
        """(element, attribute, link, position) for link attributes."""
        for element in self._nodes("descendant-or-self::*[@*]"):
            for key, value in element.items():
                if key in _LINK_ATTRS and value:
                    yield element, key, value, 0
            if element.tag == "meta" and (element.get("http-equiv") or "").lower() == "refresh":
                found = re.search(r"url\s*=\s*(.+)$", element.get("content") or "", re.I)
                if found:
                    yield element, "content", found.group(1).strip("\"' "), found.start(1)

    def rewrite_links(self, link_repl_func, resolve_base_href=True, base_href=None):
        if resolve_base_href:
            self.resolve_base_href()
        for element, key, link, pos in list(self.iterlinks()):
            new = link_repl_func(link.strip() if base_href is None else _join(base_href, link.strip()))
            if new == link:
                continue
            if new is None:
                element._set_attr(key, None)
            elif pos:
                element.set(key, element.get(key)[:pos] + new)
            else:
                element.set(key, new)

    def resolve_base_href(self, handle_failures=None):
        found = self._nodes("descendant-or-self::base[@href]")
        if found:
            self.make_links_absolute(found[0].get("href"), resolve_base_href=False)
            _dom.remove([b._id for b in found])

    def make_links_absolute(self, base_url=None, resolve_base_href=True, handle_failures=None):
        if base_url is None:
            base_url = self.base_url
            if base_url is None:
                raise TypeError("No base_url given, and the document has no base_url")
        if resolve_base_href:
            self.resolve_base_href()

        def absolute(link):
            try:
                return _join(base_url, link)
            except ValueError:
                if handle_failures in ("ignore", "discard"):
                    return link if handle_failures == "ignore" else None
                raise

        self.rewrite_links(absolute, resolve_base_href=False)


def _join(base, link):
    from urllib.parse import urljoin

    return urljoin(base, link)


class HtmlElement(HtmlMixin, _Element):
    __slots__ = ()


HtmlComment = HtmlProcessingInstruction = HtmlEntity = HtmlElement
FormElement = InputElement = LabelElement = SelectElement = TextareaElement = HtmlElement


class HTMLParser(etree.HTMLParser):
    pass


class XHTMLParser(etree.XMLParser):
    pass


html_parser = HTMLParser()
xhtml_parser = XHTMLParser()


def _parser(parser):
    return parser or html_parser


def document_fromstring(html, parser=None, ensure_head_body=False, base_url=None, **kw):
    root = _load_html(html, _parser(parser), HtmlElement, base_url or kw.get("base_url"))
    if root is None:
        raise etree.ParserError("Document is empty")
    return root


def _wrapped(markup, base_url, tag="div"):
    """Parse a fragment inside a wrapper element and return the wrapper."""
    doc = "<html><body><%s>%s</%s></body></html>" % (tag, markup, tag)
    root = _load_html(doc, None, HtmlElement, base_url)
    found = root._nodes("/html/body/*[1]")
    if not found:
        raise etree.ParserError("无法解析 HTML 片段")
    return found[0]


def fragments_fromstring(html, no_leading_text=False, base_url=None, parser=None, **kw):
    """List of the top-level elements of a fragment; a leading text comes first as a plain str."""
    markup = _markup(html, _parser(parser))
    if _FULL.match(markup):
        root = document_fromstring(markup, base_url=base_url)
        body = root.body
        holder = body if body is not None else root
    else:
        holder = _wrapped(markup, base_url)
    out = []
    text = holder.text
    if text and text.strip():
        if no_leading_text:
            raise etree.ParserError("There is leading text: %r" % text)
        out.append(text)
    out.extend(holder.getchildren())
    return out


def fragment_fromstring(html, create_parent=False, base_url=None, parser=None, **kw):
    """Exactly one element; with create_parent the fragment is put into a new <div> (or the named tag)."""
    markup = _markup(html, _parser(parser))
    if create_parent:
        return _wrapped(markup, base_url, create_parent if isinstance(create_parent, str) else "div")
    elements = fragments_fromstring(markup, no_leading_text=True, base_url=base_url)
    if not elements:
        raise etree.ParserError("No elements found")
    if len(elements) > 1:
        raise etree.ParserError("Multiple elements found (%s)" % ", ".join(str(e.tag) for e in elements))
    if elements[0].tail and elements[0].tail.strip():
        raise etree.ParserError("Element followed by text: %r" % elements[0].tail)
    return elements[0]


def fromstring(html, base_url=None, parser=None, **kw):
    """A document for full pages, otherwise the single element (or a wrapper around several)."""
    parser = _parser(parser)
    if not parser._html:
        return etree._load_xml(html, parser, base_url)
    markup = _markup(html, parser)
    if not markup.strip():
        raise etree.ParserError("Document is empty")
    root = document_fromstring(markup, base_url=base_url)
    if _FULL.match(markup) or _STRUCTURE.search(markup):
        return root
    body = root.body
    if body is None:
        return root
    kids = body.getchildren()
    head = root.head
    if head is not None and len(head):
        return root  # <title>, <meta> … were moved into an implied head: keep the whole structure
    if len(kids) == 1 and not (body.text or "").strip() and not (kids[0].tail or "").strip():
        return kids[0]
    block = any(k.tag in _BLOCK for k in body.iterdescendants())
    return _wrapped(markup, base_url, "div" if block else "span")


def parse(filename_or_url, parser=None, base_url=None, **kw):
    data, name = etree._read(filename_or_url)
    root = document_fromstring(data, parser=parser, base_url=base_url or (name if isinstance(name, str) else None))
    return etree._ElementTree(root._doc, root)


def tostring(
    doc, pretty_print=False, include_meta_content_type=False, encoding=None, method="html", with_tail=True,
    doctype=None
):
    out = etree.tostring(
        doc, method=method, pretty_print=pretty_print, encoding=encoding, with_tail=with_tail, doctype=doctype
    )
    if method == "html" and not include_meta_content_type:
        if isinstance(out, str):
            out = re.sub(r'<meta http-equiv="Content-Type"[^>]*>', "", out, flags=re.I)
        else:
            out = re.sub(rb'<meta http-equiv="Content-Type"[^>]*>', b"", out, flags=re.I)
    return out


def open_in_browser(doc, encoding=None):
    _unsupported("lxml.html.open_in_browser()")


def submit_form(form, extra_values=None, open_http=None):
    _unsupported("lxml.html.submit_form()")


def Element(*args, **kw):
    return etree.Element(*args, **kw)


def _apply(name):
    def function(doc, *args, **kw):
        """Module-level variant: accepts markup or an element and returns the same kind."""
        is_text = isinstance(doc, (str, bytes))
        element = fromstring(doc) if is_text else doc
        result = getattr(element, name)(*args, **kw)
        if name in ("make_links_absolute", "resolve_base_href", "rewrite_links"):
            if is_text:
                return tostring(element, encoding="unicode") if isinstance(doc, str) else tostring(element)
            return None
        return result

    function.__name__ = name
    return function


find_class = _apply("find_class")
find_rel_links = _apply("find_rel_links")
iterlinks = _apply("iterlinks")
make_links_absolute = _apply("make_links_absolute")
resolve_base_href = _apply("resolve_base_href")
rewrite_links = _apply("rewrite_links")
