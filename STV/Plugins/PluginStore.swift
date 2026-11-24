import Foundation
import Combine
import CryptoKit

/// One installed plugin (index entry). Files live in `Application Support/Plugins/<id>/`.
struct InstalledPlugin: Codable, Hashable, Identifiable {
    var manifest: PluginManifest
    var enabled: Bool = true
    /// Hashes pinned at install time; the runtime refuses to load files that no longer match.
    var fileHashes: [String: String]
    /// Author key pinned on first signed install (TOFU); later updates must be signed by it.
    var publicKey: String?
    var origin: String
    var installedAt = Date()
    var updatedAt = Date()
    /// Domains the user granted on top of the manifest (e.g. a new 18comic mirror).
    var extraDomains: [String] = []
    var settings: [String: String] = [:]
    var learnedUA: String?
    var failures = 0
    var disabledReason: String?
    var cachedCategories: [PluginCategory] = []
    var id: String { manifest.id }
}

struct PluginCategory: Codable, Hashable { var id: String; var name: String; var isRank: Bool = false }

/// `.idjplugin` file = JSON bundle (no zip): `{ "manifest": {...}, "files": { "main.js": "..." } }`.
struct PluginBundle: Codable { var manifest: PluginManifest; var files: [String: String] }

/// Everything the install / update prompt needs.
struct PendingInstall: Identifiable {
    var manifest: PluginManifest
    var source: String
    var fileHash: String
    var origin: String
    var existing: InstalledPlugin?
    var diff: PermissionDiff?
    var signedBy: String?
    var exported: [String] = []
    var id: String { manifest.id + "@" + manifest.version }
    var isUpdate: Bool { existing != nil }
}

/// A subscription list: `{ "name": "...", "plugins": [ { "id", "name", "manifest", "type", "adult", "version", "description" } ],
/// "cms": [ { "name", "api", "adult" } ] }`.
struct PluginSubscription: Codable, Hashable, Identifiable {
    struct Entry: Codable, Hashable, Identifiable {
        var id: String
        var name: String
        var manifest: String
        var type: String?
        var adult: Bool?
        var version: String?
        var description: String?
    }
    struct CMSEntry: Codable, Hashable, Identifiable {
        var name: String
        var api: String
        var adult: Bool?
        var id: String { api }
    }
    var url: String
    var name: String = ""
    var plugins: [Entry] = []
    var cms: [CMSEntry] = []
    var fetchedAt: Date?
    var error: String?
    var id: String { url }
}

