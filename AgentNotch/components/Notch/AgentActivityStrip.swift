// AgentNotch addition. App presence is not inference or per-chat activity.
import AppKit
import Combine
import Defaults
import SwiftUI

struct RunningAgent: Identifiable, Equatable {
    enum Kind: String { case claude, gpt }
    let kind: Kind
    let bundleIdentifier: String
    var id: String { kind.rawValue }
    var name: String { kind == .claude ? "Claude" : "GPT" }
    var tint: Color { kind == .claude ? Color(red: 0.85, green: 0.43, blue: 0.30) : .white }
}

@MainActor
final class AgentPresenceMonitor: ObservableObject {
    static let shared = AgentPresenceMonitor()
    @Published private(set) var agents: [RunningAgent] = []
    @Published private(set) var chats: [AgentChat] = []
    @Published private(set) var connectionError: String?
    /// Chat whose task list the user opened, per agent kind.
    @Published var expandedChatIDs: [String: String] = [:]
    @Published var collapsedChatIDs: Set<String> = []
    var displayedAgents: [RunningAgent] {
        let defaults = Self.visibleAgents(bundleIdentifiers: ["com.anthropic.claudefordesktop", "com.openai.codex"])
        return defaults.compactMap { candidate in
            guard chats.contains(where: { $0.kind == candidate.kind.rawValue }) else { return nil }
            return agents.first(where: { $0.kind == candidate.kind }) ?? candidate
        }
    }
    private var pollingTask: Task<Void, Never>?
    func chats(for agent: RunningAgent) -> [AgentChat] {
        chats.filter { $0.kind == agent.kind.rawValue }
    }
    func summary(for agent: RunningAgent) -> String {
        let rows = chats(for: agent)
        if rows.contains(where: \.waiting) { return "Your turn" }
        return !rows.isEmpty && rows.allSatisfy(\.done) ? "Done" : "Cooking"
    }
    func progress(for agent: RunningAgent) -> String {
        let rows = chats(for: agent)
        return "\(rows.filter(\.done).count)/\(rows.count)"
    }

