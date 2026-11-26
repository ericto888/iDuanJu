"""CSS selector engine working on any tree through a small adapter (original code, GPL-3.0).

bs4 uses it for `select`; pyquery and lxml use it to test single elements (the host's `html.select` does the searching
there). Supports CSS3 selectors, :is/:not/:has, `!=`, and the jQuery extras :contains :eq :gt :lt :first :last :even
:odd (positional filters apply to the whole matched set, as in jQuery).

Adapter protocol (elements only):
    tag(n) -> str, attr(n, name) -> str or None, parent(n) -> n or None, children(n) -> [n],
    container(n) -> object whose children() are the siblings of n (the parent, or the document for a root), or None,
    descendants(n) -> iterable in document order, text(n) -> str, own_text(n) -> str, empty(n) -> bool,
    key(n) -> hashable identity, xml: bool (case-sensitive names)
"""

from __future__ import annotations

import re
from functools import lru_cache

__all__ = ["SelectorSyntaxError", "parse", "select", "matches", "filter_nodes", "is_positional"]


class SelectorSyntaxError(ValueError):
    pass


_POSITIONAL = frozenset(("eq", "gt", "lt", "first", "last", "even", "odd", "nth"))
_IDENT = re.compile(r"(?:\\[0-9a-fA-F]{1,6}[ \t\n]?|\\.|[\w\-]|[^\x00-\x7f])+")
_ESCAPE = re.compile(r"\\(?:([0-9a-fA-F]{1,6})[ \t\n]?|(.))", re.S)
_NTH = re.compile(r"^\s*(?:(?P<word>odd|even)|(?P<a>[+-]?\d*)n\s*(?P<b>[+-]\s*\d+)?|(?P<only>[+-]?\d+))\s*$", re.I)
_ATTR = re.compile(
    r"""\[\s*(?P<name>(?:\\.|[^\s\]=~|^$*!"'\\])+(?:\|(?!=)(?:\\.|[^\s\]=~|^$*!"'\\])+)?)\s*"""
    r"""(?:(?P<op>[~|^$*!]?=)\s*(?:"(?P<dq>(?:\\.|[^"\\])*)"|'(?P<sq>(?:\\.|[^'\\])*)'|(?P<raw>[^\]\s"']+))"""
    r"""\s*(?P<flag>[iIsS])?\s*)?\]""",
    re.S,
)
_LOOSE_ATTR = re.compile(r"""\[\s*(?P<name>[^\s\]=~|^$*!"'\\]+)\s*(?P<op>[~|^$*!]?=)\s*(?P<raw>[^\]"']*)\]""")


def _unescape(text):
    if "\\" not in text:
        return text

    def sub(found):
        if found.group(1):
            code = int(found.group(1), 16)
            return chr(code) if 0 < code <= 0x10FFFF else "�"
        return found.group(2)

    return _ESCAPE.sub(sub, text)


class _Compound:
    """One compound selector: type, id, classes, attributes and pseudo-classes, in source order."""

    __slots__ = ("tag", "tests", "positional")

    def __init__(self):
        self.tag = None
        self.tests = []
        self.positional = False


class _Complex:
    """Compounds joined by combinators; `lead` is the leading combinator of a relative selector (:has)."""

    __slots__ = ("parts", "lead", "positional")

    def __init__(self, parts, lead):
        self.parts = parts  # [(combinator before it or None, _Compound)]
        self.lead = lead
        self.positional = any(c.positional for _, c in parts)


