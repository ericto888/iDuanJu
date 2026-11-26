"""XPath 1.0 evaluator over fake_dom (tests only, GPL-3.0). Covers the core library; no namespaces, no variables."""

import math

from _idj_xpath import tokenize
from fake_dom import Comment, Document, Element, Text, local


class XPathFailure(ValueError):
    pass


class Attr:
    __slots__ = ("owner", "name", "data")

    def __init__(self, owner, name, data):
        self.owner, self.name, self.data = owner, name, data

    def __eq__(self, other):
        return isinstance(other, Attr) and other.owner is self.owner and other.name == self.name

    def __hash__(self):
        return hash((id(self.owner), self.name))


def key(node):
    return (id(node.owner), node.name) if isinstance(node, Attr) else id(node)


def parent_of(node):
    return node.owner if isinstance(node, Attr) else node.parent


def string_of(node):
    if isinstance(node, (Text, Comment, Attr)):
        return node.data
    return node.string()


def number_of_string(text):
    text = text.strip()
    try:
        if not text or any(c not in "0123456789.-" for c in text):
            return math.nan
        return float(text)
    except ValueError:
        return math.nan


def format_number(value):
    if value != value:
        return "NaN"
    if value in (math.inf, -math.inf):
        return "Infinity" if value > 0 else "-Infinity"
    if value == int(value):
        return str(int(value))
    return repr(value)


def to_string(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        return format_number(value)
    if isinstance(value, list):
        return string_of(value[0]) if value else ""
    return value


def to_number(value):
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, float):
        return value
    return number_of_string(to_string(value))


def to_bool(value):
    if isinstance(value, float):
        return value == value and value != 0
    return bool(value)


class Context:
    __slots__ = ("node", "position", "size")

    def __init__(self, node, position=1, size=1):
        self.node, self.position, self.size = node, position, size


def siblings(node):
    up = node.parent if not isinstance(node, Attr) else None
    return (up.children, next(i for i, c in enumerate(up.children) if c is node)) if up is not None else ([], 0)


def axis_nodes(axis, node):
    if axis == "self":
        return [node]
    if axis == "attribute":
        return [Attr(node, k, v) for k, v in node.attrs.items()] if isinstance(node, Element) else []
    if axis == "parent":
        up = parent_of(node)
        return [up] if up is not None else []
    if axis in ("ancestor", "ancestor-or-self"):
        out = [node] if axis == "ancestor-or-self" else []
        up = parent_of(node)
        while up is not None:
            out.append(up)
            up = parent_of(up)
        return out
    if axis == "child":
        return list(node.children) if isinstance(node, Element) else []
    if axis in ("descendant", "descendant-or-self"):
        out = [node] if axis == "descendant-or-self" else []
        if isinstance(node, Element):
            out.extend(node.descendants())
        return out
    if axis == "following-sibling":
        kids, at = siblings(node)
        return kids[at + 1:] if kids else []
    if axis == "preceding-sibling":
        kids, at = siblings(node)
        return kids[:at][::-1] if kids else []
    if axis in ("following", "preceding"):
        out = []
        while node is not None and parent_of(node) is not None:
            kids, at = siblings(node)
            group = kids[at + 1:] if axis == "following" else kids[:at][::-1]
            for item in group:
                below = [item] + (list(item.descendants()) if isinstance(item, Element) else [])
                out.extend(below if axis == "following" else below[::-1])
            node = parent_of(node)
        return out
    raise XPathFailure("未知轴 " + axis)


