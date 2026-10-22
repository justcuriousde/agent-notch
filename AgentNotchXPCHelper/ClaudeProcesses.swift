import Darwin
import Foundation

// Finds Claude Desktop's local Claude Code processes and the session each one
// serves. Claude Desktop starts each CLI with CLAUDE_CODE_HOST_SESSION_ID set to
// the session's `local_…` id. Only process metadata of the same user is read.
enum ClaudeProcesses {
    private static let sessionKey = Array("CLAUDE_CODE_HOST_SESSION_ID=".utf8)
    // Keyed by pid + start time so a reused pid is never mistaken for an old one.
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func liveSessionIDs() -> Set<String> {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var result = Set<String>()
        var seen: [String: String] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == getuid(),
                  name(of: info) == "claude" else { continue }
            let key = "\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
            // "" remembers a claude process without a desktop session (e.g. terminal).
            let id = cache[key] ?? sessionID(pid: pid) ?? ""
            seen[key] = id
            if !id.isEmpty { result.insert(id) }
        }
        cache = seen
        return result
    }

    private static func name(of info: proc_bsdinfo) -> String {
        withUnsafeBytes(of: info.pbi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func sessionID(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        bytes.removeSubrange(size...)
        let key = sessionKey
        guard bytes.count > key.count else { return nil }
        var index = 0
        while index <= bytes.count - key.count {
            // Each argument and environment entry starts after a NUL byte.
            if (index == 0 || bytes[index - 1] == 0), bytes[index] == key[0],
               bytes[index..<index + key.count].elementsEqual(key) {
                let start = index + key.count
                let end = bytes[start...].firstIndex(of: 0) ?? bytes.count
                let id = String(decoding: bytes[start..<end], as: UTF8.self)
                return id.hasPrefix("local_") ? id : nil
            }
            index += 1
        }
        return nil
    }
}
