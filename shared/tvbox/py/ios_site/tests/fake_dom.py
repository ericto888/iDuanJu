"""A little DOM for the fake host (tests only, GPL-3.0): html.parser based, with libxml2-like repairs."""

from html import escape
from html.parser import HTMLParser

VOID = set("area base br col embed hr img input link meta param source track wbr".split())
HEAD = set("title meta link base script style".split())
CLOSES = {
    "li": ({"li"}, {"ul", "ol"}),
    "dt": ({"dt", "dd"}, {"dl"}),
    "dd": ({"dt", "dd"}, {"dl"}),
    "tr": ({"tr", "td", "th"}, {"table"}),
    "td": ({"td", "th"}, {"tr", "table"}),
    "th": ({"td", "th"}, {"tr", "table"}),
    "option": ({"option"}, {"select"}),
    "p": ({"p"}, {"div", "body", "td", "li"}),
    "div": ({"p"}, {"div", "body", "td", "li"}),
    "ul": ({"p"}, {"div", "body", "td", "li"}),
}


class Node:
    parent = None


class Text(Node):
    def __init__(self, data):
        self.data = data


class Comment(Node):
    def __init__(self, data):
        self.data = data


class Element(Node):
    def __init__(self, tag, attrs=()):
        self.tag = tag
        self.attrs = dict(attrs)
        self.children = []

    def append(self, node):
        if isinstance(node, Text) and self.children and isinstance(self.children[-1], Text):
            self.children[-1].data += node.data
            return
        node.parent = self
        self.children.append(node)

    def elements(self):
        return [c for c in self.children if isinstance(c, Element)]

    def descendants(self):
        for child in self.children:
            yield child
            if isinstance(child, Element):
                yield from child.descendants()

    def string(self):
        return "".join(d.data for d in self.descendants() if isinstance(d, Text))


class Document(Element):
    def __init__(self, xml=False):
        super().__init__("")
        self.xml = xml


class _Builder(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.doc = Document()
        self.html = self.head = self.body = None
        self.stack = []

    def _root(self):
        if self.html is None:
            self.html = Element("html")
            self.doc.append(self.html)

    def _open_body(self):
        self._root()
        if self.body is None:
            self.body = Element("body")
            self.html.append(self.body)
        if not self.stack or self.stack[0] is not self.body:
            self.stack = [self.body]

    def _top(self):
        return self.stack[-1] if self.stack else None

    def handle_starttag(self, tag, attrs, closed=False):
        attrs = [(k, v or "") for k, v in attrs]
        if tag == "html":
            self._root()
            for k, v in attrs:
                self.html.attrs.setdefault(k, v)
            return
        if tag == "head":
            self._root()
            if self.head is None:
                self.head = Element("head", attrs)
                self.html.append(self.head)
                self.stack = [self.head]
            return
        if tag == "body":
            self._root()
            if self.body is None:
                self.body = Element("body", attrs)
                self.html.append(self.body)
            self.stack = [self.body]
            return
        if self.body is None and tag in HEAD:
            self._root()
            if self.head is None:
                self.head = Element("head")
                self.html.append(self.head)
            if not self.stack:
                self.stack = [self.head]
        else:
            if self.body is None:
                self._open_body()
        rule = CLOSES.get(tag)
        if rule:
            names, stop = rule
            for i in range(len(self.stack) - 1, -1, -1):
                if self.stack[i].tag in stop:
                    break
                if self.stack[i].tag in names:
                    del self.stack[i:]
                    break
        node = Element(tag, attrs)
        (self._top() or self.body).append(node)
        if tag not in VOID and not closed:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        # HTML ignores the slash on non-void elements

    def handle_endtag(self, tag):
        if tag in ("html", "body"):
            return
        if tag == "head":
            self.stack = []
            return
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                if not self.stack and self.body is not None:
                    self.stack = [self.body]
                return

    def handle_data(self, data):
        top = self._top()
        if top is None or top is self.head:
            if not data.strip():
                return
            self._open_body()
            p = Element("p")
            self.body.append(p)
            self.stack.append(p)
        elif top is self.html:
            return
        self._top().append(Text(data))

    def handle_comment(self, data):
        (self._top() or self.html or self.doc).append(Comment(data))


def parse_html(markup):
    builder = _Builder()
    builder.feed(markup)
    builder.close()
    return builder.doc


def parse_xml(markup):
    """Namespace-aware, Clark names, keeps what was read before an error (recover mode)."""
    from xml.parsers import expat

    doc = Document(xml=True)
    stack = [doc]
    parser = expat.ParserCreate(namespace_separator="}")
    parser.buffer_text = True

    def name(text):
        return "{" + text if "}" in text else text

    def start(tag, attrs):
        node = Element(name(tag), [(name(k), v) for k, v in attrs.items()])
        stack[-1].append(node)
        stack.append(node)

    parser.StartElementHandler = start
    parser.EndElementHandler = lambda tag: stack.pop()
    parser.CharacterDataHandler = lambda data: stack[-1].append(Text(data)) if len(stack) > 1 else None
    parser.CommentHandler = lambda data: stack[-1].append(Comment(data))
    try:
        parser.Parse(markup, True)
    except expat.ExpatError:
        pass
    return doc


def local(tag):
    return tag.rpartition("}")[2]


def serialize(node, xml=False):
    if isinstance(node, Text):
        if node.parent is not None and node.parent.tag in ("script", "style") and not xml:
            return node.data
        return escape(node.data, quote=False)
    if isinstance(node, Comment):
        return "<!--%s-->" % node.data
    inner = "".join(serialize(c, xml) for c in node.children)
    if isinstance(node, Document):
        return inner
    attrs = "".join(' %s="%s"' % (local(k), escape(v)) for k, v in node.attrs.items())
    tag = local(node.tag)
    if xml:
        return "<%s%s>%s</%s>" % (tag, attrs, inner, tag) if inner else "<%s%s/>" % (tag, attrs)
    if tag in VOID:
        return "<%s%s>" % (tag, attrs)
    return "<%s%s>%s</%s>" % (tag, attrs, inner, tag)


def inner(node, xml=False):
    return "".join(serialize(c, xml) for c in node.children)
