"""PyQuery class (original implementation for i短剧, GPL-3.0).

A PyQuery object is a list of lxml elements, as upstream: iterating yields elements, `.items()` yields PyQuery objects.
"""

from __future__ import annotations

import re
from html import escape

import _idj_css as _css
import _idj_dom as _dom
import _idj_markup as _markup
from lxml import etree
from lxml.cssselect import filter_elements, host_select, self_matches
from lxml.html import fromstring as _html_fromstring

_MISSING = object()
_ATTR_ALIASES = {"class_": "class", "for_": "for"}


def _unsupported(what):
    raise NotImplementedError("pyquery（iOS 版）不支持 %s" % what)


_HTML_TAGS = frozenset(
    "a abbr acronym address applet area article aside audio b base basefont bdi bdo big blockquote body br button "
    "canvas caption center cite code col colgroup data datalist dd del details dfn dialog dir div dl dt em embed "
    "fieldset figcaption figure font footer form frame frameset h1 h2 h3 h4 h5 h6 head header hr html i iframe img "
    "input ins kbd label legend li link main map mark menu meta meter nav noframes noscript object ol optgroup option "
    "output p param picture pre progress q rp rt ruby s samp script section select small source span strike strong "
    "style sub summary sup svg table tbody td template textarea tfoot th thead time title tr track tt u ul var video "
    "wbr".split()
)
_ROOT = re.compile(r"\s*(?:<\?xml\b[^>]*\?>\s*)?(?:<!--.*?-->\s*)*<([A-Za-z_][\w.\-]*)", re.S)


def _looks_like_xml(markup):
    """Upstream tries a strict XML parse first; that only matters when the root is not an HTML element."""
    found = _ROOT.match(markup)
    return bool(found) and found.group(1).lower() not in _HTML_TAGS


def _parse(markup, parser=None):
    """Markup -> list of root elements."""
    if hasattr(markup, "read"):
        markup = markup.read()
    if isinstance(markup, (bytes, bytearray)):
        markup = etree._markup(markup, None)
    if not markup.strip():
        return []
    if parser == "xml":
        return [etree.fromstring(markup)]
    if parser is None and _looks_like_xml(markup):
        try:
            return [etree.fromstring(markup)]
        except etree.XMLSyntaxError:
            pass
    if parser == "html_fragments":
        from lxml.html import fragments_fromstring

        return [e for e in fragments_fromstring(markup) if not isinstance(e, str)]
    return [_html_fromstring(markup)]


def _distinct(elements):
    seen, out = set(), []
    for element in elements:
        if isinstance(element, etree._Element) and element._id not in seen:
            seen.add(element._id)
            out.append(element)
    return out


def _call(func, index, element):
    """Call a user callback with as many of (index, element) as it accepts, like pyquery."""
    code = getattr(func, "__code__", None)
    if code is None:
        return func(index, element)
    if code.co_flags & 0x04:  # *args
        count = 2
    else:
        count = code.co_argcount - (1 if hasattr(func, "__self__") else 0)
    arguments = (index, element)[:max(count, 0)]
    scope = getattr(func, "__globals__", None)
    if scope is None or "this" not in code.co_names:
        return func(*arguments)
    # Upstream exposes the element as a global named `this`.
    had, old = "this" in scope, scope.get("this")
    scope["this"] = element
    try:
        return func(*arguments)
    finally:
        if had:
            scope["this"] = old
        else:
            del scope["this"]


class _Accessor:
    """`doc.attr('x')`, `doc.attr['x']`, `doc.attr.x`, and the assigning/deleting forms."""

    __slots__ = ("_owner",)

    def __init__(self, owner):
        object.__setattr__(self, "_owner", owner)

    def __call__(self, *args, **kwargs):
        return self._owner._attr(*args, **kwargs)

    def __getitem__(self, name):
        return self._owner._attr(name)

    def __setitem__(self, name, value):
        self._owner._attr(name, value)

    def __delitem__(self, name):
        self._owner.remove_attr(name)

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        owner = self._owner
        value = owner._attr(name)
        if value is None and "_" in name and name not in _ATTR_ALIASES:
            value = owner._attr(name.replace("_", "-"))
        return value

    def __setattr__(self, name, value):
        self._owner._attr(name, value)

    def __delattr__(self, name):
        self._owner.remove_attr(name)

    def __repr__(self):
        return "<flexible_element attr>"


