import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "sun.max")
                }

            ProjectsView()
                .tabItem {
                    Label("Projects", systemImage: "folder")
                }

            SourcesView()
                .tabItem {
                    Label("Sources", systemImage: "doc.text")
                }

            TriageView(store: appState.store)
                .tabItem {
                    Label("待归属", systemImage: "questionmark.square")
                }
                .badge(appState.triageBadgeCount)

            AskView()
                .tabItem {
                    Label("Ask", systemImage: "questionmark.bubble")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            appState.reload()
        }
    }
}
