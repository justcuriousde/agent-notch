#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Optional: pass three public/local test-photo paths: same person, same person,
# different person. The default suite never opens a camera or accesses Keychain.
face_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentnotch-face-tests.XXXXXX")
trap 'rm -rf "$face_test_dir"' EXIT
swiftc -module-cache-path "$face_test_dir/ModuleCache" \
  AgentNotch/models/FaceIdentity.swift \
  AgentNotch/managers/FaceRecognitionManager.swift \
  Tests/FaceRecognition/main.swift -o "$face_test_dir/tests"
"$face_test_dir/tests" "$@"
