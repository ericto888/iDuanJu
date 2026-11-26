import Foundation

/// Stale-while-revalidate store for home / category / live texts: one folder per owner, plain files, bounded.
final class TVBoxCache {
    struct Hit {
        let text: String
        let at: Date
        var ageMs: Int { Int(Date().timeIntervalSince(at) * 1000) }
    }

    /// Bigger texts are read from disk each time.
    private static let maxInMemory = 1 << 20

    private let dir: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private var memory: [String: Hit] = [:]
    /// Least recently used first.
    private var order: [String] = []
    /// Files are read and written one at a time; texts are small.
    private let disk = NSLock()

    init(_ dir: URL, maxBytes: Int = 48 << 20) { self.dir = dir; self.maxBytes = maxBytes }

    private func folder(_ owner: String) -> URL { dir.appendingPathComponent(String(owner.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(40)), isDirectory: true) }
    private func file(_ owner: String, _ key: String) -> URL { folder(owner).appendingPathComponent(Bytes.hex(Bytes.md5(key))) }

    /// `lock` is held.
    private func remember(_ id: String, _ hit: Hit, _ bytes: Int) {
        order.removeAll { $0 == id }
        memory[id] = bytes < Self.maxInMemory ? hit : nil
        if memory[id] == nil { return }
        order.append(id)
        if order.count > 24 { memory[order.removeFirst()] = nil }
    }

    func get(_ owner: String, _ key: String) -> Hit? {
        let id = "\(owner)|\(key)"
        lock.lock()
        if let h = memory[id] { remember(id, h, 0); lock.unlock(); return h }
        lock.unlock()
        let f = file(owner, key)
        disk.lock()
        let data = try? Data(contentsOf: f)
        let at = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date
        disk.unlock()
        guard let data, let at else { return nil }
        let hit = Hit(text: String(decoding: data, as: UTF8.self), at: at)
        lock.lock()
        remember(id, hit, data.count)
        lock.unlock()
        return hit
    }

    func put(_ owner: String, _ key: String, _ text: String) {
        let data = Data(text.utf8)
        disk.lock()
        try? FileManager.default.createDirectory(at: folder(owner), withIntermediateDirectories: true)
        try? data.write(to: file(owner, key), options: .atomic)
        disk.unlock()
        lock.lock()
        remember("\(owner)|\(key)", Hit(text: text, at: Date()), data.count)
        lock.unlock()
    }

    func clear(_ owner: String) {
        lock.lock()
        for k in order where k.hasPrefix(owner + "|") { memory[k] = nil }
        order.removeAll { memory[$0] == nil }
        lock.unlock()
        disk.lock()
        defer { disk.unlock() }
        try? FileManager.default.removeItem(at: folder(owner))
    }

    /// Oldest files first once the folder grows past its budget (called off the main thread at start).
    func trim() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int, at: Date)] = []
        for case let u as URL in walk {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files.append((u, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for f in files.sorted(by: { $0.at < $1.at }) {
            if total <= maxBytes { return }
            total -= f.size
            disk.lock()
            try? FileManager.default.removeItem(at: f.url)
            disk.unlock()
        }
    }
}
