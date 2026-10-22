import Foundation
import SQLite3
import CryptoKit

// Read-only adapters. No credentials, chat content, or remote API calls leave this process.
enum AgentSessionReader {
    struct Row: Codable {
        let id: String
        let kind: String
        let title: String
        let status: String
        let updated: Double
        var tasks: [PlanTask]? = nil
    }
    // One step of the agent's own task list: "done", "active" or "pending".
    struct PlanTask: Codable, Equatable {
        let title: String
        let status: String
    }
    static let queue = DispatchQueue(label: "app.agentnotch.sessions", qos: .utility)

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Row] {
        (codex(home: home) + claude(home: home)).sorted { $0.updated > $1.updated }
    }

    static func shouldDisplay(status: String, unread: Bool) -> Bool {
        status == "Cooking…" || status == "Waiting" || (status == "Done" && unread)
    }

    // Match Electron's account-scoped read-state identity, without using or
    // transmitting a credential. The JWT is decoded only for account/user IDs.
    static func codexUnreadIDs(home: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".codex/.codex-global-state.json")),
              let global = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = global["electron-thread-read-state-v1"] as? [String: Any],
              let identities = state["unreadByIdentity"] as? [String: [String: [String]]],
              let authData = try? Data(contentsOf: home.appendingPathComponent(".codex/auth.json")),
              let auth = (try? JSONSerialization.jsonObject(with: authData)) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any], let token = tokens["id_token"] as? String else { return [] }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return [] }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let payload = Data(base64Encoded: encoded),
              let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let principal = claims["https://api.openai.com/auth"] as? [String: Any],
              let account = principal["chatgpt_account_id"] as? String,
              let user = principal["chatgpt_user_id"] as? String,
              let identity = try? JSONSerialization.data(withJSONObject: ["chatgpt", account, user], options: [.withoutEscapingSlashes]) else { return [] }
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return Set((identities[key] ?? [:]).filter { $0.key.hasPrefix("local:") }.flatMap(\.value))
    }

    static func codexTurnStatuses(home: URL) -> [String: String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent(".codex/thread_history_1.sqlite").path,
                             &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }; return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 150)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT thread_id,status FROM thread_turns ORDER BY thread_id,rollout_ordinal DESC", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let status = sqlite3_column_text(statement, 1) else { continue }
            let key = String(cString: id)
            if result[key] == nil { result[key] = String(cString: status) }
        }
        return result
    }

    static func tail(_ url: URL) -> [[String: Any]] {
        guard let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return [] }
        try? file.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        guard let data = try? file.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            guard let data = String($0).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    // A pending structured question remains waiting until its matching result or
    // a turn boundary. Never infer a question from ordinary assistant prose.
    static func codexWaiting(_ events: [[String: Any]]) -> Bool {
        var resolved = Set<String>()
        for event in events.reversed() {
            let payload = event["payload"] as? [String: Any] ?? [:]
            let type = payload["type"] as? String ?? ""
            if event["type"] as? String == "event_msg",
               ["task_started", "turn_started", "user_message", "task_complete", "task_completed",
                "turn_complete", "turn_completed", "turn_aborted", "task_aborted"].contains(type) { return false }
            guard event["type"] as? String == "response_item" else { continue }
            if ["function_call_output", "custom_tool_call_output"].contains(type),
               let id = payload["call_id"] as? String { resolved.insert(id) }
            if ["function_call", "custom_tool_call"].contains(type),
               let name = payload["name"] as? String,
               ["request_user_input", "request_user_input_async"].contains(name.components(separatedBy: ".").last ?? ""),
               let id = payload["call_id"] as? String, !resolved.contains(id) { return true }
        }
        return false
    }

    static func codexStatus(_ events: [[String: Any]], updated: Double, now: Double = Date().timeIntervalSince1970) -> String {
        if codexWaiting(events) { return "Waiting" }
        for event in events.reversed() {
            let payload = event["payload"] as? [String: Any] ?? [:]
            let type = payload["type"] as? String ?? ""
            if event["type"] as? String == "event_msg" {
                if ["task_complete", "task_completed", "turn_complete", "turn_completed"].contains(type) { return "Done" }
                if ["turn_aborted", "task_aborted"].contains(type) { return "Stopped" }
                if ["task_started", "turn_started", "user_message"].contains(type) {
                    return now - updated < 120 ? "Cooking…" : "Idle"
                }
            }
            if event["type"] as? String == "response_item", type == "message",
               payload["role"] as? String == "assistant", payload["phase"] as? String == "final_answer" { return "Done" }
            if event["type"] as? String == "response_item",
               ["function_call", "custom_tool_call", "reasoning"].contains(type) {
                return now - updated < 120 ? "Cooking…" : "Idle"
            }
        }
        return "Idle"
    }

    static func codex(home: URL) -> [Row] {
        var db: OpaquePointer?
        let path = home.appendingPathComponent(".codex/state_5.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }; return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 150)
        var statement: OpaquePointer?
        let sql = "SELECT id,COALESCE(NULLIF(name,''),title),rollout_path,updated_at FROM threads WHERE archived=0 AND source NOT LIKE '%subagent%' ORDER BY updated_at DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        func value(_ index: Int32) -> String {
            sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
        }
        let unread = codexUnreadIDs(home: home)
        let statuses = codexTurnStatuses(home: home)
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let updated = sqlite3_column_double(statement, 3)
            let id = value(0)
            let status: String
            switch statuses[id] {
            case "inProgress": status = codexWaiting(tail(URL(fileURLWithPath: value(2)))) ? "Waiting" : "Cooking…"
            case "asking", "waitingForInput", "needsInput": status = "Waiting"
            case "completed": status = "Done"
            case "failed": status = "Error"
            case "interrupted": status = "Stopped"
            default: status = codexStatus(tail(URL(fileURLWithPath: value(2))), updated: updated)
            }
            guard shouldDisplay(status: status, unread: unread.contains(id)) else { continue }
            rows.append(Row(id: id, kind: "gpt", title: value(1),
                            status: status == "Cooking…" ? "Loading" : status, updated: updated))
        }
        return rows
    }

    // Where a Claude transcript says the latest turn stands.
    enum ClaudeTurn: Equatable { case done, stopped, running, waiting, unknown }

    static func claudeTurn(_ events: [[String: Any]]) -> ClaudeTurn {
        var latest: ClaudeTurn = .unknown
        for event in events.reversed() where event["isSidechain"] as? Bool != true {
            let type = event["type"] as? String
            guard type == "assistant" || type == "user" else { continue }
            let message = event["message"] as? [String: Any] ?? [:]
            let blocks = message["content"] as? [[String: Any]] ?? []
            if type == "assistant" {
                let tools = blocks.filter { $0["type"] as? String == "tool_use" }
                for tool in tools.reversed() {
                    let name = tool["name"] as? String ?? ""
                    let input = tool["input"] as? [String: Any] ?? [:]
                    if name == "mcp__ccd_turn__wrap_up" {
                        let ask = input["ask"] as? String ?? ""
                        return ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .done : .waiting
                    }
                    if name == "AskUserQuestion", latest != .done { return .waiting }
                }
                if !tools.isEmpty { return latest == .unknown ? .running : latest }
                if latest == .unknown {
                    let stop = message["stop_reason"] as? String ?? ""
                    latest = ["end_turn", "stop_sequence", "max_tokens", "refusal"].contains(stop) ? .done : .running
                }
                // A final text message follows wrap_up; keep looking for its ask.
                continue
            }
            if isInterruption(message["content"]) { return .stopped }
            // Tool results acknowledge delivery of the card, not the user's answer.
            if !blocks.isEmpty && blocks.allSatisfy({ $0["type"] as? String == "tool_result" }) {
                if latest == .unknown { latest = .running }
                continue
            }
            return latest == .unknown ? .running : latest
        }
        return latest
    }

    private static func isInterruption(_ content: Any?) -> Bool {
        if let text = content as? String { return text.hasPrefix("[Request interrupted") }
        guard let blocks = content as? [[String: Any]], blocks.count == 1,
              blocks[0]["type"] as? String == "text", let text = blocks[0]["text"] as? String else { return false }
        return text.hasPrefix("[Request interrupted")
    }

    /// - lastWrite: newest of the session metadata and transcript write times.
    ///   Claude only updates `lastActivityAt` at turn edges, so the transcript is
    ///   what moves while a turn runs.
    /// - processAlive: Claude Desktop still has the session's CLI process. Long
    ///   tool calls and long thinking write nothing for minutes; a live process
    ///   keeps such a turn Cooking instead of letting it drop out.
    static func claudeStatus(_ metadata: [String: Any], turn: ClaudeTurn, lastWrite: Double,
                             processAlive: Bool, now: Double = Date().timeIntervalSince1970) -> String {
        if metadata["interruptedAwaitingPerson"] as? Bool == true || turn == .waiting { return "Waiting" }
        let quiet = now - lastWrite
        if turn == .running, quiet < 120 || (processAlive && quiet < 3600) { return "Cooking…" }
        if let error = metadata["error"] as? String, !error.isEmpty { return "Error" }
        if metadata["lastTurnCutShort"] as? Bool == true { return "Stopped" }
        switch turn {
        case .done: return "Done"
        case .stopped: return "Stopped"
        case .waiting: return "Waiting"
        case .running, .unknown: return "Idle"
        }
    }

    static func claudeStatus(_ metadata: [String: Any], events: [[String: Any]], now: Double = Date().timeIntervalSince1970) -> String {
        claudeStatus(metadata, turn: claudeTurn(events),
                     lastWrite: (metadata["lastActivityAt"] as? Double ?? 0) / 1000, processAlive: false, now: now)
    }

    // Reads backward until it finds the latest turn event. Screenshots can make
    // one transcript line larger than a fixed-size tail, so the window grows.
    static func lastClaudeTurn(_ url: URL, size: UInt64) -> ClaudeTurn {
        guard let file = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? file.close() }
        var window: UInt64 = 262_144
        while true {
            let offset = size > window ? size - window : 0
            guard (try? file.seek(toOffset: offset)) != nil, let data = try? file.read(upToCount: Int(size - offset)) else { return .unknown }
            var lines = data.split(separator: UInt8(ascii: "\n"))
            if offset > 0, !lines.isEmpty { lines.removeFirst() } // partial line
            let assistant = Data("\"type\":\"assistant\"".utf8), user = Data("\"type\":\"user\"".utf8)
            let events: [[String: Any]] = lines.compactMap { line in
                guard line.range(of: assistant) != nil || line.range(of: user) != nil else { return nil }
                return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
            }
            let turn = claudeTurn(events)
            if turn != .unknown || offset == 0 || window >= 16_777_216 { return turn }
            window *= 4
        }
    }

    // Rebuilds the task list the agent keeps with update_plan (Claude Desktop)
    // or TodoWrite (CLI). Only the latest full list and the steps after it count.
    static func claudePlan(_ events: [[String: Any]]) -> [PlanTask]? {
        var tasks: [PlanTask]?
        func set(_ index: Int, _ status: String) {
            guard var list = tasks, list.indices.contains(index) else { return }
            list[index] = PlanTask(title: list[index].title, status: status)
            tasks = list
        }
        func normalized(_ status: String?) -> String {
            switch status {
            case "completed": return "done"
            case "in_progress": return "active"
            default: return "pending"
            }
        }
        for event in events where event["isSidechain"] as? Bool != true {
            // A new message from the person starts a new turn; the old list is over.
            if event["type"] as? String == "user" {
                if isHumanPrompt(event) { tasks = nil }
                continue
            }
            guard event["type"] as? String == "assistant" else { continue }
            let message = event["message"] as? [String: Any] ?? [:]
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                let input = block["input"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "mcp__ccd_turn__update_plan":
                    if let items = input["items"] as? [[String: Any]] {
                        tasks = items.compactMap { item in
                            (item["content"] as? String).map { PlanTask(title: $0, status: normalized(item["status"] as? String)) }
                        }
                    }
                    if input["advance"] as? Bool == true, let list = tasks {
                        if let current = list.firstIndex(where: { $0.status == "active" }) {
                            set(current, "done")
                            if let next = list.indices.first(where: { $0 > current && list[$0].status == "pending" }) { set(next, "active") }
                        } else if let next = list.firstIndex(where: { $0.status == "pending" }) {
                            set(next, "active")
                        }
                    }
                    for number in input["done"] as? [Int] ?? [] { set(number - 1, "done") }
                    if let number = input["start"] as? Int { set(number - 1, "active") }
                case "mcp__ccd_turn__wrap_up":
                    tasks = tasks?.map { PlanTask(title: $0.title, status: "done") }
                case "TodoWrite":
                    if let todos = input["todos"] as? [[String: Any]] {
                        tasks = todos.compactMap { item in
                            (item["content"] as? String).map { PlanTask(title: $0, status: normalized(item["status"] as? String)) }
                        }
                    }
                default: break
                }
            }
        }
        return tasks?.isEmpty == true ? nil : tasks
    }

    static func isHumanPrompt(_ event: [String: Any]) -> Bool {
        if let origin = event["origin"] as? [String: Any] { return origin["kind"] as? String == "human" }
        guard event["isMeta"] as? Bool != true else { return false }
        let content = (event["message"] as? [String: Any])?["content"]
        if let text = content as? String { return !text.hasPrefix("<") && !text.hasPrefix("[Request interrupted") }
        let blocks = content as? [[String: Any]] ?? []
        return !blocks.isEmpty && !blocks.contains { $0["type"] as? String == "tool_result" }
    }

    private static func isPlanStart(_ event: [String: Any]) -> Bool {
        let message = event["message"] as? [String: Any] ?? [:]
        return (message["content"] as? [[String: Any]] ?? []).contains { block in
            let input = block["input"] as? [String: Any] ?? [:]
            return (block["name"] as? String == "mcp__ccd_turn__update_plan" && input["items"] != nil)
                || (block["name"] as? String == "TodoWrite" && input["todos"] != nil)
        }
    }

    // Reads backward until the window holds the latest full task list.
    static func lastClaudePlan(_ url: URL, size: UInt64) -> [PlanTask]? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        let markers = [Data("\"name\":\"mcp__ccd_turn__".utf8), Data("\"name\":\"TodoWrite\"".utf8)]
        let assistant = Data("\"type\":\"assistant\"".utf8)
        let user = Data("\"type\":\"user\"".utf8), toolResult = Data("\"tool_use_id\"".utf8)
        var window: UInt64 = 262_144
        while true {
            let offset = size > window ? size - window : 0
            guard (try? file.seek(toOffset: offset)) != nil, let data = try? file.read(upToCount: Int(size - offset)) else { return nil }
            var lines = data.split(separator: UInt8(ascii: "\n"))
            if offset > 0, !lines.isEmpty { lines.removeFirst() } // partial line
            let events: [[String: Any]] = lines.compactMap { line in
                let planCall = line.range(of: assistant) != nil && markers.contains { line.range(of: $0) != nil }
                let prompt = line.range(of: user) != nil && line.range(of: toolResult) == nil
                guard planCall || prompt else { return nil }
                return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
            }
            if let start = events.lastIndex(where: isPlanStart) { return claudePlan(Array(events[start...])) }
            if offset == 0 || window >= 16_777_216 { return nil }
            window *= 4
        }
    }

    // Transcript parsing is cached by file size and write time; unchanged files
    // are not read again. Accessed only on `queue`.
    private struct CachedTurn { let size: UInt64; let modified: Double; let turn: ClaudeTurn; let plan: [PlanTask]? }
    nonisolated(unsafe) private static var turnCache: [String: CachedTurn] = [:]

    static func claude(home: URL, now: Double = Date().timeIntervalSince1970,
                       liveSessions: Set<String>? = nil) -> [Row] {
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var metadata: [([String: Any], Double)] = []
        for case let file as URL in files where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("local_") {
            guard let data = try? Data(contentsOf: file), let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  item["isArchived"] as? Bool != true, item["title"] as? String != nil else { continue }
            metadata.append((item, (item["lastActivityAt"] as? Double ?? 0) / 1000))
        }
        let unread = ClaudeUnreadStore.ids(home: home) ?? []
        let live = liveSessions ?? ClaudeProcesses.liveSessionIDs()
        var cache: [String: CachedTurn] = [:]
        defer { turnCache = cache }
        return metadata.compactMap { item, activity -> Row? in
            guard let id = item["sessionId"] as? String, let title = item["title"] as? String,
                  let cli = item["cliSessionId"] as? String, let cwd = item["cwd"] as? String,
                  !cli.isEmpty, !cli.contains("/"), !cli.contains("..") else { return nil }
            let project = cwd.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            let transcript = home.appendingPathComponent(".claude/projects/\(project)/\(cli).jsonl")
            let attributes = try? FileManager.default.attributesOfItem(atPath: transcript.path)
            let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let lastWrite = max(activity, modified)
            let alive = live.contains(id), isUnread = unread.contains(id)
            // Nothing can show: not running recently, no live process, not unread.
            let turn: ClaudeTurn, plan: [PlanTask]?
            if let cached = turnCache[transcript.path], cached.size == size, cached.modified == modified {
                turn = cached.turn
                plan = cached.plan
            } else {
                turn = size > 0 ? lastClaudeTurn(transcript, size: size) : .unknown
                plan = size > 0 ? lastClaudePlan(transcript, size: size) : nil
            }
            cache[transcript.path] = CachedTurn(size: size, modified: modified, turn: turn, plan: plan)
            let status = claudeStatus(item, turn: turn, lastWrite: lastWrite, processAlive: alive, now: now)
            guard shouldDisplay(status: status, unread: isUnread) else { return nil }
            return Row(id: id, kind: "claude", title: title, status: status == "Cooking…" ? "Loading" : status,
                       updated: lastWrite, tasks: plan)
        }
    }
}

extension AgentNotchXPCHelper {
    func agentSessions(with reply: @escaping (Data?) -> Void) {
        AgentSessionReader.queue.async {
            reply(try? JSONEncoder().encode(AgentSessionReader.read()))
        }
    }
}
