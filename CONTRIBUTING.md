# Contributing to AgentNotch

Use main as your base and keep changes focused. Open an issue before making large changes.

## Development

Open `AgentNotch.xcodeproj` in full Xcode and choose the AgentNotch scheme. Run `./scripts/build-local.sh` to verify a local Release package.

Run `./scripts/test-agent-sessions.sh` for session changes and `./scripts/test-face-recognition.sh` for camera recognition changes. Prefer synthetic fixtures. Never commit real chat transcripts, authentication files, face photos, Keychain exports, or private screenshots.

## Pull requests

Describe the problem, resulting behavior, and validation. Include before/after screenshots for UI changes with private details removed. Preserve Reduce Motion support and avoid high-frequency polling or whole-window animation updates.

Use this repository’s Issues tab for bugs and feature requests. Follow SECURITY.md for sensitive reports. Contributions use the project’s GPL-3.0 license. Preserve original authorship and dependency notices.
