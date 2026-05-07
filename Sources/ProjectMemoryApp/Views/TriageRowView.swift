import ProjectMemoryCore
import SwiftUI

struct TriageRowView: View {
    enum Action {
        case assign(UUID)
        case ignore
    }

    let session: PersistedActivitySession
    let projects: [Project]
    let onAction: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(timeRange)
                    .font(.headline)
                Text("· \(durationText) · \(session.frameCount) 帧")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(session.appName)
                    .font(.subheadline.bold())
                Text(session.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let browserHost = session.browserHost {
                Text("浏览器：\(browserHost)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !session.titleSamples.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("标题样本：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(session.titleSamples.prefix(3), id: \.self) { title in
                        Text("• \(String(title.prefix(80)))")
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 8) {
                Menu("归属到项目") {
                    if projects.isEmpty {
                        Text("暂无项目")
                    } else {
                        ForEach(projects) { project in
                            Button(project.name) {
                                onAction(.assign(project.id))
                            }
                        }
                    }
                }
                Button("忽略") {
                    onAction(.ignore)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
    }

    private var timeRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: session.startedAt))-\(formatter.string(from: session.endedAt))"
    }

    private var durationText: String {
        let seconds = max(0, Int(session.endedAt.timeIntervalSince(session.startedAt)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
