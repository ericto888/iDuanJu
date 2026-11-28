import Foundation
import UIKit
import CoreGraphics

/// Host-side content rule applied to every plugin / 采集站 result (plugins cannot opt out):
/// anything tagged or titled as involving minors is dropped.
enum ContentFilter {
    static let cjk = ["未成年", "幼女", "幼童", "幼儿", "幼児", "儿童", "兒童", "萝莉", "蘿莉", "ロリ", "ショタ", "正太", "小学生", "小學生",
                      "中学生", "中學生", "初中", "女子中学", "女子小学", "童女", "炼铜", "煉銅", "女高中生", "高中生", "女子校生", "女子高生", "女子中学生", "学生妹", "學生妹", "JK制服"]
    static let latin = ["loli", "lolis", "lolicon", "shota", "shotacon", "toddler", "toddlers", "underage", "under age", "preteen", "pre teen",
                        "child", "children", "kid", "kids", "minor", "minors", "jailbait", "elementary school", "middle school", "junior high",
                        "schoolgirl", "schoolgirls", "school girl", "school girls", "schoolboy", "school boy", "jk", "jc", "teen", "teens", "age regression", "high school girl", "highschool girl", "joshikousei", "joshi kousei", "jogakusei", "jogakuin", "joshikou", "joshi chuugakusei", "little girl", "little boy"]
    private static let latinRegex: NSRegularExpression = {
        let alt = latin.map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }.joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?<![a-z0-9])(" + alt + ")(?![a-z0-9])", options: [.caseInsensitive])
    }()

    static func isBlocked(_ texts: [String]) -> Bool {
        for t in texts where !t.isEmpty {
            let s = t.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            if cjk.contains(where: { s.localizedCaseInsensitiveContains($0) }) { return true }
            if latinRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { return true }
        }
        return false
    }
}

/// Dynamic image CDN cache, scoped to one plugin and learned only from successful responses
/// fetched from that plugin's explicitly authorized HTTP origins. It never expands host.http policy.
enum PluginMediaDomainCache {
    private static let lock = NSLock()
    private static let keyPrefix = "stv.plugin.learnedImageDomains."
    private static let ttl: TimeInterval = 24 * 60 * 60
    private static let maxDomains = 64
    private static var generations: [String: UInt64] = [:]
    /// HTTPS hosts seen in successful, authorized source responses. They are
    /// candidates only; a provider must later classify an exact URL as an image.
    private static var observedHosts: [String: [String: TimeInterval]] = [:]
    private struct EncryptedPayload {
        let sourceURL: URL
        let sourcePolicy: DomainPolicy
        let generation: UInt64
        let expiresAt: TimeInterval
        let bytes: Data
    }
    /// Encoded payload fragments from successful authorized responses. A decrypt result
    /// is inspected only when its exact ciphertext bytes came from one of these responses.
    private static var encryptedPayloads: [String: [EncryptedPayload]] = [:]

    static func generation(pluginID: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generations[pluginID, default: 0]
    }