class _Parser:
    def __init__(self, text):
        self.text = text
        self.pos = 0

    def fail(self, why):
        raise SelectorSyntaxError("无效的 CSS 选择器 %r（位置 %d）：%s" % (self.text, self.pos, why))

    def peek(self):
        return self.text[self.pos:self.pos + 1]

    def space(self):
        start = self.pos
        while self.peek() and self.peek() in " \t\r\n\f":
            self.pos += 1
        return self.pos > start

    def ident(self):
        found = _IDENT.match(self.text, self.pos)
        if not found:
            self.fail("缺少名称")
        self.pos = found.end()
        return _unescape(found.group())

    def selector_list(self, relative=False):
        out = []
        while True:
            self.space()
            out.append(self.complex(relative))
            self.space()
            if self.peek() != ",":
                break
            self.pos += 1
        if self.pos != len(self.text):
            self.fail("多余的内容")
        return tuple(out)

    def complex(self, relative):
        lead = None
        if self.peek() and self.peek() in ">+~":
            if not relative:
                self.fail("选择器不能以组合符开头")
            lead = self.peek()
            self.pos += 1
            self.space()
        parts = [(None, self.compound())]
        while True:
            gap = self.space()
            ch = self.peek()
            if not ch or ch == ",":
                break
            if ch in ">+~":
                self.pos += 1
                self.space()
                parts.append((ch, self.compound()))
            elif gap:
                parts.append((" ", self.compound()))
            else:
                self.fail("意外的字符")
        return _Complex(parts, lead)

    def compound(self):
        out = _Compound()
        start = self.pos
        ch = self.peek()
        if ch == "*" or ch == "|" or (ch and _IDENT.match(self.text, self.pos)):
            name = None
            if ch == "*":
                self.pos += 1
            elif ch != "|":
                name = self.ident()
            if self.peek() == "|" and self.text[self.pos + 1:self.pos + 2] != "=":
                self.pos += 1
                if self.peek() == "*":
                    self.pos += 1
                    name = None
                else:
                    local = self.ident()
                    name = local if ch in "*|" else "%s:%s" % (name, local)
            out.tag = name
        while True:
            ch = self.peek()
            if ch == "#":
                self.pos += 1
                out.tests.append(("id", self.ident()))
            elif ch == ".":
                self.pos += 1
                out.tests.append(("class", self.ident()))
            elif ch == "[":
                out.tests.append(self.attribute())
            elif ch == ":":
                test = self.pseudo()
                out.tests.append(test)
                if test[0] == "pos":
                    out.positional = True
            else:
                break
        if self.pos == start:
            self.fail("缺少选择器")
        return out

    def attribute(self):
        found = _ATTR.match(self.text, self.pos)
        loose = None if found else _LOOSE_ATTR.match(self.text, self.pos)
        if not found and not loose:
            self.fail("属性选择器不完整")
        hit = found or loose
        self.pos = hit.end()
        name = _unescape(hit.group("name")).replace("|", ":")
        if name.startswith(("*:", ":")):
            name = name.partition(":")[2]
        op = hit.group("op")
        if not op:
            return ("attr", name, None, None, False)
        if loose:
            return ("attr", name, op, _unescape(loose.group("raw").strip()), False)
        value = found.group("dq")
        if value is None:
            value = found.group("sq")
        if value is None:
            value = found.group("raw")
        return ("attr", name, op, _unescape(value), (found.group("flag") or "").lower() == "i")

    def argument(self):
        """Raw text of a balanced (...) argument, quotes respected."""
        depth, start, quote = 0, self.pos + 1, None
        while self.pos < len(self.text):
            ch = self.text[self.pos]
            if ch == "\\":
                self.pos += 1
            elif quote:
                if ch == quote:
                    quote = None
            elif ch in "\"'":
                # An apostrophe inside bare text, as in :contains(it's), is not a quote.
                if self.text.find(ch, self.pos + 1) >= 0:
                    quote = ch
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    raw = self.text[start:self.pos]
                    self.pos += 1
                    return raw
            self.pos += 1
        self.fail("括号不匹配")

    def pseudo(self):
        self.pos += 1
        if self.peek() == ":":
            self.fail("不支持伪元素")
        name = self.ident().lower()
        arg = self.argument() if self.peek() == "(" else None
        if name in _POSITIONAL:
            if name in ("eq", "gt", "lt", "nth"):
                try:
                    return ("pos", name, int((arg or "").strip()))
                except ValueError:
                    self.fail(":%s 需要整数参数" % name)
            return ("pos", name, 0)
        if name in ("nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type"):
            return ("nth", name, _parse_nth(arg, self))
        if name in ("not", "is", "where", "matches", "any"):
            return ("not" if name == "not" else "is", _Parser((arg or "").strip()).selector_list())
        if name == "has":
            return ("has", _Parser((arg or "").strip()).selector_list(relative=True))
        if name in ("contains", "-soup-contains", "-soup-contains-own", "containsown"):
            kind = "own" if name.endswith("own") else "text"
            return ("contains", kind, _strings(arg or ""))
        if arg is None and name in _SIMPLE:
            return ("simple", name)
        self.fail("不支持的伪类 :%s" % name)


