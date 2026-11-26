"""lxml.etree-compatible API (original implementation for i短剧, GPL-3.0)."""

from __future__ import annotations

import re
from collections.abc import MutableMapping

import _idj_dom as _dom
import _idj_text as _text
import _idj_xpath as _xp
from _idj_bridge import HostError as _HostError

LXML_VERSION = (5, 3, 0, 0)
LIBXML_VERSION = LIBXML_COMPILED_VERSION = (2, 12, 9)
LIBXSLT_VERSION = LIBXSLT_COMPILED_VERSION = (1, 1, 42)
__version__ = "5.3.0"


# --- errors -------------------------------------------------------------------------------------------------------


class Error(Exception):
    pass


class LxmlError(Error):
    def __init__(self, message="", error_log=None):
        super().__init__(message)
        self.error_log = error_log if error_log is not None else ()


class LxmlSyntaxError(LxmlError, SyntaxError):
    def __init__(self, message="", *args):
        LxmlError.__init__(self, message)
        self.msg = message


class ParseError(LxmlSyntaxError):
    position = (0, 0)
    code = None


class XMLSyntaxError(ParseError):
    pass


class ParserError(LxmlError):
    pass


class XPathError(LxmlError):
    pass


class XPathEvalError(XPathError):
    pass


class XPathSyntaxError(LxmlSyntaxError, XPathError):
    pass


class SerialisationError(LxmlError):
    pass


class C14NError(LxmlError):
    pass


class DocumentInvalid(LxmlError):
    pass


def _unsupported(what):
    raise NotImplementedError("lxml（iOS 版）不支持 %s" % what)


# --- node kinds ---------------------------------------------------------------------------------------------------


def Comment(text=None):
    _unsupported("创建注释节点 etree.Comment()")


def ProcessingInstruction(target=None, text=None):
    _unsupported("创建处理指令 etree.ProcessingInstruction()")


PI = ProcessingInstruction


def Entity(name):
    _unsupported("etree.Entity()")


def CDATA(data):
    _unsupported("etree.CDATA()")


class QName:
    """Qualified name in Clark notation."""

    def __init__(self, text_or_uri_or_element, tag=None):
        base = text_or_uri_or_element
        if isinstance(base, (_Element, QName)):
            base = base.tag if isinstance(base, _Element) else base.text
        if tag is not None:
            base = "{%s}%s" % (base, tag) if base else tag
        self.text = base
        found = re.match(r"\{([^}]*)\}(.*)$", base, re.S)
        self.namespace, self.localname = (found.group(1), found.group(2)) if found else (None, base)

    def __str__(self):
        return self.text

    def __hash__(self):
        return hash(self.text)

    def __eq__(self, other):
        return self.text == (other.text if isinstance(other, QName) else other)


# --- XPath string results -------------------------------------------------------------------------------------------


class _SmartString(str):
    """String result of an XPath query; remembers the query so that getparent() can be answered on demand."""

    def __new__(cls, value, origin=None, index=0):
        self = super().__new__(cls, value)
        self._origin = origin
        self._index = index
        return self

    def __reduce__(self):
        return str, (str(self),)  # copies and pickles are ordinary strings

    def getparent(self):
        return self._origin.parent_of(self._index, str(self)) if self._origin else None

    @property
    def is_attribute(self):
        return bool(self._origin and self._origin.attribute)

    @property
    def attrname(self):
        name = self._origin.attribute if self._origin else None
        return None if name in (None, "*") else name

    @property
    def is_text(self):
        if not self._origin or self._origin.attribute:
            return False
        parent = self.getparent()
        return parent is not None and parent.text == str(self)

    @property
    def is_tail(self):
        return bool(self._origin) and not self._origin.attribute and not self.is_text


_ElementUnicodeResult = _SmartString
_ElementStringResult = _SmartString


class _Origin:
    """Where a list of XPath strings came from."""

    __slots__ = ("element", "query", "total", "attribute", "_parents")

    def __init__(self, element, query, total):
        self.element = element
        self.query = query
        self.total = total
        self._parents = None
        found = re.search(r"(?:@|attribute::)\s*([\w.\-:]+|\*)\s*(?:\[[^\[\]]*\]\s*)*\)?\s*$", query)
        self.attribute = found.group(1) if found else None

    def parent_of(self, index, value):
        if self._parents is None:
            try:
                self._parents = self.element._nodes("(%s)/.." % self.query)
            except LxmlError:
                self._parents = []
        parents = self._parents
        if len(parents) == self.total:
            return parents[index]
        # Several strings share a parent: fall back to the first parent that owns an equal string.
        want = _xp.literal(value)
        test = "@*[.=%s]" % want if self.attribute else "text()[.=%s]" % want
        for parent in parents:
            if parent._raw_xpath("boolean(%s)" % test)[:1] == [{"s": "true"}]:
                return parent
        return None


# --- attributes -----------------------------------------------------------------------------------------------------


