import Foundation
import libxml2

/// One parsed page of a script; nodes keep it alive. libxml2 underneath, jsoup semantics where scripts depend on them
/// (`text()`, serialisation, selectors), because both platforms run the same scripts.
final class HtmlDoc {
    let ptr: htmlDocPtr
    /// Subtrees cut out of the page.
    fileprivate var detached: [xmlNodePtr] = []

    init(_ html: String) {
        var src = html.utf8.contains(0) ? html.replacingOccurrences(of: "\0", with: "") : html
        if src.utf8.count > 20 << 20 { src = String(decoding: src.utf8.prefix(20 << 20), as: UTF8.self) }
        // A fragment gets its html and body here: libxml2 would put loose text into a <p>.
        let whole = src.withCString { strcasestr($0, "<html") != nil || strcasestr($0, "<body") != nil }
        if !whole { src = "<html><head></head><body>" + src + "</body></html>" }
        let opts = Int32(HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_NONET.rawValue)
        ptr = src.withCString { htmlReadMemory($0, Int32(strlen($0)), "about:blank", "UTF-8", opts) } ?? htmlNewDocNoDtD(nil, nil)
        if src.withCString({ strcasestr($0, "<table") != nil }) { addTableBodies() }
    }

    /// Browsers (and jsoup) put the bare rows of a table into a tbody; rules rely on it.
    private func addTableBodies() {
        var tables: [xmlNodePtr] = []
        node.ptr.eachDescendant {
            if $0.tag == "table" { tables.append($0) }
            return true
        }
        for t in tables {
            var body: xmlNodePtr?
            for c in t.childElements {
                guard c.tag == "tr" else { body = nil; continue }
                if body == nil {
                    body = xmlNewDocNode(ptr, nil, "tbody", nil)
                    xmlAddPrevSibling(c, body)
                }
                xmlUnlinkNode(c)
                xmlAddChild(body, c)
            }
        }
    }

    /// A page that consists of a copy of `node`.
    fileprivate init(copy node: HtmlNode) {
        ptr = htmlNewDocNoDtD(nil, nil)
        if let c = xmlDocCopyNode(node.ptr, ptr, 1) { _ = xmlDocSetRootElement(ptr, c) }
    }

    deinit {
        detached.forEach { xmlFreeNode($0) }
        xmlFreeDoc(ptr)
    }

    var node: HtmlNode { HtmlNode(doc: self, ptr: UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: xmlNode.self)) }
}

private let blockTags: Set<String> = ["html", "head", "body", "frameset", "script", "noscript", "style", "meta", "link", "title", "frame", "noframes", "section", "nav", "aside",
    "hgroup", "header", "footer", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "pre", "div", "blockquote", "hr", "address", "figure", "figcaption", "form", "fieldset",
    "ins", "del", "dl", "dt", "dd", "li", "table", "caption", "thead", "tfoot", "tbody", "colgroup", "col", "tr", "th", "td", "video", "audio", "canvas", "details", "menu",
    "plaintext", "template", "article", "main", "svg", "math", "center", "dir", "applet", "marquee", "listing"]
private let voidTags: Set<String> = ["meta", "link", "base", "frame", "img", "br", "wbr", "embed", "hr", "input", "keygen", "col", "command", "device", "area", "basefont", "bgsound",
    "menuitem", "param", "source", "track"]
private let booleanAttributes: Set<String> = ["allowfullscreen", "async", "autofocus", "checked", "compact", "declare", "default", "defer", "disabled", "formnovalidate", "hidden",
    "inert", "ismap", "itemscope", "multiple", "muted", "nohref", "noresize", "noshade", "novalidate", "nowrap", "open", "readonly", "required", "reversed", "seamless", "selected",
    "sortable", "truespeed", "typemustmatch"]

private extension UnsafeMutablePointer where Pointee == xmlNode {
    var isElement: Bool { pointee.type == XML_ELEMENT_NODE }
    var tag: String { pointee.name.map { String(cString: $0).lowercased() } ?? "" }
    var parentElement: UnsafeMutablePointer<xmlNode>? { pointee.parent.flatMap { $0.isElement ? $0 : nil } }

    var nextElement: UnsafeMutablePointer<xmlNode>? {
        var n = pointee.next
        while let x = n, !x.isElement { n = x.pointee.next }
        return n
    }

    var previousElement: UnsafeMutablePointer<xmlNode>? {
        var n = pointee.prev
        while let x = n, !x.isElement { n = x.pointee.prev }
        return n
    }

