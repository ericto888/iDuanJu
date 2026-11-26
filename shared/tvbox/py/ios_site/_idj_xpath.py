"""XPath 1.0 expression analysis for the lxml shim (original code, GPL-3.0).

The host evaluates the expression; this module only looks at it: result type (so that numbers and booleans come back as
float/bool), `$variables`, namespace prefixes and EXSLT `re:` calls, none of which the host knows about.
"""

from __future__ import annotations

import re
from functools import lru_cache

EXSLT_RE = "http://exslt.org/regular-expressions"

_TOKEN = re.compile(
    r"""\s*(?:
    (?P<lit>"[^"]*"|'[^']*')
  | (?P<num>\d+(?:\.\d*)?|\.\d+)
  | (?P<var>\$[^\W\d][\w.\-]*(?::[^\W\d][\w.\-]*)?)
  | (?P<name>[^\W\d][\w.\-]*(?::(?:\*|[^\W\d][\w.\-]*))?(?!:[^:]))
  | (?P<sym>::|//|\.\.|!=|<=|>=|[()\[\]@,/|+\-=<>*.])
    )""",
    re.X,
)
_AXIS_NAME = re.compile(r"([^\W\d][\w\-]*)\s*::")
_OPERATOR_WORDS = frozenset(("and", "or", "mod", "div"))
_NODE_TYPES = frozenset(("text", "comment", "node", "processing-instruction"))
_STRING = frozenset((
    "string", "concat", "normalize-space", "substring", "substring-before", "substring-after", "translate", "name",
    "local-name", "namespace-uri",
))
_NUMBER = frozenset(("count", "sum", "number", "floor", "ceiling", "round", "string-length", "position", "last"))
_BOOLEAN = frozenset(("boolean", "not", "true", "false", "contains", "starts-with", "lang"))


class XPathSyntaxProblem(ValueError):
    pass


class Token:
    """kind: lit num var name func axis op sym; `pos`/`end` are offsets into the expression."""

    __slots__ = ("kind", "text", "pos", "end")

    def __init__(self, kind, text, pos, end):
        self.kind, self.text, self.pos, self.end = kind, text, pos, end

    def __repr__(self):
        return "%s:%s" % (self.kind, self.text)


@lru_cache(maxsize=1024)
def tokenize(expr):
    out, pos, size = [], 0, len(expr)
    while pos < size:
        if expr[pos:].strip() == "":
            break
        # "axis::" must win over the QName rule ("self::a", "ancestor-or-self::ns:a").
        skip = len(expr[pos:]) - len(expr[pos:].lstrip())
        axis = _AXIS_NAME.match(expr, pos + skip)
        if axis and not _after_operand(out):
            out.append(Token("axis", axis.group(1), axis.start(), axis.end()))
            pos = axis.end()
            continue
        found = _TOKEN.match(expr, pos)
        if not found or found.end() == pos:
            raise XPathSyntaxProblem("Invalid expression: %r (位置 %d)" % (expr, pos))
        kind = found.lastgroup
        text, start, end = found.group(kind), found.start(kind), found.end()
        if kind == "name":
            if _after_operand(out) and text.split(":")[0] in _OPERATOR_WORDS:
                kind = "op"
            elif expr[end:].lstrip()[:1] == "(":
                kind = "func"
        elif kind == "sym":
            if text == "*":
                if _after_operand(out):
                    kind = "op"
                else:
                    kind = "name"
            elif text in ("+", "-", "=", "!=", "<", "<=", ">", ">=", "|"):
                kind = "op"
        out.append(Token(kind, text, start, end))
        pos = end
    return tuple(out)


def _after_operand(tokens):
    """True when the next token must be an operator (XPath 1.0 section 3.7)."""
    if not tokens:
        return False
    last = tokens[-1]
    if last.kind in ("op", "axis", "func"):
        return False
    if last.kind == "sym":
        return last.text in (")", "]", ".", "..")
    return True


def closing(tokens, at):
    """Index of the bracket that closes tokens[at]."""
    pairs = {"(": ")", "[": "]"}
    open_, close = tokens[at].text, pairs[tokens[at].text]
    depth = 0
    for i in range(at, len(tokens)):
        token = tokens[i]
        if token.kind == "sym":
            if token.text == open_:
                depth += 1
            elif token.text == close:
                depth -= 1
                if depth == 0:
                    return i
    raise XPathSyntaxProblem("Invalid expression: 括号不匹配")


def top_level(tokens):
    """Indexes of tokens outside every bracket."""
    i, out = 0, []
    while i < len(tokens):
        out.append(i)
        if tokens[i].kind == "sym" and tokens[i].text in ("(", "["):
            i = closing(tokens, i)
            out.append(i)
        i += 1
    return out


