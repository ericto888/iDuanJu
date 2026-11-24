import Foundation
import JavaScriptCore
import CommonCrypto
import Security

/// Thin JavaScriptCore bridge for the GuoApp Hongguo V5 playback signer.
/// The signing implementation is kept byte-for-byte aligned with the GuoApp source;
/// native networking, device registration, and media parsing remain in Swift.
final class HGPlaybackV5Signer {
    private let context: JSContext

    init() throws {
        guard let context = JSContext() else {
            throw ProviderError.upstream("无法创建红果 V5 签名运行环境")
        }
        self.context = context
        context.exceptionHandler = { _, exception in
            NSLog("[HG-V5] JavaScript exception: %@", exception?.toString() ?? "unknown")
        }

        let native = JSValue(newObjectIn: context)!
        let hexDecode: @convention(block) (String) -> [NSNumber] = { value in
            guard value.count % 2 == 0 else { return [] }
            var bytes: [NSNumber] = []
            let chars = Array(value.utf8)
            for i in stride(from: 0, to: chars.count, by: 2) {
                guard let hi = Self.hexNibble(chars[i]), let lo = Self.hexNibble(chars[i + 1]) else { return [] }
                bytes.append(NSNumber(value: (hi << 4) | lo))
            }
            return bytes
        }
        let md5: @convention(block) (NSArray) -> [NSNumber] = { input in
            Self.md5(Self.bytes(input)).map(NSNumber.init(value:))
        }
        let utf8Encode: @convention(block) (String) -> [NSNumber] = { value in
            Array(value.utf8).map(NSNumber.init(value:))
        }
        let hexEncode: @convention(block) (NSArray) -> String = { input in
            Self.bytes(input).map { String(format: "%02x", $0) }.joined()
        }
        let base64Encode: @convention(block) (NSArray) -> String = { input in
            Data(Self.bytes(input)).base64EncodedString()
        }
        let randomBytes: @convention(block) (Int) -> [NSNumber] = { count in
            Self.randomBytes(max(0, min(count, 4096))).map(NSNumber.init(value:))
        }
        let aesCbcEncrypt: @convention(block) (NSArray, NSArray, NSArray) -> [NSNumber] = { key, iv, input in
            Self.aesCBCEncrypt(Self.bytes(input), key: Self.bytes(key), iv: Self.bytes(iv)).map(NSNumber.init(value:))
        }

        native.setObject(hexDecode, forKeyedSubscript: "hexDecode" as NSString)
        native.setObject(md5, forKeyedSubscript: "md5" as NSString)
        native.setObject(utf8Encode, forKeyedSubscript: "utf8Encode" as NSString)
        native.setObject(hexEncode, forKeyedSubscript: "hexEncode" as NSString)
        native.setObject(base64Encode, forKeyedSubscript: "base64Encode" as NSString)
        native.setObject(randomBytes, forKeyedSubscript: "randomBytes" as NSString)
        native.setObject(aesCbcEncrypt, forKeyedSubscript: "aesCbcEncrypt" as NSString)
        context.setObject(native, forKeyedSubscript: "__nativeHost" as NSString)

        let shim = """
        var host = {
          hexDecode: function(s) { return new Uint8Array(__nativeHost.hexDecode(String(s))); },
          md5: function(b) { return new Uint8Array(__nativeHost.md5(Array.from(b))); },
          utf8Encode: function(s) { return new Uint8Array(__nativeHost.utf8Encode(String(s))); },
          hexEncode: function(b) { return __nativeHost.hexEncode(Array.from(b)); },
          base64Encode: function(b) { return __nativeHost.base64Encode(Array.from(b)); },
          randomBytes: function(n) { return new Uint8Array(__nativeHost.randomBytes(Number(n))); },
          aesCbcEncrypt: function(k, iv, b) {
            return new Uint8Array(__nativeHost.aesCbcEncrypt(Array.from(k), Array.from(iv), Array.from(b)));
          }
        };
        """
        _ = context.evaluateScript(shim)
        guard let url = Bundle.main.url(forResource: "HGPlaybackV5", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            throw ProviderError.upstream("缺少红果 V5 签名脚本资源")
        }
        _ = context.evaluateScript(script)
        _ = context.evaluateScript("globalThis.__signPlaybackV5 = signPlaybackV5;")
        if let exception = context.exception {
            context.exception = nil
            throw ProviderError.upstream("红果 V5 签名脚本初始化失败：\(exception.toString() ?? "unknown")")
        }
    }

    func sign(base: String, values: [String: String], body: Data?, nowMillis: Int64) throws -> (url: String, headers: [String: String]) {
        guard let function = context.objectForKeyedSubscript("__signPlaybackV5") else {
            throw ProviderError.upstream("红果 V5 签名函数不可用")
        }
        let bodyValue: Any = body.map { $0.map { NSNumber(value: $0) } as NSArray } ?? NSNull()
        let result = function.call(withArguments: [base, values as NSDictionary, bodyValue, NSNumber(value: nowMillis)])
        if let exception = context.exception {
            context.exception = nil
            throw ProviderError.upstream("红果 V5 签名失败：\(exception.toString() ?? "unknown")")
        }
        guard let result, let url = result.objectForKeyedSubscript("url")?.toString(),
              let rawHeaders = result.objectForKeyedSubscript("headers")?.toDictionary() as? [String: Any] else {
            throw ProviderError.upstream("红果 V5 签名结果无效")
        }
        let headers = rawHeaders.reduce(into: [String: String]()) { output, pair in
            if let value = pair.value as? String { output[pair.key] = value }
        }
        return (url, headers)
    }

    private static func bytes(_ values: NSArray) -> [UInt8] {
        values.compactMap { ($0 as? NSNumber).map { UInt8(truncatingIfNeeded: $0.intValue) } }
    }

    private static func hexNibble(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: return value - 48
        case 65...70: return value - 65 + 10
        case 97...102: return value - 97 + 10
        default: return nil
        }
    }

    private static func md5(_ input: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        input.withUnsafeBytes { raw in
            _ = CC_MD5(raw.baseAddress, CC_LONG(input.count), &digest)
        }
        return digest
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: count)
        guard count > 0 else { return output }
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &output)
        if status != errSecSuccess {
            for index in output.indices { output[index] = UInt8.random(in: 0...255) }
        }
        return output
    }

    private static func aesCBCEncrypt(_ input: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return [] }
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                input.withUnsafeBytes { inputBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inputBytes.baseAddress, input.count, &output, output.count, &moved)
                }
            }
        }
        guard status == kCCSuccess else { return [] }
        return Array(output.prefix(moved))
    }
}
