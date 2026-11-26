import Foundation
import CommonCrypto
import CryptoKit
import zlib

/// Primitives behind the `hash`, `cipher`, `rsa` and `inflate` host calls. Padding is done here, so every mode accepts every
/// padding and the results match the Android side.
enum HostCrypto {
    // MARK: Digests

    static func hash(_ alg: String, _ d: Data, key: Data? = nil) throws -> Data {
        func mac<H: HashFunction>(_: H.Type) -> Data {
            guard let key else { return Data(H.hash(data: d)) }
            return Data(HMAC<H>.authenticationCode(for: d, using: SymmetricKey(data: key.isEmpty ? Data([0]) : key)))
        }
        switch alg.lowercased() {
        case "md5": return mac(Insecure.MD5.self)
        case "sha1": return mac(Insecure.SHA1.self)
        case "sha256": return mac(SHA256.self)
        case "sha512": return mac(SHA512.self)
        default: throw TVBoxError("不支持的摘要算法 \(alg)")
        }
    }

    static func hex<S: Sequence>(_ d: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for b in d { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Symmetric ciphers

    static func cipher(_ alg: String, _ mode: String, _ pad: String, encrypt: Bool, key: Data, iv: Data?, data: Data) throws -> Data {
        let a = alg.lowercased(), m = mode.isEmpty ? "cbc" : mode.lowercased()
        if a == "rc4" { return try crypt(CCAlgorithm(kCCAlgorithmRC4), CCMode(kCCModeRC4), true, key, nil, data, block: 1) }
        let algorithm: CCAlgorithm, block: Int
        switch a {
        case "aes": algorithm = CCAlgorithm(kCCAlgorithmAES); block = 16
        case "des": algorithm = CCAlgorithm(kCCAlgorithmDES); block = 8
        case "3des", "tripledes", "desede": algorithm = CCAlgorithm(kCCAlgorithm3DES); block = 8
        default: throw TVBoxError("不支持的加密算法 \(alg)")
        }
        let k = fit(a, key)
        if m == "gcm" {
            guard a == "aes" else { throw TVBoxError("\(alg) 不支持 GCM") }
            guard let nonce = try? AES.GCM.Nonce(data: iv ?? Data(count: 12)) else { throw TVBoxError("GCM 的 iv 至少 12 字节") }
            if encrypt {
                let box = try AES.GCM.seal(data, using: SymmetricKey(data: k), nonce: nonce)
                return box.ciphertext + box.tag
            }
            guard data.count >= 16, let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16)),
                  let out = try? AES.GCM.open(box, using: SymmetricKey(data: k)) else { throw TVBoxError("解密失败：校验不通过") }
            return out
        }
        let input = encrypt ? padded(data, pad, block) : data
        let vector = resized(iv ?? Data(), block)
        let out: Data
        switch m {
        case "ecb", "cbc":
            guard input.count % block == 0 else { throw TVBoxError("数据长度不是 \(block) 的整数倍") }
            out = try crypt(algorithm, CCMode(m == "ecb" ? kCCModeECB : kCCModeCBC), encrypt, k, m == "ecb" ? nil : vector, input, block: block)
        case "cfb", "ofb", "ctr": out = try stream(algorithm, m, encrypt, k, vector, input, block: block)
        default: throw TVBoxError("不支持的加密模式 \(mode)")
        }
        return encrypt ? out : try unpadded(out, pad, block)
    }