def result_type(tokens, variables=None):
    """'nodeset', 'string', 'number' or 'boolean'."""
    if not tokens:
        raise XPathSyntaxProblem("Invalid expression: 表达式为空")
    outer = top_level(tokens)
    operators = {tokens[i].text for i in outer if tokens[i].kind == "op"}
    if operators & {"or", "and", "=", "!=", "<", "<=", ">", ">="}:
        return "boolean"
    if operators & {"+", "-", "*", "div", "mod"}:
        return "number"
    if "|" in operators:
        return "nodeset"
    first = tokens[0]
    if len(tokens) == 1:
        if first.kind == "lit":
            return "string"
        if first.kind == "num":
            return "number"
        if first.kind == "var":
            value = (variables or {}).get(first.text[1:])
            if isinstance(value, bool):
                return "boolean"
            if isinstance(value, (int, float)):
                return "number"
            return "string"
    if first.kind == "sym" and first.text == "(" and closing(tokens, 0) == len(tokens) - 1:
        return result_type(tokens[1:-1], variables)
    if first.kind == "func" and first.text not in _NODE_TYPES and closing(tokens, 1) == len(tokens) - 1:
        name = first.text
        if name in _STRING:
            return "string"
        if name in _NUMBER:
            return "number"
        if name in _BOOLEAN:
            return "boolean"
        local = name.partition(":")[2]
        if local == "test":
            return "boolean"
        if local == "replace":
            return "string"
    return "nodeset"


def literal(value):
    """Python value -> XPath literal."""
    if isinstance(value, bool):
        return "true()" if value else "false()"
    if isinstance(value, (int, float)):
        if value != value or value in (float("inf"), float("-inf")):
            raise NotImplementedError("XPath 变量不支持 %r" % value)
        text = repr(value) if isinstance(value, int) else format(value, "f").rstrip("0").rstrip(".")
        return text if value >= 0 else "(%s)" % text
    if isinstance(value, bytes):
        value = value.decode("utf-8")
    if not isinstance(value, str):
        raise NotImplementedError("XPath 变量只支持字符串、数字和布尔值，收到 %s" % type(value).__name__)
    if "'" not in value:
        return "'%s'" % value
    if '"' not in value:
        return '"%s"' % value
    parts = []
    for i, piece in enumerate(value.split("'")):
        if i:
            parts.append('"\'"')
        if piece:
            parts.append("'%s'" % piece)
    return "concat(%s)" % ", ".join(parts)


def rewrite(expr, namespaces=None, variables=None):
    """Substitute `$variables` and namespace prefixes. `re:` calls are left alone."""
    tokens = tokenize(expr)
    edits = []
    for i, token in enumerate(tokens):
        if token.kind == "var":
            name = token.text[1:]
            if not variables or name not in variables:
                raise XPathSyntaxProblem("Undefined variable: $%s" % name)
            edits.append((token.pos, token.end, literal(variables[name])))
        elif token.kind == "name" and ":" in token.text:
            prefix, local = token.text.split(":", 1)
            if prefix == "xml":
                continue
            if not namespaces or prefix not in namespaces:
                raise XPathSyntaxProblem("Undefined namespace prefix: %s" % prefix)
            test = "namespace-uri()=%s" % literal(namespaces[prefix])
            if local != "*":
                test = "local-name()='%s' and %s" % (local, test)
            edits.append((token.pos, token.end, "*[%s]" % test))
    for start, end, text in reversed(edits):
        expr = expr[:start] + text + expr[end:]
    return expr


def is_regex_call(token, namespaces=None):
    if token.kind != "func" or ":" not in token.text:
        return False
    prefix = token.text.split(":", 1)[0]
    if namespaces and prefix in namespaces:
        return namespaces[prefix] == EXSLT_RE
    return prefix == "re"


def needs_rewrite(tokens):
    return any(t.kind == "var" or (t.kind == "name" and ":" in t.text) for t in tokens)


def split_union(expr):
    """Top-level operands of `a | b | c`."""
    tokens = tokenize(expr)
    parts, start = [], 0
    for i in top_level(tokens):
        if tokens[i].kind == "op" and tokens[i].text == "|":
            parts.append(expr[start:tokens[i].pos])
            start = tokens[i].end
    parts.append(expr[start:])
    return parts


def call_arguments(expr, tokens, at):
    """Source text of each argument of the call whose `(` is tokens[at]; also the index of its `)`."""
    end = closing(tokens, at)
    args, start, i = [], tokens[at].end, at + 1
    while i < end:
        token = tokens[i]
        if token.kind == "sym":
            if token.text in ("(", "["):
                i = closing(tokens, i)
            elif token.text == ",":
                args.append(expr[start:token.pos].strip())
                start = token.end
        i += 1
    args.append(expr[start:tokens[end].pos].strip())
    return args, end
