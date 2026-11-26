import Foundation

/// The embedded CPython as the spider contract sees it: blocking calls, deadlines kept by the session that makes them.
final class PythonEngine: PyEngine, @unchecked Sendable {
    static let shared = PythonEngine()

    /// Only a backstop: `SpiderSession` interrupts a call at its own deadline.
    private static let limit: TimeInterval = 150

    private let runtime = PythonRuntime.shared
    private let lock = NSLock()
    private var hosts: [String: ScriptHosting] = [:]

    private init() {}

    private func host(_ key: String) -> ScriptHosting? {
        lock.lock(); defer { lock.unlock() }
        return hosts[key]
    }

    private func set(_ key: String, _ host: ScriptHosting?) {
        lock.lock(); hosts[key] = host; lock.unlock()
    }

    /// Host calls of every script arrive here, named by the spider's key.
    private func connect() {
        runtime.setHost { [weak self] key, name, args in
            self?.host(key)?.call(name, args) ?? #"{"e":"脚本已卸载"}"#
        }
    }

    func load(key: String, source: String, ext: String, siteKey: String, url: String, host: ScriptHosting) throws {
        guard PythonRuntime.isAvailable else { throw TVBoxError(PythonRuntime.missingMessage) }
        connect()
        set(key, host)
        do {
            let runtime = self.runtime
            try RT.wait { try await runtime.load(key: key, source: source, ext: ext, siteKey: siteKey, url: url, timeout: Self.limit) }
        } catch {
            set(key, nil)
            throw Self.readable(error, "脚本加载失败：")
        }
    }

    func call(key: String, method: String, argsJson: String) throws -> String {
        let runtime = self.runtime
        do {
            return try RT.wait { try await runtime.call(key: key, method: method, argsJSON: argsJson, timeout: Self.limit) }
        } catch { throw Self.readable(error, "") }
    }

    func unload(key: String) {
        runtime.unload(key: key)
        // the script's destroy() may still want the host
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) { [self] in
            if !runtime.isLoaded(key: key) { set(key, nil) }
        }
    }

    func interrupt(key: String) { runtime.interrupt(key: key) }

    /// The runner raises `RuntimeError` with a complete sentence; its type says nothing to the user.
    private static func readable(_ e: Error, _ prefix: String) -> Error {
        guard let p = e as? PythonError else { return e }
        if case .script(var m) = p {
            if m.hasPrefix("RuntimeError: ") { m.removeFirst("RuntimeError: ".count) }
            return TVBoxError(prefix + m)
        }
        if p == .timeout { return SpiderTimeout("Python 脚本执行超时") }
        return TVBoxError(p.errorDescription ?? "Python 脚本出错")
    }
}