    private static func cryptor(_ alg: CCAlgorithm, _ mode: CCMode, _ encrypt: Bool, _ key: Data, _ iv: Data?) throws -> CCCryptorRef {
        var ref: CCCryptorRef?
        let st = key.withUnsafeBytes { k in
            (iv ?? Data()).withUnsafeBytes { v in
                CCCryptorCreateWithMode(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), mode, alg, CCPadding(ccNoPadding), iv == nil ? nil : v.baseAddress, k.baseAddress, key.count, nil, 0, 0, 0, &ref)
            }
        }
        guard st == kCCSuccess, let ref else { throw TVBoxError("加密参数无效（\(st)）") }
        return ref
    }

    private static func crypt(_ alg: CCAlgorithm, _ mode: CCMode, _ encrypt: Bool, _ key: Data, _ iv: Data?, _ data: Data, block: Int) throws -> Data {
        let ref = try cryptor(alg, mode, encrypt, key, iv)
        defer { CCCryptorRelease(ref) }
        var out = [UInt8](repeating: 0, count: data.count + block)
        var moved = 0
        let st = data.withUnsafeBytes { CCCryptorUpdate(ref, $0.baseAddress, data.count, &out, out.count, &moved) }
        guard st == kCCSuccess else { throw TVBoxError("加解密失败（\(st)）") }
        return Data(out[0..<moved])
    }

    /// CFB / OFB / CTR over full blocks; the last one may be short.
    private static func stream(_ alg: CCAlgorithm, _ mode: String, _ encrypt: Bool, _ key: Data, _ iv: Data, _ data: Data, block: Int) throws -> Data {
        let ref = try cryptor(alg, CCMode(kCCModeECB), true, key, nil)
        defer { CCCryptorRelease(ref) }
        let src = [UInt8](data)
        var out = [UInt8](repeating: 0, count: src.count), reg = [UInt8](iv), ks = [UInt8](repeating: 0, count: block), at = 0, moved = 0
        while at < src.count {
            guard CCCryptorUpdate(ref, reg, block, &ks, block, &moved) == kCCSuccess else { throw TVBoxError("加解密失败") }
            let n = min(block, src.count - at)
            for j in 0..<n { out[at + j] = src[at + j] ^ ks[j] }
            switch mode {
            case "ofb": reg = ks
            case "ctr":
                var j = block - 1
                while j >= 0 { reg[j] = reg[j] &+ 1; if reg[j] != 0 { break }; j -= 1 }
            default: if n == block { for j in 0..<block { reg[j] = encrypt ? out[at + j] : src[at + j] } }
            }
            at += n
        }
        return Data(out)
    }

    private static func resized(_ d: Data, _ n: Int) -> Data { d.count >= n ? Data(d.prefix(n)) : d + Data(count: n - d.count) }

    private static func fit(_ alg: String, _ key: Data) -> Data {
        switch alg {
        case "aes": return [16, 24, 32].contains(key.count) ? key : resized(key, key.count < 16 ? 16 : key.count < 24 ? 24 : 32)
        case "des": return resized(key, 8)
        default: return key.count >= 24 ? resized(key, 24) : resized(key, 16) + resized(key, 8)
        }
    }

    private static func padded(_ d: Data, _ pad: String, _ block: Int) -> Data {
        switch pad.lowercased() {
        case "none", "nopadding": return d
        case "zero", "zeropadding": return d.count % block == 0 ? d : d + Data(count: block - d.count % block)
        default:
            let n = block - d.count % block
            return d + Data(repeating: UInt8(n), count: n)
        }
    }

    private static func unpadded(_ d: Data, _ pad: String, _ block: Int) throws -> Data {
        switch pad.lowercased() {
        case "none", "nopadding": return d
        case "zero", "zeropadding": return Data(d.prefix((d.lastIndex { $0 != 0 }.map { $0 - d.startIndex + 1 }) ?? 0))
        default:
            let n = Int(d.last ?? 0)
            guard n >= 1, n <= block, n <= d.count, d.suffix(n).allSatisfy({ Int($0) == n }) else { throw TVBoxError("解密失败：填充无效") }
            return Data(d.dropLast(n))
        }
    }

    // MARK: RSA

    struct RSAKey {
        let n: [UInt8], e: [UInt8], d: [UInt8]?
        var size: Int { n.count }
    }

    /// PEM or Base64 DER: PKCS#1, PKCS#8 or SubjectPublicKeyInfo. Keys of any size work (SecKey refuses the short ones many
    /// sites still use).
    static func rsaKey(_ text: String) throws -> RSAKey {
        let body = text.replacingOccurrences(of: "-----[^-]+-----", with: "", options: .regularExpression)
        guard let k = rsaKey(der: [UInt8](RT.base64(body))[...], depth: 0) else { throw TVBoxError("RSA 密钥无法识别") }
        return k
    }

    private static func rsaKey(der: ArraySlice<UInt8>, depth: Int) -> RSAKey? {
        guard depth < 4, let outer = items(der)?.first, outer.tag == 0x30, let seq = items(outer.body) else { return nil }
        func number(_ i: Int) -> [UInt8] { Array(seq[i].body.drop { $0 == 0 }) }
        if seq.count == 2, seq.allSatisfy({ $0.tag == 2 }) { return RSAKey(n: number(0), e: number(1), d: nil) }
        if seq.count >= 9, seq.prefix(9).allSatisfy({ $0.tag == 2 }) { return RSAKey(n: number(1), e: number(2), d: number(3)) }
        if seq.count >= 3, seq[0].tag == 2, seq[2].tag == 4 { return rsaKey(der: seq[2].body, depth: depth + 1) }
        if seq.count == 2, seq[0].tag == 0x30, seq[1].tag == 3 { return rsaKey(der: seq[1].body.dropFirst(), depth: depth + 1) }
        return nil
    }

    private static func items(_ d: ArraySlice<UInt8>) -> [(tag: UInt8, body: ArraySlice<UInt8>)]? {
        var out: [(tag: UInt8, body: ArraySlice<UInt8>)] = [], i = d.startIndex
        while i < d.endIndex {
            let tag = d[i]
            i += 1
            guard i < d.endIndex else { return nil }
            var n = Int(d[i])
            i += 1
            if n >= 0x80 {
                let c = n & 0x7f
                guard c > 0, c <= 3, i + c <= d.endIndex else { return nil }
                n = 0
                for _ in 0..<c { n = n << 8 | Int(d[i]); i += 1 }
            }
            guard i + n <= d.endIndex else { return nil }
            out.append((tag, d[i..<(i + n)]))
            i += n
        }
        return out
    }

    private static func exponent(_ k: RSAKey, public pub: Bool) throws -> [UInt8] {
        if pub { return k.e }
        guard let d = k.d else { throw TVBoxError("需要 RSA 私钥") }
        return d
    }

    private static func power(_ x: [UInt8], _ k: RSAKey, public pub: Bool) throws -> [UInt8] {
        guard let r = BigMod.pow(x, try exponent(k, public: pub), k.n) else { throw TVBoxError("RSA 数据无效") }
        return r
    }

    /// Block-wise, so inputs longer than the modulus work like the JS libraries' "long" variants.
    static func rsa(encrypt: Bool, key: String, public pub: Bool, pad: String, data: Data) throws -> Data {
        let k = try rsaKey(key), size = k.size, src = [UInt8](data)
        let step = !encrypt || pad == "none" ? size : size - (pad == "oaep" ? 42 : 11)
        guard step > 0 else { throw TVBoxError("RSA 密钥太短") }
        var out: [UInt8] = [], at = 0
        repeat {
            let chunk = Array(src[at..<min(src.count, at + step)])
            at += step
            if encrypt {
                out += try power(pad == "none" ? chunk : pad == "oaep" ? oaep(chunk, size) : type1or2(chunk, size, type: pub ? 2 : 1), k, public: pub)
            } else {
                let raw = try power(chunk, k, public: pub)
                out += try pad == "none" ? raw : pad == "oaep" ? unOaep(raw) : unpad(raw)
            }
        } while at < src.count
        return Data(out)
    }

    private static func type1or2(_ m: [UInt8], _ size: Int, type: UInt8) -> [UInt8] {
        let fill = size - 3 - m.count
        var out: [UInt8] = [0, type]
        for _ in 0..<max(fill, 0) { out.append(type == 1 ? 0xff : UInt8.random(in: 1...255)) }
        out.append(0)
        return out + m
    }

    private static func unpad(_ r: [UInt8]) throws -> [UInt8] {
        guard r.count > 10, r[0] == 0, r[1] == 1 || r[1] == 2, let z = r[2...].firstIndex(of: 0), z >= 10 else { throw TVBoxError("RSA 解密失败：填充无效") }
        return Array(r[(z + 1)...])
    }

    private static func sha1(_ b: [UInt8]) -> [UInt8] { Array(Insecure.SHA1.hash(data: b)) }

    private static func mgf(_ seed: [UInt8], _ n: Int) -> [UInt8] {
        var out: [UInt8] = [], i: UInt32 = 0
        while out.count < n { out += sha1(seed + [UInt8(i >> 24), UInt8(i >> 16 & 255), UInt8(i >> 8 & 255), UInt8(i & 255)]); i += 1 }
        return Array(out.prefix(n))
    }

    private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] { zip(a, b).map { $0 ^ $1 } }

    private static func oaep(_ m: [UInt8], _ size: Int) -> [UInt8] {
        let seed = (0..<20).map { _ in UInt8.random(in: 0...255) }
        var db = sha1([])
        db += [UInt8](repeating: 0, count: size - m.count - 42)
        db.append(1)
        db += m
        let masked = xor(db, mgf(seed, db.count))
        var out: [UInt8] = [0]
        out += xor(seed, mgf(masked, 20))
        return out + masked
    }

    private static func unOaep(_ r: [UInt8]) throws -> [UInt8] {
        guard r.count >= 42, r[0] == 0 else { throw TVBoxError("RSA 解密失败：填充无效") }
        let masked = Array(r[21...]), seed = xor(Array(r[1..<21]), mgf(masked, 20)), db = xor(masked, mgf(seed, masked.count))
        guard Array(db.prefix(20)) == sha1([]), let one = db.dropFirst(20).firstIndex(where: { $0 != 0 }), db[one] == 1 else { throw TVBoxError("RSA 解密失败：填充无效") }
        return Array(db[(one + 1)...])
    }

    private static func digestInfo(_ hash: String, _ data: Data) throws -> [UInt8] {
        let prefix: [UInt8], digest: Data
        switch hash.lowercased().replacingOccurrences(of: "-", with: "") {
        case "md5": prefix = [0x30, 0x20, 0x30, 0x0c, 0x06, 0x08, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x05, 0x05, 0x00, 0x04, 0x10]; digest = Data(Insecure.MD5.hash(data: data))
        case "", "sha1": prefix = [0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14]; digest = Data(Insecure.SHA1.hash(data: data))
        case "sha256": prefix = [0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20]; digest = Data(SHA256.hash(data: data))
        case "sha384": prefix = [0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30]; digest = Data(SHA384.hash(data: data))
        case "sha512": prefix = [0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40]; digest = Data(SHA512.hash(data: data))
        default: throw TVBoxError("不支持的签名摘要 \(hash)")
        }
        return prefix + [UInt8](digest)
    }

    static func rsaSign(key: String, hash: String, data: Data) throws -> Data {
        let k = try rsaKey(key), info = try digestInfo(hash, data)
        guard k.size >= info.count + 11 else { throw TVBoxError("RSA 密钥太短") }
        return Data(try power(type1or2(info, k.size, type: 1), k, public: false))
    }

    static func rsaVerify(key: String, hash: String, data: Data, signature: Data) throws -> Bool {
        let k = try rsaKey(key), info = try digestInfo(hash, data)
        guard k.size >= info.count + 11, signature.count <= k.size, let raw = BigMod.pow([UInt8](signature), k.e, k.n) else { return false }
        return raw == type1or2(info, k.size, type: 1)
    }

    // MARK: Inflate

    static func inflate(_ d: Data, _ kind: String, limit: Int = NetRequest.defaultMaxBytes) throws -> Data {
        guard !d.isEmpty else { return Data() }
        var z = z_stream()
        guard inflateInit2_(&z, kind == "gzip" ? 31 : kind == "raw" ? -15 : 15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw TVBoxError("解压失败") }
        defer { inflateEnd(&z) }
        var src = [UInt8](d), out = Data(), buffer = [UInt8](repeating: 0, count: 64 << 10)
        try src.withUnsafeMutableBufferPointer { s in
            z.next_in = s.baseAddress
            z.avail_in = uInt(s.count)
            while true {
                let rc = buffer.withUnsafeMutableBufferPointer { b -> Int32 in
                    z.next_out = b.baseAddress
                    z.avail_out = uInt(b.count)
                    return zlib.inflate(&z, Z_NO_FLUSH)
                }
                let n = buffer.count - Int(z.avail_out)
                guard out.count + n <= limit else { throw TVBoxError("内容超过 \(limit >> 20) MB") }
                out.append(contentsOf: buffer[0..<n])
                if rc == Z_STREAM_END {
                    // a gzip file may have several members
                    if kind == "gzip", z.avail_in > 18, inflateReset(&z) == Z_OK { continue }
                    return
                }
                guard rc == Z_OK, n > 0 || z.avail_in > 0 else { throw TVBoxError("压缩数据无效或不完整") }
            }
        }
        return out
    }
}