    static func domains(pluginID: String, now: Date = Date()) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let key = keyPrefix + pluginID
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        let valid = stored.filter { $0.value > now.timeIntervalSince1970 }
        if valid.count != stored.count { UserDefaults.standard.set(valid, forKey: key) }
        return valid.keys.sorted()
    }

    /// Short-lived candidates may authorize a redirect only when the redirect
    /// originates from an already-authorized image request.
    static func candidates(pluginID: String, now: Date = Date()) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let timestamp = now.timeIntervalSince1970
        let valid = observedHosts[pluginID, default: [:]].filter { $0.value > timestamp }
        observedHosts[pluginID] = valid
        return Set(valid.keys)
    }

    static func clear(pluginID: String) {
        lock.lock(); defer { lock.unlock() }
        generations[pluginID, default: 0] &+= 1
        observedHosts.removeValue(forKey: pluginID)
        encryptedPayloads.removeValue(forKey: pluginID)
        UserDefaults.standard.removeObject(forKey: keyPrefix + pluginID)
    }

    /// Record bounded base64 payloads embedded in a successful authorized JSON response.
    /// These are provenance tokens, not permissions; a later decrypt must use matching bytes.
    static func observeEncryptedPayloads(pluginID: String, sourceURL: URL, sourcePolicy: DomainPolicy,
                                          contentType: String, body: Data, expectedGeneration: UInt64? = nil,
                                          now: Date = Date()) {
        guard sourceURL.scheme?.lowercased() == "https",
              let sourceHost = sourceURL.host?.lowercased(), sourcePolicy.allows(sourceHost),
              contentType.lowercased().contains("json"), body.count <= 8 << 20,
              let root = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { return }

        var payloads: [Data] = []
        var totalBytes = 0
        // Bound total traversal work, not just recursion depth and per-array width.
        // JSON objects can contain millions of shallow keys, so depth alone is insufficient.
        var remainingNodes = 4_096
        func visit(_ value: Any, depth: Int) {
            guard remainingNodes > 0, depth <= 16, payloads.count < 64, totalBytes < 4 << 20 else { return }
            remainingNodes -= 1
            if let object = value as? [String: Any] {
                for child in object.values {
                    guard remainingNodes > 0, payloads.count < 64, totalBytes < 4 << 20 else { break }
                    visit(child, depth: depth + 1)
                }
            } else if let array = value as? [Any] {
                for child in array.prefix(512) {
                    guard remainingNodes > 0, payloads.count < 64, totalBytes < 4 << 20 else { break }
                    visit(child, depth: depth + 1)
                }
            } else if let string = value as? String {
                var encoded = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    .filter { !$0.isWhitespace }
                    .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                guard encoded.count >= 32, encoded.count <= 3 << 20 else { return }
                while encoded.count % 4 != 0 { encoded += "=" }
                guard let bytes = Data(base64Encoded: encoded), bytes.count >= 16,
                      bytes.count <= 2 << 20, totalBytes + bytes.count <= 4 << 20 else { return }
                payloads.append(bytes)
                totalBytes += bytes.count
            }
        }
        visit(root, depth: 0)
        guard !payloads.isEmpty else { return }

        lock.lock()
        if let expectedGeneration, generations[pluginID, default: 0] != expectedGeneration {
            lock.unlock()
            return
        }
        let timestamp = now.timeIntervalSince1970
        var entries = encryptedPayloads[pluginID, default: []].filter { $0.expiresAt > timestamp }
        for bytes in payloads {
            entries.append(EncryptedPayload(sourceURL: sourceURL, sourcePolicy: sourcePolicy,
                                            generation: generations[pluginID, default: 0],
                                            expiresAt: timestamp + 10 * 60, bytes: bytes))
        }
        var storedBytes = entries.reduce(0) { $0 + $1.bytes.count }
        while entries.count > 128 || storedBytes > 8 << 20 {
            guard !entries.isEmpty else { break }
            storedBytes -= entries.removeFirst().bytes.count
        }
        encryptedPayloads[pluginID] = entries
        lock.unlock()
    }

    /// Inspect decrypted text only when the exact input bytes are contained in a
    /// base64 payload observed in a successful authorized response for this plugin.
    static func learnDecryptedPayload(pluginID: String, ciphertext: Data, plaintext: Data, now: Date = Date()) {
        guard ciphertext.count >= 16, plaintext.count <= 8 << 20,
              String(data: plaintext, encoding: .utf8) != nil else { return }
        let timestamp = now.timeIntervalSince1970
        lock.lock()
        var entries = encryptedPayloads[pluginID, default: []].filter { $0.expiresAt > timestamp }
        encryptedPayloads[pluginID] = entries
        let match = entries.first { entry in
            generations[pluginID, default: 0] == entry.generation && entry.bytes.range(of: ciphertext) != nil
        }
        lock.unlock()
        guard let match else { return }
        learn(pluginID: pluginID, sourceURL: match.sourceURL, sourcePolicy: match.sourcePolicy,
              contentType: "application/json", body: plaintext, expectedGeneration: match.generation, now: now)
    }

    /// A provider has already classified this value as an image (cover, poster,
    /// thumbnail or comic page). Learn its HTTPS host at the point where that
    /// semantic image reference is created; serialized Nuxt payloads do not
    /// necessarily keep the image key adjacent to the URL string.
    static func learnImageURL(pluginID: String, url: String, now: Date = Date()) {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(),
              !NetGuard.isIPLiteral(host), DomainRule(host) != nil else { return }

        lock.lock()
        let observedExpiry = observedHosts[pluginID]?[host] ?? 0
        guard observedExpiry > now.timeIntervalSince1970 else {
            lock.unlock()
            return
        }
        let key = keyPrefix + pluginID
        var stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        let timestamp = now.timeIntervalSince1970
        stored = stored.filter { $0.value > timestamp }
        let isNew = stored[host] == nil
        stored[host] = timestamp + ttl
        if stored.count > maxDomains {
            let keep = stored.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }.prefix(maxDomains)
            stored = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(stored, forKey: key)
        lock.unlock()

        if isNew {
            PluginLog.add(pluginID, "📝 动态授权图片 CDN（24 小时）：\(host)")
        }
    }

    static func learn(pluginID: String, sourceURL: URL, sourcePolicy: DomainPolicy,
                      contentType: String, body: Data, expectedGeneration: UInt64? = nil,
                      now: Date = Date()) {
        guard sourceURL.scheme == "https",
              let sourceHost = sourceURL.host?.lowercased(), sourcePolicy.allows(sourceHost) else { return }
        let type = contentType.lowercased()
        guard type.contains("text/html") || type.contains("json") || type.contains("javascript") else { return }
        // Keep synchronous scanning bounded; normal HTML/JSON API payloads are far smaller.
        guard body.count <= 8 << 20,
              let raw = String(data: body, encoding: .utf8), !raw.isEmpty else { return }

        // Nuxt/JSON payloads commonly escape URL slashes.
        let text = raw.replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\\u002[fF]"#, with: "/", options: .regularExpression)
        let ns = text as NSString
        var observed = Set<String>()
        let scanRange = NSRange(location: 0, length: ns.length)

        // Enumerate lazily and stop as soon as the per-response candidate budget is
        // reached. matches(in:) allocates an array for every match in the body first.
        let pattern = #"https://[A-Za-z0-9.-]+(?::443)?(?:/[^\s"'<>\\]*)?"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            regex.enumerateMatches(in: text, range: scanRange) { match, _, stop in
                guard observed.count < maxDomains, let match else {
                    stop.pointee = true
                    return
                }
                var candidate = ns.substring(with: match.range)
                while let last = candidate.last, ".,;)]}".contains(last) { candidate.removeLast() }
                guard let components = URLComponents(string: candidate),
                      components.scheme?.lowercased() == "https",
                      components.user == nil, components.password == nil,
                      components.port == nil || components.port == 443,
                      let host = components.host?.lowercased(),
                      host != sourceHost, !NetGuard.isIPLiteral(host),
                      DomainRule(host) != nil else { return }
                observed.insert(host)
                if observed.count >= maxDomains { stop.pointee = true }
            }
        }

        // Some APIs return CDN origins as bare host strings rather than URLs.
        // This second lazy pass shares the same budget with URL matches.
        let bareHostPattern = #"(?<![A-Za-z0-9.-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}(?![A-Za-z0-9.-])"#
        if observed.count < maxDomains,
           let hostRegex = try? NSRegularExpression(pattern: bareHostPattern, options: [.caseInsensitive]) {
            hostRegex.enumerateMatches(in: text, range: scanRange) { match, _, stop in
                guard observed.count < maxDomains, let match else {
                    stop.pointee = true
                    return
                }
                let host = ns.substring(with: match.range).lowercased()
                guard host != sourceHost, !NetGuard.isIPLiteral(host), DomainRule(host) != nil else { return }
                observed.insert(host)
                if observed.count >= maxDomains { stop.pointee = true }
            }
        }
        guard !observed.isEmpty else { return }

        lock.lock()
        if let expectedGeneration, generations[pluginID, default: 0] != expectedGeneration {
            lock.unlock()
            return
        }
        let timestamp = now.timeIntervalSince1970
        var candidates = observedHosts[pluginID, default: [:]].filter { $0.value > timestamp }
        for host in observed { candidates[host] = timestamp + 10 * 60 }
        if candidates.count > maxDomains {
            let keep = candidates.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }.prefix(maxDomains)
            candidates = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        observedHosts[pluginID] = candidates
        lock.unlock()
    }
}

