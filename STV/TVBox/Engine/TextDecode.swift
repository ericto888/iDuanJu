import Foundation

/// Response text by forced charset, BOM, `Content-Type`, `<meta>` / XML declaration, then UTF-8 or GB18030.
enum TextDecode {
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    private static let contentCharset = TVBoxRegex("charset=[\"']?([\\w-]+)", .caseInsensitive)
    private static let meta = TVBoxRegex("<meta[^>]+charset=[\"']?\\s*([\\w-]+)", .caseInsensitive)
    private static let xml = TVBoxRegex("^\\s*<\\?xml[^>]+encoding=[\"']([\\w-]+)", .caseInsensitive)

    static func charset(_ name: String?) -> String.Encoding? {
        guard let n = name?.lowercased(), !n.isEmpty else { return nil }
        switch n {
        case "utf-8", "utf8": return .utf8
        case "gb2312", "gbk", "gb18030", "x-gbk": return gb18030
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(n as CFString)
            return cf == kCFStringEncodingInvalidId ? nil : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    static func decode(_ data: Data, _ contentType: String? = nil, _ forced: String? = nil) -> String {
        if let e = charset(forced) { return lossy(data, e) }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if let ct = contentType, let e = charset(contentCharset.match(ct)?.groups[1]) { return lossy(data, e) }
        let head = String(String.UnicodeScalarView(data.prefix(2048).map { UnicodeScalar($0) }))
        if let e = charset((meta.match(head) ?? xml.match(head))?.groups[1]) { return lossy(data, e) }
        return TVBoxDecoder.text([UInt8](data))
    }

    /// Never fails: a declared charset that does not fit is applied with replacement characters.
    static func lossy(_ data: Data, _ e: String.Encoding) -> String {
        if e == .utf8 { return String(decoding: data, as: UTF8.self) }
        if let s = String(data: data, encoding: e) { return s }
        var out: NSString?
        NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: [NSNumber(value: e.rawValue)], .useOnlySuggestedEncodingsKey: true, .allowLossyKey: true,
        ], convertedString: &out, usedLossyConversion: nil)
        return out.map { $0 as String } ?? String(decoding: data, as: UTF8.self)
    }
}

extension NetResponse {
    func text(_ charset: String? = nil) -> String { TextDecode.decode(body, header("Content-Type"), charset) }
}

extension TVBoxHttp {
    /// Blocking GET of a text; anything but 2xx is an error.
    func text(_ url: String, headers: [String: String] = [:], timeoutMs: Int = 15_000, tag: AnyObject? = nil) throws -> String {
        let r = try execute(NetRequest(url: url, headers: headers, timeoutMs: timeoutMs, tag: tag))
        if !r.ok { throw TVBoxIOError("HTTP \(r.code) · \(TVBoxUrl.host(url))") }
        return r.text()
    }
}
