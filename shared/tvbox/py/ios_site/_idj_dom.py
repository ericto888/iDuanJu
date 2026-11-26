"""Thin wrappers around the host's `html.*` functions (original code, GPL-3.0).

Node ids are only valid until the current spider call returns. `epoch` counts mutations so that element wrappers
can drop the node information they cached.
"""

from __future__ import annotations

from _idj_bridge import call

epoch = 0


def _touch():
    global epoch
    epoch += 1


def _clean(markup):
    # A NUL would end the document early in a C parser.
    return markup.replace("\x00", "") if "\x00" in markup else markup


def load_html(markup):
    return call("html.load", html=_clean(markup))


def load_xml(markup):
    return call("html.loadXml", xml=_clean(markup))


def info(node):
    return call("html.info", id=node) or {}


def rel(node, op):
    found = call("html.rel", id=node, op=op)
    if found is None:
        return []
    return found if isinstance(found, list) else [found]


def select(nodes, css):
    return call("html.select", ids=list(nodes), css=css) or []


def xpath(node, query):
    return call("html.xpath", id=node, q=query) or []


def string(node):
    """XPath string value: the exact concatenated text of the subtree."""
    found = xpath(node, "string(.)")
    return found[0].get("s") or "" if found else ""


def outer(node):
    return call("html.outer", id=node) or ""


def inner(node):
    return call("html.html", id=node) or ""


def child_nodes(node):
    return call("html.childNodes", id=node) or []


def remove(nodes, tail=False):
    """Detach nodes. With `tail` the host is asked to drop the text that follows each node as well."""
    nodes = list(nodes)
    if not nodes:
        return
    if tail:
        call("html.remove", ids=nodes, tail=True)
    else:
        call("html.remove", ids=nodes)
    _touch()


def set_attr(node, name, value):
    call("html.setAttr", id=node, k=name, v=value)
    _touch()


def set_text(node, value):
    call("html.setText", id=node, s=value)
    _touch()
