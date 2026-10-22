import Foundation
import CryptoKit
import SQLite3
class AgentNotchXPCHelper {}
func event(_ type: String) -> [String: Any] { ["type": "event_msg", "payload": ["type": type]] }
let now = Date().timeIntervalSince1970
precondition(AgentSessionReader.codexStatus([event("task_started"), event("task_complete")], updated: now) == "Done")
precondition(AgentSessionReader.codexStatus([event("task_complete"), event("task_started")], updated: now) == "Cooking…")
for unread in [false, true] {
    precondition(AgentSessionReader.shouldDisplay(status: "Cooking…", unread: unread))
    precondition(AgentSessionReader.shouldDisplay(status: "Done", unread: unread) == unread)
    precondition(AgentSessionReader.shouldDisplay(status: "Waiting", unread: unread))
    for status in ["Error", "Stopped", "Idle"] {
        precondition(!AgentSessionReader.shouldDisplay(status: status, unread: unread))
    }
}
precondition(AgentSessionReader.claudeStatus(["error": "limit"], events: []) == "Error")
precondition(AgentSessionReader.claudeStatus(["lastTurnCutShort": true], events: []) == "Stopped")
precondition(AgentSessionReader.claudeStatus([:], events: [["type": "assistant", "message": ["stop_reason": "end_turn"]]]) == "Done")

// Claude turn tracking: metadata lastActivityAt goes stale while a turn runs.
typealias Turn = AgentSessionReader.ClaudeTurn
let toolUse: [String: Any] = ["type": "assistant", "message": ["stop_reason": "tool_use"]]
let toolResult: [String: Any] = ["type": "user", "message": ["content": [["type": "tool_result"]]]]
let interrupted: [String: Any] = ["type": "user", "message": ["content": [["type": "text", "text": "[Request interrupted by user]"]]]]
let sidechainDone: [String: Any] = ["type": "assistant", "isSidechain": true, "message": ["stop_reason": "end_turn"]]
precondition(AgentSessionReader.claudeTurn([toolUse, toolResult]) == .running)
precondition(AgentSessionReader.claudeTurn([toolUse, ["type": "attachment"], ["type": "api-request"]]) == .running)
precondition(AgentSessionReader.claudeTurn([toolUse, interrupted]) == .stopped)
precondition(AgentSessionReader.claudeTurn([toolResult, sidechainDone]) == .running, "Subagent end must not end the main turn")
func claude(_ turn: Turn, quiet: Double, alive: Bool, _ meta: [String: Any] = [:]) -> String {
    AgentSessionReader.claudeStatus(meta, turn: turn, lastWrite: now - quiet, processAlive: alive, now: now)
}
precondition(claude(.running, quiet: 5, alive: false) == "Cooking…")
precondition(claude(.running, quiet: 600, alive: true) == "Cooking…", "Long tool call with a live process stays visible")
precondition(claude(.running, quiet: 600, alive: false) == "Idle", "Dead process mid-turn is not Cooking")
precondition(claude(.running, quiet: 7200, alive: true) == "Idle")
precondition(claude(.running, quiet: 5, alive: true, ["interruptedAwaitingPerson": true]) == "Waiting")
precondition(claude(.running, quiet: 5, alive: true, ["lastTurnCutShort": true]) == "Cooking…", "A new turn overrides an old cut-short flag")
precondition(claude(.done, quiet: 5, alive: true) == "Done")
precondition(claude(.stopped, quiet: 5, alive: true) == "Stopped")

