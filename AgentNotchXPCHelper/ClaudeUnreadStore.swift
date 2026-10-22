import Foundation

// Bounded, read-only snapshot of Claude's own unread IDs. Never opens/locks or
// modifies its live LevelDB. Sequence numbers resolve SST/WAL versions and deletes.
enum ClaudeUnreadStore {
    enum Invalid: Error { case data }
    struct Version { let sequence: UInt64; let value: [UInt8]? }
    static let target = Array("_https://claude.ai\0\u{1}epitaxy-unread-v1".utf8)
    static let limit = 32 * 1024 * 1024

    static func ids(home: URL) -> Set<String>? {
        let root = home.appendingPathComponent("Library/Application Support/Claude/Local Storage/leveldb")
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var latest: Version?
        for file in files where ["ldb", "log"].contains(file.pathExtension) {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= limit, let data = try? Data(contentsOf: file) else { continue }
            let versions = (try? (file.pathExtension == "ldb" ? table(Array(data)) : log(Array(data)))) ?? []
            for version in versions where latest == nil || version.sequence > latest!.sequence { latest = version }
        }
        guard let latest else { return nil }
        guard let value = latest.value else { return [] }
        guard let encoding = value.first, encoding == 0 || encoding == 1,
              let string = String(bytes: value.dropFirst(), encoding: encoding == 1 ? .utf8 : .utf16LittleEndian),
              let data = string.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = object["state"] as? [String: Any], let unread = state["unreadIds"] as? [String] else { return nil }
        return Set(unread + (state["explicitUnreadIds"] as? [String] ?? []))
    }

