import Foundation
import ProjectMemoryCore

@MainActor
internal final class ActivityCoordinator {
    private let isRuntimeEnabled: () -> Bool
    private let isUserEnabled: () -> Bool
    private let scheduler: ActivityTickScheduler
    private let idleStateProvider: IdleStateProvider
    private let screenLockStateProvider: ScreenLockStateProvider
    private let frontmostAppProvider: FrontmostAppProvider
    private let selfBundleID: String
    private let collector: ActivityCandidateCollecting
    private let store: MemoryStore
    private let extraDenied: () -> Set<String>
    private let now: () -> Date

    private static let idleThresholdSeconds: TimeInterval = 300

    private var lastCaptureAt: Date?

    init(
        isRuntimeEnabled: @escaping () -> Bool,
        isUserEnabled: @escaping () -> Bool,
        scheduler: ActivityTickScheduler,
        idleStateProvider: IdleStateProvider,
        screenLockStateProvider: ScreenLockStateProvider,
        frontmostAppProvider: FrontmostAppProvider,
        selfBundleID: String,
        collector: ActivityCandidateCollecting,
        store: MemoryStore,
        extraDenied: @escaping () -> Set<String>,
        now: @escaping () -> Date = Date.init
    ) {
        self.isRuntimeEnabled = isRuntimeEnabled
        self.isUserEnabled = isUserEnabled
        self.scheduler = scheduler
        self.idleStateProvider = idleStateProvider
        self.screenLockStateProvider = screenLockStateProvider
        self.frontmostAppProvider = frontmostAppProvider
        self.selfBundleID = selfBundleID
        self.collector = collector
        self.store = store
        self.extraDenied = extraDenied
        self.now = now
    }

    func start() {
        scheduler.start { [weak self] in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    func stop() {
        scheduler.stop()
    }

    private func tick() {
        guard isRuntimeEnabled() else { return }
        guard isUserEnabled() else { return }
        guard idleStateProvider.secondsSinceLastUserInput() < Self.idleThresholdSeconds else { return }
        guard !screenLockStateProvider.isScreenLocked else { return }
        guard let snapshot = frontmostAppProvider.snapshot() else { return }
        guard snapshot.bundleID != selfBundleID else { return }

        let currentNow = now()
        let candidate = collector.collect(snapshot: snapshot, now: currentNow)

        let decision = ActivityGate.decide(
            candidate: candidate,
            now: currentNow,
            lastCaptureAt: lastCaptureAt,
            extraDenied: extraDenied()
        )
        guard decision == .capture else { return }

        let frame = ActivityFrame(
            observedAt: candidate.observedAt,
            bundleID: candidate.bundleID,
            appName: candidate.appName,
            windowTitle: candidate.windowTitle,
            browserURL: candidate.browserURL,
            category: ActivityClassifier.classify(candidate),
            projectID: nil
        )

        do {
            try store.saveActivityFrame(frame)
            lastCaptureAt = currentNow
        } catch {
            // best-effort; persistence error is non-fatal for the loop
        }
    }
}