    private var observations: Set<AnyCancellable> = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        Publishers.Merge(
            center.publisher(for: NSWorkspace.didLaunchApplicationNotification),
            center.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.refresh() }
        .store(in: &observations)
        refresh()
        pollingTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                let result = await XPCHelperClient.shared.agentSessions()
                guard let self else { return }
                if let result, let rows = try? JSONDecoder().decode([AgentChat].self, from: result) {
                    failures = 0
                    let incoming = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let existing = Set(self.chats.map(\.id))
                    let ordered = self.chats.compactMap { incoming[$0.id] } + rows.filter { !existing.contains($0.id) }
                    if self.chats != ordered { self.chats = ordered }
                    self.connectionError = nil
                } else {
                    // A helper restart or a slow read must not blink chats away;
                    // clear them only after ~10 seconds without an answer.
                    failures += 1
                    if failures >= 3 {
                        self.chats = []
                        self.connectionError = "Session source unavailable"
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    static func visibleAgents(bundleIdentifiers: Set<String>) -> [RunningAgent] {
        var result: [RunningAgent] = []
        if bundleIdentifiers.contains("com.anthropic.claudefordesktop") {
            result.append(RunningAgent(kind: .claude, bundleIdentifier: "com.anthropic.claudefordesktop"))
        }
        // The user's installed ChatGPT distribution uses com.openai.codex.
        // Support the standard ChatGPT app as well, without duplicate entries.
        if let identifier = ["com.openai.chat", "com.openai.codex"].first(where: bundleIdentifiers.contains) {
            result.append(RunningAgent(kind: .gpt, bundleIdentifier: identifier))
        }
        return result
    }

    private func refresh() {
        let identifiers = Set(NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier))
        let updated = Self.visibleAgents(bundleIdentifiers: identifiers)
        if agents != updated { agents = updated }
    }

    func activate(_ agent: RunningAgent) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: agent.bundleIdentifier).first {
            app.activate(options: [])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: agent.bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

struct AgentChat: Identifiable, Codable, Equatable {
    let id: String
    let kind: String
    let title: String
    let status: String
    let updated: Double
    var tasks: [AgentTask]? = nil
    var done: Bool { status == "Done" }
    var waiting: Bool { status == "Waiting" }
}

struct AgentTask: Codable, Equatable {
    let title: String
    let status: String // "done", "active" or "pending"
}

// Height of the task list under a chat: three rows plus the gap above it.
let agentTaskRowHeight: CGFloat = 20
func agentTaskListHeight(_ count: Int) -> CGFloat {
    count == 0 ? 0 : CGFloat(min(3, count)) * agentTaskRowHeight + 4
}

extension AgentPresenceMonitor {
    /// The chat whose task list shows under the agent's chat list: the only
    /// chat on its own, otherwise the one the user clicked open.
    func taskChat(for agent: RunningAgent) -> AgentChat? {
        let rows = chats(for: agent)
        let chat = rows.count == 1 ? rows.first(where: { !collapsedChatIDs.contains($0.id) }) : rows.first { $0.id == expandedChatIDs[agent.kind.rawValue] }
        return (chat?.tasks ?? []).isEmpty ? nil : chat
    }

    /// Opens this chat itself inside Claude or ChatGPT.
    func open(_ chat: AgentChat, of agent: RunningAgent) {
        let id = chat.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? chat.id
        let link = agent.kind == .claude ? "claude://code/continue?session=\(id)" : "codex://threads/\(id)"
        guard let url = URL(string: link),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: agent.bundleIdentifier) else {
            activate(agent)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
    }
}

struct AgentActivityStrip: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject var monitor: AgentPresenceMonitor
    let availableWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var compactSectionWidth: CGFloat {
        let count = max(1, monitor.displayedAgents.count)
        return max(0, (availableWidth - 8 - CGFloat(count - 1) * 24.5) / CGFloat(count))
    }

    private var presenceTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 14, y: -4))
                .combined(with: .scale(scale: 0.94, anchor: .trailing)),
            removal: .opacity.combined(with: .offset(x: 8, y: -3))
                .combined(with: .scale(scale: 0.97, anchor: .trailing))
        )
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: vm.notchState == .open ? .top : .center, spacing: 12) {
                ForEach(Array(monitor.displayedAgents.enumerated()), id: \.element.id) { index, agent in
                    if index > 0 {
                        Rectangle().fill(.white.opacity(0.10)).frame(width: 0.5, height: vm.notchState == .open ? 66 : 14)
                    }
                    if vm.notchState == .open {
                        AgentChatWheel(agent: agent, monitor: monitor)
                            .transition(presenceTransition)
                    } else {
                        Button { monitor.activate(agent) } label: {
                            HStack(spacing: 5) {
                                Image(agent.kind == .claude ? "AgentClaudeMark" : "AgentGPTMark")
                                    .renderingMode(.template).resizable().scaledToFit()
                                    .foregroundStyle(agent.tint).frame(width: 17, height: 17)
                                Spacer(minLength: 8)
                                AgentStatusLabel(status: monitor.summary(for: agent))
                                    .font(.system(size: 11, weight: .medium))
                                    .fixedSize(horizontal: true, vertical: false)
                                AgentProgressBadge(chats: monitor.chats(for: agent), tint: agent.tint)

                            }
                            .frame(width: compactSectionWidth, alignment: .leading)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .help(agent.name + " · local sessions")
                        .transition(presenceTransition)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88), value: monitor.displayedAgents)
        .padding(.horizontal, vm.notchState == .open ? 0 : 4)
        // Match the album artwork's leading inset in NotchHomeView.
        .padding(.leading, vm.notchState == .open ? -12 : 0)
        // Gap between the album artwork and both agent columns (kept in sync
        // with agentOpenTopGap in ContentView's height).
        .padding(.top, vm.notchState == .open ? agentOpenTopGap : 0)
        .padding(.bottom, 5)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Live local agent sessions")
    }
}

// Identity follows the semantic state, so every direction gets the same
// interruptible transition without replaying on polling timestamps or titles.
private struct AgentStatusLabel: View {
    let status: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 4) {
                switch status {
                case "Done":
                    Image(systemName: "checkmark.circle.fill")
                    Text("Done")
                case "Your turn":
                    AwaitingReplyLabel()
                default:
                    CookingLabel()
                }
            }
            .foregroundStyle(status == "Done" ? Color.green : status == "Your turn" ? .yellow : .white.opacity(0.78))
            .id(status)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 5)).combined(with: .scale(scale: 0.96)),
                removal: .opacity.combined(with: .offset(y: -4)).combined(with: .scale(scale: 0.98))
            ))
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.88), value: status)
    }
}