/// Plugin-provided images go through `idjimg://` refs so that every fetch is checked against that plugin's
/// manifest permissions plus that plugin's learned image CDN hosts, uses only its cookies, and applies transforms natively.
enum PluginMedia {
    static let scheme = "idjimg://"
    static let allowedHeaders: Set<String> = ["referer", "user-agent", "origin", "accept", "accept-language"]

    static func ref(plugin: String, url: String, headers: [String: String]? = nil, transform: [String: Any]? = nil) -> String {
        guard !url.isEmpty else { return "" }
        // This API is used only for provider-classified image references. It is
        // the reliable signal for Nuxt/table payloads where JSON keys and URL
        // strings are separated by an index-based serialization format.
        PluginMediaDomainCache.learnImageURL(pluginID: plugin, url: url)
        var o: [String: Any] = ["u": url]
        if let h = headers?.filter({ allowedHeaders.contains($0.key.lowercased()) }), !h.isEmpty { o["h"] = h }
        if let transform, !transform.isEmpty { o["t"] = transform }
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        let b64 = d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return scheme + plugin + "/" + b64
    }

    static func parse(_ ref: String) -> (plugin: String, url: URL, headers: [String: String], transform: [String: Any]?)? {
        guard ref.hasPrefix(scheme) else { return nil }
        let rest = ref.dropFirst(scheme.count)
        guard let slash = rest.lastIndex(of: "/") else { return nil }
        let plugin = String(rest[..<slash])
        var b64 = String(rest[rest.index(after: slash)...]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let u = o["u"] as? String, let url = URL(string: u) else { return nil }
        return (plugin, url, o["h"] as? [String: String] ?? [:], o["t"] as? [String: Any])
    }

    static func allows(_ url: URL, explicitPolicy: DomainPolicy, learnedHosts: Set<String>) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty,
              !NetGuard.isIPLiteral(host) else { return false }

        // Match PluginNet's transport boundary: HTTPS 443 and HTTP 80 only.
        // Explicit HTTP remains available for legacy manifests; learned hosts are HTTPS-only.
        if let port = url.port {
            guard (scheme == "https" && port == 443) || (scheme == "http" && port == 80) else { return false }
        }
        let explicitlyAllowed = explicitPolicy.allows(host)
        let dynamicallyAllowed = scheme == "https"
            && (url.port == nil || url.port == 443)
            && learnedHosts.contains(host)
        return explicitlyAllowed || dynamicallyAllowed
    }