class _Attrib(MutableMapping):
    """Live view of an element's attributes."""

    __slots__ = ("_element",)

    def __init__(self, element):
        self._element = element

    def _map(self):
        return self._element._info().get("attrs") or {}

    def __getitem__(self, key):
        return self._map()[_name(key)]

    def __setitem__(self, key, value):
        self._element.set(key, value)

    def __delitem__(self, key):
        key = _name(key)
        if key not in self._map():
            raise KeyError(key)
        self._element._set_attr(key, None)

    def __iter__(self):
        return iter(list(self._map()))

    def __len__(self):
        return len(self._map())

    def __contains__(self, key):
        return _name(key) in self._map()

    def has_key(self, key):
        return key in self

    def keys(self):
        return list(self._map())

    def values(self):
        return list(self._map().values())

    def items(self):
        return list(self._map().items())

    iterkeys = __iter__

    def itervalues(self):
        return iter(self.values())

    def iteritems(self):
        return iter(self.items())

    def __copy__(self):
        return dict(self._map())

    def __deepcopy__(self, memo):
        return dict(self._map())

    def __eq__(self, other):
        return dict(self._map()) == (dict(other) if isinstance(other, (dict, MutableMapping)) else other)

    def __repr__(self):
        return repr(dict(self._map()))


def _name(key):
    if isinstance(key, QName):
        return key.text
    return key.decode("utf-8") if isinstance(key, bytes) else key


def _to_text(value, what):
    if isinstance(value, str):
        return value
    if isinstance(value, (bytes, bytearray)):
        return bytes(value).decode("utf-8")
    if isinstance(value, QName):
        return value.text
    raise TypeError("%s must be bytes or unicode, got %s" % (what, type(value).__name__))


# --- documents and elements -----------------------------------------------------------------------------------------


class _Document:
    """One parsed host document."""

    __slots__ = ("id", "xml", "base")

    def __init__(self, doc_id, xml, base=None):
        self.id = doc_id
        self.xml = xml
        self.base = base

    def root(self, cls):
        kids = _dom.rel(self.id, "children")
        return cls(kids[0], self) if kids else None