// Keep the capsule's footprint stable while a completed session is acknowledged.
private struct AgentProgressBadge: View {
    let chats: [AgentChat]
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var celebration = 0
    @State private var confirming = false
    @State private var ring: CGFloat = 0
    @State private var check: CGFloat = 0
    @State private var settled = false

    private var completed: Int { chats.filter(\.done).count }
    private var allDone: Bool { !chats.isEmpty && completed == chats.count }

    var body: some View {
        ZStack {
            Text("\(completed)/\(chats.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(allDone ? Color.green : tint.opacity(0.85))
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.86), value: completed)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.86), value: chats.count)
                .opacity(confirming ? 0 : 1)
                .offset(y: confirming && !reduceMotion ? -2 : 0)
            if confirming {
                ZStack {
                    Circle().stroke(Color.green.opacity(0.15), lineWidth: 1.1)
                    Circle().trim(from: 0, to: ring)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    CompletionCheck().trim(from: 0, to: check)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                        .padding(3.5)
                }
                .frame(width: 14, height: 14)
                .scaleEffect(reduceMotion ? 1 : (settled ? 1 : 0.94))
                .shadow(color: .green.opacity(0.12), radius: 2)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        .frame(minWidth: 27, minHeight: 19)
        .background(Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1),
                    in: RoundedRectangle(cornerRadius: 4))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(completed) of \(chats.count) completed")
        .onChange(of: chats) { old, new in
            // Initial snapshots and newly discovered historical sessions stay quiet.
            guard old.map({ "\($0.id):\($0.status)" }) != new.map({ "\($0.id):\($0.status)" }) else { return }
            let previouslyWorking = Set(old.filter { !$0.done }.map(\.id))
            confirming = new.contains(where: { $0.done && previouslyWorking.contains($0.id) })
            celebration += 1
        }
        .task(id: celebration) {
            guard confirming else { return }
            ring = 0
            check = 0
            settled = false
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { confirming = true }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                settled = true
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) { ring = 1 }
            do {
                try await Task.sleep(for: .milliseconds(180))
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { check = 1 }
                try await Task.sleep(for: .milliseconds(650))
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) { confirming = false }
            } catch {
                // The next state owns the badge after cancellation.
                return
            }
        }
    }
}

private struct CompletionCheck: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.height * 0.82))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.14))
        }
    }
}

// Keep the label width fixed while dots advance: ".", "..", "...".
private struct CookingLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0

    var body: some View {
        HStack(spacing: 0) {
            Text("Cooking")
            Text("...").hidden()
                .overlay(alignment: .leading) {
                    Text(String(repeating: ".", count: reduceMotion ? 3 : step + 1))
                }
        }
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cooking")
        .task(id: reduceMotion) {
            step = 0
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(400)) }
                catch { return }
                step = (step + 1) % 3
            }
        }
    }
}

// One quiet invitation every four seconds, with a resting interval between.
// Animation state stays inside this label rather than refreshing the notch.
private struct AwaitingReplyLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inviting = false
    @State private var halo = false
    @State private var sheen: CGFloat = -0.5
    private let gold = Color(red: 1, green: 0.78, blue: 0.30)

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(gold.opacity(halo ? 0 : 0.5), lineWidth: 0.65)
                    .scaleEffect(halo ? 1.55 : 0.85)
                    .opacity(reduceMotion ? 0 : 1)
                Circle()
                    .fill(gold.opacity(inviting ? 0.16 : 0.06))
                Image(systemName: "questionmark")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(gold)
                    .scaleEffect(inviting ? 1.06 : 1)
            }
            .frame(width: 12, height: 12)
            .shadow(color: gold.opacity(inviting ? 0.24 : 0), radius: 3)
            Text("Your turn")
                .foregroundStyle(gold)
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Color(red: 1, green: 0.96, blue: 0.78), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.45)
                        .offset(x: proxy.size.width * sheen)
                    }
                    .mask(Text("Your turn"))
                    .opacity(reduceMotion ? 0 : 0.85)
                    .allowsHitTesting(false)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waiting for your reply")
        .task(id: reduceMotion) {
            inviting = false
            halo = false
            sheen = -0.5
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.85)) { inviting = true }
                withAnimation(.easeOut(duration: 1.6)) { halo = true }
                withAnimation(.easeInOut(duration: 1.5)) { sheen = 1.1 }
                do { try await Task.sleep(for: .milliseconds(1700)) }
                catch { return }
                withAnimation(.easeInOut(duration: 0.9)) { inviting = false }
                do { try await Task.sleep(for: .milliseconds(2200)) }
                catch { return }
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) {
                    halo = false
                    sheen = -0.5
                }
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
            }
        }
    }
}