@MainActor
final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    @Published private(set) var plugins: [InstalledPlugin] = []
    @Published private(set) var subscriptions: [PluginSubscription] = []
    /// Bumped on every change so views that read static snapshots re-render.
    @Published private(set) var revision = 0

    // Lock-protected copy for non-main readers (providers, runtime, DramaSource.label …).
    nonisolated(unsafe) private static var snap: [String: InstalledPlugin] = [:]
    nonisolated private static let snapLock = NSLock()

    nonisolated static func snapshot(_ id: String) -> InstalledPlugin? { snapLock.lock(); defer { snapLock.unlock() }; return snap[id] }
    nonisolated static func allSnapshot() -> [InstalledPlugin] {
        snapLock.lock(); defer { snapLock.unlock() }
        return snap.values.sorted { $0.installedAt < $1.installedAt }
    }
    nonisolated static func overridePlugin(for source: DramaSource) -> InstalledPlugin? {
        guard DramaSource.overridableBuiltins.contains(source) else { return nil }
        return allSnapshot().first { $0.enabled && $0.manifest.type == .video && ($0.manifest.overrides ?? []).contains(source.rawValue) }
    }
    nonisolated static func videoSources() -> [DramaSource] {
        allSnapshot().filter { $0.enabled && [.video, .shortdrama].contains($0.manifest.type) && ($0.manifest.overrides ?? []).isEmpty }.map { DramaSource.plugin($0.id) }
    }
    nonisolated static func comicSources() -> [MangaSourceID] {
        allSnapshot().filter { $0.enabled && $0.manifest.type == .comic }.map { MangaSourceID.plugin($0.id) }
    }

    private var indexURL: URL { PluginPaths.root.appendingPathComponent("index.json") }
    private let d = UserDefaults.standard
    static let subsKey = "stv.plugins.subscriptions"

    private init() {
        if let data = try? Data(contentsOf: indexURL), let list = try? JSONDecoder().decode([InstalledPlugin].self, from: data) { plugins = list }
        subscriptions = d.data(forKey: Self.subsKey).flatMap { try? JSONDecoder().decode([PluginSubscription].self, from: $0) } ?? []
        publish()
        #if DEBUG
        DebugPlugins.seedIfRequested(self)
        #endif
    }

    private func publish() {
        Self.snapLock.lock()
        Self.snap = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0) })
        Self.snapLock.unlock()
        revision += 1
    }

    private func save() {
        if let data = try? JSONEncoder().encode(plugins) { try? data.write(to: indexURL, options: .atomic) }
        publish()
    }

    func plugin(_ id: String) -> InstalledPlugin? { plugins.first { $0.id == id } }

    /// Installed plugins the current gate lets the user see (adult ones only after the 片源管理 lock is open).
    var visiblePlugins: [InstalledPlugin] { plugins.filter { !$0.manifest.adult || SourceGate.shared.unlocked } }

    // MARK: Install / update

    func commit(_ p: PendingInstall) throws {
        let targets = Set(p.manifest.overrides ?? [])
        let conflicts = plugins.filter { $0.id != p.manifest.id && $0.enabled && !targets.isDisjoint(with: $0.manifest.overrides ?? []) }
        if let conflict = conflicts.first, let target = targets.intersection(conflict.manifest.overrides ?? []).sorted().first {
            throw PluginError.install("内置站源 \(target) 已由插件 \(conflict.manifest.name) 接管，请先停用或卸载冲突插件")
        }
        let dir = PluginPaths.dir(p.manifest.id)
        try Data(p.source.utf8).write(to: dir.appendingPathComponent(p.manifest.entry), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try JSONEncoder().encode(p.manifest).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        var rec = p.existing ?? InstalledPlugin(manifest: p.manifest, fileHashes: [:], origin: p.origin)
        rec.manifest = p.manifest
        rec.fileHashes = [p.manifest.entry: p.fileHash]
        rec.publicKey = p.signedBy ?? rec.publicKey
        rec.origin = p.origin
        rec.updatedAt = Date()
        rec.failures = 0
        rec.disabledReason = nil
        if p.existing == nil { rec.enabled = true }
        // Settings removed from the manifest are dropped.
        let keys = Set((p.manifest.settings ?? []).map(\.key))
        rec.settings = rec.settings.filter { keys.contains($0.key) }
        plugins.removeAll { $0.id == rec.id }
        plugins.append(rec)
        save()
        PluginRuntime.unload(rec.id)
        PluginLog.add(rec.id, p.existing == nil ? "安装 \(p.manifest.version)（来源 \(p.origin)）" : "更新到 \(p.manifest.version)")
    }

    func uninstall(_ id: String) {
        guard let rec = plugin(id) else { return }
        PluginRuntime.unload(id)
        PluginSecrets.removeAll(id, keys: (rec.manifest.settings ?? []).map(\.key))
        try? FileManager.default.removeItem(at: PluginPaths.dir(id))
        Task { await PluginCF.removeStore(id) }
        plugins.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ id: String, _ on: Bool) {
        if on, let rec = plugin(id) {
            let targets = Set(rec.manifest.overrides ?? [])
            let conflict = plugins.first { $0.id != id && $0.enabled && !targets.isDisjoint(with: $0.manifest.overrides ?? []) }
            if let conflict, let target = targets.intersection(conflict.manifest.overrides ?? []).sorted().first {
                PluginLog.add(id, "启用失败：内置站源 \\(target) 已由插件 \\(conflict.manifest.name) 接管")
                return
            }
        }
        mutate(id) { $0.enabled = on; if on { $0.failures = 0; $0.disabledReason = nil } }
        PluginRuntime.unload(id)
    }

    func setSetting(_ id: String, _ key: String, _ value: String) {
        guard let s = plugin(id)?.manifest.settings?.first(where: { $0.key == key }) else { return }
        if s.type == "secret" { PluginSecrets.set(id, key, value) } else { mutate(id) { $0.settings[key] = value } }
        PluginRuntime.unload(id)
    }

    func addDomain(_ id: String, _ domain: String) -> Bool {
        guard let r = DomainRule(domain) else { return false }
        mutate(id) { if !$0.extraDomains.contains(r.text) { $0.extraDomains.append(r.text) } }
        PluginLog.add(id, "用户授权新域名 \(r.text)")
        PluginRuntime.unload(id)
        return true
    }

    func removeDomain(_ id: String, _ domain: String) {
        mutate(id) { $0.extraDomains.removeAll { $0 == domain } }
        PluginRuntime.unload(id)
    }

    /// 清除数据：cookies, storage, WebKit store (keeps the plugin installed).
    func clearData(_ id: String) {
        PluginRuntime.unload(id)
        let dir = PluginPaths.dir(id)
        for f in ["cookies.plist", "storage.json"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        mutate(id) { $0.learnedUA = nil; $0.cachedCategories = [] }
        Task { await PluginCF.removeStore(id) }
        PluginLog.add(id, "已清除 cookie / 存储 / 浏览器数据")
    }

    func setLearnedUA(_ id: String, _ ua: String) { mutate(id) { $0.learnedUA = ua } }

    func cacheCategories(_ id: String, _ cats: [PluginCategory]) {
        guard plugin(id)?.cachedCategories != cats else { return }
        mutate(id) { $0.cachedCategories = cats }
    }

    /// Watchdog: 3 consecutive timeouts / memory blow-ups → disable.
    func recordOutcome(_ id: String, error: PluginError?) {
        guard let rec = plugin(id) else { return }
        if let e = error, ["E_TIMEOUT", "E_MEMORY"].contains(e.code) {
            let n = rec.failures + 1
            mutate(id) {
                $0.failures = n
                if n >= 3 { $0.enabled = false; $0.disabledReason = "连续 \(n) 次超时或内存超限，已自动停用" }
            }
            if n >= 3 { PluginRuntime.unload(id); PluginLog.add(id, "⛔︎ 连续 \(n) 次超时/内存超限，已自动停用") }
        } else if rec.failures != 0 {
            mutate(id) { $0.failures = 0 }
        }
    }

    func importWebCookies(_ id: String) async {
        guard let rec = plugin(id) else { return }
        let policy = DomainPolicy(rec.manifest.httpDomains + rec.extraDomains)
        let store = PluginCF.configuration(id).websiteDataStore
        let cookies = await store.httpCookieStore.allCookies().filter { policy.allows($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
        PluginRuntime.jar(id).add(cookies)
        PluginLog.add(id, "从验证页同步 \(cookies.count) 个 cookie")
    }

    private func mutate(_ id: String, _ f: (inout InstalledPlugin) -> Void) {
        guard let i = plugins.firstIndex(where: { $0.id == id }) else { return }
        f(&plugins[i])
        save()
    }

    // MARK: Subscriptions

    func addSubscription(_ url: String) async throws {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: u)?.scheme == "https" || URL(string: u)?.scheme == "http" else { throw PluginError.install("订阅地址必须是 http(s) 链接") }
        var sub = PluginSubscription(url: u)
        try await refresh(&sub)
        subscriptions.removeAll { $0.url == u }
        subscriptions.append(sub)
        saveSubs()
    }

    func refreshSubscriptions() async {
        for i in subscriptions.indices {
            var s = subscriptions[i]
            do { try await refresh(&s) } catch { s.error = error.localizedDescription }
            subscriptions[i] = s
        }
        saveSubs()
    }

    func removeSubscription(_ url: String) { subscriptions.removeAll { $0.url == url }; saveSubs() }

    private func refresh(_ sub: inout PluginSubscription) async throws {
        let data = try await PluginInstaller.download(sub.url, limit: 1 << 20)
        try PluginInstaller.applySubscription(data, to: &sub)
    }

    private func saveSubs() {
        if let data = try? JSONEncoder().encode(subscriptions) { d.set(data, forKey: Self.subsKey) }
        revision += 1
    }

    // MARK: Updates

    /// Pending updates (newer version at `update.url`).
    func checkUpdates() async -> [PendingInstall] {
        struct Catalog: Decodable {
            struct Entry: Decodable { let id: String; let manifest: String }
            let plugins: [Entry]
        }
        var catalogURLs: [String: String] = [:]
        // Older plugins may not declare update.url; resolve them through the
        // official catalog so existing installations can still receive updates.
        if let data = try? await PluginInstaller.download(
            "https://raw.githubusercontent.com/ericto888/iduanju-sources/main/index.json?_=" + String(Int(Date().timeIntervalSince1970)), limit: 1 << 20
        ), let catalog = try? JSONDecoder().decode(Catalog.self, from: data) {
            catalogURLs = Dictionary(catalog.plugins.map { ($0.id, $0.manifest) }, uniquingKeysWith: { first, _ in first })
        }

        var out: [PendingInstall] = []
        for p in plugins {
            let u = p.manifest.update?.url ?? catalogURLs[p.id]
            guard let u, !u.isEmpty else { continue }
            do {
                let pending = try await PluginInstaller.prepare(manifestURL: u, origin: p.origin)
                if PluginManifest.compare(pending.manifest.version, p.manifest.version) > 0 { out.append(pending) }
            } catch {
                PluginLog.add(p.id, "检查更新失败：\(error.localizedDescription)")
            }
        }
        return out
    }
}

/// Download / parse / validate a plugin before the user confirms. Nothing here touches installed state.
enum PluginInstaller {
    private final class NoRedirects:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
        func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
    }
    static func checkedDownloadURL(_ value:String) throws -> URL {
        guard let url=URL(string:value),url.scheme=="https",let host=url.host,!host.isEmpty,
              url.user==nil,url.password==nil,url.port==nil || url.port==443,!NetGuard.isIPLiteral(host) else {
            throw PluginError.install("插件/订阅地址只支持无凭证的 HTTPS 公网域名和443端口")
        }
        return url
    }
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func download(_ url: String, limit: Int) async throws -> Data {
        var next=url
        for hop in 0...5 {
            let u=try checkedDownloadURL(next)
            var req=URLRequest(url:u)
            req.setValue("STV/\(AppInfo.version) plugin-installer",forHTTPHeaderField:"User-Agent")
            let data:Data;let response:HTTPURLResponse
            #if DEBUG
            let fixture=PluginFixtures.responder?(req)
            #else
            let fixture:PluginFixtures.Reply?=nil
            #endif
            if let fixture {
                data=fixture.body
                response=HTTPURLResponse(url:u,statusCode:fixture.status,httpVersion:nil,headerFields:fixture.headers)!
            } else {
                if await Task.detached(operation:{NetGuard.resolvesToBlocked(u.host!)}).value { throw PluginError.install("插件/订阅地址解析到本机或内网，已拒绝") }
                let (body,resp)=try await session.data(for:req)
                guard let http=resp as? HTTPURLResponse else { throw PluginError.install("插件下载响应无效") }
                data=body;response=http
            }
            if [301,302,303,307,308].contains(response.statusCode),let location=response.value(forHTTPHeaderField:"Location") {
                guard hop<5,let target=URL(string:location,relativeTo:u)?.absoluteURL else { throw PluginError.install("插件跳转过多或地址无效") }
                next=target.absoluteString;continue
            }
            guard (200..<300).contains(response.statusCode) else { throw PluginError.install("下载失败 HTTP \(response.statusCode)：\(u.host ?? "")") }
            guard data.count<=limit else { throw PluginError.install("文件太大（>\(limit/1024)KB）") }
            return data
        }
        throw PluginError.install("插件跳转过多")
    }

    /// Text pasted / scanned by the user: a manifest URL, a subscription URL, an M3U URL, a bundle JSON or an M3U list.
    enum Pasted { case plugin(PendingInstall), subscription(String), tvbox(TVBoxImport.Config) }
    static func interpret(_ text: String) async throws -> Pasted {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if M3UImport.isChannelList(t) { return .plugin(try prepareM3U(t, url: nil, name: nil, origin: "粘贴")) }
        if let data = t.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           o["sites"] != nil || o["spider"] != nil || o["lives"] != nil {
            return .tvbox(try TVBoxImport.parse(data))
        }
        if t.hasPrefix("http://") || t.hasPrefix("https://") {
            let data = try await download(t, limit: 2 << 20)
            if let list = String(data: data, encoding: .utf8), M3UImport.isChannelList(list) {
                return .plugin(try prepareM3U(list, url: t, name: nil, origin: t))
            }
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if o["sites"] != nil || o["spider"] != nil || o["lives"] != nil { return .tvbox(try TVBoxImport.parse(data)) }
                if o["plugins"] != nil || o["cms"] != nil { return .subscription(t) }
                if o["manifest"] != nil { return .plugin(try prepare(bundle: data, origin: t)) }
                if o["schema"] != nil { return .plugin(try await prepare(manifestData: data, manifestURL: t, origin: t)) }
            }
            throw PluginError.install("这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U")
        }
        guard let data = t.data(using: .utf8) else { throw PluginError.install("无法识别") }
        return .plugin(try prepare(bundle: data, origin: "粘贴"))
    }

    /// A reviewed M3U channel list becomes a static video plugin, under the same rules as scripts/source-compat/m3u_to_idj.py.
    static func prepareLive(_ live: TVBoxImport.Live) async throws -> PendingInstall {
        let raw = String(decoding: try await download(live.url, limit: 2 << 20), as: UTF8.self)
        if M3UImport.isChannelList(raw) { return try prepareM3U(raw, url: live.url, name: live.name, origin: "TVBox") }
        var lines = ["#EXTM3U"]
        for line in raw.split(whereSeparator: \.isNewline) {
            guard let split = line.firstIndex(of: ",") else { continue }
            let title = line[..<split].trimmingCharacters(in: .whitespaces)
            let url = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            if !title.isEmpty, url.hasPrefix("https://") { lines += ["#EXTINF:-1," + title, url] }
        }
        return try prepareM3U(lines.joined(separator: "\n"), url: live.url, name: live.name, origin: "TVBox")
    }

    static func prepareM3U(_ text: String, url: String?, name: String?, origin: String) throws -> PendingInstall {
        let channels: [M3UImport.Channel]
        do { channels = try M3UImport.parse(text, base: url) }
        catch let e as M3UImport.Rejected { throw PluginError.install("M3U 导入失败：" + e.message) }
        let given = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = !given.isEmpty ? given : (url.flatMap { M3UImport.name(fromURL: $0) } ?? "M3U 频道列表")
        let data = try M3UImport.bundle(channels, name: title, id: M3UImport.importID(url ?? text), author: "M3U 导入")
        return try prepare(bundle: data, origin: origin)
    }

    static func prepare(manifestURL: String, origin: String) async throws -> PendingInstall {
        let data = try await download(manifestURL, limit: 256 << 10)
        return try await prepare(manifestData: data, manifestURL: manifestURL, origin: origin)
    }

    static func prepare(manifestData: Data, manifestURL: String, origin: String) async throws -> PendingInstall {
        let m = try PluginManifest.decode(manifestData)
        guard let base = URL(string: manifestURL), let entry = URL(string: m.entry, relativeTo: base) else { throw PluginError.install("entry 地址无效") }
        let js = try await download(entry.absoluteString, limit: 2 << 20)
        return try validate(manifest: m, source: js, origin: origin)
    }

    static func prepare(bundle data: Data, origin: String) throws -> PendingInstall {
        let b: PluginBundle
        do { b = try JSONDecoder().decode(PluginBundle.self, from: data) }
        catch {
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let m = o["manifest"] {
                _ = try PluginManifest.decode(try JSONSerialization.data(withJSONObject: m))
            }
            throw PluginError.install("不是合法的 .idjplugin（需要 {\"manifest\":…, \"files\":{…}}）")
        }
        let raw = try JSONSerialization.data(withJSONObject: (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["manifest"] ?? [:])
        let m = try PluginManifest.decode(raw)
        guard let js = b.files[m.entry] else { throw PluginError.install("包里缺少入口文件 \(m.entry)") }
        if b.files.count > 1 { throw PluginError.install("idj1 插件只能有一个脚本文件（不支持 import）") }
        return try validate(manifest: m, source: Data(js.utf8), origin: origin)
    }

    @MainActor static func validateOnMain(manifest m: PluginManifest, source: Data, origin: String) throws -> PendingInstall {
        try validate(manifest: m, source: source, origin: origin)
    }

    static func validate(manifest m: PluginManifest, source: Data, origin: String) throws -> PendingInstall {
        let problems = m.problems()
        guard problems.isEmpty else { throw PluginError.invalidManifest(problems) }
        guard let text = String(data: source, encoding: .utf8) else { throw PluginError.install("脚本不是 UTF-8 文本") }
        let hash = PluginManifest.fileHash(source)
        if let declared = m.integrity?.files?[m.entry], !declared.isEmpty, !declared.contains("<"), declared != hash {
            throw PluginError.integrity("\(m.entry) 的哈希与 manifest 声明不一致")
        }
        let existing = PluginStore.snapshot(m.id)
        var signer: String?
        if let sig = m.integrity?.signature {
            guard let pk = Data(base64Encoded: sig.publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pk),
                  let sv = Data(base64Encoded: sig.value),
                  key.isValidSignature(sv, for: PluginManifest.signingPayload(id: m.id, version: m.version, fileHashes: [m.entry: hash])) else {
                throw PluginError.integrity("作者签名无效")
            }
            signer = sig.publicKey
        }
        if let pinned = existing?.publicKey {
            guard signer == pinned else { throw PluginError.integrity(signer == nil ? "之前的版本有作者签名，这个更新没有，拒绝安装" : "更新的签名者与已安装版本不同，拒绝安装") }
        }
        if let e = existing, PluginManifest.compare(m.version, e.manifest.version) < 0 {
            throw PluginError.install("版本 \(m.version) 比已安装的 \(e.manifest.version) 旧")
        }
        // Compile check in a throw-away sandbox with no network (top-level code cannot phone home).
        let exported = try PluginRuntime.syntaxCheck(manifest: m, source: text)
        for c in m.type.requiredCapabilities where !exported.contains(c) { throw PluginError.install("脚本没有实现 \(c)()") }
        return PendingInstall(manifest: m, source: text, fileHash: hash, origin: origin, existing: existing,
                              diff: existing.map { PermissionDiff(old: $0.manifest, new: m) }, signedBy: signer, exported: exported.sorted())
    }

    static func applySubscription(_ data: Data, to sub: inout PluginSubscription) throws {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PluginError.install("订阅不是 JSON 对象") }
        // Reject foreign formats before mutating a saved subscription. Previously a TVBox
        // object silently succeeded with zero entries and erased the last good list.
        if o["sites"] != nil || o["spider"] != nil || o["lives"] != nil {
            throw PluginError.install("这是 TVBox 配置，不是 idj1 订阅；不支持直接运行 JAR / CatVod / Python 源")
        }
        guard o["plugins"] is [Any] || o["cms"] is [Any] else {
            throw PluginError.install("不是 idj1 订阅（需要 plugins 或 cms 数组）；阅读 RSS 规则不能直接导入")
        }
        for key in ["plugins", "cms"] where o[key] != nil && !(o[key] is [Any]) {
            throw PluginError.install("订阅字段 \(key) 必须是数组")
        }
        sub.name = o["name"] as? String ?? URL(string: sub.url)?.host ?? "订阅"
        let entries = (o["plugins"] as? [[String: Any]] ?? []).compactMap { e -> PluginSubscription.Entry? in
            guard let id = e["id"] as? String, let m = e["manifest"] as? String, let base = URL(string: sub.url),
                  let abs = URL(string: m, relativeTo: base)?.absoluteString else { return nil }
            return .init(id: id, name: e["name"] as? String ?? id, manifest: abs, type: e["type"] as? String, adult: e["adult"] as? Bool,
                         version: e["version"] as? String, description: e["description"] as? String)
        }
        let cms = (o["cms"] as? [[String: Any]] ?? []).compactMap { e -> PluginSubscription.CMSEntry? in
            guard let api = e["api"] as? String, URL(string: api)?.host != nil else { return nil }
            return .init(name: e["name"] as? String ?? (URL(string: api)?.host ?? api), api: api, adult: e["adult"] as? Bool)
        }
        sub.plugins = entries
        sub.cms = cms
        sub.fetchedAt = Date()
        sub.error = nil
    }

    /// Plugins shipped inside the app (Resources/Plugins/*.idjplugin) — offered under 推荐插件, never auto-installed.
    static func bundled() -> [(name: String, manifest: PluginManifest, data: Data)] {
        guard let root = Bundle.main.resourceURL else { return [] }
        // xcodegen flattens resource groups, so look both in the bundle root and in a Plugins folder.
        let files = [root, root.appendingPathComponent("Plugins")].flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        return files.filter { $0.pathExtension == "idjplugin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { f in
            guard let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let mo = o["manifest"],
                  let md = try? JSONSerialization.data(withJSONObject: mo), let m = try? PluginManifest.decode(md) else { return nil }
            return (f.deletingPathExtension().lastPathComponent, m, d)
        }
    }
}