def _strings(arg):
    """Argument of :contains(): quoted strings separated by commas, or bare text."""
    arg = arg.strip()
    if arg[:1] in ("'", '"'):
        found = re.findall(r"""\s*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)')\s*(?:,|$)""", arg)
        if found:
            return tuple(_unescape(a or b) for a, b in found)
    return (_unescape(arg),)


def _parse_nth(arg, parser):
    found = _NTH.match(arg or "")
    if not found:
        parser.fail("nth 参数无效")
    if found.group("word"):
        return (2, 1) if found.group("word").lower() == "odd" else (2, 0)
    if found.group("only"):
        return (0, int(found.group("only")))
    step = found.group("a")
    step = int(step) if step not in ("", "+", "-") else int(step + "1")
    return (step, int(re.sub(r"\s", "", found.group("b") or "0")))


_FORM = frozenset(("input", "button", "select", "textarea", "option", "optgroup", "fieldset"))
_SIMPLE = frozenset((
    "first-child", "last-child", "only-child", "first-of-type", "last-of-type", "only-of-type", "empty", "root",
    "parent", "checked", "selected", "disabled", "enabled", "link", "any-link", "header", "input", "button", "text",
    "checkbox", "radio", "image", "password", "submit", "hidden", "file", "reset", "scope",
))


@lru_cache(maxsize=512)
def parse(selector):
    """Compile a selector list; raises SelectorSyntaxError."""
    text = selector.strip()
    if not text:
        raise SelectorSyntaxError("CSS 选择器为空")
    return _Parser(text).selector_list()


def is_positional(selector):
    return any(c.positional for c in parse(selector))