/// Modular exponentiation (Montgomery) on big-endian byte strings; the modulus must be odd.
enum BigMod {
    /// nil when the base is not smaller than the modulus. The result is as long as the modulus.
    static func pow(_ base: [UInt8], _ exponent: [UInt8], _ modulus: [UInt8]) -> [UInt8]? {
        var m = limbs(modulus)
        while m.last == 0 { m.removeLast() }
        let k = m.count
        guard let low = m.first, low & 1 == 1 else { return nil }
        var b = limbs(base)
        while b.count > k, b.last == 0 { b.removeLast() }
        guard b.count <= k else { return nil }
        b += [UInt32](repeating: 0, count: k - b.count)
        guard less(b, m) else { return nil }
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- low &* inv) }
        let n0 = 0 &- inv
        // one = R mod m, then R² mod m, by doubling
        var one = [UInt32](repeating: 0, count: k)
        one[0] = 1
        if k == 1, low == 1 { return [UInt8](repeating: 0, count: modulus.count) }
        for _ in 0..<(32 * k) { double(&one, m) }
        var square = one
        for _ in 0..<(32 * k) { double(&square, m) }
        var t = [UInt32](repeating: 0, count: k + 2)
        func mul(_ x: [UInt32], _ y: [UInt32]) -> [UInt32] {
            var r = [UInt32](repeating: 0, count: k)
            montgomery(x, y, m, n0, &t, &r)
            return r
        }
        let x = mul(b, square)
        var acc = one, started = false
        for byte in exponent {
            for bit in stride(from: 7, through: 0, by: -1) {
                if started { acc = mul(acc, acc) }
                if byte >> UInt8(bit) & 1 == 1 { acc = mul(acc, x); started = true }
            }
        }
        var unit = [UInt32](repeating: 0, count: k)
        unit[0] = 1
        let r = mul(acc, unit)
        var out = [UInt8](repeating: 0, count: modulus.count)
        for i in 0..<out.count {
            let w = i / 4
            if w < k { out[out.count - 1 - i] = UInt8(truncatingIfNeeded: r[w] >> UInt32(8 * (i % 4))) }
        }
        return out
    }

    private static func limbs(_ b: [UInt8]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: (b.count + 3) / 4)
        for (i, x) in b.reversed().enumerated() { out[i / 4] |= UInt32(x) << UInt32(8 * (i % 4)) }
        return out
    }

    private static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: b.count - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] }
        return false
    }

    private static func double(_ x: inout [UInt32], _ m: [UInt32]) {
        var carry: UInt32 = 0
        for i in 0..<x.count { let v = x[i]; x[i] = v << 1 | carry; carry = v >> 31 }
        if carry != 0 || !less(x, m) { subtract(&x, m) }
    }

    private static func subtract(_ x: inout [UInt32], _ m: [UInt32]) {
        var borrow: UInt64 = 0
        for i in 0..<m.count {
            let v = UInt64(x[i]) &- UInt64(m[i]) &- borrow
            x[i] = UInt32(truncatingIfNeeded: v)
            borrow = v >> 63
        }
    }

    private static func montgomery(_ a: [UInt32], _ b: [UInt32], _ m: [UInt32], _ n0: UInt32, _ scratch: inout [UInt32], _ out: inout [UInt32]) {
        let k = m.count
        let over: Bool = a.withUnsafeBufferPointer { a in b.withUnsafeBufferPointer { b in m.withUnsafeBufferPointer { m in scratch.withUnsafeMutableBufferPointer { t in
            for i in 0..<(k + 2) { t[i] = 0 }
            for i in 0..<k {
                let y = UInt64(b[i])
                var c: UInt64 = 0
                for j in 0..<k {
                    let s = UInt64(t[j]) &+ UInt64(a[j]) &* y &+ c
                    t[j] = UInt32(truncatingIfNeeded: s)
                    c = s >> 32
                }
                var s = UInt64(t[k]) &+ c
                t[k] = UInt32(truncatingIfNeeded: s)
                t[k + 1] = UInt32(truncatingIfNeeded: s >> 32)
                let u = UInt64(t[0] &* n0)
                c = (UInt64(t[0]) &+ u &* UInt64(m[0])) >> 32
                for j in 1..<max(k, 1) {
                    s = UInt64(t[j]) &+ u &* UInt64(m[j]) &+ c
                    t[j - 1] = UInt32(truncatingIfNeeded: s)
                    c = s >> 32
                }
                s = UInt64(t[k]) &+ c
                t[k - 1] = UInt32(truncatingIfNeeded: s)
                t[k] = t[k + 1] &+ UInt32(truncatingIfNeeded: s >> 32)
            }
            return t[k] != 0
        } } } }
        for i in 0..<k { out[i] = scratch[i] }
        if over || !less(out, m) { subtract(&out, m) }
    }
}
