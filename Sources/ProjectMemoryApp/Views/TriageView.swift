import ProjectMemoryCore
import SwiftUI

struct TriageView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel: TriageListViewModel

    init(store: MemoryStore) {
        _viewModel = StateObject(wrappedValue: TriageListViewModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.unassignedSessions.isEmpty {
                ContentUnavailableView(
                    "暂无待归属的工作时段。",
                    systemImage: "questionmark.square",
                    description: Text("活动 session 聚合后会出现在这里。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.unassignedSessions, id: \.id) { session in
                    TriageRowView(session: session, projects: appState.projects) { action in
                        handle(action: action, sessionID: session.id)
                    }
                }
            }

            if !viewModel.ignoredSessions.isEmpty {
                DisclosureGroup("已忽略（\(viewModel.ignoredSessions.count)）") {
                    List(viewModel.ignoredSessions, id: \.id) { session in
                        HStack {
                            Text("\(session.appName) · \(formatRange(session.startedAt, session.endedAt))")
                                .lineLimit(1)
                            Spacer()
                            Button("撤销忽略") {
                                Task {
                                    try? await viewModel.undoIgnore(sessionID: session.id)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 240)
                }
                .padding()
            }
        }
        .onAppear {
            try? SessionPipeline(store: appState.store).run(window: SessionPipeline.triageWindow())
            viewModel.refresh()
            appState.refreshTriageBadge()
        }
    }

    private func handle(action: TriageRowView.Action, sessionID: UUID) {
        Task {
            switch action {
            case .assign(let projectID):
                try? await viewModel.assign(sessionID: sessionID, projectID: projectID)
            case .ignore:
                try? await viewModel.ignore(sessionID: sessionID)
            }
        }
    }

    private func formatRange(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "\(formatter.string(from: start))-\(formatter.string(from: end))"
    }
}