private struct AgentChatWheel: View {
    let agent: RunningAgent
    @ObservedObject var monitor: AgentPresenceMonitor
    @State private var scrollID: String?
    @State private var shakes: [String: Int] = [:]
    @State private var pendingClick: Task<Void, Never>?
    @Default(.chatScrollButtons) private var showButtons
    @Default(.chatAnimationStyle) private var animationStyle
    @Default(.chatSnapEnabled) private var snapEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var chats: [AgentChat] { monitor.chats(for: agent) }

    var body: some View {
        VStack(spacing: 2) {
        if showButtons {
            HStack {
                Button { move(by: -1) } label: { Image(systemName: "chevron.up") }
                Spacer()
                Button { move(by: 1) } label: { Image(systemName: "chevron.down") }
            }
            .buttonStyle(.plain).font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .disabled(chats.count <= 3)
        }
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                if chats.isEmpty {
                    Text(monitor.connectionError ?? "No local sessions")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(height: 24)
                }
                ForEach(chats) { chat in
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(agent.kind == .claude ? "AgentClaudeMark" : "AgentGPTMark")
                                .renderingMode(.template).resizable().scaledToFit()
                                .foregroundStyle(agent.tint).frame(width: 14, height: 14)
                            Text(chat.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(isExpanded(chat) ? 1 : 0.85))
                                .lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            AgentStatusLabel(status: chat.done ? "Done" : chat.waiting ? "Your turn" : "Cooking")
                                .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1),
                                        in: Capsule())
                            .fixedSize()
                        }
                        .frame(height: 24)
                        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88), value: isExpanded(chat))
                        .modifier(ShakeEffect(shakes: CGFloat(shakes[chat.id, default: 0])))
                        .contentShape(Rectangle())
                        // Used only when drag-to-scroll is off; otherwise the
                        // scrollbar probe below reports the clicks.
                        .onTapGesture(count: 2) { open(chat) }
                        .onTapGesture(count: 1) { select(chat) }
                    .help(chat.title + " · " + (chat.done ? "Done" : chat.waiting ? "Your turn" : "Cooking...")
                          + " — click for tasks, double-click to open")
                        if let tasks = chat.tasks, !tasks.isEmpty {
                            AgentTaskWheel(tasks: tasks, onClick: { _, clicks in
                                if clicks >= 2 { open(chat) }
                            })
                            .padding(.top, 4)
                            .padding(.leading, 20)
                            .opacity(isExpanded(chat) ? 1 : 0)
                            .offset(y: reduceMotion || isExpanded(chat) ? 0 : -6)
                            .frame(height: isExpanded(chat) ? agentTaskListHeight(tasks.count) : 0, alignment: .top)
                            .clipped()
                            .allowsHitTesting(isExpanded(chat))
                            .accessibilityHidden(!isExpanded(chat))
                        }
                    }
                    .id(chat.id)
                }
            }
            .scrollTargetLayout()
            .background(HideAgentScrollbars(onClick: { y, clicks in
                guard y >= 0, !chats.isEmpty else { return }
                var top: CGFloat = 0
                for chat in chats {
                    let taskHeight = isExpanded(chat) ? agentTaskListHeight(chat.tasks?.count ?? 0) : 0
                    if y < top + 24 + taskHeight {
                        if y < top + 24 {
                            clicks >= 2 ? open(chat) : clickOnce(chat)
                        } else if clicks >= 2 { open(chat) }
                        return
                    }
                    top += 24 + taskHeight
                }
            }, scrollingEnabled: chats.count > 3))
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(ChatRowScrollBehavior(enabled: chats.count > 3 && snapEnabled && monitor.taskChat(for: agent) == nil))
        .scrollPosition(id: $scrollID)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9), value: chats.map(\.id))
        .frame(height: CGFloat(max(1, min(3, chats.count))) * 24 + agentTaskListHeight(monitor.taskChat(for: agent)?.tasks?.count ?? 0))
        .clipped()
        .onChange(of: scrollID) { old, new in
            guard old != nil, new != old else { return }
            agentWheelTick()
        }
        }
        .clipped()
        .animation(reduceMotion ? nil : .smooth(duration: 0.34), value: monitor.taskChat(for: agent)?.id)
    }

    private func isExpanded(_ chat: AgentChat) -> Bool {
        monitor.taskChat(for: agent)?.id == chat.id
    }

    // The probe sees each click of a double-click; wait out the double-click
    // interval so a double-click opens the chat without toggling tasks first.
    private func clickOnce(_ chat: AgentChat) {
        pendingClick?.cancel()
        pendingClick = Task { @MainActor in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled else { return }
            select(chat)
        }
    }

    // One click: show or hide the chat's tasks; a chat without tasks shakes.
    private func select(_ chat: AgentChat) {
        let key = agent.kind.rawValue
        if (chat.tasks ?? []).isEmpty {
            if Defaults[.enableHaptics] {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.36)) { shakes[chat.id, default: 0] += 1 }
            return
        }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.34)) {
            if chats.count == 1 {
                if monitor.collapsedChatIDs.contains(chat.id) {
                    monitor.collapsedChatIDs.remove(chat.id)
                } else {
                    monitor.collapsedChatIDs.insert(chat.id)
                }
            } else {
                monitor.expandedChatIDs[key] = monitor.expandedChatIDs[key] == chat.id ? nil : chat.id
            }
        }
    }

    private func open(_ chat: AgentChat) {
        pendingClick?.cancel()
        monitor.open(chat, of: agent)
    }

    private func move(by step: Int) {
        guard !chats.isEmpty else { return }
        let current = chats.firstIndex(where: { $0.id == scrollID }) ?? 0
        let target = min(max(0, current + step), max(0, chats.count - 3))
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
            scrollID = chats[target].id
        }
    }
}