    var childElements: [UnsafeMutablePointer<xmlNode>] {
        var out: [UnsafeMutablePointer<xmlNode>] = []
        var n = pointee.children
        while let x = n { if x.isElement { out.append(x) }; n = x.pointee.next }
        return out
    }

    /// Element descendants in document order; `body` returns false to stop.
    func eachDescendant(_ body: (UnsafeMutablePointer<xmlNode>) -> Bool) {
        var n = pointee.children
        while let x = n {
            if x.isElement {
                if !body(x) { return }
                if let c = x.pointee.children { n = c; continue }
            }
            var up: UnsafeMutablePointer<xmlNode>? = x
            while let u = up, u != self, u.pointee.next == nil { up = u.pointee.parent }
            guard let u = up, u != self else { return }
            n = u.pointee.next
        }
    }

    func attribute(_ name: String) -> String? {
        guard isElement, xmlHasProp(self, name) != nil else { return nil }
        guard let v = xmlGetProp(self, name) else { return "" }
        defer { xmlFree(v) }
        return String(cString: v)
    }

    func hasClass(_ name: String) -> Bool {
        guard let v = attribute("class") else { return false }
        return v.split(whereSeparator: \.isWhitespace).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    var text: String {
        var out: [UInt8] = []
        accumulate(&out, preserve: false)
        return String(decoding: out.trimmed, as: UTF8.self)
    }

    var ownText: String {
        var out: [UInt8] = []
        var n = pointee.children
        while let x = n {
            if x.pointee.type == XML_TEXT_NODE { x.appendText(&out, preserve: false) } else if x.isElement, x.tag == "br", out.last != 0x20 { out.append(0x20) }
            n = x.pointee.next
        }
        return String(decoding: out.trimmed, as: UTF8.self)
    }

    private func accumulate(_ out: inout [UInt8], preserve: Bool) {
        var n = pointee.children
        while let x = n {
            if x.pointee.type == XML_TEXT_NODE {
                x.appendText(&out, preserve: preserve)
            } else if x.isElement {
                let name = x.tag, block = blockTags.contains(name)
                if !out.isEmpty, block || name == "br", out.last != 0x20 { out.append(0x20) }
                x.accumulate(&out, preserve: preserve || name == "pre" || name == "textarea")
                if block, let after = x.pointee.next, after.pointee.type == XML_TEXT_NODE || after.isElement, out.last != 0x20 { out.append(0x20) }
            }
            n = x.pointee.next
        }
    }

    /// Collapses white space (a no-break space counts as one) and drops zero-width spaces and soft hyphens.
    private func appendText(_ out: inout [UInt8], preserve: Bool) {
        guard var p = pointee.content else { return }
        if preserve { while p.pointee != 0 { out.append(p.pointee); p += 1 }; return }
        var white = out.last == 0x20
        while p.pointee != 0 {
            let b = p.pointee
            if b == 0x20 || (b >= 9 && b <= 13 && b != 11) || (b == 0xc2 && p[1] == 0xa0) {
                if !white { out.append(0x20); white = true }
                p += b == 0xc2 ? 2 : 1
            } else if b == 0xc2 && p[1] == 0xad { p += 2 } else if b == 0xe2 && p[1] == 0x80 && p[2] == 0x8b { p += 3 } else {
                out.append(b); white = false
                p += 1
            }
        }
    }

    func dump(_ out: inout [UInt8]) {
        switch pointee.type {
        case XML_TEXT_NODE: escape(pointee.content, &out, attribute: false)
        case XML_CDATA_SECTION_NODE: if let c = pointee.content { out.append(contentsOf: UnsafeBufferPointer(start: c, count: strlen(UnsafeRawPointer(c).assumingMemoryBound(to: CChar.self)))) }
        case XML_COMMENT_NODE:
            out.append(contentsOf: "<!--".utf8)
            if let c = pointee.content { out.append(contentsOf: String(cString: c).utf8) }
            out.append(contentsOf: "-->".utf8)
        case XML_ELEMENT_NODE:
            let name = tag
            out.append(0x3c); out.append(contentsOf: name.utf8)
            var a = pointee.properties
            while let attr = a {
                let key = String(cString: attr.pointee.name).lowercased()
                out.append(0x20); out.append(contentsOf: key.utf8)
                if let v = xmlNodeListGetString(pointee.doc, attr.pointee.children, 1) {
                    if !(booleanAttributes.contains(key) && (v.pointee == 0 || String(cString: v).lowercased() == key)) {
                        out.append(contentsOf: "=\"".utf8)
                        escape(v, &out, attribute: true)
                        out.append(0x22)
                    }
                    xmlFree(v)
                } else if attr.pointee.children != nil { out.append(contentsOf: "=\"\"".utf8) }
                a = attr.pointee.next
            }
            out.append(0x3e)
            if voidTags.contains(name), pointee.children == nil { return }
            dumpChildren(&out)
            out.append(contentsOf: "</".utf8); out.append(contentsOf: name.utf8); out.append(0x3e)
        case XML_HTML_DOCUMENT_NODE, XML_DOCUMENT_NODE: dumpChildren(&out)
        default: break
        }
    }

    func dumpChildren(_ out: inout [UInt8]) {
        let raw = isElement && (tag == "script" || tag == "style")
        var n = pointee.children
        while let x = n {
            if raw, x.pointee.type == XML_TEXT_NODE, let c = x.pointee.content { out.append(contentsOf: String(cString: c).utf8) } else { x.dump(&out) }
            n = x.pointee.next
        }
    }

    private func escape(_ content: UnsafeMutablePointer<xmlChar>?, _ out: inout [UInt8], attribute: Bool) {
        guard var p = content else { return }
        while p.pointee != 0 {
            let b = p.pointee
            switch b {
            case 0x26: out.append(contentsOf: "&amp;".utf8)
            case 0x3c where !attribute: out.append(contentsOf: "&lt;".utf8)
            case 0x3e where !attribute: out.append(contentsOf: "&gt;".utf8)
            case 0x22 where attribute: out.append(contentsOf: "&quot;".utf8)
            case 0xc2 where p[1] == 0xa0: out.append(contentsOf: "&nbsp;".utf8); p += 1
            default: out.append(b)
            }
            p += 1
        }
    }
}

private extension Array where Element == UInt8 {
    var trimmed: ArraySlice<UInt8> {
        guard let a = firstIndex(where: { $0 > 0x20 }), let z = lastIndex(where: { $0 > 0x20 }) else { return [] }
        return self[a...z]
    }
}

struct HtmlNode: Hashable {
    let doc: HtmlDoc
    let ptr: xmlNodePtr

