import XCTest
@testable import ProjectMemoryApp
@testable import ProjectMemoryCore

private final class ManualTickScheduler: ActivityTickScheduler {
    private var onTick: (() -> Void)?
    func start(onTick: @escaping () -> Void) { self.onTick = onTick }
    func stop() { onTick = nil }
    func fire() { onTick?() }
}

private struct StubIdleStateProvider: IdleStateProvider {
    var seconds: TimeInterval
    func secondsSinceLastUserInput() -> TimeInterval { seconds }
}

private struct StubScreenLockStateProvider: ScreenLockStateProvider {
    var locked: Bool
    var isScreenLocked: Bool { locked }
}

private struct StubFrontmostAppProvider: FrontmostAppProvider {
    var snapshot_: FrontmostApplicationSnapshot?
    func snapshot() -> FrontmostApplicationSnapshot? { snapshot_ }
}

private final class StubActivityCandidateCollector: ActivityCandidateCollecting {
    var nextCandidate: ActivityCandidate?
    init(nextCandidate: ActivityCandidate? = nil) { self.nextCandidate = nextCandidate }
    func collect(snapshot: FrontmostApplicationSnapshot, now: Date) -> ActivityCandidate {
        // For tests, return the stubbed candidate or synthesize one matching the snapshot.
        if let c = nextCandidate { return c }
        return ActivityCandidate(
            observedAt: now,
            bundleID: snapshot.bundleID,
            appName: snapshot.appName,
            windowTitle: nil,
            browserURL: nil
        )
    }
}

@MainActor
final class ActivityCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        runtimeEnabled: Bool = true,
        userEnabled: Bool = true,
        idleSeconds: TimeInterval = 0,
        locked: Bool = false,
        frontmost: String? = "com.tinyspeck.slackmacgap",
        selfBundleID: String = "com.example.ProjectMemoryApp",
        candidate: ActivityCandidate? = nil,
        store: MemoryStore,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1000) }
    ) -> (ActivityCoordinator, ManualTickScheduler, StubActivityCandidateCollector) {
        let scheduler = ManualTickScheduler()
        let collector = StubActivityCandidateCollector(nextCandidate: candidate)
        let snapshot: FrontmostApplicationSnapshot? = frontmost.map {
            FrontmostApplicationSnapshot(bundleID: $0, appName: "App", pid: 0)
        }
        let coordinator = ActivityCoordinator(
            isRuntimeEnabled: { runtimeEnabled },
            isUserEnabled: { userEnabled },
            scheduler: scheduler,
            idleStateProvider: StubIdleStateProvider(seconds: idleSeconds),
            screenLockStateProvider: StubScreenLockStateProvider(locked: locked),
            frontmostAppProvider: StubFrontmostAppProvider(snapshot_: snapshot),
            selfBundleID: selfBundleID,
            collector: collector,
            store: store,
            extraDenied: { [] },
            now: now
        )
        return (coordinator, scheduler, collector)
    }

    private func makeCandidate(
        bundleID: String = "com.tinyspeck.slackmacgap",
        windowTitle: String? = "general"
    ) -> ActivityCandidate {
        ActivityCandidate(
            observedAt: Date(timeIntervalSince1970: 1000),
            bundleID: bundleID,
            appName: "Slack",
            windowTitle: windowTitle,
            browserURL: nil
        )
    }

    func testTickWritesFrameWhenAllChecksPass() throws {
        let store = try MemoryStore.inMemory()
        let (coordinator, scheduler, _) = makeCoordinator(
            candidate: makeCandidate(),
            store: store
        )
        coordinator.start()
        scheduler.fire()

        let frames = try store.fetchActivityFrames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.bundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(frames.first?.category, .chat)
    }

    func testIdlePauseSkipsTick() throws {
        let store = try MemoryStore.inMemory()
        let (coordinator, scheduler, _) = makeCoordinator(
            idleSeconds: 600,
            candidate: makeCandidate(),
            store: store
        )
        coordinator.start()
        scheduler.fire()
        XCTAssertEqual(try store.fetchActivityFrames().count, 0)
    }

    func testLockPauseSkipsTick() throws {
        let store = try MemoryStore.inMemory()
        let (coordinator, scheduler, _) = makeCoordinator(
            locked: true,
            candidate: makeCandidate(),
            store: store
        )
        coordinator.start()
        scheduler.fire()
        XCTAssertEqual(try store.fetchActivityFrames().count, 0)
    }

    func testSelfFrontmostPauseSkipsTick() throws {
        let store = try MemoryStore.inMemory()
        let (coordinator, scheduler, _) = makeCoordinator(
            frontmost: "com.example.ProjectMemoryApp",
            selfBundleID: "com.example.ProjectMemoryApp",
            candidate: makeCandidate(),
            store: store
        )
        coordinator.start()
        scheduler.fire()
        XCTAssertEqual(try store.fetchActivityFrames().count, 0)
    }

    func testRuntimeFlagOffSkipsTick() throws {
        let store = try MemoryStore.inMemory()
        let (coordinator, scheduler, _) = makeCoordinator(
            runtimeEnabled: false,
            candidate: makeCandidate(),
            store: store
        )
        coordinator.start()
        scheduler.fire()
        XCTAssertEqual(try store.fetchActivityFrames().count, 0)
    }

    func testUserToggleOffSkipsTick() throws {
        let store = try MemoryStore.inMemory()
        let (coordinator, scheduler, _) = makeCoordinator(
            userEnabled: false,
            candidate: makeCandidate(),
            store: store
        )
        coordinator.start()
        scheduler.fire()
        XCTAssertEqual(try store.fetchActivityFrames().count, 0)
    }

    func testRateLimitSkipsImmediateSecondTick() throws {
        let store = try MemoryStore.inMemory()
        var t = Date(timeIntervalSince1970: 1000)
        let (coordinator, scheduler, _) = makeCoordinator(
            candidate: makeCandidate(),
            store: store,
            now: { t }
        )
        coordinator.start()
        scheduler.fire()                      // captures
        t = t.addingTimeInterval(2)           // 2s later, within rate limit
        scheduler.fire()
        XCTAssertEqual(try store.fetchActivityFrames().count, 1)
    }

    func testNoFrontmostAppSkipsTick() throws {
        let store = try MemoryStore.inMemory()
        let (coordinator, scheduler, _) = makeCoordinator(
            frontmost: nil,
            candidate: makeCandidate(),
            store: store
        )
        coordinator.start()
        scheduler.fire()
        XCTAssertEqual(try store.fetchActivityFrames().count, 0)
    }
}