class _Element:
    """An element of a host document."""

    __slots__ = ("_id", "_doc", "_data", "_seen")

    def __init__(self, node_id, doc):
        self._id = node_id
        self._doc = doc
        self._data = None
        self._seen = -1

    # -- host access -------------------------------------------------------------------------------------------------
    def _info(self):
        if self._data is None or self._seen != _dom.epoch:
            self._seen = _dom.epoch
            self._data = _dom.info(self._id)
        return self._data

    def _wrap(self, ids):
        cls, doc = type(self), self._doc
        return [cls(i, doc) for i in ids]

    def _set_attr(self, key, value):
        _dom.set_attr(self._id, key, value)

    def _raw_xpath(self, query):
        try:
            return _dom.xpath(self._id, query)
        except _HostError as exc:
            raise XPathEvalError("%s（XPath: %s）" % (exc.message, query)) from exc

    def _nodes(self, query):
        """Element results of a native node-set query."""
        doc = self._doc.id
        return self._wrap(r["n"] for r in self._raw_xpath(query) if "n" in r and r["n"] != doc)

    # -- identity ----------------------------------------------------------------------------------------------------
    def __eq__(self, other):
        return self is other or (isinstance(other, _Element) and other._id == self._id and other._doc is self._doc)

    def __ne__(self, other):
        return not self == other

    def __hash__(self):
        return hash(self._id)

    def __repr__(self):
        try:
            tag = self.tag
        except _HostError:
            tag = "?"
        if tag is Comment:
            return "<!--%s-->" % self.text
        return "<Element %s at 0x%x>" % (tag, id(self))

    # -- names and text ----------------------------------------------------------------------------------------------
    @property
    def tag(self):
        tag = self._info().get("tag")
        return Comment if tag == "!comment" else tag

    @tag.setter
    def tag(self, value):
        _unsupported("修改元素标签 element.tag = …")

    @property
    def prefix(self):
        tag = self._info().get("tag") or ""
        return tag.partition(":")[0] if ":" in tag and not tag.startswith("{") else None

    @property
    def nsmap(self):
        return {}

    @property
    def base(self):
        return self._doc.base

    @property
    def sourceline(self):
        return None

    @property
    def text(self):
        data = self._info()
        if data.get("tag") == "!comment":
            return data.get("text") if data.get("text") is not None else _dom.string(self._id)
        return data.get("text") or None

    @text.setter
    def text(self, value):
        if value is not None:
            value = _to_text(value, "text")
        if len(self):
            _unsupported("修改带子元素的 element.text")
        _dom.set_text(self._id, value or "")

    @property
    def tail(self):
        return self._info().get("tail") or None

    @tail.setter
    def tail(self, value):
        if (value or "") != (self.tail or ""):
            _unsupported("修改 element.tail")

    def itertext(self, *tags, with_tail=True):
        if tags and tags[0] is not None:
            for element in self.iter(*tags):
                if element.text:
                    yield element.text
                if with_tail and element.tail and element != self:
                    yield element.tail
            return
        for item in self._raw_xpath(".//text()"):
            if "s" in item:
                yield item["s"]

    def text_content(self):
        return _SmartString(_dom.string(self._id))

    # -- attributes --------------------------------------------------------------------------------------------------
    @property
    def attrib(self):
        return _Attrib(self)

    def get(self, key, default=None):
        value = (self._info().get("attrs") or {}).get(_name(key))
        return default if value is None else value

    def set(self, key, value=None):
        self._set_attr(_to_text(key, "attribute name"), "" if value is None else _to_text(value, "attribute value"))

    def keys(self):
        return list(self._info().get("attrs") or {})

    def values(self):
        return list((self._info().get("attrs") or {}).values())

    def items(self):
        return list((self._info().get("attrs") or {}).items())

    # -- children ----------------------------------------------------------------------------------------------------
    def getchildren(self):
        return self._wrap(_dom.rel(self._id, "children"))

    def __len__(self):
        return len(_dom.rel(self._id, "children"))

    def __bool__(self):
        # lxml: an element is true when it has children.
        return len(self) > 0

    def __iter__(self):
        return iter(self.getchildren())

    def __reversed__(self):
        return reversed(self.getchildren())

    def __getitem__(self, index):
        return self.getchildren()[index]

    def __contains__(self, element):
        return isinstance(element, _Element) and element in self.getchildren()

    def index(self, child, start=None, stop=None):
        kids = self.getchildren()
        found = kids.index(child) if child in kids else -1
        low, high, _ = slice(start, stop).indices(len(kids))
        if not low <= found < high:
            raise ValueError("Element is not a child of this node.")
        return found

    def iterchildren(self, *tags, reversed=False, tag=None):
        kids = _by_tag(self.getchildren(), tags or ((tag,) if tag is not None else ()))
        return iter(kids[::-1] if reversed else kids)

    # -- relatives ---------------------------------------------------------------------------------------------------
    def getparent(self):
        ids = _dom.rel(self._id, "parent")
        if not ids or ids[0] == self._doc.id:
            return None
        parent = type(self)(ids[0], self._doc)
        return parent if parent._info().get("tag") else None

    def getnext(self):
        ids = _dom.rel(self._id, "next")
        return type(self)(ids[0], self._doc) if ids else None

    def getprevious(self):
        ids = _dom.rel(self._id, "prev")
        return type(self)(ids[0], self._doc) if ids else None

    def itersiblings(self, *tags, preceding=False, tag=None):
        nodes = self._nodes("preceding-sibling::*" if preceding else "following-sibling::*")
        if preceding:
            nodes.reverse()
        return iter(_by_tag(nodes, tags or ((tag,) if tag is not None else ())))

    def iterancestors(self, *tags, tag=None):
        nodes = self._nodes("ancestor::*")
        nodes.reverse()
        return iter(_by_tag(nodes, tags or ((tag,) if tag is not None else ())))

    def iterdescendants(self, *tags, tag=None):
        return self._walk("descendant", tags or ((tag,) if tag is not None else ()))

    def iter(self, *tags, tag=None):
        return self._walk("descendant-or-self", tags or ((tag,) if tag is not None else ()))

    getiterator = iter

    def _walk(self, axis, tags):
        tags = _flat_tags(tags)
        if not tags:
            return iter(self._nodes("%s::*" % axis))
        steps = []
        for tag in tags:
            if tag is Comment:
                steps.append("%s::comment()" % axis)
            elif tag is ProcessingInstruction:
                steps.append("%s::processing-instruction()" % axis)
            else:
                steps.append("%s::%s" % (axis, _clark_test(tag)))
        return iter(self._nodes(" | ".join(steps)))

    def getroottree(self):
        return _ElementTree(self._doc, self._doc.root(type(self)))

    # -- queries -----------------------------------------------------------------------------------------------------
    def xpath(self, _path, *, namespaces=None, extensions=None, smart_strings=True, **_variables):
        if extensions:
            _unsupported("XPath 扩展函数 extensions=")
        if not isinstance(_path, str):
            _path = _path.decode("utf-8")
        return _evaluate(self, _path, namespaces, _variables, smart_strings)

    def cssselect(self, expr, *, translator="html"):
        from .cssselect import css_select

        return css_select(self, expr)

    def find(self, path, namespaces=None):
        return next(self.iterfind(path, namespaces), None)

    def findall(self, path, namespaces=None):
        return list(self.iterfind(path, namespaces))

    def iterfind(self, path, namespaces=None):
        return iter(self._nodes(_find_path(path, namespaces)))

    def findtext(self, path, default=None, namespaces=None):
        found = self.find(path, namespaces)
        if found is None:
            return default
        return found.text or ""

    # -- editing -----------------------------------------------------------------------------------------------------
    def remove(self, element):
        if element not in self.getchildren():
            raise ValueError("Element is not a child of this node.")
        _dom.remove([element._id], tail=True)

    def drop_tree(self):
        _dom.remove([self._id])

    def clear(self, keep_tail=False):
        for key in self.keys():
            self._set_attr(key, None)
        _dom.set_text(self._id, "")

    def append(self, element):
        _unsupported("element.append()")

    def extend(self, elements):
        _unsupported("element.extend()")

    def insert(self, index, element):
        _unsupported("element.insert()")

    def replace(self, old, new):
        _unsupported("element.replace()")

    def addnext(self, element):
        _unsupported("element.addnext()")

    def addprevious(self, element):
        _unsupported("element.addprevious()")

    def makeelement(self, *args, **kwargs):
        _unsupported("element.makeelement()")

    def __setitem__(self, index, value):
        _unsupported("element[i] = …")

    def __delitem__(self, index):
        kids = self.getchildren()[index]
        _dom.remove([k._id for k in (kids if isinstance(kids, list) else [kids])], tail=True)

    def __copy__(self):
        return self.__deepcopy__(None)

    def __deepcopy__(self, memo):
        source = _dom.outer(self._id)
        if not self._doc.xml:
            doc = _Document(_dom.load_html("<html><body>%s</body></html>" % source), False, self._doc.base)
            found = doc.root(type(self))._nodes("/html/body/*[1]")
            if found and found[0].tag == self.tag:
                return found[0]
            from _idj_markup import to_xml

            source = to_xml(source)
        return _Document(_dom.load_xml(source), self._doc.xml, self._doc.base).root(type(self))

    # -- lxml.html conveniences --------------------------------------------------------------------------------------
    @property
    def classes(self):
        return _Classes(self)

    @property
    def label(self):
        return None


