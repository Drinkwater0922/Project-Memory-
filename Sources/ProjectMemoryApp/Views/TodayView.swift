import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today")
                        .font(.largeTitle.bold())
                    Text("\(appState.projects.count) projects, \(appState.sources.count) sources indexed")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task {
                        await appState.generateDailyBrief()
                    }
                } label: {
                    Label(appState.isLoading ? "Generating" : "Generate Brief", systemImage: "sparkles")
                }
                .disabled(appState.isLoading)
            }

            if let errorMessage = appState.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            ScrollView {
                Text(appState.dailyBrief.isEmpty ? "Generate a daily brief from the indexed project evidence." : appState.dailyBrief)
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
