import Foundation

/// Small pieces the runtimes share.
enum RT {
    // MARK: JSON

    static func quote(_ s: String) -> String { JSONObject.quote(s) }

    static func json(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options: [.withoutEscapingSlashes]) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }

    private static let loneSurrogate = TVBoxRegex(#"\\u[dD][89abAB][0-9a-fA-F]{2}(?!\\u[dD][c-fC-F][0-9a-fA-F]{2})|(?<!\\u[dD][89abAB][0-9a-fA-F]{2})\\u[dD][c-fC-F][0-9a-fA-F]{2}"#)

    /// Strict JSON; half surrogate pairs (legal in JavaScript strings) become U+FFFD.
    static func object(_ text: String) -> [String: Any]? {
        if let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return o }
        guard text.containsIgnoringCase("\\ud") else { return nil }
        let fixed = loneSurrogate.replace(text) { _ in "\\ufffd" }
        return (try? JSONSerialization.jsonObject(with: Data(fixed.utf8))) as? [String: Any]
    }

    // MARK: Text

    /// `a=b&c=d` with percent decoding and `+` as a space; undecodable text stays as it is.
    static func query(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        func d(_ s: Substring) -> String { let t = s.replacingOccurrences(of: "+", with: " "); return t.removingPercentEncoding ?? t }
        for p in raw.split(separator: "&") {
            if let i = p.firstIndex(of: "=") { out[d(p[..<i])] = d(p[p.index(after: i)...]) } else { out[d(p)] = "" }
        }
        return out
    }

    static func gbkEncode(_ s: String) -> Data { s.data(using: TextDecode.gb18030, allowLossyConversion: true) ?? Data() }

    /// Undecodable bytes become U+FFFD.
    static func gbkDecode(_ d: Data) -> String {
        let e = TextDecode.gb18030
        if let s = String(data: d, encoding: e) { return s }
        var out = "", b = [UInt8](d)[...]
        while let c = b.first {
            if c < 0x80 { out.unicodeScalars.append(Unicode.Scalar(c)); b = b.dropFirst(); continue }
            let n = [2, 4].first { b.count >= $0 && String(data: Data(b.prefix($0)), encoding: e) != nil }
            if let n { out += String(data: Data(b.prefix(n)), encoding: e) ?? ""; b = b.dropFirst(n) } else { out += "\u{FFFD}"; b = b.dropFirst() }
        }
        return out
    }

    /// Standard or URL-safe alphabet, white space and missing padding accepted.
    static func base64(_ s: String) -> Data {
        if let d = Data(base64Encoded: s) { return d }
        var t = s.filter { !$0.isWhitespace && $0 != "=" }
        if t.contains("-") || t.contains("_") { t = t.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") }
        return Data(base64Encoded: t + String(repeating: "=", count: (4 - t.utf8.count % 4) % 4)) ?? Data()
    }

    // MARK: Threads

    private final class Box<T>: @unchecked Sendable { var r: Result<T, Error>? }

    /// Runs async work from a thread of its own (never from the cooperative pool).
    static func wait<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = Box<T>(), sem = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.r = .success(try await body()) } catch { box.r = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try box.r!.get()
    }
}