class _Comment(_Element):
    __slots__ = ()


class _ProcessingInstruction(_Element):
    __slots__ = ()


class _Classes:
    """Set-like view of the class attribute."""

    __slots__ = ("_element",)

    def __init__(self, element):
        self._element = element

    def _list(self):
        out = []
        for name in (self._element.get("class") or "").split():
            if name not in out:
                out.append(name)
        return out

    def _store(self, names):
        if names:
            self._element.set("class", " ".join(names))
        elif self._element.get("class") is not None:
            self._element._set_attr("class", None)

    def __iter__(self):
        return iter(self._list())

    def __len__(self):
        return len(self._list())

    def __contains__(self, name):
        return name in self._list()

    def __repr__(self):
        return "Classes(%r)" % set(self._list())

    def add(self, name):
        names = self._list()
        if name not in names:
            self._store(names + [name])

    def discard(self, name):
        names = self._list()
        if name in names:
            self._store([n for n in names if n != name])

    def remove(self, name):
        if name not in self:
            raise KeyError(name)
        self.discard(name)

    def update(self, values):
        for name in values:
            self.add(name)

    def toggle(self, name):
        if name in self:
            self.discard(name)
            return False
        self.add(name)
        return True


class _ElementTree:
    """Document wrapper returned by parse() and getroottree()."""

    def __init__(self, doc, root):
        self._doc = doc
        self._root = root

    def getroot(self):
        return self._root

    def _need(self):
        if self._root is None:
            raise AssertionError("ElementTree not initialized, missing root")
        return self._root

    @property
    def docinfo(self):
        return DocInfo(self._doc)

    @property
    def parser(self):
        return None

    def xpath(self, _path, *, namespaces=None, extensions=None, smart_strings=True, **_variables):
        root = self._need()
        at_doc = type(root)(self._doc.id, self._doc)
        return at_doc.xpath(
            _path, namespaces=namespaces, extensions=extensions, smart_strings=smart_strings, **_variables
        )

    def find(self, path, namespaces=None):
        return self._need().find(_tree_path(path), namespaces)

    def findall(self, path, namespaces=None):
        return self._need().findall(_tree_path(path), namespaces)

    def iterfind(self, path, namespaces=None):
        return self._need().iterfind(_tree_path(path), namespaces)

    def findtext(self, path, default=None, namespaces=None):
        return self._need().findtext(_tree_path(path), default, namespaces)

    def iter(self, *tags, tag=None):
        return self._need().iter(*tags, tag=tag)

    getiterator = iter

    def getpath(self, element):
        steps = []
        while element is not None:
            parent = element.getparent()
            step = element.tag
            if parent is not None:
                same = [k for k in parent.getchildren() if k.tag == element.tag]
                if len(same) > 1:
                    step = "%s[%d]" % (step, same.index(element) + 1)
            steps.append(step)
            element = parent
        return "/" + "/".join(reversed(steps))

    def write(self, file, encoding=None, method="xml", pretty_print=False, xml_declaration=None, with_tail=True, **_):
        data = tostring(
            self, encoding=encoding, method=method, pretty_print=pretty_print, xml_declaration=xml_declaration
        )
        if hasattr(file, "write"):
            file.write(data)
        else:
            with open(file, "wb") as out:
                out.write(data)

    def __copy__(self):
        return _ElementTree(self._doc, self._root)


class DocInfo:
    def __init__(self, doc):
        self._doc = doc
        self.encoding = "UTF-8"
        self.xml_version = "1.0"
        self.standalone = None
        self.URL = doc.base
        self.public_id = self.system_url = None
        self.doctype = "" if doc.xml else "<!DOCTYPE html>"
        self.root_name = None


def ElementTree(element=None, *, file=None, parser=None):
    if file is not None:
        return parse(file, parser)
    if element is None:
        _unsupported("空的 etree.ElementTree()")
    if not isinstance(element, _Element):
        from xml.etree.ElementTree import ElementTree as Plain

        return Plain(element)
    return _ElementTree(element._doc, element)


def iselement(element):
    return isinstance(element, _Element) or _is_plain(element)


# --- building new trees ---------------------------------------------------------------------------------------------
# The host cannot create nodes, so new XML is built with the standard library's element type; tostring() accepts it.


def _is_plain(element):
    import sys

    module = sys.modules.get("xml.etree.ElementTree")
    return module is not None and isinstance(element, module.Element)


def Element(_tag, attrib=None, nsmap=None, **_extra):
    """A new, detached element. It supports the ElementTree API (append, set, text…) but not xpath()."""
    from xml.etree.ElementTree import Element as Plain

    if nsmap:
        _unsupported("etree.Element(nsmap=…)")
    return Plain(_name(_tag), dict(attrib or {}), **_extra)


def SubElement(_parent, _tag, attrib=None, nsmap=None, **_extra):
    if isinstance(_parent, _Element):
        _unsupported("在已解析的文档里 etree.SubElement()")
    child = Element(_tag, attrib, nsmap, **_extra)
    _parent.append(child)
    return child


# --- tag filters and path translation -------------------------------------------------------------------------------


def _flat_tags(tags):
    out = []
    for tag in tags:
        if tag is None:
            continue
        if isinstance(tag, (list, tuple, set, frozenset)):
            out.extend(_flat_tags(tag))
        elif tag == "*":
            return []
        elif isinstance(tag, QName):
            out.append(tag.text)
        else:
            out.append(tag)
    return out


