import Foundation
import Security

/// WebDAV multi-device sync for watch progress, favorites, installed plugins (including scripts/settings/cookies),
/// subscriptions, MacCMS sites, TVBox configs, source ordering, Legado book sources, novels & manga.
///
/// Built on top of `AppBackup`'s lossless smart-merge archive (`sync.idjbackup`), so two-way sync merges
/// newest episode timestamps & unions collections across iPhone / iPad without clobbering offline edits.
@MainActor
final class WebDAVSync: ObservableObject {
    static let shared = WebDAVSync()

    static let syncFileName = "sync.idjbackup"
    private static let urlKey = "stv.webdav.url"
    private static let userKey = "stv.webdav.user"
    private static let folderKey = "stv.webdav.folder"
    private static let autoKey = "stv.webdav.auto"
    private static let lastAtKey = "stv.webdav.lastAt"
    private static let lastStatusKey = "stv.webdav.lastStatus"
    private static let keychainService = "com.local.STV.webdav"
    private static let keychainAccount = "password"

    @Published var serverURL: String
    @Published var username: String
    @Published var password: String
    @Published var remoteFolder: String
    @Published var autoSync: Bool
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastStatus: String?
    @Published private(set) var busy: String?

    private let d = UserDefaults.standard
    private var lastAutoAt: Date?

    private init() {
        serverURL = d.string(forKey: Self.urlKey) ?? ""
        username = d.string(forKey: Self.userKey) ?? ""
        remoteFolder = d.string(forKey: Self.folderKey) ?? "iDuanJu"
        autoSync = d.bool(forKey: Self.autoKey)
        lastSyncAt = d.object(forKey: Self.lastAtKey) as? Date
        lastStatus = d.string(forKey: Self.lastStatusKey)
        password = Self.loadKeychainPassword() ?? ""
    }

    var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    var statusBadge: String? {
        guard isConfigured else { return nil }
        if let busy { return busy }
        if let lastSyncAt {
            let f = RelativeDateTimeFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.unitsStyle = .abbreviated
            return autoSync ? "自动 · " + f.localizedString(for: lastSyncAt, relativeTo: Date()) : f.localizedString(for: lastSyncAt, relativeTo: Date())
        }
        return autoSync ? "已开启自动" : "已配置"
    }

    func saveConfig() {
        serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Self.cleanFolder(remoteFolder)
        remoteFolder = folder
        d.set(serverURL, forKey: Self.urlKey)
        d.set(username, forKey: Self.userKey)
        d.set(folder, forKey: Self.folderKey)
        d.set(autoSync, forKey: Self.autoKey)
        Self.saveKeychainPassword(password)
    }

    func clearConfig() {
        serverURL = ""
        username = ""
        password = ""
        remoteFolder = "iDuanJu"
        autoSync = false
        lastSyncAt = nil
        lastStatus = nil
        for k in [Self.urlKey, Self.userKey, Self.folderKey, Self.autoKey, Self.lastAtKey, Self.lastStatusKey] {
            d.removeObject(forKey: k)
        }
        Self.deleteKeychainPassword()
    }

    // MARK: Operations

