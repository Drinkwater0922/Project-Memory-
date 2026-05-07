import AppKit
import SwiftUI

@main
struct ProjectMemoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }

        MenuBarExtra("Project Memory", systemImage: "brain.head.profile") {
            Button("Reload") {
                appState.reload()
            }
            Button("Generate Brief") {
                Task {
                    await appState.generateDailyBrief()
                }
            }
            .disabled(appState.isLoading || appState.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Divider()
            Text(appState.selectedProject?.name ?? "No project selected")
            Divider()
            Text(appState.dailyBrief.isEmpty ? "No brief generated yet" : String(appState.dailyBrief.prefix(220)))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