    /// Redirects are evaluated in the context of an already-classified image request.
    /// A short-lived candidate may be promoted only after its exact redirect URL passes
    /// HTTPS/port and fresh DNS checks.
    static func allowsRedirect(pluginID: String, url: URL, explicitPolicy: DomainPolicy,
                               learnedHosts: Set<String>) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let candidates = PluginMediaDomainCache.candidates(pluginID: pluginID)
        let allowed = allows(url, explicitPolicy: explicitPolicy, learnedHosts: learnedHosts.union(candidates))
        guard allowed, !NetGuard.resolvesToBlocked(host, useCache: false) else { return false }
        if candidates.contains(host) {
            PluginMediaDomainCache.learnImageURL(pluginID: pluginID, url: url.absoluteString)
        }
        return true
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        let pluginID: String
        let explicitPolicy: DomainPolicy
        let learnedHosts: Set<String>
        var blocked: String?
        private var redirectHops = 0
        init(pluginID: String, explicitPolicy: DomainPolicy, learnedHosts: Set<String>) {
            self.pluginID = pluginID
            self.explicitPolicy = explicitPolicy
            self.learnedHosts = learnedHosts
        }
        private func allows(_ url: URL) -> Bool {
            PluginMedia.allowsRedirect(pluginID: pluginID, url: url,
                                       explicitPolicy: explicitPolicy, learnedHosts: learnedHosts)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            redirectHops += 1
            guard redirectHops <= 10, let url = request.url, allows(url) else {
                blocked = request.url?.host ?? "redirect-limit"
                return nil
            }
            return request
        }
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    /// Final image bytes (transform applied).
    static func load(_ ref: String) async throws -> Data {
        guard let r = parse(ref) else { throw ProviderError.invalid("图片地址无效") }
        guard let rec = PluginStore.snapshot(r.plugin), rec.enabled else { throw ProviderError.invalid("插件未启用") }
        let explicitPolicy = DomainPolicy(rec.manifest.mediaDomains + rec.manifest.httpDomains + rec.extraDomains)
        let learnedHosts = Set(PluginMediaDomainCache.domains(pluginID: r.plugin))
        guard let host = r.url.host?.lowercased(), r.url.scheme == "https" || r.url.scheme == "http" else {
            throw ProviderError.invalid("图片地址无效")
        }
        guard PluginMedia.allows(r.url, explicitPolicy: explicitPolicy, learnedHosts: learnedHosts) else {
            PluginLog.add(r.plugin, "✕ 图片域名未授权 \(host)")
            throw ProviderError.invalid("图片域名未授权：\(host)")
        }
        let blocked = await Task.detached { NetGuard.resolvesToBlocked(host, useCache: false) }.value
        if blocked { throw ProviderError.invalid("图片地址解析到内网") }
        var data: Data
        if let fx = PluginFixtures.responder, let reply = fx(URLRequest(url: r.url)) { data = reply.body }
        else {
            var req = URLRequest(url: r.url)
            req.setValue(rec.learnedUA ?? PluginHostContext.defaultUA, forHTTPHeaderField: "User-Agent")
            for (k, v) in r.headers where allowedHeaders.contains(k.lowercased()) { req.setValue(v, forHTTPHeaderField: k) }
            let cs = PluginRuntime.jar(r.plugin).cookies(for: r.url)
            for (k, v) in HTTPCookie.requestHeaderFields(with: cs) { req.setValue(v, forHTTPHeaderField: k) }
            let guardD = RedirectGuard(pluginID: r.plugin, explicitPolicy: explicitPolicy, learnedHosts: learnedHosts)
            let (d, resp) = try await session.data(for: req, delegate: guardD)
            if let b = guardD.blocked { throw ProviderError.invalid("图片跳转到未授权域名 \(b)") }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code), !d.isEmpty else { throw ProviderError.upstream("图片 HTTP \(code) · \(host)") }
            guard d.count <= 30 << 20 else { throw ProviderError.upstream("图片太大") }
            data = d
        }
        if let t = r.transform { data = try apply(t, data) }
        return data
    }

    static func apply(_ t: [String: Any], _ data: Data) throws -> Data {
        switch t["type"] as? String ?? "" {
        case "stripes":
            let n = t["segments"] as? Int ?? 0
            guard n > 1 else { return data }
            guard let img = UIImage(data: data)?.cgImage else { throw ProviderError.invalid("图片无法解码") }
            guard let out = ImageStripes.unscramble(img, segments: n) else { throw ProviderError.invalid("图片还原失败") }
            return UIImage(cgImage: out).jpegData(compressionQuality: 0.92) ?? data
        case "aes":
            let enc = t["keyEncoding"] as? String ?? "utf8"
            let key = try PluginCrypto.decode(t["key"] as? String ?? "", enc)
            let iv = try (t["iv"] as? String).map { try PluginCrypto.decode($0, enc) }
            var input = data
            if (t["encoding"] as? String) == "base64" { input = try PluginCrypto.decode(String(decoding: data, as: UTF8.self), "base64") }
            return try PluginCrypto.aes(encrypt: false, mode: t["mode"] as? String ?? "cbc", key: key, iv: iv, data: input,
                                        padding: (t["padding"] as? String ?? "pkcs7") != "none")
        default:
            return data
        }
    }
}

