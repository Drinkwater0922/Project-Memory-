import Foundation
import ProjectMemoryCore

internal enum ActivitySettings {
    enum AddResult: Equatable {
        case added(String, [String])
        case rejectedEmpty
        case rejectedAlreadyInDefaults
        case rejectedDuplicate
    }

    static func tryAddExtraDeniedBundleID(_ input: String, current: [String]) -> AddResult {
        let cleaned = TextSanitizer.stripInvisibleControls(input)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .rejectedEmpty }
        if ActivityDenyList.defaultBundleIDs.contains(cleaned) {
            return .rejectedAlreadyInDefaults
        }
        if current.contains(cleaned) {
            return .rejectedDuplicate
        }
        return .added(cleaned, current + [cleaned])
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [Project] = []
    @Published var sources: [MemorySource] = []
    @Published var selectedProjectID: UUID?
    @Published var dailyBrief = ""
    @Published var question = ""
    @Published var answer = ""
    @Published var openRouterAPIKey: String
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var autoWebCaptureEnabled = false
    @Published var autoWebCaptureStatus = "Auto web capture is off."
    @Published var activityCaptureEnabled: Bool = false
    @Published var activityExtraDenied: [String] = []

    let store: MemoryStore
    let databasePath: String
    private let usesInMemoryStore: Bool
    private var autoWebCaptureTask: Task<Void, Never>?
    private var lastAutoCapturedNormalizedURL: String?
    private var lastAutoCapturedAt: Date?
    private let automationAttemptLog = AutomationAttemptLog()
    private lazy var browserTabReader: BrowserTabReader = OSABrowserTabReader(attemptLog: automationAttemptLog)

    private static let activityToggleKey = "ProjectMemory.activityCaptureEnabled"
    private static let activityExtraDeniedKey = "ProjectMemory.activityExtraDeniedBundleIDs"

    private var activityCoordinator: ActivityCoordinator?
    private lazy var activityRetentionGC = ActivityRetentionGC(store: store)
    private var activityRetentionGCTimer: Timer?

    var isAutoWebCaptureFeatureEnabled: Bool {
        Self.isAutoWebCaptureFeatureEnabled
    }

    var isActivityFeatureEnvOn: Bool {
        Self.isActivityFeatureEnvOn
    }

    private static var isActivityFeatureEnvOn: Bool {
        ProcessInfo.processInfo.environment["PROJECT_MEMORY_ENABLE_ACTIVITY_CAPTURE"] == "1"
    }

    var selectedProject: Project? {
        guard let selectedProjectID else {
            return projects.first
        }
        return projects.first { $0.id == selectedProjectID }
    }

    var selectedProjectSources: [MemorySource] {
        guard let projectID = selectedProject?.id else {
            return []
        }
        return sources.filter { $0.projectID == projectID }
    }

    func timeline(for project: Project) -> [TimelineEvent] {
        (try? store.fetchTimeline(projectID: project.id)) ?? []
    }