    static func == (a: HtmlNode, b: HtmlNode) -> Bool { a.ptr == b.ptr }
    func hash(into h: inout Hasher) { h.combine(ptr) }

    private func with(_ p: xmlNodePtr) -> HtmlNode { HtmlNode(doc: doc, ptr: p) }
    var isElement: Bool { ptr.isElement }
    var name: String { ptr.tag }
    var parent: HtmlNode? { ptr.parentElement.map(with) }
    var children: [HtmlNode] { ptr.childElements.map(with) }
    var next: HtmlNode? { ptr.nextElement.map(with) }
    var previous: HtmlNode? { ptr.previousElement.map(with) }
    var siblings: [HtmlNode] { ptr.pointee.parent?.childElements.filter { $0 != ptr }.map(with) ?? [] }
    var text: String { ptr.text }
    /// nil = no such attribute.
    func attr(_ name: String) -> String? { ptr.attribute(name.lowercased()) }

    var html: String { var out: [UInt8] = []; ptr.dumpChildren(&out); return String(decoding: out, as: UTF8.self) }
    var outerHtml: String { var out: [UInt8] = []; ptr.dump(&out); return String(decoding: out, as: UTF8.self) }

    fileprivate func select(_ s: HtmlSelector) -> [HtmlNode] {
        var out: [HtmlNode] = []
        ptr.eachDescendant { if s.test(ptr, $0) { out.append(with($0)) }; return true }
        return out
    }

    fileprivate func matches(_ s: HtmlSelector) -> Bool { s.test(doc.node.ptr, ptr) }

    /// An independent copy that may be cut up.
    fileprivate var copy: HtmlNode? {
        let d = HtmlDoc(copy: self)
        return xmlDocGetRootElement(d.ptr).map { HtmlNode(doc: d, ptr: $0) }
    }

    fileprivate func remove() {
        xmlUnlinkNode(ptr)
        doc.detached.append(ptr)
    }
}

/// jsoup's selector language, matched from right to left.
final class HtmlSelector {
    typealias Test = (_ root: xmlNodePtr, _ el: xmlNodePtr) -> Bool
    struct Bad: Error { let message: String }

    let test: Test
    private init(_ test: @escaping Test) { self.test = test }

    private static let cache: NSCache<NSString, HtmlSelector> = { let c = NSCache<NSString, HtmlSelector>(); c.countLimit = 300; return c }()