/// 18comic-style horizontal stripe scramble (public JMComic algorithm, MIT reference implementation
/// hect0x7/JMComic-Crawler-Python `JmImageTool.decode_and_save`): the image is cut into `segments`
/// horizontal bands stored in reverse order; the first band of the original absorbs `height % segments` rows.
enum ImageStripes {
    /// (source y, destination y, height) for each band, in the original algorithm's coordinate system (top-left origin).
    static func plan(height h: Int, segments num: Int) -> [(src: Int, dst: Int, h: Int)] {
        guard num > 1, h >= num else { return [] }
        let over = h % num
        var out: [(Int, Int, Int)] = []
        for i in 0..<num {
            var move = h / num
            let ySrc = h - move * (i + 1) - over
            var yDst = move * i
            if i == 0 { move += over } else { yDst += over }
            out.append((ySrc, yDst, move))
        }
        return out
    }

    static func unscramble(_ img: CGImage, segments: Int) -> CGImage? {
        let w = img.width, h = img.height
        let bands = plan(height: h, segments: segments)
        guard !bands.isEmpty else { return img }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for b in bands {
            guard let piece = img.cropping(to: CGRect(x: 0, y: b.src, width: w, height: b.h)) else { return nil }
            // CGContext origin is bottom-left.
            ctx.draw(piece, in: CGRect(x: 0, y: h - b.dst - b.h, width: w, height: b.h))
        }
        return ctx.makeImage()
    }

    /// Inverse (used by tests to build scrambled fixtures).
    static func scramble(_ img: CGImage, segments: Int) -> CGImage? {
        let w = img.width, h = img.height
        let bands = plan(height: h, segments: segments)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for b in bands {
            guard let piece = img.cropping(to: CGRect(x: 0, y: b.dst, width: w, height: b.h)) else { return nil }
            ctx.draw(piece, in: CGRect(x: 0, y: h - b.src - b.h, width: w, height: b.h))
        }
        return ctx.makeImage()
    }
}

/// Shared output validation for plugin results.
enum PluginOut {
    static func s(_ v: Any?, max: Int = 300) -> String {
        let t = (v as? String) ?? (v as? NSNumber)?.stringValue ?? ""
        return String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }
    static func url(_ v: Any?) -> String {
        let u = s(v, max: 2000)
        return u.hasPrefix("https://") || u.hasPrefix("http://") ? u : ""
    }
    /// Sources repeat entries; list views need ids that differ.
    static func unique<T, K: Hashable>(_ list: [T], _ key: (T) -> K) -> [T] {
        var seen = Set<K>()
        return list.filter { seen.insert(key($0)).inserted }
    }
    static func strings(_ v: Any?, max: Int = 30) -> [String] {
        unique(((v as? [Any]) ?? []).prefix(max).map { s($0, max: 60) }.filter { !$0.isEmpty }) { $0 }
    }
    static func headers(_ v: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for (k, val) in (v as? [String: Any]) ?? [:] where PluginMedia.allowedHeaders.contains(k.lowercased()) {
            let value=s(val,max:500)
            if !value.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) {out[k]=value}
        }
        return out
    }
    /// 插件声明的图片处理（封面 coverTransform / 章节图片 transform）。
    /// 只接受宿主原生支持的 stripes（横条重排）与 aes（整包解密）。
    static func mediaTransform(_ v: Any?) -> [String: Any]? {
        guard let t = v as? [String: Any], ["stripes", "aes"].contains(t["type"] as? String ?? "") else { return nil }
        return t
    }
    static func categories(_ v: Any?) -> [PluginCategory] {
        let all = ((v as? [[String: Any]]) ?? []).prefix(60).compactMap { c -> PluginCategory? in
            let id = s(c["id"]), name = s(c["name"], max: 40)
            guard !id.isEmpty, !name.isEmpty, !ContentFilter.isBlocked([name, id]) else { return nil }
            return PluginCategory(id: id, name: name, isRank: c["isRank"] as? Bool ?? false)
        }
        return unique(all) { $0.id }
    }
}

