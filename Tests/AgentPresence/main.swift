import Foundation

MainActor.assumeIsolated {
    let claude = "com.anthropic.claudefordesktop"
    let gpt = "com.openai.chat"
    let localGPT = "com.openai.codex"
    let cases: [(Set<String>, [RunningAgent.Kind])] = [
        ([], []),
        ([claude], [.claude]),
        ([gpt], [.gpt]),
        ([localGPT], [.gpt]),
        ([claude, gpt], [.claude, .gpt]),
        ([claude, gpt, localGPT], [.claude, .gpt]),
        (["com.spotify.client", "com.anthropic.claudefordesktop.helper"], [])
    ]
    for (input, expected) in cases {
        precondition(AgentPresenceMonitor.visibleAgents(bundleIdentifiers: input).map(\.kind) == expected)
    }
    print("Agent presence: all 7 visibility cases passed")
}
