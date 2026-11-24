import Foundation
import Security

/// Dedicated device identity for GuoApp's 7.4.5.32 V5 playback profile.
/// Kept separate from search/category and the older 7.3.9 player identities.
struct HGPlaybackV5Device: Codable {
    var deviceId: String
    var iid: String
    var registeredAt: Double

    static let maxAge: TimeInterval = 7 * 60
    var isUsable: Bool {
        !deviceId.isEmpty && deviceId != "0" && !iid.isEmpty && iid != "0" &&
        Date().timeIntervalSince1970 - registeredAt < Self.maxAge
    }

    private static let appVersionCode = "74532"
    private static let appVersionName = "7.4.5.32"
    private static let appUA = "com.phoenix.read/74532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
    private static let registerURL = "https://log.snssdk.com/service/2/device_register/"

    private static var fileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("hongguo_playback_v5_device.json")
    }

    static func load() -> HGPlaybackV5Device? {
        for url in [fileURL, URL(fileURLWithPath: fileURL.path + ".bak")] {
            guard let data = try? Data(contentsOf: url),
                  let device = try? JSONDecoder().decode(HGPlaybackV5Device.self, from: data),
                  device.isUsable else { continue }
            return device
        }
        return nil
    }

    func save() {
        if let old = try? Data(contentsOf: Self.fileURL), !old.isEmpty {
            try? old.write(to: URL(fileURLWithPath: Self.fileURL.path + ".bak"), options: .atomic)
        }
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func register(session: URLSession) async throws -> HGPlaybackV5Device {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let cdid = UUID().uuidString.lowercased()
        let openudid = randomHex(8)
        var query: [String: String] = [
            "aid": "8662", "app_name": "novelread", "version_code": appVersionCode, "version_name": appVersionName,
            "manifest_version_code": appVersionCode, "update_version_code": appVersionCode, "channel": "update_64",
            "device_platform": "android", "os": "android", "ssmix": "a", "device_type": "25053RT47C",
            "device_brand": "Redmi", "language": "zh", "os_api": "36", "os_version": "16",
            "resolution": "1280*2772", "dpi": "520", "ac": "wifi", "req_id": UUID().uuidString.lowercased(),
            "_rticket": String(now)
        ]
        let queryString = query.keys.sorted().map { key in
            Self.escape(key) + "=" + Self.escape(query[key] ?? "")
        }.joined(separator: "&")

        let header: [String: Any] = [
            "display_name": "红果免费短剧", "aid": 8662, "app_version": appVersionName, "version_code": 74532,
            "manifest_version_code": 74532, "update_version_code": 74532, "channel": "update_64",
            "package": "com.phoenix.read", "app_language": "zh", "os": "Android", "os_version": "16", "os_api": 36,
            "device_model": "25053RT47C", "device_brand": "Redmi", "device_manufacturer": "Xiaomi",
            "cpu_abi": "arm64-v8a", "density_dpi": 520, "display_density": "xxhdpi", "resolution": "2772x1280",
            "language": "zh", "timezone": 8, "access": "wifi", "openudid": openudid,
            "clientudid": UUID().uuidString.lowercased(), "cdid": cdid, "region": "CN", "tz_name": "Asia/Shanghai",
            "tz_offset": 28800, "sim_region": "cn", "device_platform": "android", "not_request_sender": 0,
            "is_system_app": 0, "sdk_flavor": "china", "rom": "OS2.0", "rom_version": "BP2A.250605.031.A3"
        ]
        let bodyObject: [String: Any] = [
            "magic_tag": "ss_app_log", "header": header, "_gen_time": Int(now / 1000)
        ]
        let body = try JSONSerialization.data(withJSONObject: bodyObject, options: [.sortedKeys])
        guard let url = URL(string: registerURL + "?" + queryString) else {
            throw ProviderError.invalid("红果 V5 设备注册地址无效")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(appUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else {
            throw ProviderError.upstream("红果 V5 设备注册 HTTP \(status)")
        }
        let json = try J.parse(data)
        var deviceId = J.firstNonEmpty(J.str(json["device_id_str"]), J.str(json["device_id"]))
        var installId = J.firstNonEmpty(J.str(json["install_id_str"]), J.str(json["install_id"]), J.str(json["iid"]))
        guard deviceId.allSatisfy(\.isNumber), installId.allSatisfy(\.isNumber),
              !deviceId.isEmpty, deviceId != "0", !installId.isEmpty, installId != "0" else {
            throw ProviderError.upstream("红果 V5 设备注册未返回有效身份")
        }
        let device = HGPlaybackV5Device(deviceId: deviceId, iid: installId, registeredAt: Date().timeIntervalSince1970)
        device.save()
        return device
    }

    private static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: "%20", with: "+") ?? value
    }
}
