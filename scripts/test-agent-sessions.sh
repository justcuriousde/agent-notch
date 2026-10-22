#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
session_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentnotch-sessions.XXXXXX")
trap 'rm -rf "$session_test_dir"' EXIT
swiftc -module-cache-path "$session_test_dir/ModuleCache" AgentNotchXPCHelper/AgentSessionReader.swift AgentNotchXPCHelper/ClaudeProcesses.swift AgentNotchXPCHelper/ClaudeUnreadStore.swift Tests/AgentSessions/main.swift -o "$session_test_dir/tests"
"$session_test_dir/tests"
