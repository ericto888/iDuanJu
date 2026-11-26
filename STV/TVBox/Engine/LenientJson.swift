import Foundation

/// Insertion-ordered JSON object (org.json semantics): `ext` objects reach spiders as text in the order their author wrote.
/// Values are `JSONObject`, `[Any]`, `String`, `Int`, `Double`, `Bool` or `NSNull`, so the `J` accessors work on them.
final class JSONObject: CustomStringConvertible {
    private(set) var keys: [String] = []
    private var map: [String: Any] = [:]

    init() {}

    /// Foundation dictionaries have no order: keys are sorted to stay deterministic.
    init(_ d: [String: Any]) {
        for k in d.keys.sorted() { put(k, JSONObject.wrap(d[k])) }
    }

    subscript(_ k: String) -> Any? { map[k] }
    func opt(_ k: String) -> Any? { map[k] }
    func has(_ k: String) -> Bool { map[k] != nil }
    func isNull(_ k: String) -> Bool { map[k] == nil || map[k] is NSNull }
    func optJSONObject(_ k: String) -> JSONObject? { map[k] as? JSONObject }
    func optJSONArray(_ k: String) -> [Any]? { map[k] as? [Any] }
    func string(_ k: String) -> String { J.str(map[k]) }

    /// nil removes the key.
    @discardableResult
    func put(_ k: String, _ v: Any?) -> JSONObject {
        guard let v else {
            if map.removeValue(forKey: k) != nil { keys.removeAll { $0 == k } }
            return self
        }
        if map.updateValue(v, forKey: k) == nil { keys.append(k) }
        return self
    }

    func strings() -> [String: String] {
        var out: [String: String] = [:]
        for k in keys { out[k] = J.str(map[k]) }
        return out
    }

    /// Plain Foundation value (for `JSONSerialization` and friends).
    var dictionary: [String: Any] { map.mapValues { JSONObject.unwrap($0) } }

    func toString() -> String { JSONObject.text(self) }
    var description: String { toString() }

    static func wrap(_ v: Any?) -> Any {
        switch v {
        case let d as [String: Any]: return JSONObject(d)
        case let a as [Any]: return a.map { wrap($0) }
        case let x?: return x
        default: return NSNull()
        }
    }

    static func unwrap(_ v: Any) -> Any {
        switch v {
        case let o as JSONObject: return o.dictionary
        case let a as [Any]: return a.map { unwrap($0) }
        default: return v
        }
    }

    /// Compact JSON of any value.
    static func text(_ v: Any?) -> String {
        var out = ""
        write(v, &out)
        return out
    }

    static func quote(_ s: String) -> String {
        var out = ""
        quote(s, &out)
        return out
    }

    private static func write(_ v: Any?, _ out: inout String) {
        guard let v, !(v is NSNull) else { out += "null"; return }
        switch v {
        case let o as JSONObject:
            out += "{"
            for (i, k) in o.keys.enumerated() {
                if i > 0 { out += "," }
                quote(k, &out)
                out += ":"
                write(o.map[k], &out)
            }
            out += "}"
        case let s as String:
            quote(s, &out)
        case let d as [String: Any]:
            write(JSONObject(d), &out)
        case let a as [Any]:
            out += "["
            for (i, x) in a.enumerated() {
                if i > 0 { out += "," }
                write(x, &out)
            }
            out += "]"
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { out += n.boolValue ? "true" : "false" }
            else if !n.doubleValue.isFinite { out += "null" }
            else { out += n.stringValue }
        default:
            quote(String(describing: v), &out)
        }
    }

    private static func quote(_ s: String, _ out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }
}

/// JSON as TVBox configs are really written: `//`, `/* */` and `#` comments, single quotes, bare keys and values, trailing or
/// missing commas, raw line breaks inside strings, a BOM, unknown escapes.
enum LenientJson {
    struct Malformed: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func parse(_ text: String) throws -> Any {
        var p = Parser(text)
        return try p.root()
    }

    static func objectOrNull(_ text: String) -> JSONObject? { (try? parse(text)) as? JSONObject }
    static func arrayOrNull(_ text: String) -> [Any]? { (try? parse(text)) as? [Any] }

    /// Works on UTF-8 bytes: every structural character is ASCII.
    private struct Parser {
        private let s: [UInt8]
        private var i = 0
        private var depth = 0

        init(_ text: String) { s = Array(text.utf8) }

        mutating func root() throws -> Any {
            skip()
            if i >= s.count { throw Malformed("内容为空") }
            return try value()
        }

        private func fail(_ what: String) -> Malformed {
            var line = 1
            for k in 0..<min(i, s.count) where s[k] == 0x0A { line += 1 }
            return Malformed("JSON 第 \(line) 行：\(what)")
        }

        private func at(_ o: Int) -> UInt8 { i + o < s.count ? s[i + o] : 0 }

        private mutating func skip() {
            while i < s.count {
                let c = s[i]
                if c <= 0x20 { i += 1 }
                else if c == 0x23 { line() }                                                // #
                else if c == 0x2F && at(1) == 0x2F { line() }                               // //
                else if c == 0x2F && at(1) == 0x2A { i = end(of: 0x2A, 0x2F, from: i + 2) } // /* */
                else if c == 0xEF && at(1) == 0xBB && at(2) == 0xBF { i += 3 }              // BOM
                else if c == 0xC2 && at(1) == 0xA0 { i += 2 }                               // NBSP
                else if c == 0xE2 && at(1) == 0x80 && at(2) == 0x8B { i += 3 }              // ZWSP
                else { return }
            }
        }

        private func end(of a: UInt8, _ b: UInt8, from: Int) -> Int {
            var k = from
            while k + 1 < s.count {
                if s[k] == a && s[k + 1] == b { return k + 2 }
                k += 1
            }
            return s.count
        }