// MARK: - Comic plugins

struct JSComicProvider: MangaProvider {
    let source: MangaSourceID
    var pluginID: String { source.pluginID ?? "" }
    static let homeID = "__home"

    var categories: [MangaCategory] {
        [MangaCategory(id: Self.homeID, title: "推荐")] + (PluginStore.snapshot(pluginID)?.cachedCategories ?? []).map { MangaCategory(id: $0.id, title: $0.name) }
    }
    var imageHeaders: [String: String] { [:] }

    private func item(_ o: [String: Any]) -> MangaItem? {
        let id = PluginOut.s(o["id"]), title = PluginOut.s(o["title"], max: 200)
        guard !id.isEmpty, !title.isEmpty else { return nil }
        let tags = PluginOut.strings(o["tags"]) + PluginOut.strings(o["badges"])
        guard !ContentFilter.isBlocked([title] + tags) else { return nil }
        let cover = PluginOut.url(o["cover"])
        return MangaItem(source: source, mangaId: id, title: title,
                         cover: PluginMedia.ref(plugin: pluginID, url: cover, headers: PluginOut.headers(o["coverHeaders"]),
                                                transform: PluginOut.mediaTransform(o["coverTransform"])),
                         author: PluginOut.s(o["author"], max: 80), tags: tags, latest: PluginOut.s(o["remarks"], max: 40))
    }

    private func page(_ v: Any) -> MangaPage {
        let o = v as? [String: Any] ?? [:]
        let items = PluginOut.unique(((o["items"] as? [[String: Any]]) ?? []).prefix(500).compactMap(item)) { $0.id }
        return MangaPage(items: items, hasMore: (o["hasMore"] as? Bool ?? false) && !items.isEmpty)
    }

    func list(_ c: MangaCategory, page p: Int) async throws -> MangaPage {
        if c.id == Self.homeID {
            if p > 1 { return MangaPage(items: [], hasMore: false) }
            let r = try await PluginRuntime.call(pluginID, "home", [:])
            let cats = PluginOut.categories((r as? [String: Any])?["categories"])
            let id = pluginID
            await MainActor.run { PluginStore.shared.cacheCategories(id, cats) }
            if let items = (r as? [String: Any])?["items"] as? [Any], !items.isEmpty { return page(r) }
            guard let first = cats.first else { return MangaPage(items: [], hasMore: false) }
            return page(try await PluginRuntime.call(pluginID, "category", ["id": first.id, "page": 1, "filters": [String: String]()]))
        }
        return page(try await PluginRuntime.call(pluginID, "category", ["id": c.id, "page": p, "filters": [String: String]()]))
    }

    func search(_ q: String, page p: Int) async throws -> MangaPage {
        page(try await PluginRuntime.call(pluginID, "search", ["keyword": q, "page": p]))
    }

    func detail(_ m: MangaItem) async throws -> MangaDetail {
        let o = try await PluginRuntime.call(pluginID, "detail", ["id": m.mangaId]) as? [String: Any] ?? [:]
        var item = m
        let title = PluginOut.s(o["title"], max: 200)
        if !title.isEmpty { item.title = title }
        let cover = PluginOut.url(o["cover"])
        if !cover.isEmpty { item.cover = PluginMedia.ref(plugin: pluginID, url: cover, headers: PluginOut.headers(o["coverHeaders"]),
                                                        transform: PluginOut.mediaTransform(o["coverTransform"])) }
        let tags = PluginOut.strings(o["tags"])
        if !tags.isEmpty { item.tags = tags }
        let author = PluginOut.s(o["author"], max: 80)
        if !author.isEmpty { item.author = author }
        guard !ContentFilter.isBlocked([item.title] + item.tags) else { throw ProviderError.unsupported("该内容已被过滤") }
        let chapters = ((o["chapters"] as? [[String: Any]]) ?? []).prefix(5000).enumerated().compactMap { i, c -> MangaChapter? in
            let id = PluginOut.s(c["id"]), name = PluginOut.s(c["name"], max: 120)
            return id.isEmpty ? nil : MangaChapter(chapterId: id, title: name.isEmpty ? "第\(i + 1)话" : name, index: i)
        }.enumerated().map { MangaChapter(chapterId: $0.element.chapterId, title: $0.element.title, index: $0.offset) }
        let status = (o["status"] as? String) == "completed" ? "已完结" : (o["status"] as? String) == "ongoing" ? "连载中" : ""
        return MangaDetail(item: item, desc: PluginOut.s(o["desc"], max: 4000), status: status, chapters: chapters)
    }