class _Run:
    """One evaluation: the adapter plus sibling caches that make :nth-* linear."""

    __slots__ = ("ad", "xml", "cache", "scope")

    def __init__(self, adapter, scope=None):
        self.ad = adapter
        self.xml = adapter.xml
        self.cache = {}
        self.scope = scope

    # -- structure ---------------------------------------------------------------------------------------------
    def siblings(self, node):
        """(element siblings including node, index of node)"""
        ad = self.ad
        parent = ad.container(node)
        if parent is None:
            return [node], 0
        key = ad.key(parent)
        entry = self.cache.get(key)
        if entry is None:
            kids = list(ad.children(parent))
            entry = self.cache[key] = (kids, {ad.key(k): i for i, k in enumerate(kids)})
        kids, index = entry
        at = index.get(ad.key(node))
        if at is None:
            return [node], 0
        return kids, at

    # -- matching ----------------------------------------------------------------------------------------------
    def same_tag(self, node, name):
        tag = self.ad.tag(node)
        if self.xml:
            return tag == name
        return tag.lower() == name.lower()

    def compound(self, node, compound):
        """Everything except positional filters."""
        if compound.tag is not None and not self.same_tag(node, compound.tag):
            return False
        for test in compound.tests:
            if test[0] != "pos" and not self.test(node, test):
                return False
        return True

    def test(self, node, test):
        kind, ad = test[0], self.ad
        if kind == "class":
            value = ad.attr(node, "class")
            return value is not None and test[1] in value.split()
        if kind == "id":
            return ad.attr(node, "id") == test[1]
        if kind == "attr":
            return self.attribute(node, test)
        if kind == "nth":
            return self.nth(node, test[1], test[2])
        if kind == "not":
            return not any(self.complex(node, c) for c in test[1])
        if kind == "is":
            return any(self.complex(node, c) for c in test[1])
        if kind == "has":
            return any(self.has(node, c) for c in test[1])
        if kind == "contains":
            text = ad.own_text(node) if test[1] == "own" else ad.text(node)
            return any(value in text for value in test[2])
        return self.simple(node, test[1])

    def attribute(self, node, test):
        _, name, op, want, fold = test
        value = self.ad.attr(node, name)
        if op is None:
            return value is not None
        if op == "!=":
            return value is None or (value.lower() != want.lower() if fold else value != want)
        if value is None:
            return False
        if fold:
            value, want = value.lower(), want.lower()
        if op == "=":
            return value == want
        if op == "~=":
            return bool(want) and want in value.split()
        if op == "|=":
            return value == want or value.startswith(want + "-")
        if not want:
            return False
        if op == "^=":
            return value.startswith(want)
        if op == "$=":
            return value.endswith(want)
        return want in value

    def nth(self, node, name, formula):
        kids, at = self.siblings(node)
        if name.endswith("of-type"):
            tag = self.ad.tag(node)
            kids = [k for k in kids if self.ad.tag(k) == tag]
            key = self.ad.key(node)
            at = next(i for i, k in enumerate(kids) if self.ad.key(k) == key)
        place = len(kids) - at if "last" in name else at + 1
        step, offset = formula
        if step == 0:
            return place == offset
        return (place - offset) % step == 0 and (place - offset) // step >= 0

    def simple(self, node, name):
        ad = self.ad
        if name == "first-child":
            return self.siblings(node)[1] == 0
        if name == "last-child":
            kids, at = self.siblings(node)
            return at == len(kids) - 1
        if name == "only-child":
            return len(self.siblings(node)[0]) == 1
        if name == "first-of-type":
            return self.nth(node, "nth-of-type", (0, 1))
        if name == "last-of-type":
            return self.nth(node, "nth-last-of-type", (0, 1))
        if name == "only-of-type":
            return self.simple(node, "first-of-type") and self.simple(node, "last-of-type")
        if name == "empty":
            return ad.empty(node)
        if name == "parent":
            return not ad.empty(node)
        if name == "root":
            return ad.parent(node) is None
        if name == "scope":
            return self.scope is not None and ad.key(node) in self.scope
        tag = ad.tag(node).lower()
        if name in ("checked", "selected"):
            if tag == "option":
                return ad.attr(node, "selected") is not None
            return name == "checked" and tag == "input" and ad.attr(node, "checked") is not None
        if name == "disabled":
            return tag in _FORM and ad.attr(node, "disabled") is not None
        if name == "enabled":
            return tag in _FORM and ad.attr(node, "disabled") is None
        if name in ("link", "any-link"):
            return tag in ("a", "area") and ad.attr(node, "href") is not None
        if name == "header":
            return len(tag) == 2 and tag[0] == "h" and tag[1] in "123456"
        if name == "input":
            return tag in ("input", "select", "textarea", "button")
        if name == "button":
            return tag == "button" or (tag == "input" and (ad.attr(node, "type") or "").lower() == "button")
        kind = (ad.attr(node, "type") or ("text" if tag == "input" else "")).lower()
        return tag == "input" and kind == name

    def complex(self, node, chain, at=None):
        """Right-to-left match of a chain ending at `node`."""
        if chain.positional:
            raise NotImplementedError("位置伪类（:eq/:first/…）不能用于 :not()/:is()/:has() 内部")
        parts = chain.parts
        if at is None:
            at = len(parts) - 1
        if not self.compound(node, parts[at][1]):
            return False
        if at == 0:
            return True
        link, ad = parts[at][0], self.ad
        if link == ">":
            up = ad.parent(node)
            return up is not None and self.complex(up, chain, at - 1)
        if link == " ":
            up = ad.parent(node)
            while up is not None:
                if self.complex(up, chain, at - 1):
                    return True
                up = ad.parent(up)
            return False
        kids, index = self.siblings(node)
        if link == "+":
            return index > 0 and self.complex(kids[index - 1], chain, at - 1)
        return any(self.complex(kids[i], chain, at - 1) for i in range(index - 1, -1, -1))

    def has(self, node, chain):
        lead = chain.lead
        if lead in ("+", "~"):
            kids, index = self.siblings(node)
            firsts = kids[index + 1:index + 2] if lead == "+" else kids[index + 1:]
        elif lead == ">":
            firsts = self.ad.children(node)
        else:
            firsts = self.ad.descendants(node)
        if len(chain.parts) == 1 and not chain.positional:
            only = chain.parts[0][1]
            return any(self.compound(n, only) for n in firsts)
        return bool(self.walk(list(firsts), chain))

    # -- left-to-right evaluation (positional filters, :has chains) ----------------------------------------------
    def step(self, nodes, link):
        ad, seen, out = self.ad, set(), []
        for node in nodes:
            if link == " ":
                found = ad.descendants(node)
            elif link == ">":
                found = ad.children(node)
            else:
                kids, index = self.siblings(node)
                found = kids[index + 1:index + 2] if link == "+" else kids[index + 1:]
            for item in found:
                key = ad.key(item)
                if key not in seen:
                    seen.add(key)
                    out.append(item)
        return out

    def narrow(self, nodes, compound):
        """Apply a compound to a list, positional filters in source order on the surviving list."""
        if compound.tag is not None:
            nodes = [n for n in nodes if self.same_tag(n, compound.tag)]
        for test in compound.tests:
            if test[0] == "pos":
                nodes = _position(nodes, test[1], test[2])
            else:
                nodes = [n for n in nodes if self.test(n, test)]
        return nodes

    def walk(self, candidates, chain):
        nodes = self.narrow(candidates, chain.parts[0][1])
        for link, compound in chain.parts[1:]:
            if not nodes:
                break
            nodes = self.narrow(self.step(nodes, link), compound)
        return nodes