        private mutating func line() {
            while i < s.count && s[i] != 0x0A { i += 1 }
            if i < s.count { i += 1 }
        }

        private mutating func value() throws -> Any {
            skip()
            if i >= s.count { throw fail("内容不完整") }
            depth += 1
            if depth > 256 { throw fail("嵌套过深") }
            defer { depth -= 1 }
            let c = s[i]
            switch c {
            case 0x7B: return try obj()
            case 0x5B: return try arr()
            case 0x22, 0x27: return try str(c)
            default: return try bare()
            }
        }

        private mutating func obj() throws -> JSONObject {
            let out = JSONObject()
            i += 1
            while true {
                skip()
                if i >= s.count { throw fail("对象没有结束") }
                let c = s[i]
                if c == 0x7D { i += 1; return out }
                if c == 0x2C || c == 0x3B { i += 1; continue }
                let key = try (c == 0x22 || c == 0x27) ? str(c) : bareKey()
                skip()
                if i >= s.count || (s[i] != 0x3A && s[i] != 0x3D) { throw fail("键 \(key) 后面缺少冒号") }
                i += 1
                skip()
                if i < s.count && (s[i] == 0x2C || s[i] == 0x7D) { out.put(key, NSNull()); continue }
                out.put(key, try value())
            }
        }

        private mutating func arr() throws -> [Any] {
            var out: [Any] = []
            i += 1
            while true {
                skip()
                if i >= s.count { throw fail("数组没有结束") }
                switch s[i] {
                case 0x5D: i += 1; return out
                case 0x2C: i += 1
                case 0x7D: throw fail("数组没有结束")
                default: out.append(try value())
                }
            }
        }

        private func slice(_ a: Int, _ b: Int) -> String {
            String(decoding: s[a..<b], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private mutating func bareKey() throws -> String {
            let start = i
            loop: while i < s.count {
                switch s[i] {
                case 0x3A, 0x3D, 0x2C, 0x7D, 0x7B, 0x0A: break loop
                default: i += 1
                }
            }
            if i == start { throw fail("键名为空") }
            return slice(start, i)
        }

        private mutating func bare() throws -> Any {
            let start = i
            while i < s.count {
                let c = s[i]
                if c == 0x2C || c == 0x7D || c == 0x5D || c == 0x0A || c == 0x0D { break }
                if c == 0x2F && at(1) == 0x2A { break }
                if c == 0x2F && at(1) == 0x2F && i > start && s[i - 1] != 0x3A { break }
                i += 1
            }
            let t = slice(start, i)
            switch t {
            case "": throw fail("缺少值")
            case "true", "True": return true
            case "false", "False": return false
            case "null", "None", "undefined": return NSNull()
            default: return number(t) ?? t
            }
        }

        private func number(_ t: String) -> Any? {
            guard let c = t.utf8.first, (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E else { return nil }
            if t.hasPrefix("0x") || t.hasPrefix("0X") { return Int(t.dropFirst(2), radix: 16) }
            let n = t.hasPrefix("+") ? String(t.dropFirst()) : t
            if let v = Int(n) { return v }
            guard n.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x65 || $0 == 0x45 || $0 == 0x2B || $0 == 0x2D }),
                  let d = Double(n), d.isFinite else { return nil }
            return d
        }

        private func hex(_ from: Int, _ n: Int) -> UInt32? {
            guard from + n <= s.count else { return nil }
            var v: UInt32 = 0
            for k in from..<(from + n) {
                switch s[k] {
                case 0x30...0x39: v = v << 4 | UInt32(s[k] - 0x30)
                case 0x41...0x46: v = v << 4 | UInt32(s[k] - 0x37)
                case 0x61...0x66: v = v << 4 | UInt32(s[k] - 0x57)
                default: return nil
                }
            }
            return v
        }

        private mutating func str(_ quote: UInt8) throws -> String {
            var out: [UInt8] = []
            i += 1
            while i < s.count {
                let from = i
                while i < s.count && s[i] != quote && s[i] != 0x5C { i += 1 }
                if i > from { out.append(contentsOf: s[from..<i]) }
                if i >= s.count { break }
                if s[i] == quote {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                i += 1
                if i >= s.count { break }
                let e = s[i]
                i += 1
                switch e {
                case 0x6E: out.append(0x0A)
                case 0x74: out.append(0x09)
                case 0x72: out.append(0x0D)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x30: out.append(0x00)
                case 0x75: unicode(&out)
                case 0x78:
                    if let v = hex(i, 2), let u = UnicodeScalar(v) { append(u, &out); i += 2 } else { out.append(0x5C); out.append(0x78) }
                case 0x0A: break
                case 0x0D: if i < s.count && s[i] == 0x0A { i += 1 }
                case 0x22, 0x27, 0x5C, 0x2F, 0x60: out.append(e)
                // unknown escape: keep both characters (regex rules are often written with a single backslash)
                default: out.append(0x5C); out.append(e)
                }
            }
            throw fail("字符串没有结束")
        }

        /// `\uXXXX`, joining surrogate pairs.
        private mutating func unicode(_ out: inout [UInt8]) {
            guard let v = hex(i, 4) else { out.append(0x5C); out.append(0x75); return }
            i += 4
            if v >= 0xD800 && v < 0xDC00, at(0) == 0x5C, at(1) == 0x75, let low = hex(i + 2, 4), low >= 0xDC00, low < 0xE000,
               let u = UnicodeScalar(0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)) {
                i += 6
                append(u, &out)
                return
            }
            append(UnicodeScalar(v) ?? "\u{FFFD}", &out)
        }

        private func append(_ u: UnicodeScalar, _ out: inout [UInt8]) { out.append(contentsOf: Array(String(Character(u)).utf8)) }
    }
}
