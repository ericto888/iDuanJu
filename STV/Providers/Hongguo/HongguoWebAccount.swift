import Foundation
import WebKit

/// Hongguo web account session (QR login via https://hongguoduanju.com) + cloud watch-history sync.
/// Mirrors Android's `HongguoWebAccount.kt`.
@MainActor
final class HongguoWebAccount: ObservableObject {
    struct Profile: Codable, Equatable {
        let nickname: String
        let avatarUrl: String
    }

    static let shared = HongguoWebAccount()
    static let webOrigin = "https://hongguoduanju.com"
    static let pcUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private static let profileKey = "stv.hg.web.profile"
    private static let cookieKey = "stv.hg.web.cookie"
    private static let sessionTagTTL: TimeInterval = 15 * 60
    private static let reportThrottle: TimeInterval = 30

    @Published private(set) var profile: Profile?
    @Published private(set) var syncing = false
    @Published private(set) var lastSyncNote: String?

    var isLoggedIn: Bool { profile != nil }

    private var cachedCookieHeader: String?
    private var sessionTags: [String: (tag: String, at: Date)] = [:]
    private var lastReportedAt: [String: Date] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        return URLSession(configuration: c)
    }()

    private init() {
        cachedCookieHeader = UserDefaults.standard.string(forKey: Self.cookieKey)
        if let data = UserDefaults.standard.data(forKey: Self.profileKey),
           let saved = try? JSONDecoder().decode(Profile.self, from: data),
           !saved.nickname.isEmpty {
            profile = saved
        }
    }

    /// Snapshot cookies for `hongguoduanju.com` from `WKWebsiteDataStore` into `UserDefaults`.
    func syncCookiesFromWebView() async -> String? {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let matching = all.filter { c in
            let d = c.domain.lowercased()
            return d == "hongguoduanju.com" || d == ".hongguoduanju.com" || d.hasSuffix(".hongguoduanju.com")
        }
        guard !matching.isEmpty else {
            return cachedCookieHeader
        }
        let header = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        cachedCookieHeader = header
        UserDefaults.standard.set(header, forKey: Self.cookieKey)
        return header
    }

    private func saveProfile(_ next: Profile?) {
        profile = next
        if let next, let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.profileKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.profileKey)
        }
    }

    @discardableResult
    func refreshProfile() async -> Profile? {
        syncing = true
        defer { syncing = false }
        let cookie = await syncCookiesFromWebView()
        guard let cookie, !cookie.isEmpty, let url = URL(string: "\(Self.webOrigin)/api/pc/profile") else {
            saveProfile(nil)
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(Self.pcUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("\(Self.webOrigin)/", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let p = root["profile"] as? [String: Any] else {
                if code == 200 { saveProfile(nil) }
                return profile
            }
            let nickname = ((p["nickname"] as? String) ?? (p["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let avatar = ((p["avatarUrl"] as? String) ?? (p["avatar_url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nickname.isEmpty else {
                saveProfile(nil)
                return nil
            }
            let next = Profile(nickname: nickname, avatarUrl: avatar)
            saveProfile(next)
            return next
        } catch {
            return profile
        }
    }

    func logout() {
        Task {
            let store = WKWebsiteDataStore.default().httpCookieStore
            let all = await store.allCookies()
            for c in all where c.domain.lowercased().contains("hongguoduanju.com") {
                await store.deleteCookie(c)
            }
        }
        cachedCookieHeader = nil
        UserDefaults.standard.removeObject(forKey: Self.cookieKey)
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
        sessionTags.removeAll()
        lastReportedAt.removeAll()
        profile = nil
        lastSyncNote = nil
    }

    func reportProgressAsync(
        seriesId: String,
        vid: String,
        episodeNumber: Int,
        positionMs: Int64,
        accumulatedMs: Int64,
        force: Bool = false
    ) {
        guard isLoggedIn,
              !seriesId.isEmpty, seriesId.allSatisfy(\.isNumber),
              !vid.isEmpty, vid.allSatisfy(\.isNumber),
              episodeNumber > 0, positionMs >= 0 else { return }

        let key = "\(seriesId):\(vid)"
        let now = Date()
        if !force, let prev = lastReportedAt[key], now.timeIntervalSince(prev) < Self.reportThrottle {
            return
        }
        lastReportedAt[key] = now

        Task { [weak self] in
            guard let self else { return }
            guard let cookie = await self.syncCookiesFromWebView(), !cookie.isEmpty else { return }
            guard let sessionTag = await self.fetchSessionTag(seriesId: seriesId, vid: vid, cookie: cookie) else {
                self.lastSyncNote = "未获取到网页同步会话，请尝试重新登录"
                return
            }
            guard let url = URL(string: "\(Self.webOrigin)/api/pc/watch-history") else { return }
            let payload: [String: Any] = [
                "book_id": seriesId,
                "book_type": 2,
                "is_delete": false,
                "read_timestamp_ms": String(Int64(Date().timeIntervalSince1970 * 1000)),
                "vid": vid,
                "vid_index": String(episodeNumber),
                "current_play_position": String(max(0, positionMs)),
                "player_accumulate_total_time": String(max(1000, accumulatedMs))
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            req.setValue(Self.pcUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue(Self.webOrigin, forHTTPHeaderField: "Origin")
            req.setValue("\(Self.webOrigin)/player/\(seriesId)/\(vid)", forHTTPHeaderField: "Referer")
            req.setValue(sessionTag, forHTTPHeaderField: "X-PC-History-Session")

            do {
                let (data, resp) = try await self.session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let ok = (json?["isSuccess"] as? Bool) == true
                if ok {
                    self.lastSyncNote = "已同步第 \(episodeNumber) 集到红果"
                } else {
                    if code == 401 || code == 403 || !ok {
                        self.sessionTags.removeValue(forKey: seriesId)
                    }
                    let reason = (json?["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "HTTP \(code)"
                    self.lastSyncNote = "同步未生效（\(reason)）"
                }
            } catch {
                // Silent network failure during background sync
            }
        }
    }

    private func fetchSessionTag(seriesId: String, vid: String, cookie: String) async -> String? {
        if let cached = sessionTags[seriesId], Date().timeIntervalSince(cached.at) < Self.sessionTagTTL {
            return cached.tag
        }
        let candidates = ["\(Self.webOrigin)/player/\(seriesId)/\(vid)", "\(Self.webOrigin)/player/\(seriesId)"]
        for page in candidates {
            guard let url = URL(string: page) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            req.setValue(Self.pcUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("\(Self.webOrigin)/", forHTTPHeaderField: "Referer")
            guard let (data, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { continue }
            if let tag = Self.extractSessionTag(from: html) {
                sessionTags[seriesId] = (tag, Date())
                return tag
            }
        }
        return nil
    }

    private static func extractSessionTag(from html: String) -> String? {
        let patterns = [
            "\"pcHistorySessionTag\"\\s*:\\s*\"([^\"]+)\"",
            "\\\\\"pcHistorySessionTag\\\\\"\\s*:\\s*\\\\\"([^\\\\\"]+)\\\\\""
        ]
        let ns = html as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges >= 2 else { continue }
            let range = match.range(at: 1)
            if range.location != NSNotFound {
                let value = ns.substring(with: range)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}