// Three task rows: the last finished one above, the current one in the
// middle, the next one below. Scroll or drag to see the rest.
private struct AgentTaskWheel: View {
    let tasks: [AgentTask]
    var onClick: (CGFloat, Int) -> Void
    @State private var scrollID: Int?
    @State private var autoScrolling = false
    @Default(.chatSnapEnabled) private var snapEnabled
    @Default(.chatAnimationStyle) private var animationStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Titles survive insertion/removal above a task; duplicate titles get an
    // occurrence key because the session source does not provide task IDs.
    private var taskRows: [(id: String, index: Int, task: AgentTask)] {
        var occurrences: [String: Int] = [:]
        return tasks.enumerated().map { index, task in
            let occurrence = occurrences[task.title, default: 0]
            occurrences[task.title] = occurrence + 1
            return ("\(task.title)#\(occurrence)", index, task)
        }
    }

    // Top row that keeps the current task in the middle.
    private var restingTop: Int {
        let anchor = tasks.firstIndex { $0.status == "active" }
            ?? tasks.firstIndex { $0.status == "pending" }
            ?? tasks.count - 1
        return min(max(0, anchor - 1), max(0, tasks.count - 3))
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(taskRows, id: \.id) { row in
                    let task = row.task
                    HStack(spacing: 6) {
                        AgentTaskIcon(status: task.status)
                        Text(task.title)
                            .font(.system(size: 10, weight: task.status == "active" ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(task.status == "active" ? 0.9 : task.status == "done" ? 0.45 : 0.6))
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: agentTaskRowHeight)
                    .contentShape(Rectangle())
                    .help(task.title)
                    .id(row.index)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: task.status)
                    .scrollTransition(.interactive, axis: .vertical) { content, phase in
                        content
                            .opacity(reduceMotion || animationStyle == "none" || phase.isIdentity ? 1 : 0.55)
                            .scaleEffect(x: 1, y: reduceMotion || animationStyle != "wheel" || phase.isIdentity ? 1 : 0.92)
                            .rotation3DEffect(.degrees(reduceMotion || animationStyle != "wheel" ? 0 : phase.value * -10), axis: (x: 1, y: 0, z: 0))
                    }
                }
            }
            .scrollTargetLayout()
            .background(HideAgentScrollbars(onClick: onClick, rowHeight: agentTaskRowHeight))
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(ChatRowScrollBehavior(enabled: snapEnabled, rowHeight: agentTaskRowHeight))
        .scrollPosition(id: $scrollID, anchor: .top)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9), value: tasks.count)
        .frame(height: CGFloat(min(3, tasks.count)) * agentTaskRowHeight)
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tasks: \(tasks.filter { $0.status == "done" }.count) of \(tasks.count) done")
        .onAppear { scrollID = restingTop }
        .onChange(of: tasks) {
            autoScrolling = true
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { scrollID = restingTop }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                autoScrolling = false
            }
        }
        .onChange(of: scrollID) { old, new in
            guard old != nil, new != old, !autoScrolling else { return }
            agentWheelTick()
        }
    }
}

