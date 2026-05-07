import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("OpenRouter") {
                SecureField("API Key", text: $appState.openRouterAPIKey)
                Button {
                    appState.saveAPIKey()
                } label: {
                    Label("Save API Key", systemImage: "key")
                }
                Button(role: .destructive) {
                    appState.clearAPIKey()
                } label: {
                    Label("Clear API Key", systemImage: "trash")
                }
            }

            Section("Storage") {
                LabeledContent("Database", value: appState.databasePath)
                Text("Project Memory stores indexed metadata locally under Application Support. The OpenRouter API key is stored in Keychain. Only locally selected and truncated snippets are sent when you generate a brief or ask a project-scoped question.")
                    .foregroundStyle(.secondary)
            }

            ActivitySection()
        }
        .formStyle(.grouped)
        .padding()
    }
}