    enum SyncError: LocalizedError {
        case notConfigured
        case invalidURL
        case unauthorized
        case serverError(Int, String)
        case noRemoteBackup

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "请先填写 WebDAV 服务器地址、账号和应用密码"
            case .invalidURL: return "WebDAV 地址格式无效（需以 http:// 或 https:// 开头）"
            case .unauthorized: return "WebDAV 鉴权失败（401），请检查账号与应用专用密码"
            case .serverError(let code, let detail): return "WebDAV 请求失败（HTTP \(code)\(detail.isEmpty ? "" : "：\(detail)")）"
            case .noRemoteBackup: return "云端尚无同步文件，请先点击「双向同步」或「上传到云端」"
            }
        }
    }

    func testConnection() async throws -> String {
        saveConfig()
        let req = try makeTarget()
        busy = "测试中…"
        defer { busy = nil }
        let code = try await Self.probeAndEnsureFolder(req)
        let msg = code == 201 ? "连接成功，已自动创建目录 /\(req.folder)/" : "WebDAV 连接正常"
        recordStatus(msg, stampDate: false)
        return msg
    }

    /// Two-way smart-merge sync: download & smart-merge remote snapshot first, then upload the merged snapshot.
    @discardableResult
    func syncNow() async throws -> String {
        saveConfig()
        let target = try makeTarget()
        guard busy == nil else { return "同步进行中" }
        busy = "同步中…"
        defer { busy = nil }

        _ = try await Self.probeAndEnsureFolder(target)

        // 1. Pull remote snapshot if present and smart-merge locally.
        var mergedRemote = false
        if let remoteData = try await Self.getFile(target) {
            if AppBackup.isBackupData(remoteData) {
                _ = try await AppBackup.restore(from: remoteData)
                mergedRemote = true
            }
        }

        // 2. Pack merged local state and upload back to WebDAV.
        let localData = try await AppBackup.createBackupData()
        try await Self.putFile(target, data: localData)

        let plugins = PluginStore.shared.plugins.count
        let history = LibraryStore.shared.progress.count
        let favs = LibraryStore.shared.allFavorites.count
        let msg = (mergedRemote ? "双向合并完成" : "首次上传完成") + " · 插件 \(plugins) · 进度 \(history) · 收藏 \(favs)"
        recordStatus(msg, stampDate: true)
        return msg
    }

    @discardableResult
    func pushOnly() async throws -> String {
        saveConfig()
        let target = try makeTarget()
        guard busy == nil else { return "同步进行中" }
        busy = "上传中…"
        defer { busy = nil }

        _ = try await Self.probeAndEnsureFolder(target)
        let data = try await AppBackup.createBackupData()
        try await Self.putFile(target, data: data)
        let kb = max(1, data.count / 1024)
        let msg = "已上传到云端（\(kb) KB）"
        recordStatus(msg, stampDate: true)
        return msg
    }

    @discardableResult
    func pullOnly() async throws -> String {
        saveConfig()
        let target = try makeTarget()
        guard busy == nil else { return "同步进行中" }
        busy = "拉取中…"
        defer { busy = nil }

        guard let data = try await Self.getFile(target) else { throw SyncError.noRemoteBackup }
        let summary = try await AppBackup.restore(from: data)
        let msg = "云端拉取成功 · " + summary.toastText
        recordStatus(msg, stampDate: true)
        return msg
    }

    func autoSyncIfNeeded(minInterval: TimeInterval = 90) async {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["STV_SHOTS"] == "1" { return }
        guard autoSync, isConfigured, busy == nil else { return }
        if let last = lastAutoAt, Date().timeIntervalSince(last) < minInterval { return }
        lastAutoAt = Date()
        _ = try? await syncNow()
    }

    private func recordStatus(_ msg: String, stampDate: Bool) {
        lastStatus = msg
        d.set(msg, forKey: Self.lastStatusKey)
        if stampDate {
            let now = Date()
            lastSyncAt = now
            d.set(now, forKey: Self.lastAtKey)
        }
    }

    // MARK: URL & HTTP Wire Layer

    struct Target: Sendable {
        let baseURL: URL
        let folderSegments: [String]
        let folder: String
        let folderURL: URL
        let fileURL: URL
        let authHeader: String
    }

    private func makeTarget() throws -> Target {
        guard isConfigured else { throw SyncError.notConfigured }
        return try Self.buildTarget(serverURL: serverURL, folder: remoteFolder, username: username, password: password)
    }

    nonisolated static func cleanFolder(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " /\t\r\n"))
        let parts = trimmed.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.isEmpty ? "iDuanJu" : parts.joined(separator: "/")
    }

    nonisolated static func buildTarget(serverURL: String, folder: String, username: String, password: String) throws -> Target {
        var normalized = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.hasSuffix("/") { normalized += "/" }
        guard let base = URL(string: normalized),
              let scheme = base.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              base.host != nil else {
            throw SyncError.invalidURL
        }
        let cleaned = cleanFolder(folder)
        let segs = cleaned.split(separator: "/").map(String.init)
        var folderURL = base
        for seg in segs {
            folderURL = folderURL.appendingPathComponent(seg, isDirectory: true)
        }
        let fileURL = folderURL.appendingPathComponent(syncFileName, isDirectory: false)
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return Target(baseURL: base, folderSegments: segs, folder: cleaned, folderURL: folderURL, fileURL: fileURL, authHeader: "Basic \(token)")
    }

    /// URLSession delegate that preserves Basic Auth only on same-host redirects (prevents credential leaks).
    private final class SameHostRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var next = request
            if let oldHost = task.originalRequest?.url?.host?.lowercased(),
               let newHost = request.url?.host?.lowercased(),
               oldHost == newHost,
               let auth = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
                next.setValue(auth, forHTTPHeaderField: "Authorization")
            } else {
                next.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            completionHandler(next)
        }
    }

    private nonisolated static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: SameHostRedirectDelegate(), delegateQueue: nil)
    }

    private nonisolated static func request(_ url: URL, method: String, auth: String, body: Data? = nil, headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue(auth, forHTTPHeaderField: "Authorization")
        r.setValue("iDuanJu-WebDAV/1.6", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = body
        return r
    }

    private nonisolated static func probeAndEnsureFolder(_ t: Target) async throws -> Int {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        // Check folder existence via PROPFIND Depth: 0
        let prop = request(t.folderURL, method: "PROPFIND", auth: t.authHeader, headers: ["Depth": "0"])
        let (_, resp) = try await session.data(for: prop)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.serverError(0, "无响应") }
        if http.statusCode == 401 || http.statusCode == 403 { throw SyncError.unauthorized }
        if (200...299).contains(http.statusCode) { return http.statusCode }

        // Create intermediate directories via MKCOL
        var cur = t.baseURL
        var lastCode = http.statusCode
        for seg in t.folderSegments {
            cur = cur.appendingPathComponent(seg, isDirectory: true)
            let mk = request(cur, method: "MKCOL", auth: t.authHeader)
            let (_, mkResp) = try await session.data(for: mk)
            guard let mkHTTP = mkResp as? HTTPURLResponse else { continue }
            lastCode = mkHTTP.statusCode
            if mkHTTP.statusCode == 401 || mkHTTP.statusCode == 403 { throw SyncError.unauthorized }
            if !(200...299).contains(mkHTTP.statusCode) && mkHTTP.statusCode != 405 && mkHTTP.statusCode != 301 && mkHTTP.statusCode != 302 {
                throw SyncError.serverError(mkHTTP.statusCode, "创建目录失败")
            }
        }
        return lastCode
    }

    private nonisolated static func getFile(_ t: Target) async throws -> Data? {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let req = request(t.fileURL, method: "GET", auth: t.authHeader)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.serverError(0, "无响应") }
        if http.statusCode == 401 || http.statusCode == 403 { throw SyncError.unauthorized }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw SyncError.serverError(http.statusCode, "读取云端文件失败")
        }
        return data
    }

    private nonisolated static func putFile(_ t: Target, data: Data) async throws {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let req = request(t.fileURL, method: "PUT", auth: t.authHeader, body: data, headers: ["Content-Type": "application/octet-stream"])
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.serverError(0, "无响应") }
        if http.statusCode == 401 || http.statusCode == 403 { throw SyncError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw SyncError.serverError(http.statusCode, "写入云端文件失败")
        }
    }

    // MARK: Keychain

    private nonisolated static func saveKeychainPassword(_ password: String) {
        deleteKeychainPassword()
        guard !password.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private nonisolated static func loadKeychainPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func deleteKeychainPassword() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
