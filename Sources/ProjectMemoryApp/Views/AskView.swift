import SwiftUI

struct AskView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask")
                    .font(.largeTitle.bold())
                Text(appState.selectedProject.map { "Scoped to \($0.name)" } ?? "Select a project before asking.")
                    .foregroundStyle(.secondary)
            }

            Picker("Project", selection: $appState.selectedProjectID) {
                ForEach(appState.projects) { project in
                    Text(project.name).tag(UUID?.some(project.id))
                }
            }

            TextField("Question", text: $appState.question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)

            HStack {
                Spacer()
                Button {
                    Task {
                        await appState.askSelectedProject()
                    }
                } label: {
                    Label(appState.isLoading ? "Asking" : "Ask", systemImage: "paperplane")
                }
                .disabled(appState.isLoading || appState.selectedProject == nil || appState.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ScrollView {
                Text(appState.answer.isEmpty ? "Answers will cite the selected project's indexed sources." : appState.answer)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding()
    }
}