class PyQuery(list):
    """jQuery-like wrapper around a list of lxml elements."""

    def __init__(self, *args, **kwargs):
        super().__init__()
        self._parent = kwargs.pop("parent", None)
        self._base_url = kwargs.pop("base_url", None)
        self.parser = kwargs.pop("parser", None)
        kwargs.pop("css_translator", None)
        kwargs.pop("namespaces", None)
        if self._base_url is None and isinstance(self._parent, PyQuery):
            self._base_url = self._parent._base_url
        self._load(args, kwargs)

    # -- construction ------------------------------------------------------------------------------------------------
    def _load(self, args, options):
        if not args:
            if "filename" in options:
                with open(options["filename"], "rb") as handle:
                    list.extend(self, _parse(handle.read(), self.parser))
            elif "url" in options:
                list.extend(self, _parse(self._fetch(options.pop("url"), options), self.parser))
            return
        if len(args) == 1:
            source = args[0]
            if isinstance(source, (str, bytes, bytearray)):
                list.extend(self, _parse(source, self.parser))
                return
            list.extend(self, self._elements(source))
            return
        selector, context = args[0], args[1]
        if isinstance(context, (str, bytes, bytearray)):
            base = _parse(context, self.parser)
        elif context is None:
            base = []
        else:
            base = self._elements(context)
        if selector is None or selector == "":
            list.extend(self, base)
        elif isinstance(selector, str):
            list.extend(self, self._search(base, selector, True))
        else:
            wanted = {e._id for e in self._elements(selector)}
            pool = []
            for element in base:
                pool.append(element)
                pool.extend(element.iterdescendants())
            list.extend(self, [e for e in _distinct(pool) if e._id in wanted])

    @staticmethod
    def _elements(source):
        if source is None:
            return []
        if isinstance(source, etree._Element):
            return [source]
        if isinstance(source, etree._ElementTree):
            return [source.getroot()]
        if hasattr(source, "read"):
            return _parse(source.read())
        if isinstance(source, (list, tuple)) or hasattr(source, "__iter__"):
            out = []
            for item in source:
                if isinstance(item, etree._Element):
                    out.append(item)
                elif isinstance(item, PyQuery):
                    out.extend(item)
                elif isinstance(item, str):
                    out.extend(_parse(item))
                else:
                    raise TypeError("PyQuery 无法处理 %s" % type(item).__name__)
            return out
        raise TypeError("PyQuery 无法处理 %s" % type(source).__name__)

    def _fetch(self, url, options):
        import requests

        method = options.pop("method", "get")
        encoding = options.pop("encoding", None)
        data = options.pop("data", None)
        options.pop("opener", None)
        kept = {k: options[k] for k in ("headers", "cookies", "timeout", "auth", "verify", "session") if k in options}
        client = kept.pop("session", None) or requests
        if method.lower() == "post":
            reply = client.post(url, data=data, **kept)
        else:
            reply = client.get(url, params=data, **kept)
        if encoding:
            reply.encoding = encoding
        self._base_url = reply.url
        return reply.text

    def _new(self, elements, parent=_MISSING):
        out = PyQuery(parent=self if parent is _MISSING else parent)
        list.extend(out, elements)
        return out

    def __call__(self, *args, **kwargs):
        if not args:
            return self._new([], self)
        if len(args) == 1 and not kwargs:
            selector = args[0]
            if isinstance(selector, str):
                if selector.lstrip().startswith("<"):
                    return PyQuery(selector, parent=self)
                if not selector.strip():
                    return self._new([])
                return self._new(self._search(list(self), selector, True))
            if isinstance(selector, PyQuery):
                return selector
            return PyQuery(selector, parent=self)
        kwargs.setdefault("parent", self)
        return PyQuery(*args, **kwargs)

    @staticmethod
    def _search(elements, selector, with_self):
        """Host search below `elements`, optionally testing the elements themselves as well."""
        if not elements:
            return []
        found = host_select(elements, selector)
        roots = {e._id for e in elements}
        overlap = [e for e in found if e._id in roots]
        if with_self:
            try:
                positional = _css.is_positional(selector)
            except _css.SelectorSyntaxError:
                positional = False
            if not positional:
                have = {e._id for e in found}
                own = [e for e in elements if e._id not in have and self_matches(e, selector)]
                if own:
                    if len(elements) == 1:
                        return own + found
                    order = []
                    for element in elements:
                        order.append(element)
                        order.extend(element.iterdescendants())
                    keep = have | {e._id for e in own}
                    return [e for e in _distinct(order) if e._id in keep]
            return found
        if overlap:
            # A context element may only stay when it is really below another context element.
            drop = {e._id for e in overlap if not any(a._id in roots for a in e.iterancestors())}
            found = [e for e in found if e._id not in drop]
        return found

    # -- list behaviour ----------------------------------------------------------------------------------------------
    def __getitem__(self, index):
        if isinstance(index, slice):
            return self._new(list.__getitem__(self, index))
        return list.__getitem__(self, index)

    def __add__(self, other):
        extra = self._elements(other)
        return self._new(list(self) + extra)

    def __iadd__(self, other):
        list.extend(self, self._elements(other))
        return self

    def add(self, other, context=None):
        extra = PyQuery(other, context) if isinstance(other, str) and context is not None else PyQuery(other)
        return self._new(list(self) + [e for e in extra if e not in self])

    def copy(self):
        return self._new(list(self), self._parent)

    __copy__ = copy

    def __deepcopy__(self, memo):
        return self.clone()

    def extend(self, other):
        list.extend(self, self._elements(other))
        return self

    @property
    def length(self):
        return len(self)

    def size(self):
        return len(self)

    @property
    def root(self):
        return self[0].getroottree() if self else None

    @property
    def base_url(self):
        return self._base_url

    @property
    def encoding(self):
        return "utf-8"

    @property
    def fn(self):
        _unsupported("PyQuery.fn")

    def __repr__(self):
        out = []
        for element in self:
            mark = element.get("id")
            names = (element.get("class") or "").split()
            out.append("<%s%s%s>" % (element.tag, "#" + mark if mark else "", "".join("." + n for n in names)))
        return "[%s]" % ", ".join(out)

    def __str__(self):
        return "".join(etree.tostring(e, encoding=str) for e in self)

    __unicode__ = __str__

    def __html__(self):
        from lxml.html import tostring

        return "".join(tostring(e, encoding=str) for e in self)

    # -- traversal ---------------------------------------------------------------------------------------------------
    def items(self, selector=None):
        found = self
        if selector:
            found = self.find(selector)
            if not found:
                found = self.filter(selector)
        for element in list(found):
            yield self._new([element])

    def find(self, selector):
        if not selector:
            return self._new([])
        if not isinstance(selector, str):
            wanted = {e._id for e in self._elements(selector)}
            below = _distinct(d for e in self for d in e.iterdescendants())
            return self._new([e for e in below if e._id in wanted])
        return self._new(self._search(list(self), selector, False))

    def _narrow(self, elements, selector):
        elements = _distinct(elements)
        if selector is not None and selector != "":
            if isinstance(selector, str):
                elements = filter_elements(elements, selector)
            elif callable(selector) and not isinstance(selector, PyQuery):
                elements = [e for i, e in enumerate(elements) if _call(selector, i, e)]
            else:
                wanted = {e._id for e in self._elements(selector)}
                elements = [e for e in elements if e._id in wanted]
        return self._new(elements)

    def filter(self, selector):
        return self._narrow(list(self), selector)

    def not_(self, selector):
        drop = {e._id for e in self._narrow(list(self), selector)} if selector else set()
        return self._new([e for e in self if e._id not in drop])

    def is_(self, selector):
        return bool(self._narrow(list(self), selector))

    def children(self, selector=None):
        return self._narrow([k for e in self for k in e.getchildren()], selector)

    def parent(self, selector=None):
        return self._narrow([p for p in (e.getparent() for e in self) if p is not None], selector)

    def parents(self, selector=None):
        out = []
        for element in self:
            up = list(element.iterancestors())
            out.extend(up[::-1])
        return self._narrow(out, selector)

    def closest(self, selector=None):
        out = []
        for element in self:
            node = element
            while node is not None:
                if not selector or filter_elements([node], selector):
                    out.append(node)
                    break
                node = node.getparent()
        return self._new(_distinct(out))

    def next(self, selector=None):
        return self._narrow([n for n in (e.getnext() for e in self) if n is not None], selector)

    def prev(self, selector=None):
        return self._narrow([n for n in (e.getprevious() for e in self) if n is not None], selector)

    def next_all(self, selector=None):
        return self._narrow([n for e in self for n in e.itersiblings()], selector)

    def prev_all(self, selector=None):
        return self._narrow([n for e in self for n in list(e.itersiblings(preceding=True))[::-1]], selector)

    def _until(self, following, selector, filter_):
        out = []
        for element in self:
            for node in element.itersiblings(preceding=not following):
                if selector and filter_elements([node], selector):
                    break
                out.append(node)
        return self._narrow(out, filter_)

    def next_until(self, selector, filter_=None):
        return self._until(True, selector, filter_)

    def prev_until(self, selector, filter_=None):
        return self._until(False, selector, filter_)

    def siblings(self, selector=None):
        out = []
        for element in self:
            out.extend(list(element.itersiblings(preceding=True))[::-1])
            out.extend(element.itersiblings())
        return self._narrow(out, selector)

    def contents(self):
        """Child elements and text pieces, in document order (text as plain str, as upstream)."""
        out = []
        for element in self:
            for item in _dom.child_nodes(element._id):
                if "n" in item:
                    out.append(type(element)(item["n"], element._doc))
                elif "s" in item:
                    out.append(etree._SmartString(item["s"]))
        return self._new(out)

    def eq(self, index):
        try:
            return self._new([list.__getitem__(self, index)])
        except IndexError:
            return self._new([])

    def first(self):
        return self.eq(0)

    def last(self):
        return self.eq(-1)

    def slice(self, start=None, end=None):
        return self[start:end]

    def end(self):
        return self._parent

    def each(self, func):
        for index, element in enumerate(list(self)):
            if _call(func, index, element) is False:
                break
        return self

    def map(self, func):
        out = []
        for index, element in enumerate(list(self)):
            value = _call(func, index, element)
            if value is None:
                continue
            if isinstance(value, list):
                out.extend(value)
            else:
                out.append(value)
        return self._new(out)

    # -- attributes --------------------------------------------------------------------------------------------------
    @property
    def attr(self):
        return _Accessor(self)

    @attr.setter
    def attr(self, value):
        self._attr(value)

    def _attr(self, *args, **kwargs):
        if kwargs and not args:
            args = ({_ATTR_ALIASES.get(k, k): v for k, v in kwargs.items()},)
        if len(args) == 1:
            name = args[0]
            if isinstance(name, dict):
                for key, value in name.items():
                    self._attr(key, value)
                return self
            if not self:
                return None
            return self[0].get(_ATTR_ALIASES.get(name, name))
        if len(args) != 2:
            raise ValueError("Invalid arguments %s %s" % (args, kwargs))
        name, value = args
        if value is None:
            return self.remove_attr(name)
        for element in self:
            element.set(_ATTR_ALIASES.get(name, name), str(value))
        return self

    def remove_attr(self, name):
        name = _ATTR_ALIASES.get(name, name)
        for element in self:
            if element.get(name) is not None:
                element._set_attr(name, None)
        return self

    def has_class(self, name):
        return any(name in (e.get("class") or "").split() for e in self)

    def add_class(self, value):
        for element in self:
            for name in value.split():
                element.classes.add(name)
        return self

    def remove_class(self, value=None):
        for element in self:
            if value is None:
                if element.get("class") is not None:
                    element._set_attr("class", None)
            else:
                for name in value.split():
                    element.classes.discard(name)
        return self

    def toggle_class(self, value):
        for element in self:
            for name in value.split():
                element.classes.toggle(name)
        return self

    @property
    def css(self):
        _unsupported(".css()")

    def hide(self):
        _unsupported(".hide()")

    def show(self):
        _unsupported(".show()")

    def val(self, value=_MISSING):
        if value is not _MISSING:
            return self._attr("value", value)
        if not self:
            return None
        element = self[0]
        if element.tag == "select":
            options = element._nodes("descendant::option")
            chosen = [o for o in options if o.get("selected") is not None]
            if element.get("multiple") is not None:
                return [_option(o) for o in chosen]
            return _option((chosen or options)[-1 if chosen else 0]) if options else None
        if element.tag == "textarea":
            return element.text or ""
        if element.tag == "option":
            return _option(element)
        value = element.get("value")
        if value is None and element.get("type") in ("checkbox", "radio"):
            return "on"
        return value

    # -- text and markup ---------------------------------------------------------------------------------------------
    def text(self, value=_MISSING, **kwargs):
        if value is not _MISSING:
            for element in self:
                _dom.set_text(element._id, "" if value is None else str(value))
            return self
        squash = kwargs.get("squash_space", True)
        block, separator = kwargs.get("block_symbol", "\n"), kwargs.get("sep_symbol", "\n")
        out = []
        for element in self:
            if isinstance(element, str):
                out.append(element)
            else:
                out.append(_markup.visible_text(_dom.outer(element._id), squash, block, separator))
        return " ".join(out)

    def html(self, value=_MISSING, **kwargs):
        if value is not _MISSING:
            if isinstance(value, str) and "<" not in value and "&" not in value:
                return self.text(value)
            _unsupported(".html(带标签的内容)")
        if not self:
            return None
        element = self[0]
        if isinstance(element, str):
            return escape(element, quote=False)
        inner = _dom.inner(element._id)
        method = kwargs.get("method")
        if element._doc.xml or method == "html":
            return inner
        if method not in (None, "xml"):
            _unsupported(".html(method=%r)" % method)
        if element.tag in _markup.RAW_TEXT:
            return element.text or ""  # script source as is; without its tag it would be tokenised as markup
        return _markup.to_xml(inner)

    def outer_html(self, method="html"):
        if not self:
            return None
        element = self[0]
        if isinstance(element, str):
            return str(element)
        return etree.tostring(element, encoding=str, method=method, with_tail=False)

    def serialize_array(self):
        out = []
        for element in self:
            for field in element._nodes("descendant-or-self::*[self::input or self::select or self::textarea]"):
                name, kind = field.get("name"), (field.get("type") or "").lower()
                if not name or field.get("disabled") is not None:
                    continue
                if kind in ("submit", "button", "reset", "image", "file"):
                    continue
                if kind in ("checkbox", "radio") and field.get("checked") is None:
                    continue
                value = self._new([field]).val()
                for item in value if isinstance(value, list) else [value]:
                    if item is not None:
                        out.append({"name": name, "value": item})
        return out

    def serialize_dict(self):
        out = {}
        for pair in self.serialize_array():
            old = out.get(pair["name"])
            if old is None:
                out[pair["name"]] = pair["value"]
            else:
                out[pair["name"]] = (old if isinstance(old, list) else [old]) + [pair["value"]]
        return out

    def serialize_pairs(self):
        return [(p["name"], p["value"]) for p in self.serialize_array()]

    def serialize(self):
        from urllib.parse import urlencode

        return urlencode(self.serialize_pairs())

    # -- editing -----------------------------------------------------------------------------------------------------
    def remove(self, expr=_MISSING):
        """Remove the elements (or the descendants matching `expr`); the text after them stays."""
        target = list(self) if expr is _MISSING else list(self.find(expr))
        _dom.remove([e._id for e in target if isinstance(e, etree._Element) and e.getparent() is not None])
        return self

    def empty(self):
        for element in self:
            _dom.set_text(element._id, "")
        return self

    def clone(self):
        import copy

        return self._new([copy.deepcopy(e) for e in self], self._parent)

    def append(self, value):
        _unsupported(".append()")

    def prepend(self, value):
        _unsupported(".prepend()")

    def append_to(self, value):
        _unsupported(".append_to()")

    def prepend_to(self, value):
        _unsupported(".prepend_to()")

    def after(self, value):
        _unsupported(".after()")

    def before(self, value):
        _unsupported(".before()")

    def insert_after(self, value):
        _unsupported(".insert_after()")

    def insert_before(self, value):
        _unsupported(".insert_before()")

    def wrap(self, value):
        _unsupported(".wrap()")

    def wrap_all(self, value):
        _unsupported(".wrap_all()")

    def replace_with(self, value):
        _unsupported(".replace_with()")

    def replace_all(self, expr):
        _unsupported(".replace_all()")

    # -- documents ---------------------------------------------------------------------------------------------------
    def xhtml_to_html(self):
        return self  # pages are always parsed as HTML, there is no XHTML namespace to strip

    def remove_namespaces(self):
        return self

    def make_links_absolute(self, base_url=None):
        base = base_url or self._base_url
        if base is None:
            raise ValueError("You need a base URL to make your links absolute: pass base_url.")
        from urllib.parse import urljoin

        for element in self:
            for node in element._nodes("descendant-or-self::*[@href or @src or @action]"):
                for key in ("href", "src", "action"):
                    link = node.get(key)
                    if link is None or link.strip().startswith(("data:", "javascript:")):
                        continue
                    node.set(key, urljoin(base, link.strip()))
        return self

    # -- camelCase aliases -------------------------------------------------------------------------------------------
    nextAll = next_all
    prevAll = prev_all
    nextUntil = next_until
    prevUntil = prev_until
    hasClass = has_class
    addClass = add_class
    removeClass = remove_class
    toggleClass = toggle_class
    removeAttr = remove_attr
    outerHtml = outerHTML = outer_html
    serializeArray = serialize_array
    serializeDict = serialize_dict
    serializePairs = serialize_pairs
    appendTo = append_to
    prependTo = prepend_to
    insertAfter = insert_after
    insertBefore = insert_before
    replaceWith = replace_with
    replaceAll = replace_all
    wrapAll = wrap_all


def _option(element):
    value = element.get("value")
    return value if value is not None else (_dom.string(element._id) or "").strip()