    init() {
        self.openRouterAPIKey = KeychainStore.loadAPIKey()
        let storage = Self.makeStore()
        self.databasePath = storage.path
        self.store = storage.store
        self.usesInMemoryStore = storage.usedFallback
        self.lastAutoCapturedNormalizedURL = UserDefaults.standard.string(
            forKey: Self.lastAutoCapturedNormalizedURLKey
        )
        self.lastAutoCapturedAt = UserDefaults.standard.object(
            forKey: Self.lastAutoCapturedAtKey
        ) as? Date

        if storage.usedFallback {
            self.errorMessage = "Unable to open Application Support storage. Using in-memory storage for this session."
        }

        if !Self.isAutoWebCaptureFeatureEnabled {
            self.autoWebCaptureStatus = "Auto web capture is disabled pending review."
        }

        reload()
        loadActivitySettings()
        syncActivityCoordinator()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.activityRetentionGC.runOnce()
            self.scheduleDailyActivityRetentionGC()
        }
    }

    deinit {
        activityRetentionGCTimer?.invalidate()
    }

    private func scheduleDailyActivityRetentionGC() {
        activityRetentionGCTimer?.invalidate()
        let timer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.activityRetentionGC.runOnce()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        activityRetentionGCTimer = timer
    }

    func automationOutcome(forBundleID bundleID: String) -> AutomationOutcome {
        automationAttemptLog.outcome(forBundleID: bundleID)
    }

    func reload() {
        do {
            projects = try store.fetchProjects()
            sources = try store.fetchSources()
            if dailyBrief.isEmpty, let latestBrief = try store.fetchLatestBrief() {
                dailyBrief = latestBrief.body
            }

            if selectedProjectID == nil || !projects.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID = projects.first?.id
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveAPIKey() {
        do {
            try KeychainStore.saveAPIKey(openRouterAPIKey)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAPIKey() {
        do {
            try KeychainStore.clearAPIKey()
            openRouterAPIKey = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeSource(_ source: MemorySource) {
        do {
            try store.deleteSource(id: source.id)
            reload()
        } catch {
            errorMessage = "Could not remove source: \(error.localizedDescription)"
        }
    }

    func removeProject(_ project: Project) {
        do {
            try store.deleteProject(id: project.id)
            reload()
        } catch {
            errorMessage = "Could not remove project: \(error.localizedDescription)"
        }
    }

    func importFolder(_ url: URL, projectName: String) {
        let trimmedProjectName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProjectName.isEmpty else {
            errorMessage = "Enter a project name before importing a folder."
            return
        }

        isLoading = true
        if usesInMemoryStore {
            performFolderImportOnCurrentStore(url: url, projectName: trimmedProjectName)
            isLoading = false
            return
        }

        let databasePath = self.databasePath
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FolderImportService().importFolder(
                    url: url,
                    projectName: trimmedProjectName,
                    databasePath: databasePath
                )
            }.value

            switch result {
            case .success(let payload):
                selectedProjectID = payload.projectID
                reload()
                if payload.warnings.isEmpty {
                    errorMessage = nil
                } else {
                    errorMessage = "Imported with \(payload.warnings.count) issue(s): \(payload.warnings.prefix(3).joined(separator: "; "))"
                }
            case .failure(let error):
                errorMessage = "Could not import folder: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func performFolderImportOnCurrentStore(url: URL, projectName: String) {
        switch FolderImportService().importFolder(url: url, projectName: projectName, store: store) {
        case .success(let payload):
            selectedProjectID = payload.projectID
            reload()
            errorMessage = payload.warnings.isEmpty
                ? nil
                : "Imported with \(payload.warnings.count) issue(s): \(payload.warnings.prefix(3).joined(separator: "; "))"
        case .failure(let error):
            errorMessage = "Could not import folder: \(error.localizedDescription)"
        }
    }

    func addWebCapture(title: String, url: String, text: String) {
        guard let projectID = selectedProjectID else {
            errorMessage = "Select a project before saving a web capture."
            return
        }

        let trimmedTitle = TextSanitizer.stripInvisibleControls(title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = TextSanitizer.stripInvisibleControls(url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = TextSanitizer.stripInvisibleControls(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else {
            errorMessage = "Enter a title before saving a web capture."
            return
        }

        guard !trimmedText.isEmpty else {
            errorMessage = "Paste selected page text before saving a web capture."
            return
        }

        do {
            let capturedAt = Date()
            let source = MemorySource(
                projectID: projectID,
                kind: .webCapture,
                title: trimmedTitle,
                path: "web-captures/\(UUID().uuidString).txt",
                url: trimmedURL.isEmpty ? nil : trimmedURL,
                extractedText: trimmedText,
                modifiedAt: capturedAt
            )

            try store.saveSource(source)
            try store.saveTimelineEvent(
                TimelineEvent(
                    projectID: projectID,
                    sourceID: source.id,
                    kind: .sourceAdded,
                    title: "Web capture added",
                    summary: source.path,
                    occurredAt: capturedAt
                )
            )
            reload()
            errorMessage = nil
        } catch {
            errorMessage = "Could not save web capture: \(error.localizedDescription)"
        }
    }

    func setAutoWebCaptureEnabled(_ enabled: Bool) {
        guard Self.isAutoWebCaptureFeatureEnabled else {
            autoWebCaptureEnabled = false
            autoWebCaptureStatus = "Auto web capture is disabled pending review."
            return
        }

        autoWebCaptureEnabled = enabled
        if enabled {
            startAutoWebCapture()
        } else {
            stopAutoWebCapture()
        }
    }

    func captureActiveBrowserOnce() async {
        guard Self.isAutoWebCaptureFeatureEnabled else {
            autoWebCaptureStatus = "Auto web capture is disabled pending review."
            return
        }

        guard selectedProjectID != nil else {
            autoWebCaptureStatus = "Select a project before enabling auto web capture."
            return
        }

        let reader = self.browserTabReader
        let result = await Task.detached(priority: .utility) {
            Result { try AutoWebCaptureService(reader: reader).captureActiveBrowser() }
        }.value

        switch result {
        case .success(let capture):
            persistAutoWebCapture(capture)
        case .failure(let error):
            autoWebCaptureStatus = error.localizedDescription
        }
    }

    func loadActivitySettings() {
        activityCaptureEnabled = UserDefaults.standard.bool(forKey: Self.activityToggleKey)
        activityExtraDenied = UserDefaults.standard.stringArray(forKey: Self.activityExtraDeniedKey) ?? []
    }

    func setActivityCaptureEnabled(_ enabled: Bool) {
        activityCaptureEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.activityToggleKey)
        syncActivityCoordinator()
    }

    @discardableResult
    func addActivityExtraDenied(_ input: String) -> ActivitySettings.AddResult {
        let result = ActivitySettings.tryAddExtraDeniedBundleID(input, current: activityExtraDenied)
        if case .added(_, let next) = result {
            activityExtraDenied = next
            UserDefaults.standard.set(next, forKey: Self.activityExtraDeniedKey)
        }
        return result
    }

    func removeActivityExtraDenied(_ bundleID: String) {
        activityExtraDenied.removeAll { $0 == bundleID }
        UserDefaults.standard.set(activityExtraDenied, forKey: Self.activityExtraDeniedKey)
    }

    private func syncActivityCoordinator() {
        let shouldRun = Self.isActivityFeatureEnvOn && activityCaptureEnabled
        switch (shouldRun, activityCoordinator) {
        case (true, nil):
            let frontmost = WorkspaceFrontmostAppProvider()
            let collector = MacOSActivityCandidateCollector(
                browserTabReader: browserTabReader
            )
            let coordinator = ActivityCoordinator(
                isRuntimeEnabled: { Self.isActivityFeatureEnvOn },
                isUserEnabled: { [weak self] in self?.activityCaptureEnabled ?? false },
                scheduler: TimerTickScheduler(interval: 60),
                idleStateProvider: CGEventIdleStateProvider(),
                screenLockStateProvider: CGSessionScreenLockStateProvider(),
                frontmostAppProvider: frontmost,
                selfBundleID: Bundle.main.bundleIdentifier ?? "ProjectMemoryApp",
                collector: collector,
                store: store,
                extraDenied: { [weak self] in Set(self?.activityExtraDenied ?? []) }
            )
            coordinator.start()
            activityCoordinator = coordinator
        case (false, .some(let coordinator)):
            coordinator.stop()
            activityCoordinator = nil
        default:
            break
        }
    }

    func clearAllActivityFrames() {
        do {
            try store.deleteAllActivityFrames()
        } catch {
            errorMessage = "Could not clear activity frames: \(error.localizedDescription)"
        }
    }

    private func startAutoWebCapture() {
        autoWebCaptureTask?.cancel()
        autoWebCaptureStatus = "Auto web capture is running."
        autoWebCaptureTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.captureActiveBrowserOnce()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func stopAutoWebCapture() {
        autoWebCaptureTask?.cancel()
        autoWebCaptureTask = nil
        autoWebCaptureStatus = "Auto web capture is off."
    }

    private func persistAutoWebCapture(_ capture: AutoWebCaptureResult) {
        guard let projectID = selectedProjectID else {
            autoWebCaptureStatus = "Select a project before enabling auto web capture."
            return
        }

        let sanitizedTitle = TextSanitizer.stripInvisibleControls(capture.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedURL = TextSanitizer.stripInvisibleControls(capture.url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedTextSnapshot = TextSanitizer.stripInvisibleControls(capture.textSnapshot)

        guard !URLDenyList.isDenied(sanitizedURL) else {
            autoWebCaptureStatus = "Skipped (sensitive URL)"
            return
        }

        let normalizedURL = URLDenyList.normalizeForDedup(sanitizedURL)
        if lastAutoCapturedNormalizedURL == normalizedURL,
           let lastAutoCapturedAt,
           Date().timeIntervalSince(lastAutoCapturedAt) < 600 {
            autoWebCaptureStatus = "Skipped duplicate URL captured less than 10 minutes ago."
            return
        }

        do {
            let source = MemorySource(
                projectID: projectID,
                kind: .webCapture,
                title: sanitizedTitle.isEmpty ? sanitizedURL : sanitizedTitle,
                path: "auto-web-captures/\(UUID().uuidString)",
                url: sanitizedURL,
                extractedText: sanitizedTextSnapshot,
                modifiedAt: capture.capturedAt
            )
            try store.saveSource(source)
            try store.saveTimelineEvent(
                TimelineEvent(
                    projectID: projectID,
                    sourceID: source.id,
                    kind: .sourceAdded,
                    title: "Auto web capture added",
                    summary: "\(source.title) — \(sanitizedURL)",
                    occurredAt: capture.capturedAt
                )
            )
            lastAutoCapturedNormalizedURL = normalizedURL
            lastAutoCapturedAt = capture.capturedAt
            UserDefaults.standard.set(normalizedURL, forKey: Self.lastAutoCapturedNormalizedURLKey)
            UserDefaults.standard.set(capture.capturedAt, forKey: Self.lastAutoCapturedAtKey)
            reload()
            autoWebCaptureStatus = "Captured \(capture.browserName): \(source.title)"
        } catch {
            autoWebCaptureStatus = "Could not save auto web capture: \(error.localizedDescription)"
        }
    }

    func generateDailyBrief() async {
        guard !openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dailyBrief = "Add an OpenRouter API key in Settings before generating a brief."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            reload()
            let since = Calendar.current.date(byAdding: .day, value: -7, to: Date())
            let events = try projects
                .flatMap { try store.fetchTimeline(projectID: $0.id, limit: 50, since: since) }
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(50)
            let prompt = BriefGenerator().makeDailyBriefPrompt(
                projects: projects,
                sources: sources,
                events: Array(events)
            )
            dailyBrief = try await OpenRouterClient(apiKey: openRouterAPIKey).complete(prompt: prompt)
            try store.saveBrief(
                Brief(
                    projectID: nil,
                    title: "Daily Brief",
                    body: dailyBrief,
                    sourceIDs: SourceSnippetSelector.selectForBrief(projects: projects, sources: sources).map(\.id)
                )
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func askSelectedProject() async {
        guard !openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            answer = "Add an OpenRouter API key in Settings before asking a question."
            return
        }

        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            answer = "Type a question first."
            return
        }

        guard selectedProject != nil else {
            answer = "Select a project before asking a scoped question."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            reload()
            let prompt = AnswerEngine().makeQuestionPrompt(
                question: trimmedQuestion,
                sources: selectedProjectSources
            )
            answer = try await OpenRouterClient(apiKey: openRouterAPIKey).complete(prompt: prompt)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func applicationSupportDirectory() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL.appendingPathComponent("ProjectMemory", isDirectory: true)
    }

    private static func makeStore() -> (store: MemoryStore, path: String, usedFallback: Bool) {
        do {
            let supportDirectory = try applicationSupportDirectory()
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
            let databaseURL = supportDirectory.appendingPathComponent("memory.sqlite")
            return (try MemoryStore(path: databaseURL.path), databaseURL.path, false)
        } catch {
            return (try! MemoryStore.inMemory(), ":memory:", true)
        }
    }

    private static var isAutoWebCaptureFeatureEnabled: Bool {
        ProcessInfo.processInfo.environment["PROJECT_MEMORY_ENABLE_AUTO_WEB_CAPTURE"] == "1"
    }

    private static let lastAutoCapturedNormalizedURLKey = "ProjectMemory.lastAutoCapturedNormalizedURL"
    private static let lastAutoCapturedAtKey = "ProjectMemory.lastAutoCapturedAt"

}
