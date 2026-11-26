import Foundation

/// Address policy of everything the player opens for a TVBox source (docs/unified-player-tvbox.md §4): private ranges only when
/// the config lives there or the user allowed LAN access, this device only through the app's own proxies.
/// `lan`: nil = no policy (first-party sources), false = public addresses only, true = the LAN as well.
enum LanPolicy {
    static let message = "该地址在局域网内，请在 TVBox 设置里打开「允许访问局域网」"
    static let device = "不允许访问本机地址"
    static let unsupported = "不支持的播放地址"
    /// Files, and forms another address can hide in.
    private static let closed: Set<String> = ["file", "fd", "fdclose", "memory", "hex", "edl", "lavf", "ffmpeg", "av", "concat", "subfile", "slice", "archive", "mf", "null", "content", "asset"]

    /// Why a literal address is refused; names are looked up by `check`. `own` = port of the spiders' loopback proxy.
    static func refusal(_ address: String, lan: Bool?, own: Int = TVBoxRuntime.proxyPort, bridge: String = BridgeClient.shared.address) -> String? {
        guard let lan else { return nil }
        let scheme = address.substringBefore(":", "").lowercased()
        if scheme == "data" { return nil }
        if !address.contains("://") || closed.contains(scheme) { return unsupported }
        let host = TVBoxUrl.host(address), at = port(address)
        if host.isEmpty { return nil }
        if isThisDevice(host) { return at > 0 && (at == own || at == LocalHLSProxy.shared.boundPort) ? nil : device }
        if lan || "\(host):\(at)" == bridge { return nil }
        let inside = NetGuard.isIPLiteral(host) ? NetGuard.isBlockedIP(host) : host.hasSuffix(".local") || host.hasSuffix(".lan")
        return inside ? message : nil
    }

    /// The same for names, looked up off the cooperative pool. A resolver that takes longer than the player would wait does not
    /// hold up playback.
    static func check(_ address: String, lan: Bool?) async throws {
        guard let lan else { return }
        if let why = refusal(address, lan: lan) { throw TVBoxError(why) }
        let host = TVBoxUrl.host(address)
        if host.isEmpty || NetGuard.isIPLiteral(host) || isThisDevice(host) || "\(host):\(port(address))" == BridgeClient.shared.address { return }
        let why = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let once = TVBoxOnce<String?>()
            once.deliver { c.resume(returning: try? $0.get()) }
            TVBoxWorkers.run { once.resolve(.success(resolved(host, lan))) }
            SpiderClock.after(3_000) { once.resolve(.success(nil)) }
        }
        if let why { throw TVBoxError(why) }
    }

    private static func port(_ address: String) -> Int { URL(string: address)?.port ?? (address.hasPrefixIgnoringCase("https:") ? 443 : 80) }

    /// Blocking.
    private static func resolved(_ host: String, _ lan: Bool) -> String? {
        if lan { return (NetGuard.resolverOverride?(host) ?? NetGuard.resolve(host)).contains(where: isThisDevice) ? device : nil }
        return NetGuard.resolvesToBlocked(host) ? message : nil
    }

    /// Loopback and unspecified addresses. Multicast groups are not: lists name them directly (`rtp://239.x`).
    private static func isThisDevice(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        guard TVBoxNet.isDeviceLocal(host) else { return false }
        let first = host.split(separator: ".").first.flatMap { Int($0) } ?? 0
        return !(224...239).contains(first) && !host.hasPrefix("ff")
    }

    /// Redirects are judged like the address they start from.
    static func redirect(_ next: URLRequest, lan: Bool?, _ done: @escaping (URLRequest?) -> Void) {
        guard lan != nil, let address = next.url?.absoluteString else { return done(next) }
        Task { done((try? await check(address, lan: lan)) == nil ? nil : next) }
    }

    /// For requests without a delegate of their own.
    final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lan: Bool?
        init(_ lan: Bool?) { self.lan = lan }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            LanPolicy.redirect(request, lan: lan, completionHandler)
        }
    }
}