    func pages(_ m: MangaItem, _ c: MangaChapter) async throws -> [String] {
        let o = try await PluginRuntime.call(pluginID, "pages", ["chapterId": c.chapterId, "mangaId": m.mangaId]) as? [String: Any] ?? [:]
        let common = PluginOut.headers(o["headers"])
        let imgs = ((o["images"] as? [[String: Any]]) ?? []).prefix(2000).compactMap { i -> String? in
            let u = PluginOut.url(i["url"])
            guard !u.isEmpty else { return nil }
            let h = common.merging(PluginOut.headers(i["headers"])) { _, b in b }
            return PluginMedia.ref(plugin: pluginID, url: u, headers: h, transform: PluginOut.mediaTransform(i["transform"]))
        }
        guard !imgs.isEmpty else { throw ProviderError.upstream("插件没有返回图片") }
        return imgs
    }
}

// MARK: - Video plugins

struct JSVideoProvider: SiteProvider {
    let source: DramaSource
    var pluginID: String { source.pluginID ?? "" }
    static let homeID = "__home"

    static func visibleCategories(cached: [PluginCategory], features: [String]?) -> [SiteCategory] {
        let mapped = cached.map { SiteCategory(id: $0.id, title: $0.name, path: $0.id, isRank: $0.isRank) }
        // Category-shelf plugins expose only real categories. Legacy plugins retain the
        // historical __home entry so DynamicSiteFeed can keep using home() as its feed.
        if PluginHomeFeatures.usesCategoryShelves(features) { return mapped }
        return mapped.isEmpty ? [SiteCategory(id: homeID, title: "推荐", path: homeID)] : mapped
    }

    var categories: [SiteCategory] {
        Self.visibleCategories(
            cached: PluginStore.snapshot(pluginID)?.cachedCategories ?? [],
            features: PluginStore.snapshot(pluginID)?.manifest.homeFeatures
        )
    }

    private func series(_ o: [String: Any]) -> HGSeries? {
        let id = PluginOut.s(o["id"]), title = PluginOut.s(o["title"], max: 200)
        guard !id.isEmpty, !title.isEmpty else { return nil }
        let tags = PluginOut.strings(o["tags"]) + PluginOut.strings(o["badges"])
        guard !ContentFilter.isBlocked([title] + tags) else { return nil }
        let cover = PluginMedia.ref(plugin: pluginID, url: PluginOut.url(o["cover"]), headers: PluginOut.headers(o["coverHeaders"]),
                                    transform: PluginOut.mediaTransform(o["coverTransform"]))
        return HGSeries(source: source, seriesId: id, title: title, cover: cover, subtitle: PluginOut.s(o["remarks"], max: 40).nilIfEmpty,
                        actors: PluginOut.strings(o["actors"]), orientation: (o["orientation"] as? String) == "portrait" ? "portrait" : nil, tags: tags)
    }

    private func page(_ v: Any, _ p: Int) -> HGPage {
        let o = v as? [String: Any] ?? [:]
        let items = PluginOut.unique(((o["items"] as? [[String: Any]]) ?? []).prefix(500).compactMap(series)) { $0.id }
        return HGPage(items: items, hasMore: (o["hasMore"] as? Bool ?? false) && !items.isEmpty, nextOffset: p + 1)
    }

    /// Parse home() without conflating an omitted categories field with an explicitly empty list.
    /// A missing field preserves the last known categories; an explicit [] clears them.
    func parseHomeResponse(_ response: [String: Any], features explicitFeatures: [String]? = nil) -> (categories: [PluginCategory]?, featured: [HGSeries]) {
        // Only a real array is an update. Missing/null/malformed values must not erase cached categories.
        let categories = (response["categories"] as? [[String: Any]]).map { PluginOut.categories($0) }
        let features = explicitFeatures ?? PluginStore.snapshot(pluginID)?.manifest.homeFeatures
        let featured = PluginHomeFeatures.has("featured", in: features)
            ? PluginOut.unique(((response["items"] as? [[String: Any]]) ?? []).prefix(100).compactMap(series)) { $0.id }
            : []
        return (categories, featured)
    }

    /// Load homepage data for the shared native HomeFeedPage / HomeShelf presentation.
    /// Featured items are opt-in; category items remain in their own shelves.
    func homeData() async throws -> (categories: [SiteCategory], featured: [HGSeries]) {
        let response = try await PluginRuntime.call(pluginID, "home", [:]) as? [String: Any] ?? [:]
        let parsed = parseHomeResponse(response)
        if let categories = parsed.categories {
            await MainActor.run { PluginStore.shared.cacheCategories(pluginID, categories) }
        }
        let categories = parsed.categories ?? PluginStore.snapshot(pluginID)?.cachedCategories ?? []
        return (categories.map { SiteCategory(id: $0.id, title: $0.name, path: $0.id, isRank: $0.isRank) }, parsed.featured)
    }