// End-to-end: stale metadata + fresh transcript + a screenshot line over 256 KB.
do {
    let claudeHome = FileManager.default.temporaryDirectory.appendingPathComponent("agentnotch-claude-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: claudeHome) }
    let sessions = claudeHome.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/a/b")
    let cwd = "/Users/test/My Project"
    let projectDir = claudeHome.appendingPathComponent(".claude/projects/-Users-test-My-Project")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let staleActivity = (now - 900) * 1000
    try JSONSerialization.data(withJSONObject: ["sessionId": "local_run", "cliSessionId": "cli-run", "cwd": cwd,
                                                "title": "Long build", "lastActivityAt": staleActivity])
        .write(to: sessions.appendingPathComponent("local_run.json"))
    let huge = String(repeating: "A", count: 600_000)
    let lines = [
        #"{"type":"user","message":{"content":"build it"}}"#,
        #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"image","data":""# + huge + #""}]}]}}"#,
        #"{"type":"attachment","attachment":{"type":"x"}}"#,
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: projectDir.appendingPathComponent("cli-run.jsonl"), atomically: true, encoding: .utf8)
    let fresh = AgentSessionReader.claude(home: claudeHome, liveSessions: [])
    precondition(fresh.map(\.status) == ["Loading"], "Fresh transcript must keep Claude visible despite stale lastActivityAt")
    let later = AgentSessionReader.claude(home: claudeHome, now: now + 600, liveSessions: ["local_run"])
    precondition(later.map(\.status) == ["Loading"], "Live process keeps a quiet turn visible")
    let dead = AgentSessionReader.claude(home: claudeHome, now: now + 600, liveSessions: [])
    precondition(dead.isEmpty, "No process and no writes: hidden")
}
print("PASS: Claude turn tracking (stale metadata, long tools, interrupts, sidechains, large lines)")

let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentnotch-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: home) }
let codex = home.appendingPathComponent(".codex")
try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
func json(_ value: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject: value).write(to: url) }
let principal = ["chatgpt_account_id": "test-account", "chatgpt_user_id": "test-user"]
let payload = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": principal]).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
try json(["tokens": ["id_token": "test.\(payload).test"]], codex.appendingPathComponent("auth.json"))
let identityData = try JSONSerialization.data(withJSONObject: ["chatgpt", "test-account", "test-user"], options: [.withoutEscapingSlashes])
let identity = SHA256.hash(data: identityData).map { String(format: "%02x", $0) }.joined()
func unread(_ ids: [String]) throws {
    try json(["electron-thread-read-state-v1": ["unreadByIdentity": [identity: ["local:test": ids, "durable:remote": ["remote-only"]], "other-account": ["local:test": ["wrong-account"]]]]], codex.appendingPathComponent(".codex-global-state.json"))
}
try unread(["done"])
precondition(AgentSessionReader.codexUnreadIDs(home: home) == ["done"])
func sql(_ file: String, _ query: String) {
    var db: OpaquePointer?; precondition(sqlite3_open(codex.appendingPathComponent(file).path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }; precondition(sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK)
}
sql("state_5.sqlite", "CREATE TABLE threads(id TEXT,name TEXT,title TEXT,rollout_path TEXT,updated_at REAL,archived INTEGER,source TEXT); INSERT INTO threads VALUES('active','Active','', '', 1,0,'vscode'),('done','Unread done','','',0,0,'vscode'),('read','Read done','','',2,0,'vscode'),('internal','Internal','','',3,0,'subagent');")
sql("thread_history_1.sqlite", "CREATE TABLE thread_turns(thread_id TEXT,status TEXT,rollout_ordinal INTEGER); INSERT INTO thread_turns VALUES('active','inProgress',2),('active','completed',1),('done','completed',1),('read','completed',1),('internal','inProgress',1);")
var rows = AgentSessionReader.codex(home: home)
precondition(Set(rows.map(\.id)) == ["active", "done"])
precondition(rows.first(where: { $0.id == "active" })?.status == "Loading", "Long-running tasks must not disappear after 120 seconds")
try unread([])
rows = AgentSessionReader.codex(home: home)
precondition(rows.map(\.id) == ["active"], "Reading a completed chat must remove it")
sql("thread_history_1.sqlite", "UPDATE thread_turns SET status='completed' WHERE thread_id='active';")
precondition(AgentSessionReader.read(home: home).isEmpty, "No running/unread sessions must leave no provider rows")

func little(_ value: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8((value >> (8 * $0)) & 255) } }
func variable(_ value: Int) -> [UInt8] {
    var n = value, output: [UInt8] = []
    repeat { var byte = UInt8(n & 127); n >>= 7; if n > 0 { byte |= 128 }; output.append(byte) } while n > 0
    return output
}
func block(_ key: [UInt8], _ value: [UInt8]) -> [UInt8] {
    [0] + variable(key.count) + variable(value.count) + key + value + little(0, 4) + little(1, 4)
}
let store = home.appendingPathComponent("Library/Application Support/Claude/Local Storage/leveldb")
try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
func value(_ ids: [String]) throws -> [UInt8] { [1] + Array(try JSONSerialization.data(withJSONObject: ["state": ["unreadIds": ids, "explicitUnreadIds": []], "version": 0])) }
let key = ClaudeUnreadStore.target
let dataBlock = block(key + little((10 << 8) | 1, 8), try value(["claude-done"]))
let dataHandle = variable(0) + variable(dataBlock.count)
let indexOffset = dataBlock.count + 5
let indexBlock = block(key, dataHandle)
let indexHandle = variable(indexOffset) + variable(indexBlock.count)
var footer = [UInt8]([0, 0]) + indexHandle
footer += Array(repeating: 0, count: 40 - footer.count)
footer += little(0xdb4775248b80fb57, 8)
try Data(dataBlock + [0,0,0,0,0] + indexBlock + [0,0,0,0,0] + footer).write(to: store.appendingPathComponent("000001.ldb"))
precondition(ClaudeUnreadStore.ids(home: home) == ["claude-done"])
func batch(_ sequence: UInt64, _ value: [UInt8]?) -> [UInt8] {
    little(sequence, 8) + little(1, 4) + [value == nil ? 0 : 1] + variable(key.count) + key + (value.map { variable($0.count) + $0 } ?? [])
}
func record(_ kind: UInt8, _ bytes: [UInt8]) -> [UInt8] { [0,0,0,0] + little(UInt64(bytes.count), 2) + [kind] + bytes }
let empty = batch(11, try value([])), split = empty.count / 2
try Data(record(2, Array(empty.prefix(split))) + record(4, Array(empty.dropFirst(split)))).write(to: store.appendingPathComponent("000002.log"))
precondition(ClaudeUnreadStore.ids(home: home) == [], "A newer read event in the WAL must override old SST unread IDs")
try Data(record(1, batch(12, nil))).write(to: store.appendingPathComponent("000002.log"))
precondition(ClaudeUnreadStore.ids(home: home) == [], "Deleted unread state must not resurrect old SST values")
let expanded = try ClaudeUnreadStore.snappy([6,0,97,5,1])
precondition(expanded == Array("aaaaaa".utf8))
do { _ = try ClaudeUnreadStore.snappy([6,5,0]); preconditionFailure("Corrupt Snappy must fail") } catch {}
print("PASS: lifecycle filtering, account/host scoping, read dismissal, empty provider, long-running turn, SST/WAL sequence/deletion, Snappy bounds")
let live = AgentSessionReader.read()
print("Live actionable sessions: Claude \(live.filter { $0.kind == "claude" }.count), GPT \(live.filter { $0.kind == "gpt" }.count)")
precondition(live.allSatisfy { ["Loading", "Done", "Waiting"].contains($0.status) })
print("Claude unread store available: \(ClaudeUnreadStore.ids(home: FileManager.default.homeDirectoryForCurrentUser) != nil)")


