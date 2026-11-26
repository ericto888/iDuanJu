"""bs4.element-compatible classes (original implementation for i短剧, GPL-3.0).

The tree is plain Python, so it stays valid after the spider call ends and every edit is possible.
"""

from __future__ import annotations

from html.entities import codepoint2name

import _idj_css as _css

__all__ = [
    "PageElement", "NavigableString", "PreformattedString", "Comment", "CData", "Declaration", "Doctype",
    "ProcessingInstruction", "XMLProcessingInstruction", "Script", "Stylesheet", "TemplateString", "RubyTextString",
    "RubyParenthesisString", "Tag", "ResultSet", "SoupStrainer", "CSS",
]

_VOID = frozenset(
    "area base basefont bgsound br col command embed frame hr image img input isindex keygen link menuitem meta "
    "nextid param source spacer track wbr".split()
)
_KEEP_SPACE = frozenset(("pre", "textarea"))
_UNSET = object()
_SPACE = " \n\t\f\r"


# --- output formatting ----------------------------------------------------------------------------------------------


def _minimal(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _html(text):
    out = []
    for ch in text:
        name = codepoint2name.get(ord(ch)) if ord(ch) > 127 or ch in "&<>" else None
        out.append("&%s;" % name if name else ch)
    return "".join(out)


def _formatter(value):
    if value is None:
        return lambda text: text
    if callable(value):
        return value
    if value in ("minimal",):
        return _minimal
    if value in ("html", "html5"):
        return _html
    raise ValueError("不支持的 formatter: %r" % (value,))


def _quoted(value):
    if '"' in value:
        if "'" in value:
            return '"%s"' % value.replace('"', "&quot;")
        return "'%s'" % value
    return '"%s"' % value


# --- base classes ---------------------------------------------------------------------------------------------------


class PageElement:
    """Navigation shared by tags and strings."""

    parent = None
    _decomposed = False

    # -- siblings ----------------------------------------------------------------------------------------------------
    def _at(self):
        if self.parent is None:
            return -1
        for i, child in enumerate(self.parent.contents):
            if child is self:
                return i
        return -1

    @property
    def next_sibling(self):
        at = self._at()
        if at < 0 or at + 1 >= len(self.parent.contents):
            return None
        return self.parent.contents[at + 1]

    @property
    def previous_sibling(self):
        at = self._at()
        return self.parent.contents[at - 1] if at > 0 else None

    @property
    def next_siblings(self):
        at = self._at()
        return iter(self.parent.contents[at + 1:] if at >= 0 else ())

    @property
    def previous_siblings(self):
        at = self._at()
        return iter(self.parent.contents[:at][::-1] if at > 0 else ())

    nextSibling = next_sibling
    previousSibling = previous_sibling

    # -- document order ----------------------------------------------------------------------------------------------
    @property
    def next_element(self):
        contents = getattr(self, "contents", None)
        if contents:
            return contents[0]
        node = self
        while node is not None:
            following = node.next_sibling
            if following is not None:
                return following
            node = node.parent
        return None

    @property
    def previous_element(self):
        before = self.previous_sibling
        if before is None:
            return self.parent
        while getattr(before, "contents", None):
            before = before.contents[-1]
        return before

    @property
    def next_elements(self):
        """Everything after this node in document order (its own descendants first)."""
        if isinstance(self, Tag):
            yield from self.descendants
        node = self
        while node is not None and node.parent is not None:
            for sibling in node.next_siblings:
                yield sibling
                if isinstance(sibling, Tag):
                    yield from sibling.descendants
            node = node.parent

    @property
    def previous_elements(self):
        node = self.previous_element
        while node is not None:
            yield node
            node = node.previous_element

    nextElement = next_element
    previousElement = previous_element

    @property
    def parents(self):
        node = self.parent
        while node is not None:
            yield node
            node = node.parent

    # -- searching around --------------------------------------------------------------------------------------------
    def find_next(self, name=None, attrs=None, string=None, **kwargs):
        return _first(self.next_elements, name, attrs, string, kwargs)

    def find_all_next(self, name=None, attrs=None, string=None, limit=None, **kwargs):
        return _collect(self.next_elements, name, attrs, string, limit, kwargs)

    def find_previous(self, name=None, attrs=None, string=None, **kwargs):
        return _first(self.previous_elements, name, attrs, string, kwargs)

    def find_all_previous(self, name=None, attrs=None, string=None, limit=None, **kwargs):
        return _collect(self.previous_elements, name, attrs, string, limit, kwargs)

    def find_next_sibling(self, name=None, attrs=None, string=None, **kwargs):
        return _first(self.next_siblings, name, attrs, string, kwargs)

    def find_next_siblings(self, name=None, attrs=None, string=None, limit=None, **kwargs):
        return _collect(self.next_siblings, name, attrs, string, limit, kwargs)

    def find_previous_sibling(self, name=None, attrs=None, string=None, **kwargs):
        return _first(self.previous_siblings, name, attrs, string, kwargs)

    def find_previous_siblings(self, name=None, attrs=None, string=None, limit=None, **kwargs):
        return _collect(self.previous_siblings, name, attrs, string, limit, kwargs)

    def find_parent(self, name=None, attrs=None, **kwargs):
        return _first(self.parents, name, attrs, None, kwargs)

    def find_parents(self, name=None, attrs=None, limit=None, **kwargs):
        return _collect(self.parents, name, attrs, None, limit, kwargs)

    findNext = find_next
    findAllNext = find_all_next
    findPrevious = find_previous
    findAllPrevious = find_all_previous
    findNextSibling = find_next_sibling
    findNextSiblings = fetchNextSiblings = find_next_siblings
    findPreviousSibling = find_previous_sibling
    findPreviousSiblings = fetchPreviousSiblings = find_previous_siblings
    findParent = find_parent
    findParents = fetchParents = find_parents

    # -- editing -----------------------------------------------------------------------------------------------------
    def extract(self):
        at = self._at()
        if at >= 0:
            del self.parent.contents[at]
        self.parent = None
        return self

    def replace_with(self, *args):
        if self.parent is None:
            raise ValueError(
                "Cannot replace one element with another when the element to be replaced is not part of a tree."
            )
        if len(args) == 1 and args[0] is self:
            return self
        parent, at = self.parent, self._at()
        self.extract()
        for offset, item in enumerate(args):
            parent.insert(at + offset, item)
        return self

    replaceWith = replace_with

    def unwrap(self):
        if self.parent is None:
            raise ValueError("Cannot replace an element with its contents when that element is not part of a tree.")
        parent, at = self.parent, self._at()
        self.extract()
        for child in list(getattr(self, "contents", ()))[::-1]:
            parent.insert(at, child)
        return self

    replace_with_children = replaceWithChildren = unwrap

    def wrap(self, wrap_inside):
        at_parent = self.replace_with(wrap_inside)
        wrap_inside.append(at_parent)
        return wrap_inside

    def insert_before(self, *args):
        if self.parent is None:
            raise ValueError("Element has no parent, so 'before' has no meaning.")
        for item in args:
            if isinstance(item, PageElement):
                item.extract()
            self.parent.insert(self._at(), item)

    def insert_after(self, *args):
        if self.parent is None:
            raise ValueError("Element has no parent, so 'after' has no meaning.")
        for item in args[::-1]:
            if isinstance(item, PageElement):
                item.extract()
            self.parent.insert(self._at() + 1, item)

    # -- text --------------------------------------------------------------------------------------------------------
    def get_text(self, separator="", strip=False, types=_UNSET):
        return separator.join(self._all_strings(strip, types))

    getText = get_text

    @property
    def text(self):
        return self.get_text()

    @property
    def stripped_strings(self):
        return self._all_strings(True)

    @property
    def decomposed(self):
        return self._decomposed


# --- strings --------------------------------------------------------------------------------------------------------


class NavigableString(str, PageElement):
    """A piece of text in the tree."""

    PREFIX = ""
    SUFFIX = ""
    known_xml = None
    name = None
    hidden = False

    def __new__(cls, value=""):
        if isinstance(value, bytes):
            value = value.decode("utf-8")
        return str.__new__(cls, value)

    def __copy__(self):
        return type(self)(self)

    def __deepcopy__(self, memo):
        return type(self)(self)

    def __getnewargs__(self):
        return (str(self),)

    @property
    def string(self):
        return self

    @string.setter
    def string(self, value):
        self.replace_with(type(self)(value))

    @property
    def strings(self):
        return self._all_strings()

    def _all_strings(self, strip=False, types=_UNSET):
        if types is _UNSET:
            types = _PLAIN  # comments, scripts… are not "text"
        if types is not None:
            wanted = (types,) if isinstance(types, type) else tuple(types)
            if type(self) not in wanted:
                return
        text = str(self)
        if strip:
            text = text.strip()
            if not text:
                return
        yield text if strip else self

    def output_ready(self, formatter="minimal"):
        return self.PREFIX + _formatter(formatter)(str(self)) + self.SUFFIX

    def __getattr__(self, name):
        raise AttributeError("'%s' object has no attribute '%s'" % (type(self).__name__, name))


class PreformattedString(NavigableString):
    """Text that is written out verbatim."""

    def output_ready(self, formatter=None):
        return self.PREFIX + str(self) + self.SUFFIX


class CData(PreformattedString):
    PREFIX, SUFFIX = "<![CDATA[", "]]>"


class ProcessingInstruction(PreformattedString):
    PREFIX, SUFFIX = "<?", ">"


class XMLProcessingInstruction(ProcessingInstruction):
    PREFIX, SUFFIX = "<?", "?>"


class Comment(PreformattedString):
    PREFIX, SUFFIX = "<!--", "-->"


class Declaration(PreformattedString):
    PREFIX, SUFFIX = "<?", "?>"


class Doctype(PreformattedString):
    PREFIX, SUFFIX = "<!DOCTYPE ", ">\n"


class Stylesheet(NavigableString):
    pass


class Script(NavigableString):
    pass


class TemplateString(NavigableString):
    pass


class RubyTextString(NavigableString):
    pass


class RubyParenthesisString(NavigableString):
    pass


_CONTAINERS = {
    "style": Stylesheet, "script": Script, "template": TemplateString, "rt": RubyTextString,
    "rp": RubyParenthesisString,
}
_PLAIN = (NavigableString, CData)


# --- search criteria ------------------------------------------------------------------------------------------------


def _as_text(value):
    return value.decode("utf-8") if isinstance(value, bytes) else value


def _matches_value(value, wanted):
    """One candidate string (or None) against a criterion: str, regex, True/False/None, callable or a list of them."""
    if wanted is True:
        return value is not None
    if wanted is None or wanted is False:
        return value is None
    if isinstance(wanted, (str, bytes)):
        return value is not None and value == _as_text(wanted)
    if hasattr(wanted, "search"):
        return value is not None and wanted.search(value) is not None
    if callable(wanted):
        return bool(wanted(value))
    if isinstance(wanted, (int, float)):
        return value is not None and value == str(wanted)
    try:
        options = list(wanted)
    except TypeError:
        return value is not None and value == str(wanted)
    return any(_matches_value(value, option) for option in options)


def _matches_attribute(value, wanted):
    if not isinstance(value, (list, tuple)):
        return _matches_value(value, wanted)
    # Multi-valued attribute (class): any single value, or the whole text.
    if wanted is None or wanted is False:
        return False
    return any(_matches_value(item, wanted) for item in value) or _matches_value(" ".join(value), wanted)


def _matches_name(tag, wanted):
    if wanted is True:
        return True
    if isinstance(wanted, (str, bytes)):
        wanted = _as_text(wanted)
        return tag.name == wanted or (tag.prefix is not None and "%s:%s" % (tag.prefix, tag.name) == wanted)
    if hasattr(wanted, "search"):
        return wanted.search(tag.name) is not None
    if callable(wanted):
        return bool(wanted(tag))
    if wanted is None or wanted is False:
        return False
    return any(_matches_name(tag, option) for option in wanted)


class SoupStrainer:
    """Search criteria in object form."""

    def __init__(self, name=None, attrs=None, string=None, **kwargs):
        if string is None and "text" in kwargs:
            string = kwargs.pop("text")
        self.name = name
        self.string = string
        self.attrs = _criteria(attrs, kwargs)

    @property
    def text(self):
        return self.string

    def matches(self, element):
        if isinstance(element, Tag):
            if self.string is not None and self.name is None and not self.attrs:
                return False
            return _tag_test(self.name, self.attrs, self.string)(element)
        if self.name is not None or self.attrs:
            return False
        return isinstance(element, NavigableString) and _matches_value(element, self.string)


def _criteria(attrs, kwargs):
    if attrs is None:
        merged = {}
    elif isinstance(attrs, dict):
        merged = dict(attrs)
    else:
        merged = {"class": attrs}  # find_all('div', 'x') searches by CSS class
    for key, value in kwargs.items():
        merged["class" if key == "class_" else key] = value
    return merged


def _tag_test(name, attrs, string):
    """Compile the criteria into a predicate over tags."""
    tests = []
    if name is not None and name is not True:
        if isinstance(name, str):
            def by_name(tag, want=name):
                return tag.name == want or (tag.prefix is not None and "%s:%s" % (tag.prefix, tag.name) == want)

            tests.append(by_name)
        else:
            tests.append(lambda tag: _matches_name(tag, name))
    for key, wanted in attrs.items():
        tests.append(lambda tag, k=key, w=wanted: _matches_attribute(tag.attrs.get(k), w))
    if string is not None:
        tests.append(lambda tag: _matches_value(tag.string, string) if tag.string is not None else False)
    if len(tests) == 1:
        return tests[0]
    return lambda tag: all(test(tag) for test in tests)


def _matcher(name, attrs, string, kwargs):
    """Predicate over any node."""
    kwargs = dict(kwargs)
    if string is None and "text" in kwargs:
        string = kwargs.pop("text")
    if isinstance(name, SoupStrainer):
        return name.matches
    criteria = _criteria(attrs, kwargs)
    if name is None and not criteria and string is not None:
        return lambda node: isinstance(node, NavigableString) and _matches_value(node, string)
    test = _tag_test(name, criteria, string)
    return lambda node: isinstance(node, Tag) and test(node)


def _first(nodes, name, attrs, string, kwargs):
    match = _matcher(name, attrs, string, kwargs)
    for node in nodes:
        if match(node):
            return node
    return None


def _collect(nodes, name, attrs, string, limit, kwargs):
    match = _matcher(name, attrs, string, kwargs)
    out = ResultSet(None)
    for node in nodes:
        if match(node):
            out.append(node)
            if limit and len(out) >= limit:
                break
    return out


class ResultSet(list):
    """List of search results."""

    def __init__(self, source, result=()):
        super().__init__(result)
        self.source = source

    def __getattr__(self, key):
        raise AttributeError(
            "ResultSet object has no attribute %r. You're probably treating a list of elements like a single element. "
            "Did you call find_all() when you meant to call find()?" % key
        )


# --- CSS ------------------------------------------------------------------------------------------------------------


class _Adapter:
    """Lets `_idj_css` walk the tree."""

    __slots__ = ("xml",)

    def __init__(self, xml):
        self.xml = xml

    @staticmethod
    def tag(node):
        return node.name

    @staticmethod
    def attr(node, name):
        value = node.attrs.get(name)
        if isinstance(value, (list, tuple)):
            return " ".join(value)
        return value if value is None or isinstance(value, str) else str(value)

    @staticmethod
    def parent(node):
        up = node.parent
        return None if isinstance(up, BaseSoup) else up

    @staticmethod
    def container(node):
        return node.parent

    @staticmethod
    def children(node):
        return [c for c in node.contents if isinstance(c, Tag)]

    @staticmethod
    def descendants(node):
        return (d for d in node.descendants if isinstance(d, Tag))

    @staticmethod
    def text(node):
        return node.get_text()

    @staticmethod
    def own_text(node):
        return "".join(c for c in node.contents if type(c) in _PLAIN)

    @staticmethod
    def empty(node):
        return not any(isinstance(c, Tag) or (type(c) in _PLAIN and c.strip()) for c in node.contents)

    @staticmethod
    def key(node):
        return id(node)


class CSS:
    """`tag.css`: CSS queries in their own namespace."""

    def __init__(self, tag):
        self.tag = tag

    def select(self, select, namespaces=None, limit=0, flags=0, **kwargs):
        return self.tag.select(select, namespaces, limit)

    def iselect(self, select, namespaces=None, limit=0, flags=0, **kwargs):
        return iter(self.tag.select(select, namespaces, limit))

    def select_one(self, select, namespaces=None, flags=0, **kwargs):
        return self.tag.select_one(select, namespaces)

    def match(self, select, namespaces=None, flags=0, **kwargs):
        return _css.matches(self.tag._adapter(), self.tag, select)

    def filter(self, select, namespaces=None, flags=0, **kwargs):
        kids = [c for c in self.tag.contents if isinstance(c, Tag)]
        return ResultSet(None, _css.filter_nodes(self.tag._adapter(), kids, select))

    def closest(self, select, namespaces=None, flags=0, **kwargs):
        node = self.tag
        while node is not None and not isinstance(node, BaseSoup):
            if _css.matches(self.tag._adapter(), node, select):
                return node
            node = node.parent
        return None


# --- tags -----------------------------------------------------------------------------------------------------------


class Tag(PageElement):
    """An element."""

    def __init__(self, parser=None, builder=None, name=None, namespace=None, prefix=None, attrs=None, parent=None,
                 previous=None, is_xml=None, sourceline=None, sourcepos=None, can_be_empty_element=None, **_):
        if name is None:
            raise ValueError("Cannot create Tag with no name")
        self.name = name if prefix is None else "%s:%s" % (prefix, name)
        self.prefix = prefix
        self.namespace = namespace
        self.attrs = {} if attrs is None else dict(attrs)
        self.contents = []
        self.parent = parent
        self.hidden = False
        self.known_xml = bool(is_xml)
        self.sourceline, self.sourcepos = sourceline, sourcepos
        if can_be_empty_element is None:
            can_be_empty_element = True if is_xml else name.lower() in _VOID
        self.can_be_empty_element = can_be_empty_element

    # -- names and attributes ----------------------------------------------------------------------------------------
    @property
    def is_empty_element(self):
        return not self.contents and self.can_be_empty_element

    isSelfClosing = is_empty_element

    def get(self, key, default=None):
        return self.attrs.get(key, default)

    def get_attribute_list(self, key, default=None):
        value = self.get(key, default)
        return value if isinstance(value, list) else [value]

    def has_attr(self, key):
        return key in self.attrs

    has_key = has_attr

    def __getitem__(self, key):
        return self.attrs[key]

    def __setitem__(self, key, value):
        self.attrs[key] = value

    def __delitem__(self, key):
        self.attrs.pop(key, None)

    def __iter__(self):
        return iter(self.contents)

    def __len__(self):
        return len(self.contents)

    def __contains__(self, item):
        return item in self.contents

    def __bool__(self):
        return True

    def __hash__(self):
        return hash(str(self))

    def __eq__(self, other):
        if self is other:
            return True
        if not isinstance(other, Tag):
            return NotImplemented
        if self.name != other.name or self.attrs != other.attrs or len(self) != len(other):
            return False
        return all(mine == theirs for mine, theirs in zip(self.contents, other.contents))

    def __ne__(self, other):
        return not self == other

    def __call__(self, *args, **kwargs):
        return self.find_all(*args, **kwargs)

    def __getattr__(self, name):
        if name.startswith("__") or name in ("contents", "attrs"):
            raise AttributeError("'%s' object has no attribute '%s'" % (type(self).__name__, name))
        if name.endswith("Tag") and len(name) > 3:
            return self.find(name[:-3])
        return self.find(name)

    # -- content -----------------------------------------------------------------------------------------------------
    @property
    def children(self):
        return iter(self.contents)

    @property
    def descendants(self):
        """All nodes below this one in document order."""
        stack = [iter(list(self.contents))]
        while stack:
            for node in stack[-1]:
                yield node
                if isinstance(node, Tag) and node.contents:
                    stack.append(iter(list(node.contents)))
                    break
            else:
                stack.pop()

    @property
    def self_and_descendants(self):
        yield self
        yield from self.descendants

    @property
    def string(self):
        node = self
        while isinstance(node, Tag):
            if len(node.contents) != 1:
                return None
            node = node.contents[0]
        return node

    @string.setter
    def string(self, value):
        self.clear()
        self.append(value if isinstance(value, NavigableString) else self._text_class()(value))

    def _text_class(self):
        return _CONTAINERS.get(self.name, NavigableString)

    def _wanted_types(self):
        special = None if self.known_xml else _CONTAINERS.get(self.name)
        return (special,) if special else _PLAIN

    def _all_strings(self, strip=False, types=_UNSET):
        if types is _UNSET:
            types = self._wanted_types()
        elif types is not None and isinstance(types, type):
            types = (types,)
        for node in self.descendants:
            if not isinstance(node, NavigableString):
                continue
            if types is not None and type(node) not in types:
                continue
            if strip:
                text = node.strip()
                if text:
                    yield text
            else:
                yield node

    @property
    def strings(self):
        return self._all_strings()

    def index(self, element):
        for i, child in enumerate(self.contents):
            if child is element:
                return i
        raise ValueError("Tag.index: element not in tag")

    # -- searching ---------------------------------------------------------------------------------------------------
    def find(self, name=None, attrs=None, recursive=True, string=None, **kwargs):
        return _first(self.descendants if recursive else self.children, name, attrs, string, kwargs)

    def find_all(self, name=None, attrs=None, recursive=True, string=None, limit=None, **kwargs):
        if not recursive:
            return _collect(self.children, name, attrs, string, limit, kwargs)
        return _collect(self.descendants, name, attrs, string, limit, kwargs)

    findAll = find_all
    findChild = find
    findChildren = find_all

    def _adapter(self):
        root = self
        while root.parent is not None:
            root = root.parent
        return _Adapter(root.known_xml)

    def select(self, selector, namespaces=None, limit=None, **kwargs):
        found = _css.select(self._adapter(), [self], selector, limit=limit or None)
        return ResultSet(None, found)

    def select_one(self, selector, namespaces=None, **kwargs):
        found = _css.select(self._adapter(), [self], selector, limit=1)
        return found[0] if found else None

    @property
    def css(self):
        return CSS(self)

    # -- editing -----------------------------------------------------------------------------------------------------
    def insert(self, position, *new_children):
        for offset, child in enumerate(new_children):
            if child is self:
                raise ValueError("Cannot insert a tag into itself.")
            if isinstance(child, BaseSoup):
                self.insert(position + offset, *list(child.contents))
                continue
            if not isinstance(child, PageElement):
                child = NavigableString(child)
            if child.parent is not None:
                if child.parent is self:
                    current = child._at()
                    if current < position:
                        position -= 1
                child.extract()
            at = min(position + offset, len(self.contents))
            self.contents.insert(at, child)
            child.parent = self
        return list(new_children)

    def append(self, tag):
        self.insert(len(self.contents), tag)
        return tag

    def extend(self, tags):
        for item in list(tags.contents if isinstance(tags, Tag) else tags):
            self.append(item)

    def clear(self, decompose=False):
        for child in list(self.contents):
            if decompose and isinstance(child, Tag):
                child.decompose()
            else:
                child.extract()

    def decompose(self):
        self.extract()
        nodes = [self]
        nodes.extend(self.descendants)
        for node in nodes:
            node.parent = None
            node._decomposed = True
            if isinstance(node, Tag):
                node.contents = []
                node.attrs = {}

    def smooth(self):
        """Merge adjacent strings."""
        out = []
        for child in self.contents:
            if isinstance(child, Tag):
                child.smooth()
            elif out and type(child) is NavigableString and type(out[-1]) is NavigableString:
                merged = NavigableString(out[-1] + child)
                merged.parent = self
                out[-1] = merged
                continue
            out.append(child)
        self.contents = out

    # -- output ------------------------------------------------------------------------------------------------------
    def __copy__(self):
        return self.__deepcopy__(None)

    def __deepcopy__(self, memo):
        clone = self._shallow()
        stack = [(self, clone)]
        while stack:
            source, target = stack.pop()
            for child in source.contents:
                if isinstance(child, Tag):
                    twin = child._shallow()
                    stack.append((child, twin))
                else:
                    twin = type(child)(child)
                twin.parent = target
                target.contents.append(twin)
        return clone

    def _shallow(self):
        clone = Tag(
            name=self.name, attrs={k: list(v) if isinstance(v, list) else v for k, v in self.attrs.items()},
            is_xml=self.known_xml, can_be_empty_element=self.can_be_empty_element,
        )
        clone.prefix, clone.namespace, clone.hidden = self.prefix, self.namespace, self.hidden
        return clone

    def _open(self, escape, closed):
        parts = [self.name]
        for key, value in self.attrs.items():
            if value is None:
                parts.append(key)
                continue
            if isinstance(value, (list, tuple)):
                value = " ".join(value)
            elif not isinstance(value, str):
                value = str(value)
            parts.append("%s=%s" % (key, _quoted(escape(value))))
        return "<%s%s>" % (" ".join(parts), "/" if closed else "")

    def _pieces(self, escape, with_self=True):
        """Serialised pieces; iterative so that badly nested pages cannot exhaust the stack."""
        out = []
        stack = [(self, False)] if with_self else [(c, False) for c in self.contents[::-1]]
        while stack:
            node, ending = stack.pop()
            if not isinstance(node, Tag):
                if isinstance(node, PreformattedString):
                    out.append(node.PREFIX + str(node) + node.SUFFIX)
                elif isinstance(node, (Script, Stylesheet)):
                    out.append(str(node))
                elif node.parent is not None and node.parent.name in ("script", "style") and not node.parent.known_xml:
                    out.append(str(node))
                else:
                    out.append(escape(str(node)))
                continue
            if ending:
                out.append("</%s>" % node.name)
                continue
            if not node.hidden:
                closed = node.is_empty_element
                out.append(node._open(escape, closed))
                if closed:
                    continue
                stack.append((node, True))
            stack.extend((c, False) for c in node.contents[::-1])
        return out

    def decode(self, indent_level=None, eventual_encoding="utf-8", formatter="minimal", iterator=None):
        escape = _formatter(formatter)
        if indent_level is not None and indent_level is not False:
            return self._pretty(escape, int(indent_level))
        return "".join(self._pieces(escape))

    def decode_contents(self, indent_level=None, eventual_encoding="utf-8", formatter="minimal"):
        escape = _formatter(formatter)
        if indent_level is not None and indent_level is not False:
            return self._pretty(escape, int(indent_level), with_self=False)
        return "".join(self._pieces(escape, with_self=False))

    def encode(self, encoding="utf-8", indent_level=None, formatter="minimal", errors="xmlcharrefreplace"):
        return self.decode(indent_level, encoding, formatter).encode(encoding, errors)

    def encode_contents(self, indent_level=None, encoding="utf-8", formatter="minimal"):
        return self.decode_contents(indent_level, encoding, formatter).encode(encoding, "xmlcharrefreplace")

    def renderContents(self, encoding="utf-8", prettyPrint=False, indentLevel=0):
        return self.encode_contents(indentLevel if prettyPrint else None, encoding)

    def prettify(self, encoding=None, formatter="minimal"):
        text = self._pretty(_formatter(formatter), 0)
        return text if encoding is None else text.encode(encoding, "xmlcharrefreplace")

    def _pretty(self, escape, level, with_self=True):
        lines = []
        stack = [(self, level, False)] if with_self else [(c, level, False) for c in self.contents[::-1]]
        while stack:
            node, depth, ending = stack.pop()
            pad = " " * max(depth, 0)
            if not isinstance(node, Tag):
                text = "".join(_string_pieces(node, escape)).strip()
                if text:
                    lines.append(pad + text)
                continue
            if ending:
                lines.append("%s</%s>" % (pad, node.name))
                continue
            if node.hidden:
                stack.extend((c, depth, False) for c in node.contents[::-1])
                continue
            closed = node.is_empty_element
            if closed:
                lines.append(pad + node._open(escape, True))
                continue
            if node.name in _KEEP_SPACE and not node.known_xml:
                lines.append(pad + "".join(node._pieces(escape)))
                continue
            lines.append(pad + node._open(escape, False))
            stack.append((node, depth, True))
            stack.extend((c, depth + 1, False) for c in node.contents[::-1])
        return "".join(line + "\n" for line in lines)

    def __str__(self):
        return self.decode()

    __unicode__ = __repr__ = __str__


def _string_pieces(node, escape):
    if isinstance(node, PreformattedString):
        yield node.PREFIX + str(node) + node.SUFFIX
    elif isinstance(node, (Script, Stylesheet)):
        yield str(node)
    else:
        yield escape(str(node))


class BaseSoup(Tag):
    """Marker base of BeautifulSoup (insertions of a whole document insert its contents)."""