    static func parse(_ text: String) throws -> HtmlSelector {
        if let hit = cache.object(forKey: text as NSString) { return hit }
        let groups = HtmlQuery.splitTop(text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !groups.isEmpty else { throw Bad(message: "空选择器") }
        let tests = try groups.map(one)
        let s = HtmlSelector(tests.count == 1 ? tests[0] : { r, e in tests.contains { $0(r, e) } })
        cache.setObject(s, forKey: text as NSString)
        return s
    }

    private static func one(_ text: String) throws -> Test {
        var p = Scanner(text)
        var left: Test?
        var comb: Character = " "
        p.skipSpace()
        if let c = p.peek, ">+~".contains(c) { left = { $0 == $1 }; comb = c; p.i += 1; p.skipSpace() }
        while p.peek != nil {
            let right = try p.compound()
            left = left.map { combine($0, comb, right) } ?? right
            let spaced = p.skipSpace()
            guard let c = p.peek else { break }
            if ">+~".contains(c) { comb = c; p.i += 1; p.skipSpace(); if p.peek == nil { throw Bad(message: text) } } else if spaced { comb = " " } else { throw Bad(message: text) }
        }
        guard let left else { throw Bad(message: text) }
        return left
    }

    private static func combine(_ left: @escaping Test, _ comb: Character, _ right: @escaping Test) -> Test {
        switch comb {
        case ">": return { r, e in right(r, e) && e != r && e.pointee.parent.map { left(r, $0) } ?? false }
        case "+": return { r, e in right(r, e) && e != r && e.previousElement.map { left(r, $0) } ?? false }
        case "~": return { r, e in
            guard right(r, e), e != r else { return false }
            var s = e.previousElement
            while let x = s { if left(r, x) { return true }; s = x.previousElement }
            return false
        }
        default: return { r, e in
            guard right(r, e), e != r else { return false }
            var p = e.pointee.parent
            while let x = p { if left(r, x) { return true }; if x == r { return false }; p = x.pointee.parent }
            return false
        }
        }
    }

    private struct Scanner {
        let c: [Character]
        var i = 0
        init(_ s: String) { c = Array(s) }
        var peek: Character? { i < c.count ? c[i] : nil }

        @discardableResult mutating func skipSpace() -> Bool {
            let from = i
            while let x = peek, x.isWhitespace { i += 1 }
            return i > from
        }

        mutating func ident() -> String {
            var out = ""
            while let x = peek {
                if x == "\\", i + 1 < c.count { out.append(c[i + 1]); i += 2; continue }
                guard x.isLetter || x.isNumber || x == "-" || x == "_" else { break }
                out.append(x); i += 1
            }
            return out
        }

        mutating func balanced(_ open: Character, _ close: Character) throws -> String {
            let from = i + 1
            var depth = 0, quote: Character?
            while let x = peek {
                if let q = quote {
                    if x == "\\" { i += 2; continue }
                    if x == q { quote = nil }
                } else if x == "\"" || x == "'" { quote = x } else if x == open { depth += 1 } else if x == close {
                    depth -= 1
                    if depth == 0 { i += 1; return String(c[from..<(i - 1)]) }
                }
                i += 1
            }
            throw Bad(message: "缺少 \(close)")
        }

        mutating func compound() throws -> Test {
            var tests: [Test] = []
            let from = i
            if peek == "*" { i += 1 } else if let x = peek, x.isLetter || x == "_" || x == "\\" {
                let name = ident().lowercased()
                tests.append { _, e in e.tag == name }
            }
            scan: while let x = peek {
                switch x {
                case "#": i += 1; let id = ident(); tests.append { _, e in e.attribute("id") == id }
                case ".": i += 1; let name = ident(); guard !name.isEmpty else { throw Bad(message: "空类名") }; tests.append { _, e in e.hasClass(name) }
                case "[": tests.append(try HtmlSelector.attribute(try balanced("[", "]")))
                case ":":
                    i += 1
                    let name = ident().lowercased()
                    tests.append(try HtmlSelector.pseudo(name, peek == "(" ? try balanced("(", ")") : nil))
                default: break scan
                }
            }
            guard i > from else { throw Bad(message: String(c)) }
            return { r, e in e.isElement && tests.allSatisfy { $0(r, e) } }
        }
    }

    private static func unquote(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count >= 2, let f = t.first, f == t.last, f == "\"" || f == "'" { return String(t.dropFirst().dropLast()) }
        return t
    }

    private static func attribute(_ raw: String) throws -> Test {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func clean(_ s: Substring) -> String {
            let n = s.trimmingCharacters(in: .whitespaces).lowercased()
            return n.hasPrefix("abs:") ? String(n.dropFirst(4)) : n
        }
        guard let eq = body.firstIndex(of: "=") else {
            guard !body.isEmpty else { throw Bad(message: "空属性选择器") }
            if body.hasPrefix("^") {
                let prefix = clean(body.dropFirst())
                return { _, e in
                    var a = e.pointee.properties
                    while let x = a { if String(cString: x.pointee.name).lowercased().hasPrefix(prefix) { return true }; a = x.pointee.next }
                    return false
                }
            }
            let name = clean(body[...])
            return { _, e in e.attribute(name) != nil }
        }
        var end = eq
        var op: Character = "="
        if eq > body.startIndex, case let p = body[body.index(before: eq)], "!^$*~|".contains(p) { op = p; end = body.index(before: eq) }
        let name = clean(body[..<end])
        var value = unquote(String(body[body.index(after: eq)...]))
        if op == "~" {
            let rx = try NSRegularExpression(pattern: value)
            return { _, e in e.attribute(name).map { rx.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ?? false }
        }
        value = value.trimmingCharacters(in: .whitespaces).lowercased()
        switch op {
        case "!": return { _, e in e.attribute(name)?.trimmingCharacters(in: .whitespaces).lowercased() != value }
        case "^": return { _, e in e.attribute(name)?.lowercased().hasPrefix(value) ?? false }
        case "$": return { _, e in e.attribute(name)?.lowercased().hasSuffix(value) ?? false }
        case "*": return { _, e in e.attribute(name)?.lowercased().contains(value) ?? false }
        case "|": return { _, e in e.attribute(name).map { let v = $0.lowercased(); return v == value || v.hasPrefix(value + "-") } ?? false }
        default: return { _, e in e.attribute(name)?.trimmingCharacters(in: .whitespaces).lowercased() == value }
        }
    }

    private static func pseudo(_ name: String, _ arg: String?) throws -> Test {
        func need() throws -> String { if let arg { return arg }; throw Bad(message: ":\(name) 需要参数") }
        func number() throws -> Int { if let n = Int(try need().trimmingCharacters(in: .whitespaces)) { return n }; throw Bad(message: ":\(name) 只支持数字") }
        func fold(_ s: String) -> String { s.lowercased() }
        func regex() throws -> NSRegularExpression { try NSRegularExpression(pattern: unquote(try need())) }
        func found(_ rx: NSRegularExpression, _ s: String) -> Bool { rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        /// 0-based index among the siblings; `same` only counts elements with the same tag.
        func index(_ e: xmlNodePtr, same: Bool, fromEnd: Bool) -> Int {
            let tag = same ? e.tag : ""
            var n = 0, s = fromEnd ? e.nextElement : e.previousElement
            while let x = s { if !same || x.tag == tag { n += 1 }; s = fromEnd ? x.nextElement : x.previousElement }
            return n
        }
        func nth(same: Bool, fromEnd: Bool) throws -> Test {
            let t = try need().replacingOccurrences(of: " ", with: "").lowercased()
            var a = 0, b = 0
            if t == "odd" { a = 2; b = 1 } else if t == "even" { a = 2 } else if let n = t.firstIndex(of: "n") {
                let head = String(t[..<n]), tail = String(t[t.index(after: n)...])
                guard let x = head.isEmpty || head == "+" ? 1 : head == "-" ? -1 : Int(head), let y = tail.isEmpty ? 0 : Int(tail) else { throw Bad(message: ":\(name)(\(t))") }
                a = x; b = y
            } else if let y = Int(t) { b = y } else { throw Bad(message: ":\(name)(\(t))") }
            return { _, e in
                let d = index(e, same: same, fromEnd: fromEnd) + 1 - b
                return a == 0 ? d == 0 : d % a == 0 && d / a >= 0
            }
        }
        switch name {
        case "first-child": return { _, e in e.previousElement == nil }
        case "last-child": return { _, e in e.nextElement == nil }
        case "only-child": return { _, e in e.previousElement == nil && e.nextElement == nil }
        case "first-of-type": return { _, e in index(e, same: true, fromEnd: false) == 0 }
        case "last-of-type": return { _, e in index(e, same: true, fromEnd: true) == 0 }
        case "only-of-type": return { _, e in index(e, same: true, fromEnd: false) == 0 && index(e, same: true, fromEnd: true) == 0 }
        case "nth-child": return try nth(same: false, fromEnd: false)
        case "nth-last-child": return try nth(same: false, fromEnd: true)
        case "nth-of-type": return try nth(same: true, fromEnd: false)
        case "nth-last-of-type": return try nth(same: true, fromEnd: true)
        case "eq": let n = try number(); return { _, e in n < 0 ? index(e, same: false, fromEnd: true) == -n - 1 : index(e, same: false, fromEnd: false) == n }
        case "lt": let n = try number(); return { _, e in index(e, same: false, fromEnd: false) < n }
        case "gt": let n = try number(); return { _, e in index(e, same: false, fromEnd: false) > n }
        case "first": return { _, e in e.previousElement == nil }
        case "last": return { _, e in e.nextElement == nil }
        case "root": return { _, e in e.parentElement == nil }
        case "empty": return { _, e in
            var n = e.pointee.children
            while let x = n {
                if x.isElement { return false }
                if x.pointee.type == XML_TEXT_NODE, let c = x.pointee.content, !String(cString: c).allSatisfy(\.isWhitespace) { return false }
                n = x.pointee.next
            }
            return true
        }
        case "has":
            let s = try parse(try need())
            return { _, e in
                var hit = false
                e.eachDescendant { if s.test(e, $0) { hit = true }; return !hit }
                return hit
            }
        case "not": let s = try parse(try need()); return { r, e in !s.test(r, e) }
        case "is", "where": let s = try parse(try need()); return { r, e in s.test(r, e) }
        case "contains": let t = fold(unquote(try need())); return { _, e in fold(e.text).contains(t) }
        case "containsown": let t = fold(unquote(try need())); return { _, e in fold(e.ownText).contains(t) }
        case "containsdata": let t = fold(unquote(try need())); return { _, e in var o: [UInt8] = []; e.dumpChildren(&o); return fold(String(decoding: o, as: UTF8.self)).contains(t) }
        case "matches": let rx = try regex(); return { _, e in found(rx, e.text) }
        case "matchesown": let rx = try regex(); return { _, e in found(rx, e.ownText) }
        default: throw Bad(message: "不支持的伪类 :\(name)")
        }
    }
}

/// jQuery-flavoured selection: positional pseudos (`:eq :first :last :gt :lt :even :odd`) count inside the matched set.
enum HtmlQuery {
    private static let positional = try! NSRegularExpression(pattern: #":(eq|gt|lt|nth)\(\s*(-?\d+)\s*\)|:(first|last|even|odd)(?![\w-])"#)
    private static let quoted = try! NSRegularExpression(pattern: #":(contains|containsOwn)\(\s*(['"])(.*?)\2\s*\)"#)
    private static let drop = try! NSRegularExpression(pattern: #":(visible|enabled|selected)(?![\w-])"#)

    static func select(_ roots: [HtmlNode], _ css: String) -> [HtmlNode] {
        func all(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }
        var clean = css.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.contains(":") {
            clean = quoted.stringByReplacingMatches(in: clean, range: all(clean), withTemplate: ":$1($3)")
            clean = drop.stringByReplacingMatches(in: clean, range: all(clean), withTemplate: "")
        }
        guard !clean.isEmpty else { return [] }
        var out: [HtmlNode] = [], seen = Set<xmlNodePtr>()
        for g in splitTop(clean) {
            let t = g.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { for n in (try? group(roots, t)) ?? [] where seen.insert(n.ptr).inserted { out.append(n) } }
        }
        return out
    }

    /// Commas outside brackets and quotes.
    static func splitTop(_ s: String) -> [String] {
        var out: [String] = [], cur = "", depth = 0, quote: Character?
        for ch in s {
            if let q = quote { if ch == q { quote = nil } } else if ch == "\"" || ch == "'" { quote = ch } else if ch == "(" || ch == "[" { depth += 1 } else if ch == ")" || ch == "]" { depth -= 1 } else if ch == ",", depth == 0 { out.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        out.append(cur)
        return out
    }

    /// First positional pseudo that is not inside `:has(…)` / `:not(…)` / an attribute.
    private static func position(_ s: NSString) -> NSTextCheckingResult? {
        positional.matches(in: s as String, range: NSRange(location: 0, length: s.length)).first { m in
            var depth = 0
            for i in 0..<m.range.location {
                switch s.character(at: i) { case 0x28, 0x5b: depth += 1; case 0x29, 0x5d: depth -= 1; default: break }
            }
            return depth == 0
        }
    }

    private static func group(_ roots: [HtmlNode], _ selector: String) throws -> [HtmlNode] {
        var ctx = roots, rest = selector as NSString, own = false
        while true {
            let m = position(rest)
            ctx = try apply(ctx, m.map { rest.substring(to: $0.range.location) } ?? rest as String, own)
            guard let m else { return ctx }
            ctx = pick(ctx, m, rest)
            rest = rest.substring(from: NSMaxRange(m.range)) as NSString
            let tail = rest as String
            guard let c = tail.first(where: { !$0.isWhitespace }) else { return ctx }
            own = !(tail.first!.isWhitespace || ">+~".contains(c))
        }
    }

    private static func pick(_ list: [HtmlNode], _ m: NSTextCheckingResult, _ s: NSString) -> [HtmlNode] {
        func part(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : s.substring(with: m.range(at: i)) }
        let n = Int(part(2)) ?? 0, at = n < 0 ? list.count + n : n
        switch part(1).isEmpty ? part(3) : part(1) {
        case "eq", "nth": return list.indices.contains(at) ? [list[at]] : []
        case "gt": return Array(list.dropFirst(max(0, at + 1)))
        case "lt": return Array(list.prefix(max(0, at)))
        case "first": return Array(list.prefix(1))
        case "last": return Array(list.suffix(1))
        case "even": return list.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        default: return list.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        }
    }

    /// `own`: `part` continues the compound of the current elements (`li:eq(0).on a`).
    private static func apply(_ ctx: [HtmlNode], _ part: String, _ own: Bool) throws -> [HtmlNode] {
        let body = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return own ? ctx : try descend(ctx, "*") }
        guard own else { return try descend(ctx, body) }
        var depth = 0
        let end = part.firstIndex { c in
            if c == "(" || c == "[" { depth += 1 } else if c == ")" || c == "]" { depth -= 1 }
            return depth == 0 && (c.isWhitespace || ">+~".contains(c))
        } ?? part.endIndex
        let s = try HtmlSelector.parse(String(part[..<end]))
        let kept = ctx.filter { $0.matches(s) }, tail = part[end...].trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? kept : try descend(kept, tail)
    }

    private static func descend(_ ctx: [HtmlNode], _ part: String) throws -> [HtmlNode] {
        var out: [HtmlNode] = [], seen = Set<xmlNodePtr>()
        func add(_ list: [HtmlNode]) { for n in list where seen.insert(n.ptr).inserted { out.append(n) } }
        if let c = part.first, c == "+" || c == "~" {
            let body = part.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            let cut = body.firstIndex { $0.isWhitespace || $0 == ">" } ?? body.endIndex
            let s = try HtmlSelector.parse(String(body[..<cut])), tail = body[cut...].trimmingCharacters(in: .whitespacesAndNewlines)
            for el in ctx {
                var sibs: [HtmlNode] = [], n = el.next
                while let x = n { sibs.append(x); n = c == "+" ? nil : x.next }
                let hit = sibs.filter { $0.matches(s) }
                add(tail.isEmpty ? hit : try descend(hit, tail))
            }
            return out
        }
        let s = try HtmlSelector.parse(part)
        for el in ctx { add(el.select(s)) }
        return out
    }

    enum Found { case node(HtmlNode), text(String) }

    /// Below an element, absolute paths start at that element.
    static func xpath(_ el: HtmlNode, _ q: String) -> [Found] {
        var expr = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if el.isElement {
            expr = expr.components(separatedBy: "|").map { p in
                let t = p.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("/") ? "." + t : p
            }.joined(separator: "|")
        }
        guard let ctx = xmlXPathNewContext(el.doc.ptr) else { return [] }
        defer { xmlXPathFreeContext(ctx) }
        ctx.pointee.node = el.ptr
        guard let obj = xmlXPathEvalExpression(expr, ctx) else { return [] }
        defer { xmlXPathFreeObject(obj) }
        switch obj.pointee.type {
        case XPATH_NODESET:
            guard let set = obj.pointee.nodesetval else { return [] }
            return (0..<Int(set.pointee.nodeNr)).compactMap { i in
                guard let n = set.pointee.nodeTab[i] else { return nil }
                if n.isElement { return .node(HtmlNode(doc: el.doc, ptr: n)) }
                guard n.pointee.type != XML_HTML_DOCUMENT_NODE, n.pointee.type != XML_NAMESPACE_DECL, let c = xmlNodeGetContent(n) else { return nil }
                defer { xmlFree(c) }
                return .text(String(cString: c))
            }
        case XPATH_STRING: return [.text(obj.pointee.stringval.map { String(cString: $0) } ?? "")]
        case XPATH_NUMBER:
            let v = obj.pointee.floatval
            return [.text(v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v))]
        case XPATH_BOOLEAN: return [.text(obj.pointee.boolval != 0 ? "true" : "false")]
        default: return []
        }
    }
}

/// drpy / Hiker rules: `a&&b&&Text`, `a&&href||data-src`, `.x--.ad&&Text`, `li:eq(1)`, `Html`.
enum PdfRule {
    private static let noIndex = try! NSRegularExpression(pattern: ":eq|:lt|:gt|:first|:last|:not|:even|:odd|:has|:contains|:matches|:empty|^body$|^#")
    private static let styleURL = try! NSRegularExpression(pattern: #"url\((.*?)\)"#, options: .dotMatchesLineSeparators)
    private static let linkAttr = try! NSRegularExpression(pattern: "(url|src|href|-original|-src|-play|-url|style)$|^(data-|url-|src-)", options: .caseInsensitive)
    private static let keepScheme = try! NSRegularExpression(pattern: "^(ftp|magnet|thunder|ws|data|javascript):", options: .caseInsensitive)

    private static func hit(_ rx: NSRegularExpression, _ s: String) -> Bool { rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func one(_ doc: HtmlNode, _ rule: String, _ base: String = "") -> String {
        for r in alternatives(rule) {
            let v = single(doc, trim(r), base)
            if !v.isEmpty { return v }
        }
        return ""
    }

    static func list(_ doc: HtmlNode, _ rule: String) -> [String] {
        for r in alternatives(rule) {
            let els = elements(doc, trim(r), first: false)
            if !els.isEmpty { return els.map(\.outerHtml) }
        }
        return []
    }

    static func pairs(_ doc: HtmlNode, _ rule: String, _ text: String, _ url: String, _ base: String) -> [String] {
        elements(doc, trim(rule), first: false).map { el in
            let d = HtmlDoc(el.outerHtml).node
            return trim(one(d, text)) + "$" + one(d, url, base)
        }
    }

    /// `x&&Text||y&&Text` are whole alternatives; `x&&href||src` only alternates the attribute.
    private static func alternatives(_ rule: String) -> [String] {
        let parts = rule.components(separatedBy: "||")
        if parts.count == 1 { return parts }
        var out: [String] = []
        for p in parts {
            if let last = out.last, !p.contains("&&"), last.contains("&&") { out[out.count - 1] = last + "||" + p } else { out.append(p) }
        }
        return out
    }

    private static func single(_ doc: HtmlNode, _ rule: String, _ base: String) -> String {
        if rule.isEmpty { return "" }
        if rule == "body&&Text" || rule == "Text" { return doc.text }
        if rule == "body&&Html" || rule == "Html" { return doc.html }
        let cut = rule.range(of: "&&", options: .backwards)
        let option = cut.map { trim(String(rule[$0.upperBound...])) } ?? ""
        let els = elements(doc, cut.map { String(rule[..<$0.lowerBound]) } ?? rule, first: true)
        if els.isEmpty { return "" }
        switch option {
        case "": return els.map(\.outerHtml).joined(separator: "\n")
        case "Text": return els.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        case "Html": return els.map(\.html).joined(separator: "\n")
        default:
            for name in option.components(separatedBy: "||") {
                let v = attr(els, trim(name), base)
                if !v.isEmpty { return v }
            }
            return ""
        }
    }

    private static func attr(_ els: [HtmlNode], _ name: String, _ base: String) -> String {
        var v = els.lazy.compactMap { $0.attr(name) }.first ?? ""
        if name.lowercased().contains("style"), v.contains("url("), let m = styleURL.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)), let r = Range(m.range(at: 1), in: v) {
            v = trim(String(v[r])).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        if !v.isEmpty, !base.isEmpty, hit(linkAttr, name), !hit(keepScheme, v) {
            if !v.hasPrefix("/"), let r = v.range(of: "http") { v = String(v[r.lowerBound...]) } else { v = TVBoxUrl.join(base, v) }
        }
        return v
    }

    private static func elements(_ doc: HtmlNode, _ rule: String, first: Bool) -> [HtmlNode] {
        let segs = rule.components(separatedBy: "&&").map(trim).filter { !$0.isEmpty }
        var ctx = [doc]
        for (i, seg) in segs.enumerated() {
            let bits = seg.components(separatedBy: "--")
            var css = trim(bits[0])
            let indexed = hit(noIndex, css.components(separatedBy: " ").last ?? css)
            if !indexed, first || i < segs.count - 1 { css += ":eq(0)" }
            ctx = HtmlQuery.select(ctx, css)
            if ctx.isEmpty { return [] }
            let drop = bits.dropFirst().map(trim).filter { !$0.isEmpty }
            if !drop.isEmpty {
                ctx = ctx.compactMap { el in
                    guard let c = el.copy else { return nil }
                    for d in drop { HtmlQuery.select([c], d).forEach { $0.remove() } }
                    return c
                }
            }
        }
        return ctx
    }
}
