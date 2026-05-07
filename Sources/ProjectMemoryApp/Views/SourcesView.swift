import AppKit
import SwiftUI
import ProjectMemoryCore

struct SourcesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var projectName = ""
    @State private var webTitle = ""
    @State private var webURL = ""
    @State private var webText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let errorMessage = appState.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            GroupBox("导入项目文件夹") {
                HStack(spacing: 12) {
                    TextField("项目名称", text: $projectName)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        chooseFolder()
                    } label: {
                        Label("导入文件夹", systemImage: "folder.badge.plus")
                    }
                    .disabled(appState.isLoading)
                }
                .padding(.vertical, 4)
            }

            GroupBox("网页捕获") {
                VStack(alignment: .leading, spacing: 10) {
                    if appState.isAutoWebCaptureFeatureEnabled {
                        Toggle("自动捕获前台浏览器窗口", isOn: Binding(
                            get: { appState.autoWebCaptureEnabled },
                            set: { appState.setAutoWebCaptureEnabled($0) }
                        ))
                        Text(appState.autoWebCaptureStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            Task {
                                await appState.captureActiveBrowserOnce()
                            }
                        } label: {
                            Label("立即捕获当前浏览器", systemImage: "camera.viewfinder")
                        }
                        .disabled(appState.selectedProject == nil || appState.isLoading)

                        Divider()
                    }

                    TextField("标题", text: $webTitle)
                        .textFieldStyle(.roundedBorder)

                    TextField("URL", text: $webURL)
                        .textFieldStyle(.roundedBorder)

                    TextEditor(text: $webText)
                        .font(.body)
                        .frame(minHeight: 120)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25))
                        }

                    HStack {
                        Text(appState.selectedProject?.name ?? "未选择项目")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button {
                            saveWebCapture()
                        } label: {
                            Label("保存到当前项目", systemImage: "square.and.arrow.down")
                        }
                        .disabled(appState.selectedProject == nil || appState.isLoading)
                    }
                }
                .padding(.vertical, 4)
            }

            sourcesList
        }
        .padding()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sources")
                    .font(.largeTitle.bold())
                Text("Indexed local files, captures, and Git activity.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                appState.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
        }
    }

    private var sourcesList: some View {
        Group {
            if appState.sources.isEmpty {
                ContentUnavailableView(
                    "No Sources",
                    systemImage: "doc.text",
                    description: Text("Indexed sources will appear here.")
                )
            } else {
                List(appState.sources) { source in
                    SourceRow(source: source)
                        .contextMenu {
                            Button("Remove Source", role: .destructive) {
                                appState.removeSource(source)
                            }
                        }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        appState.importFolder(url, projectName: projectName)
    }

    private func saveWebCapture() {
        appState.addWebCapture(title: webTitle, url: webURL, text: webText)

        if appState.errorMessage == nil {
            webTitle = ""
            webURL = ""
            webText = ""
        }
    }
}

struct SourceRow: View {
    var source: MemorySource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(source.title)
                    .font(.headline)
                Spacer()
                Text(source.kind.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(source.url ?? source.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !source.extractedText.isEmpty {
                Text(source.extractedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
