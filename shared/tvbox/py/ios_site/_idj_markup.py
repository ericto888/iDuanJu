"""Markup tokenizer and serialisation helpers (original code, GPL-3.0).

`events()` is a tolerant HTML/XML tokenizer that behaves the same on every Python version (the stdlib `html.parser`
changes its rules between patch releases). It feeds the bs4 tree builder, the XML serialiser used by
`lxml.etree.tostring` and the block-aware text extraction of pyquery.

Event tuples:
    ("s", name, attrs, closed)   start tag; attrs is a list of (name, value or None); closed = written as <x/>
    ("e", name)                  end tag
    ("t", text)                  character data, entities resolved
    ("r", text)                  raw text of <script>/<style>
    ("c", text)                  comment
    ("d", text)                  declaration, e.g. "DOCTYPE html"
    ("p", text)                  processing instruction (without the angle brackets and question mark)
    ("x", text)                  CDATA section
"""

from __future__ import annotations

import re
from html import unescape

VOID = frozenset(
    "area base basefont bgsound br col command embed frame hr image img input isindex keygen link menuitem meta "
    "nextid param source spacer track wbr".split()
)
RAW_TEXT = frozenset(("script", "style"))
RCDATA = frozenset(("textarea", "title"))

_START = re.compile(
    r"""<([A-Za-z_][^\s/>\x00]*+)"""
    r"""((?:[\s/]*+[^\s/>][^\s/>=]*+(?:\s*+=\s*+(?:"[^"]*+"|'[^']*+'|(?!["'])[^\s>]++|))?+)*+)"""
    r"""([\s/]*+)>"""
)
_ATTR = re.compile(
    r"""([^\s/>][^\s/>=]*+)(?:\s*+=\s*+("[^"]*+"|'[^']*+'|(?!["'])[^\s>]++|))?+"""
)
_LOOSE_START = re.compile(r"<([A-Za-z_][^\s/>\x00]*+)([^>]*?)(/?)>")
_END = re.compile(r"</([A-Za-z_][^\s/>\x00]*+)[^>]*+>")
_RAW_END = {}
_MASK = re.compile(r"[<&]")


def _attrs(text, xml):
    out = []
    if not text:
        return out
    for found in _ATTR.finditer(text):
        name, value = found.group(1), found.group(2)
        if value is not None:
            if value[:1] in ("'", '"') and len(value) > 1:
                value = value[1:-1]
            if "&" in value:
                value = unescape(value)
        out.append((name if xml else name.lower(), value))
    return out


def _raw_end(name):
    pattern = _RAW_END.get(name)
    if pattern is None:
        pattern = _RAW_END[name] = re.compile(r"</%s(?=[\s/>])[^>]*+>" % re.escape(name), re.I)
    return pattern


def events(markup, xml=False):
    """Yield the event tuples of `markup` (a str)."""
    pos, size = 0, len(markup)
    last_gt = markup.rfind(">")
    start_tag = _START
    pending = []

    def flush():
        text = "".join(pending)
        pending.clear()
        return ("t", unescape(text) if "&" in text else text)

    while pos < size:
        lt = markup.find("<", pos)
        if lt < 0 or (lt > last_gt and not markup.startswith("<!", lt)):
            pending.append(markup[pos:])  # nothing closes any more
            break
        if lt > pos:
            pending.append(markup[pos:lt])
        following = markup[lt + 1:lt + 2]
        event, end = None, -1
        if following.isalpha() or following == "_":
            found = start_tag.match(markup, lt)
            if not found and start_tag is _START:
                # A quote that never closes: from here on tags simply end at the next ">".
                start_tag = _LOOSE_START
                found = start_tag.match(markup, lt)
            if found:
                name = found.group(1)
                if not xml:
                    name = name.lower()
                closed = found.group(3).endswith("/")
                event, end = ("s", name, _attrs(found.group(2), xml), closed), found.end()
        elif following == "/":
            found = _END.match(markup, lt)
            if found:
                name = found.group(1)
                event, end = ("e", name if xml else name.lower()), found.end()
            elif markup[lt + 2:lt + 3] == ">":
                pos = lt + 3
                continue
            elif markup[lt + 2:lt + 3] and not markup[lt + 2].isspace():
                stop = markup.find(">", lt + 2)
                if stop >= 0:
                    event, end = ("c", markup[lt + 2:stop]), stop + 1
        elif following == "!":
            if markup.startswith("<!--", lt):
                if markup.startswith(("<!-->", "<!--->"), lt):
                    event, end = ("c", ""), markup.index(">", lt) + 1
                else:
                    stop = markup.find("-->", lt + 4)
                    event = ("c", markup[lt + 4:stop] if stop >= 0 else markup[lt + 4:])
                    end = stop + 3 if stop >= 0 else size
            elif markup.startswith("<![CDATA[", lt):
                stop = markup.find("]]>", lt + 9)
                event = ("x", markup[lt + 9:stop] if stop >= 0 else markup[lt + 9:])
                end = stop + 3 if stop >= 0 else size
            else:
                stop = _declaration_end(markup, lt)
                if stop >= 0:
                    body = markup[lt + 2:stop]
                    event = ("d", body) if body[:7].lower() == "doctype" else ("c", body)
                    end = stop + 1
        elif following == "?":
            stop = markup.find("?>" if xml else ">", lt + 2)
            if stop >= 0:
                body = markup[lt + 2:stop]
                event, end = ("p", body), stop + (2 if xml else 1)
        if event is None:
            pending.append("<")
            pos = lt + 1
            continue
        if pending:
            yield flush()
        yield event
        pos = end
        if not xml and event[0] == "s" and not event[3]:
            name = event[1]
            if name in RAW_TEXT or name in RCDATA:
                found = _raw_end(name).search(markup, pos)
                stop = found.start() if found else size
                text = markup[pos:stop]
                if text:
                    if name in RAW_TEXT:
                        yield ("r", text)
                    else:
                        yield ("t", unescape(text) if "&" in text else text)
                pos = stop
    if pending:
        yield flush()