def _by_tag(nodes, tags):
    tags = _flat_tags(tags)
    if not tags:
        return nodes
    return [n for n in nodes if n.tag in tags or _local_match(n.tag, tags)]


def _local_match(tag, tags):
    if not isinstance(tag, str):
        return False
    uri, _, local = tag[1:].rpartition("}") if tag.startswith("{") else ("", "", tag)
    for want in tags:
        if isinstance(want, str) and want.startswith("{"):
            space, _, name = want[1:].rpartition("}")
            if name in ("*", local) and space in ("*", uri):
                return True
    return False


def _clark_test(tag):
    """`{uri}name` or `name` -> an XPath node test."""
    if tag.startswith("{"):
        uri, _, local = tag[1:].rpartition("}")
        tests = []
        if local != "*":
            tests.append("local-name()=%s" % _xp.literal(local))
        if uri != "*":
            tests.append("namespace-uri()=%s" % _xp.literal(uri))
        return "*[%s]" % " and ".join(tests) if tests else "*"
    if ":" in tag:
        return "*[name()=%s]" % _xp.literal(tag)
    return tag


def _tree_path(path):
    path = path.text if isinstance(path, QName) else path
    return "." + path if path.startswith("/") else path


def _find_path(path, namespaces=None):
    """ElementPath -> XPath (they agree except for Clark names)."""
    if isinstance(path, QName):
        path = path.text
    if path.startswith("/"):
        # lxml rejects this; "//a" is what scripts mean by ".//a".
        path = "." + path
    path = re.sub(r"\{[^}]*\}(?:[\w.\-]+|\*)", lambda m: _clark_test(m.group()), path)
    if namespaces:
        namespaces = {k: v for k, v in namespaces.items() if k}
        path = _xp.rewrite(path, namespaces)
    return path


# --- XPath evaluation -----------------------------------------------------------------------------------------------


def _number(text):
    text = text.strip()
    if text in ("Infinity", "inf"):
        return float("inf")
    if text in ("-Infinity", "-inf"):
        return float("-inf")
    try:
        return float(text)
    except ValueError:
        return float("nan")


def _evaluate(element, expr, namespaces, variables, smart=True):
    try:
        tokens = _xp.tokenize(expr)
    except _xp.XPathSyntaxProblem:
        # Let the host judge; it either knows better or produces the error message.
        tokens = None
    if not tokens:
        if not expr.strip():
            raise XPathEvalError("Invalid expression")
        return _collect(element, expr, element._raw_xpath(expr), "nodeset", smart)
    try:
        if _xp.needs_rewrite(tokens):
            kind = _xp.result_type(tokens, variables)
            expr = _xp.rewrite(expr, namespaces, variables)
            tokens = _xp.tokenize(expr)
        else:
            kind = _xp.result_type(tokens)
        if any(_xp.is_regex_call(t, namespaces) for t in tokens):
            return _Regex(namespaces, smart).evaluate(element, expr)
    except _xp.XPathSyntaxProblem as exc:
        raise XPathEvalError(str(exc)) from exc
    return _collect(element, expr, element._raw_xpath(expr), kind, smart)


def _collect(element, expr, found, kind, smart):
    if kind == "nodeset":
        cls, doc, out = type(element), element._doc, []
        origin = None
        for index, item in enumerate(found):
            node = item.get("n")
            if node is not None:
                if node != doc.id:
                    out.append(cls(node, doc))
            else:
                if smart and origin is None:
                    origin = _Origin(element, expr, len(found))
                out.append(_SmartString(item.get("s") or "", origin, index))
        return out
    value = found[0].get("s") if found else ""
    if value is None:
        value = ""
    if not isinstance(value, str):
        value = str(value).lower() if isinstance(value, bool) else str(value)
    if kind == "number":
        return _number(value)
    if kind == "boolean":
        return value.lower() in ("true", "1")
    return _SmartString(value)