def _position(nodes, name, value):
    if name in ("eq", "nth"):
        if value < 0:
            value += len(nodes)
        return nodes[value:value + 1] if value >= 0 else []
    if name == "gt":
        return nodes[value + 1:] if value >= 0 else nodes[max(len(nodes) + value + 1, 0):]
    if name == "lt":
        return nodes[:value] if value >= 0 else nodes[:max(len(nodes) + value, 0)]
    if name == "first":
        return nodes[:1]
    if name == "last":
        return nodes[-1:]
    return nodes[0::2] if name == "even" else nodes[1::2]


def _pool(ad, roots, include_self):
    seen, out = set(), []
    for root in roots:
        key = ad.key(root)
        if include_self and key not in seen:
            seen.add(key)
            out.append(root)
        for node in ad.descendants(root):
            key = ad.key(node)
            if key not in seen:
                seen.add(key)
                out.append(node)
    return out


def select(adapter, roots, selector, include_self=False, limit=None):
    """All matches below `roots`, in document order."""
    chains = parse(selector)
    run = _Run(adapter, {adapter.key(r) for r in roots})
    if not any(c.positional for c in chains):
        pool = adapter.descendants(roots[0]) if len(roots) == 1 and not include_self else \
            _pool(adapter, roots, include_self)
        out = []
        for node in pool:
            if any(run.complex(node, c) for c in chains):
                out.append(node)
                if limit and len(out) >= limit:
                    break
        return out
    pool = _pool(adapter, roots, include_self)
    hits = set()
    for chain in chains:
        if chain.positional:
            found = run.walk(pool, chain)
        else:
            found = [n for n in pool if run.complex(n, chain)]
        hits.update(adapter.key(n) for n in found)
    out = [n for n in pool if adapter.key(n) in hits]
    return out[:limit] if limit else out


def matches(adapter, node, selector):
    """Does this single element match? Positional filters see a set that holds only this element."""
    return bool(filter_nodes(adapter, [node], selector))


def filter_nodes(adapter, nodes, selector):
    """The nodes of a list that match, positional filters applied to the list."""
    run = _Run(adapter)
    chains = parse(selector)
    if len(chains) == 1 and not chains[0].positional:
        only = chains[0]
        return [n for n in nodes if run.complex(n, only)]
    hits = set()
    for chain in chains:
        if not chain.positional:
            found = [n for n in nodes if run.complex(n, chain)]
        else:
            if any(c.positional for _, c in chain.parts[:-1]):
                raise NotImplementedError("filter() 只支持在最后一段使用位置伪类: %r" % selector)
            found = nodes
            if len(chain.parts) > 1:
                head = _Complex(chain.parts[:-1], None)
                link = chain.parts[-1][0]
                found = [n for n in nodes if _linked(run, n, head, link)]
            found = run.narrow(found, chain.parts[-1][1])
        hits.update(adapter.key(n) for n in found)
    return [n for n in nodes if adapter.key(n) in hits]


def _linked(run, node, head, link):
    ad = run.ad
    if link == ">":
        up = ad.parent(node)
        return up is not None and run.complex(up, head)
    if link == " ":
        up = ad.parent(node)
        while up is not None:
            if run.complex(up, head):
                return True
            up = ad.parent(up)
        return False
    kids, index = run.siblings(node)
    if link == "+":
        return index > 0 and run.complex(kids[index - 1], head)
    return any(run.complex(k, head) for k in kids[:index])
