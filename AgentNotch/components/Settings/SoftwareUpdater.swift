//
//  SoftwareUpdater.swift
//  AgentNotch
//
//  Created by Richard Kunkli on 09/08/2024.
//

import SwiftUI
import Sparkle

// AgentNotch has no independent signed update channel yet. Never start or
// invoke the upstream updater, including through manual settings controls.
struct CheckForUpdatesView: View {
    init(updater: SPUUpdater) {}

    var body: some View {
        Button("Check for Updates…") {}
            .disabled(true)
            .help("Updates are disabled for this customized AgentNotch build.")
    }
}

struct UpdaterSettingsView: View {
    init(updater: SPUUpdater) {}

    var body: some View {
        Section {
            Toggle("Automatically check for updates", isOn: .constant(false))
                .disabled(true)
            Toggle("Automatically download updates", isOn: .constant(false))
                .disabled(true)
            Text("Updates are disabled for this customized AgentNotch build.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Software updates")
        }
    }
}