def _declaration_end(markup, start):
    """End of <!DOCTYPE ...>, stepping over an internal subset in square brackets."""
    stop = markup.find(">", start)
    bracket = markup.find("[", start, stop if stop >= 0 else len(markup))
    if bracket >= 0:
        close = markup.find("]", bracket)
        if close >= 0:
            return markup.find(">", close)
    return stop


def escape_text(text):
    if not _MASK.search(text) and ">" not in text:
        return text
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def escape_attr(text):
    return (
        escape_text(text).replace('"', "&quot;").replace("\n", "&#10;").replace("\t", "&#9;").replace("\r", "&#13;")
    )


def to_xml(markup):
    """Rewrite an HTML serialisation as XML the way libxml2's XML output method does (<br/>, escaped scripts)."""
    out = []
    stack = []
    open_tag = False

    def settle():
        nonlocal open_tag
        if open_tag:
            out.append(">")
            open_tag = False

    for event in events(markup):
        kind = event[0]
        if kind == "s":
            settle()
            name = event[1]
            out.append("<" + name)
            seen = set()
            for key, value in event[2]:
                if key in seen:
                    continue
                seen.add(key)
                out.append(' %s="%s"' % (key, escape_attr(value or "")))
            if event[3] or name in VOID:
                out.append("/>")
            else:
                stack.append(name)
                open_tag = True
        elif kind == "e":
            name = event[1]
            if name not in stack:
                continue
            while True:
                top = stack.pop()
                if open_tag:
                    out.append("/>")
                    open_tag = False
                else:
                    out.append("</%s>" % top)
                if top == name:
                    break
        elif kind == "c":
            settle()
            out.append("<!--%s-->" % event[1])
        elif kind == "d":
            settle()
            out.append("<!%s>" % event[1])
        elif kind == "p":
            settle()
            out.append("<?%s?>" % event[1].rstrip("?"))
        elif event[1]:
            settle()
            out.append(escape_text(event[1]))
    while stack:
        top = stack.pop()
        if open_tag:
            out.append("/>")
            open_tag = False
        else:
            out.append("</%s>" % top)
    return "".join(out)


# --- pyquery style text -------------------------------------------------------------------------------------------

_INLINE = frozenset(
    "a abbr acronym b bdo big br button cite code dfn em i img input kbd label map object q samp script select small "
    "span strong sub sup textarea time tt var".split()
)
_SPACE = re.compile("[ \t\f​\n\r]+")


def visible_text(markup, squash=True, block="\n", separator="\n"):
    """Text of serialised HTML: inline runs joined and squashed, one line break around blocks and per <br>."""
    parts = []  # str = text, None = block boundary, True = explicit <br>
    for event in events(markup):
        kind = event[0]
        if kind == "s" or kind == "e":
            name = event[1]
            if name == "br":
                if kind == "s":
                    parts.append(True)
            elif name not in _INLINE:
                parts.append(None)
                if kind == "s" and (event[3] or name in VOID):
                    parts.append(None)
        elif kind in "trx":
            parts.append(event[1])
    if not squash:
        out = []
        for part in parts:
            out.append(part if isinstance(part, str) else separator if part is True else block)
        return "".join(out)
    lines, run = [], []

    def flush():
        if run:
            text = _SPACE.sub(" ", "".join(run)).strip()
            run.clear()
            if text:
                lines.append(text)

    for part in parts:
        if isinstance(part, str):
            run.append(part)
            continue
        flush()
        if part is True:
            lines.append(True)
        elif lines and lines[-1] is not None:
            lines.append(None)
    flush()
    while lines and not isinstance(lines[-1], str):
        lines.pop()
    while lines and not isinstance(lines[0], str):
        lines.pop(0)
    return "".join(x if isinstance(x, str) else separator if x is True else block for x in lines)