/// Loaded plugin instances (lazy, one per enabled plugin).
enum PluginRuntime {
    nonisolated(unsafe) private static var instances: [String: PluginInstance] = [:]
    nonisolated(unsafe) private static var jars: [String: PluginCookieJar] = [:]
    private static let lock = NSLock()

    static func unload(_ id: String) {
        lock.lock(); let i = instances.removeValue(forKey: id); jars[id] = nil; lock.unlock()
        i?.shutdown()
    }

    static func jar(_ id: String) -> PluginCookieJar {
        lock.lock(); defer { lock.unlock() }
        if let i = instances[id] { return i.host.net.jar }
        if let j = jars[id] { return j }
        let j = PluginCookieJar(file: PluginPaths.dir(id).appendingPathComponent("cookies.plist"))
        jars[id] = j
        return j
    }

    private static func cached(_ id: String) -> PluginInstance? { lock.withLock { instances[id] } }
    /// Stores `inst` unless another load won the race (returns the winner then).
    private static func store(_ id: String, _ inst: PluginInstance) -> PluginInstance? {
        lock.withLock {
            if let existing = instances[id] { return existing }
            instances[id] = inst
            jars[id] = nil
            return nil
        }
    }

    static func instance(_ id: String) async throws -> PluginInstance {
        if let i = cached(id) { return i }
        guard let rec = PluginStore.snapshot(id) else { throw PluginError.runtime(code: "E_NOT_FOUND", message: "插件未安装：\(id)") }
        guard rec.enabled else { throw PluginError.runtime(code: "E_UNSUPPORTED", message: "插件已停用" + (rec.disabledReason.map { "：\($0)" } ?? "")) }
        let dir = PluginPaths.dir(id)
        let file = dir.appendingPathComponent(rec.manifest.entry)
        guard let data = try? Data(contentsOf: file) else { throw PluginError.integrity("脚本文件缺失") }
        guard PluginManifest.fileHash(data) == rec.fileHashes[rec.manifest.entry] else {
            PluginLog.add(id, "⛔︎ 脚本被改动（哈希不符），拒绝加载")
            throw PluginError.integrity("脚本文件与安装时不一致，已拒绝加载")
        }
        var settings = rec.settings
        for s in rec.manifest.settings ?? [] where s.type == "secret" { settings[s.key] = nil }
        let inst = try await Task.detached(priority: .userInitiated) {
            try PluginInstance(manifest: rec.manifest, source: String(decoding: data, as: UTF8.self), dir: dir, settings: settings,
                               extraDomains: rec.extraDomains, learnedUA: rec.learnedUA)
        }.value
        if let existing = store(id, inst) { inst.shutdown(); return existing }
        if inst.exported.contains("init") { _ = try? await inst.call("init", [:]) }
        return inst
    }

    /// Calls a plugin function with the watchdog bookkeeping.
    static func call(_ id: String, _ fn: String, _ arg: [String: Any]) async throws -> Any {
        let inst = try await instance(id)
        do {
            let r = try await inst.call(fn, arg)
            await MainActor.run { PluginStore.shared.recordOutcome(id, error: nil) }
            return r
        } catch let e as PluginError {
            PluginLog.add(id, "✕ \(fn)() \(e.code) \(e.errorDescription ?? "")")
            await MainActor.run { PluginStore.shared.recordOutcome(id, error: e) }
            throw e
        }
    }

    /// Compiles + loads the script with network disabled; returns exported function names.
    static func syntaxCheck(manifest: PluginManifest, source: String) throws -> Set<String> {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var m = manifest
        m.permissions.http = ["offline.invalid"]
        m.permissions.media = []
        m.permissions.cloudflare = false
        let inst = try PluginInstance(manifest: m, source: source, dir: tmp, settings: [:], extraDomains: [], learnedUA: nil)
        defer { inst.shutdown() }
        return inst.exported
    }
}