class _Regex:
    """Best-effort EXSLT re:test / re:match in predicates: evaluated in Python, node by node."""

    def __init__(self, namespaces, smart):
        self.namespaces = namespaces
        self.smart = smart

    def has_call(self, tokens):
        return any(_xp.is_regex_call(t, self.namespaces) for t in tokens)

    def fail(self, expr):
        _unsupported("这种写法的 EXSLT 正则 XPath: %s" % expr)

    def evaluate(self, element, expr):
        expr = expr.strip()
        parts = _xp.split_union(expr)
        if len(parts) > 1:
            out = []
            for part in parts:
                for item in _evaluate(element, part, self.namespaces, {}, self.smart):
                    if not (isinstance(item, _Element) and item in out):
                        out.append(item)
            return out
        tokens = _xp.tokenize(expr)
        if _xp.is_regex_call(tokens[0], self.namespaces):
            args, end = _xp.call_arguments(expr, tokens, 1)
            # Outside a predicate re:match() yields <match> elements, which cannot be made here.
            if end == len(tokens) - 1 and not tokens[0].text.endswith(":match"):
                return self.call(element, tokens[0].text, args, expr)
            self.fail(expr)
        depth = 0
        for i, token in enumerate(tokens):
            if token.kind == "sym" and token.text == "(":
                depth += 1
            elif token.kind == "sym" and token.text == ")":
                depth -= 1
            elif token.kind == "sym" and token.text == "[" and depth == 0:
                end = _xp.closing(tokens, i)
                if self.has_call(tokens[i:end]):
                    if self.has_call(tokens[:i]):
                        self.fail(expr)
                    head = expr[:token.pos]
                    if any(
                        tokens[k].kind == "op" for k in _xp.top_level(tokens) if tokens[k].pos < token.pos
                    ) or tokens[0].kind == "func" and tokens[0].text not in ("text", "node", "comment"):
                        self.fail(expr)
                    nodes = element._raw_xpath(head)
                    keep = self.filter(element, nodes, expr[token.end:tokens[end].pos], expr)
                    return self.proceed(element, keep, expr[tokens[end].end:], expr)
        self.fail(expr)

    def filter(self, element, raw, predicate, expr):
        cls, doc, out = type(element), element._doc, []
        for item in raw:
            if isinstance(item, (_Element, str)):
                node = item
            elif item.get("n") is not None:
                node = cls(item["n"], doc)
            else:
                node = _SmartString(item.get("s") or "")
            if self.holds(node, predicate, expr):
                out.append(node)
        return out

    def proceed(self, element, nodes, rest, expr):
        rest = rest.strip()
        while rest.startswith("["):
            tokens = _xp.tokenize(rest)
            end = _xp.closing(tokens, 0)
            predicate = rest[tokens[0].end:tokens[end].pos]
            nodes = self.filter(element, nodes, predicate, expr)
            rest = rest[tokens[end].end:].strip()
        if not rest:
            return nodes
        if not rest.startswith("/"):
            self.fail(expr)
        out, seen = [], set()
        for node in nodes:
            if not isinstance(node, _Element):
                self.fail(expr)
            for item in _evaluate(node, "." + rest, self.namespaces, {}, self.smart):
                if isinstance(item, _Element):
                    if item._id in seen:
                        continue
                    seen.add(item._id)
                out.append(item)
        return out

    def holds(self, node, predicate, expr):
        tokens = _xp.tokenize(predicate)
        if _xp.result_type(tokens) == "number" or any(
            t.kind == "func" and t.text in ("position", "last") for t in tokens
        ):
            self.fail(expr)
        outer = set(_xp.top_level(tokens))
        edits, nested, i = [], False, 0
        depth = 0
        while i < len(tokens):
            token = tokens[i]
            if token.kind == "sym" and token.text == "[":
                depth += 1
            elif token.kind == "sym" and token.text == "]":
                depth -= 1
            elif _xp.is_regex_call(token, self.namespaces):
                if depth:
                    nested = True
                else:
                    args, end = _xp.call_arguments(predicate, tokens, i + 1)
                    value = self.call(node, token.text, args, expr)
                    edits.append((token.pos, tokens[end].end, "true()" if value else "false()"))
                    i = end
            i += 1
        if nested:
            if edits or not isinstance(node, _Element) or any(tokens[k].kind == "op" for k in outer):
                self.fail(expr)
            return bool(_evaluate(node, predicate, self.namespaces, {}, False))
        for start, end, text in reversed(edits):
            predicate = predicate[:start] + text + predicate[end:]
        if predicate.strip() in ("true()", "false()"):
            return predicate.strip() == "true()"
        if not isinstance(node, _Element):
            self.fail(expr)
        return bool(_evaluate(node, "boolean(%s)" % predicate, self.namespaces, {}, False))

    def text(self, node, arg, expr):
        tokens = _xp.tokenize(arg)
        if len(tokens) == 1 and tokens[0].kind == "lit":
            return tokens[0].text[1:-1]
        if isinstance(node, str):
            if arg.strip() in (".", "string(.)", "string()"):
                return str(node)
            self.fail(expr)
        return str(_evaluate(node, "string(%s)" % arg, self.namespaces, {}, False))

    def call(self, node, name, args, expr):
        local = name.split(":", 1)[1]
        if local not in ("test", "match", "replace") or len(args) < 2:
            self.fail(expr)
        subject, pattern = self.text(node, args[0], expr), self.text(node, args[1], expr)
        flags = self.text(node, args[2], expr) if len(args) > 2 else ""
        compiled = re.compile(pattern, re.I if "i" in flags else 0)
        if local == "replace":
            if len(args) < 4:
                self.fail(expr)
            new = self.text(node, args[3], expr)
            return compiled.sub(new, subject, 0 if "g" in flags else 1)
        return compiled.search(subject) is not None


class XPath:
    """Compiled expression: XPath('//a')(element)."""

    def __init__(self, path, *, namespaces=None, extensions=None, regexp=True, smart_strings=True):
        if extensions:
            _unsupported("XPath 扩展函数 extensions=")
        self.path = path
        self._namespaces = namespaces
        self._smart = smart_strings
        try:
            _xp.tokenize(path)
        except _xp.XPathSyntaxProblem as exc:
            raise XPathSyntaxError(str(exc)) from exc

    def __call__(self, _etree_or_element, **variables):
        return _etree_or_element.xpath(
            self.path, namespaces=self._namespaces, smart_strings=self._smart, **variables
        )

    def __repr__(self):
        return self.path


class ETXPath(XPath):
    """XPath with `{uri}name` tests."""

    def __init__(self, path, **kwargs):
        super().__init__(re.sub(r"\{[^}]*\}(?:[\w.\-]+|\*)", lambda m: _clark_test(m.group()), path), **kwargs)


class XPathEvaluator:
    def __init__(self, etree_or_element, *, namespaces=None, extensions=None, regexp=True, smart_strings=True):
        if extensions:
            _unsupported("XPath 扩展函数 extensions=")
        self._target = etree_or_element
        self._namespaces = namespaces

    def __call__(self, _path, **variables):
        return self._target.xpath(_path, namespaces=self._namespaces, **variables)


