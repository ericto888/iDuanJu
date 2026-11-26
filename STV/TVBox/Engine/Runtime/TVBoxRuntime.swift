import Foundation
import os

/// Everything the TVBox engine needs from the app, wired together once.
enum TVBoxRuntime {
    private static let proxy = LocalProxy()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "STV", category: "tvbox")

    private static let storage = FileScriptStorage(dir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tvbox/script", isDirectory: true))

    /// Port of the loopback proxy, 0 while it is not running.
    static var proxyPort: Int { proxy.port }

    static func platform() -> TVBoxPlatform {
        TVBoxPlatform(
            js: { try QuickJSEngine() },
            python: PythonRuntime.isAvailable ? PythonEngine.shared : nil,
            jar: BridgeClient.shared,
            sniffer: WebSniffer(ownPort: { proxy.port }),
            jsAsset: jsAsset,
            makeHost: { siteKey, http, port in
                ScriptHost(siteKey: siteKey, http: http, storage: storage, proxyPort: port) { log("[\(siteKey)] \($0)") }
            },
            log: log)
    }

    /// Installs the handler of `/proxy` (query and lower-cased request headers merged) and starts the server on first use.
    /// Returns its port, 0 when no port is free.
    static func startProxy(_ handler: @escaping ([String: String]) -> ProxyReply) -> Int {
        proxy.setHandler(handler)
        return proxy.start()
    }

    static func log(_ line: String) { logger.debug("\(line.prefix(2000), privacy: .public)") }

    /// `bootstrap.js` or `lib/<name>` of the bundled `tvbox/js`.
    static func jsAsset(_ name: String) -> String? {
        let plain = name.precomposedStringWithCanonicalMapping
        guard !plain.isEmpty, !plain.contains(".."), !plain.hasPrefix("/"), let root = Bundle.main.resourceURL else { return nil }
        let dir = root.appendingPathComponent("tvbox/js", isDirectory: true)
        // file names with Chinese characters may be stored in either normal form
        for n in [plain, name.decomposedStringWithCanonicalMapping] {
            if let d = try? Data(contentsOf: dir.appendingPathComponent(n)) { return String(decoding: d, as: UTF8.self) }
        }
        return nil
    }
}