private struct AgentTaskIcon: View {
    let status: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Group {
            switch status {
            case "done":
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
            case "active":
                ZStack {
                    Circle().stroke(.white.opacity(0.18), lineWidth: 1.4)
                    Circle().trim(from: 0, to: 0.3)
                        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                }
                .padding(1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
                }
            default:
                Image(systemName: "circle.dashed").foregroundStyle(.white.opacity(0.4))
            }
        }
        .id(status)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.7)))
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.8), value: status)
        .font(.system(size: 11, weight: .medium))
        .frame(width: 12, height: 12)
    }
}

// A short side-to-side shake for a chat that has no tasks to show.
private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let progress = shakes - shakes.rounded(.down)
        return ProjectionTransform(CGAffineTransform(translationX: sin(progress * .pi * 6) * 4 * (1 - progress), y: 0))
    }
}

/// Row to rest on after a scroll. Passing a fifth of a row is enough to move
/// to the next one, so short, light swipes still advance instead of bouncing back.
func agentSnappedOffset(_ y: CGFloat, from start: CGFloat, rowHeight: CGFloat, maximum: CGFloat) -> CGFloat {
    let moved = y - start, threshold = rowHeight * 0.2
    let row: CGFloat
    if moved > threshold { row = ((y - threshold) / rowHeight).rounded(.up) }
    else if moved < -threshold { row = ((y + threshold) / rowHeight).rounded(.down) }
    else { row = (y / rowHeight).rounded() }
    return min(maximum, max(0, row * rowHeight))
}

/// A light tick per row, like a picker wheel. `.alignment` is the softest
/// pattern macOS offers; ticks closer than 45 ms apart are dropped.
@MainActor func agentWheelTick() {
    guard Defaults[.enableHaptics] else { return }
    let now = CACurrentMediaTime()
    guard now - agentLastTick > 0.045 else { return }
    agentLastTick = now
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
}
@MainActor private var agentLastTick: CFTimeInterval = 0

private struct ChatRowScrollBehavior: ScrollTargetBehavior {
    let enabled: Bool
    var rowHeight: CGFloat = 24
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard enabled else { return }
        let maximum = max(0, context.contentSize.height - context.containerSize.height)
        target.rect.origin.y = agentSnappedOffset(target.rect.origin.y, from: context.originalTarget.rect.origin.y,
                                                  rowHeight: rowHeight, maximum: maximum)
    }
}

