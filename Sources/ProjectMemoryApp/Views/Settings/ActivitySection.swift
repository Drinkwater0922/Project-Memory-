import SwiftUI
import ApplicationServices
import ProjectMemoryCore

struct ActivitySection: View {
    @EnvironmentObject private var appState: AppState
    @State private var newBundleID: String = ""
    @State private var addError: String?
    @State private var debugReadout: String = "—"
    @State private var showClearConfirm = false

    var body: some View {
        Section("活动记录") {
            envFlagBanner

            Toggle("启用活动元数据记录", isOn: Binding(
                get: { appState.activityCaptureEnabled },
                set: { appState.setActivityCaptureEnabled($0) }
            ))
            .disabled(!appState.isActivityFeatureEnvOn)

            Text("仅记录前台 app / 窗口标题（如有 Accessibility 权限）/ 浏览器 URL（如有 Automation 权限）。不截图、不 OCR、不发送到 OpenRouter。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("默认排除的应用（不可删）")
                .font(.subheadline.bold())
            ForEach(Array(ActivityDenyList.defaultBundleIDs).sorted(), id: \.self) { bid in
                Text(bid).font(.caption.monospaced()).foregroundStyle(.secondary)
            }

            Divider()

            Text("自定义排除")
                .font(.subheadline.bold())
            ForEach(appState.activityExtraDenied, id: \.self) { bid in
                HStack {
                    Text(bid).font(.caption.monospaced())
                    Spacer()
                    Button(role: .destructive) {
                        appState.removeActivityExtraDenied(bid)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                }
            }
            HStack {
                TextField("添加 bundle ID", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                Button("+") {
                    let result = appState.addActivityExtraDenied(newBundleID)
                    switch result {
                    case .added:
                        newBundleID = ""
                        addError = nil
                    case .rejectedEmpty:
                        addError = "请输入非空 bundle ID"
                    case .rejectedAlreadyInDefaults:
                        addError = "该 app 已在默认排除列表"
                    case .rejectedDuplicate:
                        addError = "已添加过"
                    }
                }
            }
            if let err = addError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }

            Divider()

            Text("权限状态")
                .font(.subheadline.bold())
            Text(accessibilityStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(SupportedBrowsers.bundleIDs.sorted(), id: \.self) { bid in
                Text(automationStatus(for: bid))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("首次读取浏览器 URL 时 macOS 会弹授权提示。")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            Text("Phase 1 调试")
                .font(.subheadline.bold())
            Text(debugReadout).font(.caption)
            Button("刷新") { refreshDebug() }

            Divider()

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("清除所有活动记录", systemImage: "trash")
            }
            .confirmationDialog(
                "清除所有活动记录?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("清除", role: .destructive) {
                    appState.clearAllActivityFrames()
                    refreshDebug()
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("此操作不可恢复。SQLite 中所有 activity_frames 行将被删除。")
            }
        }
        .onAppear { refreshDebug() }
    }

    private var accessibilityStatus: String {
        AXIsProcessTrusted() ? "Accessibility ✓ 已授权" : "Accessibility ⚠ 未授权（窗口标题将不可读）"
    }

    private func automationStatus(for bundleID: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        switch appState.automationOutcome(forBundleID: bundleID) {
        case .notAttempted:
            return "\(bundleID): 尚未尝试"
        case .success(let at):
            return "\(bundleID): 成功 (\(formatter.string(from: at)))"
        case .failure(let at, let reason):
            return "\(bundleID): 失败 — \(reason) (\(formatter.string(from: at)))"
        }
    }

    @ViewBuilder
    private var envFlagBanner: some View {
        if !appState.isActivityFeatureEnvOn {
            Text("Set PROJECT_MEMORY_ENABLE_ACTIVITY_CAPTURE=1 in the run environment to enable.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func refreshDebug() {
        guard let midnight = Calendar.current.date(
            bySettingHour: 0, minute: 0, second: 0, of: Date()
        ) else {
            debugReadout = "—"
            return
        }
        let count = (try? appState.store.countActivityFrames(since: midnight)) ?? 0
        let latest = (try? appState.store.fetchActivityFrames(since: midnight, limit: 1))?.first
        if let f = latest {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            debugReadout = "今日捕获：\(count) 帧；最近：\(f.appName) — \(f.category.rawValue) — \(formatter.string(from: f.observedAt))"
        } else {
            debugReadout = "今日捕获：\(count) 帧；最近：—"
        }
    }
}
