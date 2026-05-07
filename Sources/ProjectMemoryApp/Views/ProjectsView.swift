import SwiftUI
import ProjectMemoryCore

struct ProjectsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(appState.projects, selection: $appState.selectedProjectID) { project in
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                    Text(project.rootPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(project.id)
                .contextMenu {
                    Button("Remove Project", role: .destructive) {
                        appState.removeProject(project)
                    }
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                Button {
                    appState.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            }
        } detail: {
            if let project = appState.selectedProject {
                ProjectDetailView(
                    project: project,
                    sources: appState.selectedProjectSources,
                    timeline: appState.timeline(for: project)
                )
            } else {
                ContentUnavailableView("No Project", systemImage: "folder", description: Text("Indexed projects will appear here."))
            }
        }
        .padding()
    }
}

private struct ProjectDetailView: View {
    @EnvironmentObject private var appState: AppState

    var project: Project
    var sources: [MemorySource]
    var timeline: [TimelineEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(project.name)
                    .font(.title.bold())
                Text(project.rootPath)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            GroupBox("Project Timeline") {
                if timeline.isEmpty {
                    ContentUnavailableView("No Timeline Events", systemImage: "clock", description: Text("Import a folder or Git repo to build project history."))
                } else {
                    List(timeline.prefix(20)) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(.headline)
                            Text(event.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(minHeight: 180)
                }
            }

            Text("Sources")
                .font(.headline)

            if sources.isEmpty {
                ContentUnavailableView("No Sources", systemImage: "doc.text", description: Text("Sources assigned to this project will appear here."))
            } else {
                List(sources) { source in
                    SourceRow(source: source)
                        .contextMenu {
                            Button("Remove Source", role: .destructive) {
                                appState.removeSource(source)
                            }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