    static func integer(_ bytes: [UInt8], _ offset: Int, _ count: Int) throws -> UInt64 {
        guard offset >= 0, count <= 8, offset <= bytes.count - count else { throw Invalid.data }
        return (0..<count).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
    }
    static func variable(_ bytes: [UInt8], _ offset: inout Int) throws -> Int {
        var result = 0
        for shift in stride(from: 0, through: 56, by: 7) {
            guard offset < bytes.count else { throw Invalid.data }
            let byte = bytes[offset]; offset += 1
            result |= Int(byte & 127) << shift
            if byte < 128 { return result }
        }
        throw Invalid.data
    }
    static func take(_ bytes: [UInt8], _ offset: inout Int, _ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= limit, offset >= 0, offset <= bytes.count - count else { throw Invalid.data }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
    static func snappy(_ bytes: [UInt8]) throws -> [UInt8] {
        var offset = 0
        let size = try variable(bytes, &offset)
        guard size <= limit else { throw Invalid.data }
        var output: [UInt8] = []; output.reserveCapacity(size)
        while offset < bytes.count {
            let tag = bytes[offset]; offset += 1
            let kind = tag & 3
            var count = Int(tag >> 2)
            if kind == 0 {
                if count < 60 { count += 1 }
                else {
                    let width = count - 59
                    count = Int(try integer(bytes, offset, width)) + 1; offset += width
                }
                guard count <= size - output.count else { throw Invalid.data }
                output += try take(bytes, &offset, count)
            } else {
                let distance: Int
                if kind == 1 {
                    guard offset < bytes.count else { throw Invalid.data }
                    count = 4 + Int((tag >> 2) & 7)
                    distance = (Int(tag & 224) << 3) | Int(bytes[offset]); offset += 1
                } else {
                    let width = kind == 2 ? 2 : 4
                    distance = Int(try integer(bytes, offset, width)); offset += width; count += 1
                }
                guard distance > 0, distance <= output.count, count <= size - output.count else { throw Invalid.data }
                for _ in 0..<count { output.append(output[output.count - distance]) }
            }
        }
        guard output.count == size else { throw Invalid.data }
        return output
    }
    static func block(_ bytes: [UInt8], _ handle: [UInt8]) throws -> [UInt8] {
        var cursor = 0
        let start = try variable(handle, &cursor), size = try variable(handle, &cursor)
        guard start >= 0, size >= 0, start <= bytes.count - size - 5 else { throw Invalid.data }
        let raw = Array(bytes[start..<start + size])
        switch bytes[start + size] {
        case 0: return raw
        case 1: return try snappy(raw)
        default: throw Invalid.data
        }
    }
    static func entries(_ bytes: [UInt8]) throws -> [([UInt8], [UInt8])] {
        guard bytes.count >= 4 else { throw Invalid.data }
        let restarts = Int(try integer(bytes, bytes.count - 4, 4))
        guard restarts <= (bytes.count - 4) / 4 else { throw Invalid.data }
        let end = bytes.count - 4 - restarts * 4
        var offset = 0, previous: [UInt8] = [], result: [([UInt8], [UInt8])] = []
        while offset < end {
            let shared = try variable(bytes, &offset), unique = try variable(bytes, &offset), size = try variable(bytes, &offset)
            guard shared <= previous.count else { throw Invalid.data }
            let key = Array(previous.prefix(shared)) + (try take(bytes, &offset, unique))
            let value = try take(bytes, &offset, size)
            guard offset <= end else { throw Invalid.data }
            previous = key; result.append((key, value))
        }
        return result
    }
    static func table(_ bytes: [UInt8]) throws -> [Version] {
        guard bytes.count >= 48, try integer(bytes, bytes.count - 8, 8) == 0xdb4775248b80fb57 else { throw Invalid.data }
        let footer = Array(bytes.suffix(48)); var offset = 0
        _ = try variable(footer, &offset); _ = try variable(footer, &offset)
        let index = Array(footer[offset..<40])
        var versions: [Version] = []
        for (_, handle) in try entries(block(bytes, index)) {
            for (key, value) in try entries(block(bytes, handle)) where key.count >= 8 && Array(key.dropLast(8)) == target {
                let packed = try integer(key, key.count - 8, 8)
                versions.append(Version(sequence: packed >> 8, value: packed & 255 == 1 ? value : nil))
            }
        }
        return versions
    }
    static func batch(_ bytes: [UInt8]) throws -> [Version] {
        guard bytes.count >= 12 else { throw Invalid.data }
        let sequence = try integer(bytes, 0, 8), count = Int(try integer(bytes, 8, 4))
        guard count <= bytes.count else { throw Invalid.data }
        var offset = 12, versions: [Version] = []
        for index in 0..<count {
            guard offset < bytes.count else { throw Invalid.data }
            let kind = bytes[offset]; offset += 1
            guard kind == 0 || kind == 1 else { throw Invalid.data }
            let length = try variable(bytes, &offset), key = try take(bytes, &offset, length)
            var value: [UInt8]?
            if kind == 1 { let length = try variable(bytes, &offset); value = try take(bytes, &offset, length) }
            if key == target { versions.append(Version(sequence: sequence + UInt64(index), value: value)) }
        }
        return versions
    }
    static func log(_ bytes: [UInt8]) throws -> [Version] {
        var offset = 0, pending: [UInt8] = [], versions: [Version] = []
        while offset + 7 <= bytes.count {
            if offset % 32768 > 32761 { offset += 32768 - offset % 32768; continue }
            let length = Int(try integer(bytes, offset + 4, 2)), kind = bytes[offset + 6]; offset += 7
            guard length <= 32768 - (offset % 32768), offset + length <= bytes.count else { break }
            let fragment = try take(bytes, &offset, length)
            switch kind {
            case 1: versions += (try? batch(fragment)) ?? []
            case 2: pending = fragment
            case 3: if pending.count + fragment.count <= limit { pending += fragment } else { pending = [] }
            case 4:
                if pending.count + fragment.count <= limit { versions += (try? batch(pending + fragment)) ?? [] }
                pending = []
            default: pending = []
            }
        }
        return versions
    }
}