let question: [String: Any] = ["type": "response_item", "payload": ["type": "function_call", "name": "functions.request_user_input", "call_id": "q1"]]
let answer: [String: Any] = ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "q1", "output": "yes"]]
precondition(AgentSessionReader.codexWaiting([event("task_started"), question]))
precondition(!AgentSessionReader.codexWaiting([question, answer]))
precondition(!AgentSessionReader.codexWaiting([question, event("task_complete")]))
precondition(!AgentSessionReader.codexWaiting([question, event("task_started")]))
precondition(AgentSessionReader.codexStatus([question], updated: now) == "Waiting")
print("PASS: pending questions, replies and turn boundaries")

let wrapAsk: [String: Any] = ["type": "assistant", "message": ["stop_reason": "tool_use", "content": [["type": "tool_use", "name": "mcp__ccd_turn__wrap_up", "input": ["ask": "Merge?", "actions": [["label": "Yes"]]]]]]]
let finalText: [String: Any] = ["type": "assistant", "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "Summary"]]]]
precondition(AgentSessionReader.claudeTurn([wrapAsk, toolResult, finalText]) == .waiting)
precondition(AgentSessionReader.claudeTurn([wrapAsk, toolResult, finalText, ["type": "user", "message": ["content": "Yes"]]]) == .running)
precondition(claude(.waiting, quiet: 3600, alive: false) == "Waiting")
print("PASS: Claude wrap_up question survives result/final text and clears on user reply")

// Task list rebuilt from update_plan / TodoWrite calls.
func planCall(_ input: [String: Any], name: String = "mcp__ccd_turn__update_plan") -> [String: Any] {
    ["type": "assistant", "message": ["content": [["type": "tool_use", "name": name, "input": input]]]]
}
let planItems = planCall(["items": [["content": "A", "status": "in_progress"], ["content": "B", "status": "pending"], ["content": "C", "status": "pending"]]])
precondition(AgentSessionReader.claudePlan([planItems])?.map(\.status) == ["active", "pending", "pending"])
precondition(AgentSessionReader.claudePlan([planItems, planCall(["advance": true])])?.map(\.status) == ["done", "active", "pending"])
precondition(AgentSessionReader.claudePlan([planItems, planCall(["done": [1, 2], "start": 3])])?.map(\.status) == ["done", "done", "active"])
precondition(AgentSessionReader.claudePlan([planItems, planCall(["recap": "ok"], name: "mcp__ccd_turn__wrap_up")])?.map(\.status) == ["done", "done", "done"])
precondition(AgentSessionReader.claudePlan([planCall(["todos": [["content": "X", "status": "completed"], ["content": "Y", "status": "in_progress"]]], name: "TodoWrite")])?.map(\.title) == ["X", "Y"])
precondition(AgentSessionReader.claudePlan([finalText]) == nil)
let humanPrompt: [String: Any] = ["type": "user", "origin": ["kind": "human"], "message": ["content": "Did it work?"]]
let metaPrompt: [String: Any] = ["type": "user", "isMeta": true, "message": ["content": [["type": "text", "text": "[Image: ...]"]]]]
precondition(AgentSessionReader.claudePlan([planItems, humanPrompt]) == nil, "A new question ends the previous turn's list")
precondition(AgentSessionReader.claudePlan([planItems, metaPrompt, toolResult])?.count == 3, "Meta and tool results keep the list")
precondition(AgentSessionReader.claudePlan([planItems, humanPrompt, planItems])?.count == 3)
let planFile = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString).jsonl")
let planLines = [planItems, toolResult, planCall(["advance": true])].map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
try (planLines.joined(separator: "\n") + "\n").write(to: planFile, atomically: true, encoding: .utf8)
let planSize = (try FileManager.default.attributesOfItem(atPath: planFile.path)[.size] as! NSNumber).uint64Value
precondition(AgentSessionReader.lastClaudePlan(planFile, size: planSize)?.map(\.status) == ["done", "active", "pending"])
let stalePlan = planFile.deletingLastPathComponent().appendingPathComponent("stale-\(UUID().uuidString).jsonl")
let staleLines = [planItems, humanPrompt].map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
try (staleLines.joined(separator: "\n") + "\n").write(to: stalePlan, atomically: true, encoding: .utf8)
let staleSize = (try FileManager.default.attributesOfItem(atPath: stalePlan.path)[.size] as! NSNumber).uint64Value
precondition(AgentSessionReader.lastClaudePlan(stalePlan, size: staleSize) == nil)
print("PASS: task list items, advance, done/start, wrap_up, TodoWrite, transcript read")