XPathElementEvaluator = XPathDocumentEvaluator = XPathEvaluator


# --- parsers --------------------------------------------------------------------------------------------------------


class _BaseParser:
    _html = False

    def __init__(self, *, encoding=None, recover=None, **options):
        if options.get("target") is not None:
            _unsupported("解析器 target=")
        self.encoding = encoding
        self.recover = self._html if recover is None else recover
        self.options = options
        self._chunks = []

    def feed(self, data):
        self._chunks.append(data)

    def close(self):
        chunks, self._chunks = self._chunks, []
        if not chunks:
            raise XMLSyntaxError("no element found")
        joined = b"".join(chunks) if isinstance(chunks[0], bytes) else "".join(chunks)
        return fromstring(joined, self)

    @property
    def error_log(self):
        return ()

    def set_element_class_lookup(self, lookup=None):
        if lookup is not None:
            _unsupported("set_element_class_lookup()")


class XMLParser(_BaseParser):
    """XML parser options holder; parsing happens in the host."""


class ETCompatXMLParser(XMLParser):
    pass


class HTMLParser(_BaseParser):
    """HTML parser options holder; parsing happens in the host."""

    _html = True


def XMLPullParser(*args, **kwargs):
    _unsupported("etree.XMLPullParser")


def HTMLPullParser(*args, **kwargs):
    _unsupported("etree.HTMLPullParser")


_default_parser = None


def set_default_parser(parser=None):
    global _default_parser
    _default_parser = parser


def get_default_parser():
    return _default_parser or XMLParser()


_XML_DECL = re.compile(r"^\s*<\?xml\b[^>]*\?>")


def _markup(source, parser):
    """str of the markup; bytes are decoded (declared charset, then detection)."""
    if isinstance(source, (bytes, bytearray, memoryview)):
        source, _ = _text.decode_markup(source, parser.encoding if parser else None)
    elif not isinstance(source, str):
        raise ValueError("can only parse strings")
    return str(source).lstrip("﻿")


def _check_xml(markup):
    """Well-formedness check: the host's XML parser recovers silently, lxml's default parser does not."""
    try:
        from xml.parsers import expat
    except ImportError:
        return
    checker = expat.ParserCreate()
    try:
        checker.Parse(_XML_DECL.sub("", markup).encode("utf-8", "replace"), True)
    except expat.ExpatError as exc:
        error = XMLSyntaxError(str(exc))
        error.position = (exc.lineno, exc.offset)
        raise error from None


def _load_html(source, parser, cls, base=None):
    markup = _markup(source, parser)
    if not markup.strip():
        return None
    found = _XML_DECL.match(markup)
    if found:
        markup = markup[found.end():]
    return _Document(_dom.load_html(markup), False, base).root(cls)


def _load_xml(source, parser, base=None):
    markup = _markup(source, parser)
    if not markup.strip():
        raise XMLSyntaxError("Document is empty, line 1, column 1")
    if not (parser and parser.recover):
        _check_xml(markup)
    # The text is Unicode by now; a stale encoding in the declaration must not confuse the host.
    root = _Document(_dom.load_xml(_XML_DECL.sub("", markup, count=1)), True, base).root(_Element)
    if root is None:
        raise XMLSyntaxError("Start tag expected, '<' not found, line 1, column 1")
    return root


def HTML(text, parser=None, *, base_url=None):
    """Parse an HTML document (or fragment) and return its root element."""
    if parser is not None and not parser._html:
        return _load_xml(text, parser, base_url)
    root = _load_html(text, parser, _Element, base_url)
    if root is None:
        raise XMLSyntaxError("Document is empty, line 1, column 1")
    return root


def XML(text, parser=None, *, base_url=None):
    return fromstring(text, parser, base_url=base_url)


def fromstring(text, parser=None, *, base_url=None):
    parser = parser or _default_parser
    if parser is not None and parser._html:
        return _load_html(text, parser, _Element, base_url)
    return _load_xml(text, parser, base_url)


def fromstringlist(strings, parser=None):
    strings = list(strings)
    joiner = b"" if strings and isinstance(strings[0], bytes) else ""
    return fromstring(joiner.join(strings), parser)


def XMLID(text, parser=None, *, base_url=None):
    root = XML(text, parser, base_url=base_url)
    return root, {el.get("id"): el for el in root._nodes("descendant-or-self::*[@id]")}


def _read(source):
    if hasattr(source, "read"):
        return source.read(), getattr(source, "name", None)
    if hasattr(source, "__fspath__"):
        source = source.__fspath__()
    if isinstance(source, bytes):
        source = source.decode("utf-8")
    if re.match(r"https?://", source):
        import requests

        return requests.get(source).content, source
    try:
        with open(source, "rb") as handle:
            return handle.read(), source
    except OSError as exc:
        raise OSError("Error reading file '%s': failed to load external entity \"%s\"" % (source, source)) from exc


def parse(source, parser=None, *, base_url=None):
    """Parse a file, file-like object or URL into an _ElementTree."""
    data, name = _read(source)
    base = base_url or (name if isinstance(name, str) else None)
    parser = parser or _default_parser
    if parser is not None and parser._html:
        root = _load_html(data, parser, _Element, base)
        if root is None:
            raise XMLSyntaxError("Document is empty, line 1, column 1")
    else:
        root = _load_xml(data, parser, base)
    return _ElementTree(root._doc, root)