    func list(_ c: SiteCategory, page p: Int) async throws -> HGPage {
        if c.id == Self.homeID || c.id.isEmpty {
            if p > 1 { return HGPage(items: [], hasMore: false) }
            let r = try await PluginRuntime.call(pluginID, "home", [:])
            let response = r as? [String: Any] ?? [:]
            let parsed = parseHomeResponse(response)
            if let cats = parsed.categories {
                let id = pluginID
                await MainActor.run { PluginStore.shared.cacheCategories(id, cats) }
            }
            if let items = response["items"] as? [Any], !items.isEmpty { return page(r, 1) }
            let cats = parsed.categories ?? PluginStore.snapshot(pluginID)?.cachedCategories ?? []
            guard let first = cats.first else { return HGPage(items: [], hasMore: false) }
            return page(try await PluginRuntime.call(pluginID, "category", ["id": first.id, "page": 1, "filters": [String: String]()]), 1)
        }
        return page(try await PluginRuntime.call(pluginID, "category", ["id": c.id, "page": p, "filters": [String: String]()]), p)
    }

    func search(_ q: String, page p: Int) async throws -> HGPage {
        page(try await PluginRuntime.call(pluginID, "search", ["keyword": q, "page": p]), p)
    }

    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        let o = try await PluginRuntime.call(pluginID, "detail", ["id": s.seriesId]) as? [String: Any] ?? [:]
        let title = PluginOut.s(o["title"], max: 200).nonEmptyOr(s.title)
        let tags = PluginOut.strings(o["tags"])
        guard !ContentFilter.isBlocked([title] + tags) else { throw ProviderError.unsupported("该内容已被过滤") }
        let lines = ((o["lines"] as? [[String: Any]]) ?? []).prefix(20)
        var eps: [HGEpisode] = []
        if let line = lines.first {
            let lineName = PluginOut.s(line["name"], max: 40)
            for (i, e) in ((line["episodes"] as? [[String: Any]]) ?? []).prefix(3000).enumerated() {
                let id = PluginOut.s(e["id"], max: 2000)
                guard !id.isEmpty else { continue }
                eps.append(HGEpisode(ep: i + 1, vid: id, duration: e["duration"] as? Int ?? 0, title: PluginOut.s(e["name"], max: 80).nonEmptyOr("第\(i + 1)集"), page: lineName))
            }
        }
        let cover = PluginOut.url(o["cover"])
        return HGSeriesDetail(source: source, seriesId: s.seriesId, title: title,
                              cover: cover.isEmpty ? s.cover : PluginMedia.ref(plugin: pluginID, url: cover, headers: PluginOut.headers(o["coverHeaders"]),
                                                                                transform: PluginOut.mediaTransform(o["coverTransform"])),
                              desc: PluginOut.s(o["desc"], max: 4000), author: PluginOut.s(o["director"], max: 80).nilIfEmpty,
                              actors: PluginOut.strings(o["actors"]), onlineTime: 0, totalEps: eps.count, episodes: eps, tags: tags,
                              episodeLabel: eps.count > 1 ? "共\(eps.count)集" : "长视频")
    }

    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        let o = try await PluginRuntime.call(pluginID, "play", ["line": ep.page ?? "", "episodeId": ep.vid, "id": s.seriesId]) as? [String: Any] ?? [:]
        guard let rec = PluginStore.snapshot(pluginID) else { throw ProviderError.invalid("插件未安装") }
        let media = DomainPolicy(rec.manifest.mediaDomains + rec.manifest.httpDomains + rec.extraDomains)
        var streams: [HGStream] = []
        for (i, st) in ((o["streams"] as? [[String: Any]]) ?? []).prefix(12).enumerated() {
            let u = PluginOut.url(st["url"])
            guard let url = URL(string: u), let host = url.host, url.scheme == "https", url.user == nil, url.password == nil, (url.port == nil || url.port == 443), media.allows(host), !NetGuard.isIPLiteral(host) else {
                PluginLog.add(pluginID, "✕ 丢弃未授权/非 https 的流地址 \(URL(string: u)?.host ?? u.prefix(40).description)")
                continue
            }
            let blocked = await Task.detached { NetGuard.resolvesToBlocked(host) }.value
            if blocked { PluginLog.add(pluginID,"✕ 丢弃解析到内网的媒体地址");continue }
            let fmt = (st["format"] as? String) ?? (u.contains(".m3u8") ? "hls" : "mp4")
            let key = PluginOut.s(st["key"], max: 64)
            var h = PluginOut.headers(st["headers"])
            if h["User-Agent"] == nil { h["User-Agent"] = rec.learnedUA ?? PluginHostContext.defaultUA }
            streams.append(HGStream(streamId: "p\(i)", quality: PluginOut.s(st["name"], max: 40).nonEmptyOr(host), url: u, key: key,
                                    kind: (!key.isEmpty || fmt == "cenc") ? .mp4Cenc : (fmt == "hls" ? .hls : .mp4Clear), headers: h))