class Evaluator:
    def __init__(self, expr):
        self.expr = expr
        try:
            self.tokens = list(tokenize(expr))
        except ValueError as exc:
            raise XPathFailure(str(exc)) from exc
        self.pos = 0
        self.tree = self.parse_or()
        if self.pos != len(self.tokens):
            raise XPathFailure("Invalid expression")

    # -- token helpers -----------------------------------------------------------------------------------------------
    def peek(self, kind=None, *texts):
        if self.pos >= len(self.tokens):
            return None
        token = self.tokens[self.pos]
        if kind and token.kind != kind:
            return None
        if texts and token.text not in texts:
            return None
        return token

    def take(self, kind, *texts):
        token = self.peek(kind, *texts)
        if token is None:
            raise XPathFailure("Invalid expression")
        self.pos += 1
        return token

    # -- grammar -----------------------------------------------------------------------------------------------------
    def _binary(self, below, *operators):
        left = below()
        while self.peek("op", *operators):
            op = self.take("op").text
            left = ("bin", op, left, below())
        return left

    def parse_or(self):
        return self._binary(self.parse_and, "or")

    def parse_and(self):
        return self._binary(self.parse_equal, "and")

    def parse_equal(self):
        return self._binary(self.parse_relation, "=", "!=")

    def parse_relation(self):
        return self._binary(self.parse_sum, "<", "<=", ">", ">=")

    def parse_sum(self):
        return self._binary(self.parse_product, "+", "-")

    def parse_product(self):
        return self._binary(self.parse_unary, "*", "div", "mod")

    def parse_unary(self):
        if self.peek("op", "-"):
            self.take("op")
            return ("neg", self.parse_unary())
        return self._binary(self.parse_path, "|")

    def parse_path(self):
        token = self.peek()
        if token is None:
            raise XPathFailure("Invalid expression")
        start = None
        if token.kind in ("lit", "num"):
            self.pos += 1
            start = ("lit", token.text[1:-1]) if token.kind == "lit" else ("num", float(token.text))
        elif token.kind == "sym" and token.text == "(":
            self.take("sym", "(")
            start = self.parse_or()
            self.take("sym", ")")
        elif token.kind == "func" and token.text not in ("text", "node", "comment", "processing-instruction"):
            name = self.take("func").text
            self.take("sym", "(")
            args = []
            if not self.peek("sym", ")"):
                args.append(self.parse_or())
                while self.peek("sym", ","):
                    self.take("sym")
                    args.append(self.parse_or())
            self.take("sym", ")")
            start = ("call", name, args)
        steps = []
        if start is not None:
            while self.peek("sym", "["):
                steps.append(("filter", self.predicate()))
            if not self.peek("sym", "/", "//"):
                return ("path", start, steps) if steps else start
        elif token.kind == "sym" and token.text in ("/", "//"):
            start = ("root",)
        else:
            start = ("context",)
            steps.append(self.step())
        while self.peek("sym", "/", "//"):
            slash = self.take("sym").text
            if slash == "//":
                steps.append(("step", "descendant-or-self", "node()", []))
                steps.append(self.step())
            elif self._at_step():
                steps.append(self.step())
        return ("path", start, steps)

    def _at_step(self):
        token = self.peek()
        return token is not None and (
            token.kind in ("name", "axis", "func") or (token.kind == "sym" and token.text in (".", "..", "@"))
        )

    def predicate(self):
        self.take("sym", "[")
        expr = self.parse_or()
        self.take("sym", "]")
        return expr

    def step(self):
        if self.peek("sym", "."):
            self.take("sym")
            return ("step", "self", "node()", [])
        if self.peek("sym", ".."):
            self.take("sym")
            return ("step", "parent", "node()", [])
        axis = "child"
        if self.peek("axis"):
            axis = self.take("axis").text
        elif self.peek("sym", "@"):
            self.take("sym")
            axis = "attribute"
        if self.peek("func"):
            test = self.take("func").text + "()"
            self.take("sym", "(")
            if self.peek("lit"):
                self.take("lit")
            self.take("sym", ")")
        else:
            test = self.take("name").text
            if ":" in test:
                raise XPathFailure("Undefined namespace prefix")
        predicates = []
        while self.peek("sym", "["):
            predicates.append(self.predicate())
        return ("step", axis, test, predicates)

    # -- evaluation --------------------------------------------------------------------------------------------------
    def evaluate(self, node):
        self.order = {}
        root = node
        while parent_of(root) is not None:
            root = parent_of(root)
        count = 0
        self.order[id(root)] = 0
        for item in root.descendants():
            count += 1
            self.order[id(item)] = count
        return self.value(self.tree, Context(node))

    def sorted(self, nodes):
        seen, out = set(), []
        for node in nodes:
            k = key(node)
            if k not in seen:
                seen.add(k)
                out.append(node)

        def rank(node):
            if isinstance(node, Attr):
                return (self.order[id(node.owner)], 1 + list(node.owner.attrs).index(node.name))
            return (self.order[id(node)], 0)

        return sorted(out, key=rank)

    def value(self, tree, ctx):
        kind = tree[0]
        if kind in ("lit", "num"):
            return tree[1]
        if kind == "neg":
            return -to_number(self.value(tree[1], ctx))
        if kind == "bin":
            return self.binary(tree, ctx)
        if kind == "call":
            return self.call(tree[1], tree[2], ctx)
        if kind == "context":
            return [ctx.node]
        if kind == "root":
            node = ctx.node
            while parent_of(node) is not None:
                node = parent_of(node)
            return [node]
        nodes = self.value(tree[1], ctx)
        for step in tree[2]:
            if step[0] == "filter":
                nodes = self.narrow(self.sorted(nodes), step[1])
                continue
            _, axis, test, predicates = step
            out = []
            for node in nodes:
                found = [n for n in axis_nodes(axis, node) if self.matches(axis, test, n)]
                for predicate in predicates:
                    found = self.narrow(found, predicate)
                out.extend(found)
            nodes = self.sorted(out)
        return nodes

    @staticmethod
    def matches(axis, test, node):
        if test == "node()":
            return True
        if test == "text()":
            return isinstance(node, Text)
        if test == "comment()":
            return isinstance(node, Comment)
        if test.endswith("()"):
            return False
        if axis == "attribute":
            return test == "*" or node.name == test
        if not isinstance(node, Element) or isinstance(node, Document):
            return False
        return test == "*" or node.tag == test

    def narrow(self, nodes, predicate):
        out = []
        for i, node in enumerate(nodes):
            value = self.value(predicate, Context(node, i + 1, len(nodes)))
            if (value == i + 1) if isinstance(value, float) else to_bool(value):
                out.append(node)
        return out

    def binary(self, tree, ctx):
        _, op, left, right = tree
        if op == "or":
            return to_bool(self.value(left, ctx)) or to_bool(self.value(right, ctx))
        if op == "and":
            return to_bool(self.value(left, ctx)) and to_bool(self.value(right, ctx))
        a, b = self.value(left, ctx), self.value(right, ctx)
        if op == "|":
            return self.sorted(a + b)
        if op in ("+", "-", "*", "div", "mod"):
            a, b = to_number(a), to_number(b)
            if op == "+":
                return a + b
            if op == "-":
                return a - b
            if op == "*":
                return a * b
            if b == 0:
                return math.nan if op == "mod" or a == 0 or a != a else math.copysign(math.inf, a)
            return a / b if op == "div" else math.fmod(a, b)
        return self.compare(op, a, b)

    def compare(self, op, a, b):
        if isinstance(a, list) and isinstance(b, list):
            return any(self.atoms(op, string_of(x), string_of(y)) for x in a for y in b)
        if isinstance(a, list) or isinstance(b, list):
            nodes, other, flip = (a, b, False) if isinstance(a, list) else (b, a, True)
            if isinstance(other, bool):
                x, y = bool(nodes), other
                return self.atoms(op, y, x) if flip else self.atoms(op, x, y)
            for node in nodes:
                x = string_of(node)
                if isinstance(other, float):
                    x = number_of_string(x)
                if self.atoms(op, other, x) if flip else self.atoms(op, x, other):
                    return True
            return False
        return self.atoms(op, a, b)

    @staticmethod
    def atoms(op, a, b):
        if op in ("=", "!="):
            if isinstance(a, bool) or isinstance(b, bool):
                a, b = to_bool(a), to_bool(b)
            elif isinstance(a, float) or isinstance(b, float):
                a, b = to_number(a), to_number(b)
            return (a == b) if op == "=" else (a != b)
        a, b = to_number(a), to_number(b)
        return {"<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b}[op]

    def call(self, name, args, ctx):
        values = [self.value(a, ctx) for a in args]
        text = [to_string(v) for v in values]
        here = string_of(ctx.node)
        if name == "position":
            return float(ctx.position)
        if name == "last":
            return float(ctx.size)
        if name == "count":
            return float(len(values[0]))
        if name == "string":
            return text[0] if text else here
        if name == "concat":
            return "".join(text)
        if name == "normalize-space":
            return " ".join((text[0] if text else here).split())
        if name == "contains":
            return text[1] in text[0]
        if name == "starts-with":
            return text[0].startswith(text[1])
        if name == "substring-before":
            return text[0].partition(text[1])[0] if text[1] in text[0] else ""
        if name == "substring-after":
            return text[0].partition(text[1])[2] if text[1] in text[0] else ""
        if name == "substring":
            start = round(to_number(values[1])) - 1
            stop = len(text[0]) if len(values) < 3 else start + round(to_number(values[2]))
            return text[0][max(start, 0):max(stop, 0)]
        if name == "string-length":
            return float(len(text[0] if text else here))
        if name == "translate":
            table = {}
            for i, ch in enumerate(text[1]):
                table.setdefault(ord(ch), text[2][i] if i < len(text[2]) else None)
            return text[0].translate(table)
        if name == "boolean":
            return to_bool(values[0])
        if name == "not":
            return not to_bool(values[0])
        if name in ("true", "false"):
            return name == "true"
        if name == "number":
            return to_number(values[0]) if values else number_of_string(here)
        if name == "sum":
            return float(sum(number_of_string(string_of(n)) for n in values[0]))
        if name == "floor":
            return float(math.floor(to_number(values[0])))
        if name == "ceiling":
            return float(math.ceil(to_number(values[0])))
        if name == "round":
            return float(math.floor(to_number(values[0]) + 0.5))
        if name in ("name", "local-name", "namespace-uri"):
            node = (values[0][0] if values[0] else None) if values else ctx.node
            full = getattr(node, "tag", None) or getattr(node, "name", "") or ""
            if name == "namespace-uri":
                return full[1:].partition("}")[0] if full.startswith("{") else ""
            return local(full)
        if name == "id":
            wanted = set(text[0].split())
            root = ctx.node
            while parent_of(root) is not None:
                root = parent_of(root)
            return [n for n in root.descendants() if isinstance(n, Element) and n.attrs.get("id") in wanted]
        raise XPathFailure("Unregistered function: " + name)


def query(node, expr):
    """list of nodes, or str / float / bool."""
    return Evaluator(expr).evaluate(node)