def iterparse(*args, **kwargs):
    _unsupported("etree.iterparse()")


# --- serialisation --------------------------------------------------------------------------------------------------


def _encode(text, encoding, declaration, method):
    if encoding is str or (isinstance(encoding, str) and encoding.lower() == "unicode"):
        return text
    name = encoding or "ASCII"
    if declaration is None:
        declaration = method == "xml" and name.upper() not in ("ASCII", "UTF-8", "UTF8", "US-ASCII")
    if declaration:
        text = "<?xml version='1.0' encoding='%s'?>\n%s" % (name, text)
    return text.encode(_text.canonical(name) or name, "xmlcharrefreplace")


def tostring(
    element_or_tree, *, encoding=None, method="xml", xml_declaration=None, pretty_print=False, with_tail=True,
    standalone=None, doctype=None, exclusive=False, inclusive_ns_prefixes=None, with_comments=True, strip_text=False
):
    """Serialise; bytes unless encoding is 'unicode' or str."""
    element = element_or_tree
    if isinstance(element, _ElementTree):
        element = element.getroot()
        with_tail = False
    if not isinstance(element, _Element):
        return _plain_tostring(element, encoding, method, xml_declaration, pretty_print, doctype)
    from _idj_markup import escape_text, to_xml

    if method == "text":
        text = _dom.string(element._id)
        if with_tail and element.tail:
            text += element.tail
        return _encode(text, encoding, False, method)
    if method not in ("xml", "html"):
        _unsupported("tostring(method=%r)" % method)
    if element.tag is Comment:
        text = "<!--%s-->" % element.text
    else:
        text = _dom.outer(element._id)
        if method == "xml" and not element._doc.xml:
            text = to_xml(text)
    if pretty_print:
        text = text.rstrip("\n") + "\n"
    if with_tail and element.tail:
        text += escape_text(element.tail)
    if doctype:
        text = "%s\n%s" % (doctype, text)
    return _encode(text, encoding, xml_declaration, method)


def _plain_tostring(element, encoding, method, declaration, pretty, doctype):
    if not _is_plain(element) and not hasattr(element, "getroot"):
        raise TypeError("Type '%s' cannot be serialized." % type(element).__name__)
    from xml.etree import ElementTree as plain

    root = element.getroot() if hasattr(element, "getroot") else element
    if pretty:
        import copy

        root = copy.deepcopy(root)
        plain.indent(root, "  ")
    text = re.sub(r" />", "/>", plain.tostring(root, encoding="unicode", method=method))
    if pretty:
        text += "\n"
    if doctype:
        text = "%s\n%s" % (doctype, text)
    return _encode(text, encoding, declaration, method)


def tounicode(element_or_tree, *, method="xml", pretty_print=False, with_tail=True, doctype=None):
    return tostring(
        element_or_tree, encoding=str, method=method, pretty_print=pretty_print, with_tail=with_tail, doctype=doctype
    )


def tostringlist(element_or_tree, *args, **kwargs):
    return [tostring(element_or_tree, *args, **kwargs)]


def dump(elem, *, pretty_print=True, with_tail=True):
    print(tostring(elem, encoding=str, pretty_print=pretty_print, with_tail=with_tail))


def indent(tree, space="  ", *, level=0):
    _unsupported("etree.indent()")


# --- bulk editing ---------------------------------------------------------------------------------------------------


def _root_of(tree_or_element):
    return tree_or_element.getroot() if hasattr(tree_or_element, "getroot") else tree_or_element


def strip_attributes(tree_or_element, *attribute_names):
    for element in _root_of(tree_or_element).iter():
        for key in element.keys():
            if key in attribute_names:
                element._set_attr(key, None)


def strip_elements(tree_or_element, *tag_names, with_tail=True):
    root = _root_of(tree_or_element)
    _dom.remove([e._id for e in root.iterdescendants(*tag_names)], tail=with_tail)


def strip_tags(tree_or_element, *tag_names):
    """Drop tags but keep their text. Only possible where the surrounding element holds nothing but such tags."""
    root = _root_of(tree_or_element)
    names = _flat_tags(tag_names)
    specials = [n for n in names if callable(n)]  # etree.Comment, etree.PI: nothing inside to keep
    if specials:
        _dom.remove([e._id for e in root.iterdescendants(*specials)])
        names = [n for n in names if not callable(n)]
        if not names:
            return
    parents = []
    for element in root.iterdescendants(*names):
        parent = element.getparent()
        if parent is not None and parent not in parents:
            parents.append(parent)
    for parent in parents:
        inner = list(parent.iterdescendants())
        if any(e.tag not in names for e in inner):
            _unsupported("strip_tags()：<%s> 内还有其他标签" % parent.tag)
    for parent in parents:
        if len(parent):
            _dom.set_text(parent._id, _dom.string(parent._id))


def cleanup_namespaces(tree_or_element, *args, **kwargs):
    return None


def XSLT(*args, **kwargs):
    _unsupported("etree.XSLT")


def XMLSchema(*args, **kwargs):
    _unsupported("etree.XMLSchema")


def RelaxNG(*args, **kwargs):
    _unsupported("etree.RelaxNG")


def DTD(*args, **kwargs):
    _unsupported("etree.DTD")


def Schematron(*args, **kwargs):
    _unsupported("etree.Schematron")


def FunctionNamespace(uri):
    _unsupported("etree.FunctionNamespace")
