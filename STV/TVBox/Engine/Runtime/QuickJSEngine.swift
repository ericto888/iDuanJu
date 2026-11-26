import Foundation
import CQuickJS

/// QuickJS behind the script-spider contract: a context with eval and ES modules, confined to the spider's thread. Not the
/// plugin sandbox (which has neither).
final class QuickJSEngine: JsEngine {
    struct Interrupted: LocalizedError {
        var errorDescription: String? { "脚本已被中断" }
    }

    /// Guards `tv` against a close while another thread interrupts.
    private let lock = NSLock()
    private var tv: OpaquePointer?
    private var interruptedAt: TimeInterval = 0
    private var call: ((String, String) -> String)?
    private var normalize: ((String, String) throws -> String)?
    private var load: ((String) throws -> String)?

    init(memoryLimit: Int = 128 << 20, stackLimit: Int = 4 << 20) throws {
        tv = idj_tv_new(memoryLimit, stackLimit, { opaque, name, args in
            QuickJSEngine.from(opaque).host(name, args)
        }, { opaque, base, name, err in
            let engine = QuickJSEngine.from(opaque)
            return engine.text(err) { try engine.normalize?(String(cString: base!), String(cString: name!)) }
        }, { opaque, name, err in
            let engine = QuickJSEngine.from(opaque)
            return engine.text(err) { try engine.load?(String(cString: name!)) }
        }, Unmanaged.passUnretained(self).toOpaque())
        if tv == nil { throw TVBoxError("无法创建脚本引擎") }
    }

    deinit { close() }

    private static func from(_ opaque: UnsafeMutableRawPointer?) -> QuickJSEngine {
        Unmanaged<QuickJSEngine>.fromOpaque(opaque!).takeUnretainedValue()
    }

    private func host(_ name: UnsafePointer<CChar>?, _ args: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
        autoreleasepool {
            guard let call, let name, let args else { return nil }
            return strdup(call(String(cString: name), String(cString: args)))
        }
    }

    private func text(_ err: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ body: () throws -> String?) -> UnsafeMutablePointer<CChar>? {
        autoreleasepool {
            do {
                if let s = try body() { return strdup(s) }
                err?.pointee = strdup("没有模块加载器")
            } catch {
                err?.pointee = strdup(SpiderErrors.text(error))
            }
            return nil
        }
    }

    // MARK: JsEngine

    func install(_ call: @escaping (String, String) -> String) { self.call = call }

    func modules(normalize: @escaping (String, String) throws -> String, load: @escaping (String) throws -> String) {
        self.normalize = normalize
        self.load = load
    }

    func script(_ code: String, _ name: String) throws -> String? {
        var out: UnsafeMutablePointer<CChar>?
        try run(name) { tv, err in
            code.withCString { idj_tv_script(tv, $0, strlen($0), name, &out, err) }
        }
        defer { idj_str_free(out) }
        return out.map { String(cString: $0) }
    }

    func module(_ code: String, _ name: String) throws {
        try run(name) { tv, err in
            code.withCString { idj_tv_module(tv, $0, strlen($0), name, err) }
        }
    }

    private func run(_ name: String, _ body: (OpaquePointer, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32) throws {
        lock.lock()
        guard let tv else { lock.unlock(); throw TVBoxError("脚本引擎已关闭") }
        // An interrupt that came too late for the call it was meant for must not hit a later one.
        if interruptedAt > 0, ProcessInfo.processInfo.systemUptime - interruptedAt > 2 { resume(tv) }
        lock.unlock()
        var err: UnsafeMutablePointer<CChar>?
        let rc = body(tv, &err)
        defer { idj_str_free(err) }
        if rc == 0 { return }
        if rc == -2 {
            lock.lock(); resume(tv); lock.unlock()
            throw Interrupted()
        }
        throw TVBoxError(Self.message(err.map { String(cString: $0) } ?? "脚本出错"))
    }

    /// "message\u{1}stack" → the message, with the position of a syntax error (its stack is only that).
    private static func message(_ raw: String) -> String {
        let parts = raw.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
        let text = parts.first.map(String.init) ?? "脚本出错"
        guard parts.count == 2, let line = parts[1].split(separator: "\n").first else { return text }
        let at = line.trimmingCharacters(in: CharacterSet(charactersIn: " ()")).components(separatedBy: " ").last ?? ""
        let place = at.components(separatedBy: "/").last ?? at
        let pieces = place.components(separatedBy: ":")
        guard pieces.count >= 2, Int(pieces[1]) != nil, text.utf8.count < 400 else { return text }
        return "\(text) @ \(place)"
    }

    func interrupt() {
        lock.lock(); defer { lock.unlock() }
        guard let tv else { return }
        interruptedAt = ProcessInfo.processInfo.systemUptime
        idj_tv_interrupt(tv)
    }

    func resume() {
        lock.lock(); defer { lock.unlock() }
        if let tv, interruptedAt > 0 { resume(tv) }
    }

    /// `lock` is held.
    private func resume(_ tv: OpaquePointer) {
        interruptedAt = 0
        idj_tv_resume(tv)
    }

    func close() {
        lock.lock()
        let t = tv
        tv = nil
        lock.unlock()
        if let t { idj_tv_free(t) }
        call = nil; normalize = nil; load = nil
    }
}