// Respect the compact design even when macOS is set to always show scrollbars.
private struct HideAgentScrollbars: NSViewRepresentable {
    /// Distance of the click from the top of the list, and its click count.
    var onClick: (CGFloat, Int) -> Void
    var rowHeight: CGFloat = 24
    var scrollingEnabled = true
    final class Probe: NSView {
        var rowHeight: CGFloat = 24
        var scrollingEnabled = true
        private weak var scrollView: NSScrollView?
        private var verticalObservation: NSKeyValueObservation?
        private var horizontalObservation: NSKeyValueObservation?
        private var boundsObserver: NSObjectProtocol?
        private var mouseMonitor: Any?
        var onClick: ((CGFloat, Int) -> Void)?
        private var dragStart: NSPoint?
        private var initialOrigin: CGFloat = 0
        private var didDrag = false
        private var tickedRow: Int?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hideScrollbars()
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            hideScrollbars()
        }
        func hideScrollbars() {
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        private func attach() {
            guard let scroll = enclosingScrollView else { return }
            if scrollView !== scroll {
                if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
                scrollView = scroll
                if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
                mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]) { [weak self] event in
                    guard let self, let scroll = self.scrollView, event.window === scroll.window else { return event }
                    if event.type == .scrollWheel {
                        guard !self.scrollingEnabled else { return event }
                        let point = scroll.convert(event.locationInWindow, from: nil)
                        guard scroll.bounds.contains(point),
                              scroll.hitTest(point)?.enclosingScrollView === scroll else { return event }
                        return nil
                    }
                    if event.type == .leftMouseDown {
                        guard Defaults[.chatDragEnabled] else { return event }
                        guard scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) else { return event }
                        self.dragStart = event.locationInWindow
                        self.initialOrigin = scroll.contentView.bounds.origin.y
                        self.tickedRow = Int((self.initialOrigin / self.rowHeight).rounded())
                        self.didDrag = false
                        return nil
                    }
                    guard let start = self.dragStart else { return event }
                    let travel = event.locationInWindow.y - start.y
                    if event.type == .leftMouseDragged {
                        if abs(travel) > 3 { self.didDrag = true }
                        if self.didDrag && self.scrollingEnabled {
                            let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                            let y = min(maximum, max(0, self.initialOrigin + travel))
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            let row = Int((y / self.rowHeight).rounded())
                            if row != self.tickedRow {
                                self.tickedRow = row
                                agentWheelTick()
                            }
                        }
                        return nil
                    }
                    self.dragStart = nil
                    if self.didDrag && self.scrollingEnabled {
                        let clip = scroll.contentView
                        let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - clip.bounds.height)
                        let destination = Defaults[.chatSnapEnabled]
                            ? agentSnappedOffset(clip.bounds.origin.y, from: self.initialOrigin,
                                                 rowHeight: self.rowHeight, maximum: maximum)
                            : clip.bounds.origin.y
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.26
                            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: destination))
                        }
                        let row = Int((destination / self.rowHeight).rounded())
                        if row != self.tickedRow { agentWheelTick() }
                        self.tickedRow = nil
                    } else if !self.didDrag {
                        let point = self.convert(event.locationInWindow, from: nil)
                        self.onClick?(self.isFlipped ? point.y : self.bounds.height - point.y, event.clickCount)
                    }
                    return nil
                }
                // SwiftUI can restore scrollers when either column updates or scrolls.
                // Keep this policy local to each chat list for its full lifetime.
                verticalObservation = scroll.observe(\.hasVerticalScroller, options: [.new]) { [weak self] _, change in
                    if change.newValue == true { self?.suppressScrollbars() }
                }
                horizontalObservation = scroll.observe(\.hasHorizontalScroller, options: [.new]) { [weak self] _, change in
                    if change.newValue == true { self?.suppressScrollbars() }
                }
                scroll.contentView.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
                ) { [weak self] _ in self?.suppressScrollbars() }
            }
            suppressScrollbars()
        }
        private func suppressScrollbars() {
            guard let scroll = scrollView else { return }
            scroll.verticalScroller?.isHidden = true
            scroll.verticalScroller?.alphaValue = 0
            scroll.horizontalScroller?.isHidden = true
            scroll.horizontalScroller?.alphaValue = 0
            if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
            if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
            scroll.autohidesScrollers = true
            scroll.verticalScrollElasticity = scrollingEnabled ? .automatic : .none
            if !scrollingEnabled && scroll.contentView.bounds.origin.y != 0 {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        deinit {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        }
    }
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onClick = onClick
        view.rowHeight = rowHeight
        view.scrollingEnabled = scrollingEnabled
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        view.onClick = onClick
        view.rowHeight = rowHeight
        view.scrollingEnabled = scrollingEnabled
        view.hideScrollbars()
    }
}
