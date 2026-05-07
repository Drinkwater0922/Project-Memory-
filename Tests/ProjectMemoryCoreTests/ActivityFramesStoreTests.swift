import XCTest
@testable import ProjectMemoryCore

final class ActivityFramesStoreTests: XCTestCase {
    func testSaveAndFetchActivityFrameRoundTrip() throws {
        let store = try MemoryStore.inMemory()
        let frame = ActivityFrame(
            observedAt: Date(timeIntervalSince1970: 100),
            bundleID: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            windowTitle: "general",
            browserURL: nil,
            category: .chat,
            projectID: nil
        )

        try store.saveActivityFrame(frame)
        let fetched = try store.fetchActivityFrames()

        XCTAssertEqual(fetched, [frame])
    }
}

extension ActivityFramesStoreTests {
    private func makeFrame(
        observedAt: Date,
        bundleID: String = "com.example.app",
        appName: String = "App",
        category: ActivityCategory = .other,
        projectID: UUID? = nil
    ) -> ActivityFrame {
        ActivityFrame(
            observedAt: observedAt,
            bundleID: bundleID,
            appName: appName,
            windowTitle: nil,
            browserURL: nil,
            category: category,
            projectID: projectID
        )
    }

    func testFetchOrdersDescendingByObservedAt() throws {
        let store = try MemoryStore.inMemory()
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 1)))
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 3)))
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 2)))

        let frames = try store.fetchActivityFrames()

        XCTAssertEqual(frames.map(\.observedAt.timeIntervalSince1970), [3, 2, 1])
    }

    func testFetchFilterByCategory() throws {
        let store = try MemoryStore.inMemory()
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 1), category: .chat))
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 2), category: .work))

        let chatOnly = try store.fetchActivityFrames(category: .chat)

        XCTAssertEqual(chatOnly.count, 1)
        XCTAssertEqual(chatOnly.first?.category, .chat)
    }

    func testFetchFilterByProject() throws {
        let store = try MemoryStore.inMemory()
        let pid = UUID()
        let project = Project(id: pid, name: "Alpha", rootPath: "/tmp/alpha")
        try store.saveProject(project)

        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 1), projectID: pid))
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 2), projectID: nil))

        XCTAssertEqual(try store.fetchActivityFrames(project: .any).count, 2)
        XCTAssertEqual(try store.fetchActivityFrames(project: .unassigned).count, 1)
        XCTAssertEqual(try store.fetchActivityFrames(project: .project(pid)).count, 1)
    }

    func testFetchSinceIsClosedLeftBound() throws {
        let store = try MemoryStore.inMemory()
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 99)))
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 100)))
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 101)))

        let frames = try store.fetchActivityFrames(since: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(frames.map(\.observedAt.timeIntervalSince1970), [101, 100])
    }

    func testFetchUntilIsOpenRightBound() throws {
        let store = try MemoryStore.inMemory()
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 99)))
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 100)))
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 101)))

        let frames = try store.fetchActivityFrames(until: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(frames.map(\.observedAt.timeIntervalSince1970), [99])
    }

    func testFetchLimit() throws {
        let store = try MemoryStore.inMemory()
        for i in 0..<5 {
            try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: TimeInterval(i))))
        }

        let frames = try store.fetchActivityFrames(limit: 2)

        XCTAssertEqual(frames.map(\.observedAt.timeIntervalSince1970), [4, 3])
    }

    func testCountMatchesFetchUnderSameFilter() throws {
        let store = try MemoryStore.inMemory()
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 1), category: .chat))
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 2), category: .chat))
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 3), category: .work))

        XCTAssertEqual(try store.countActivityFrames(), 3)
        XCTAssertEqual(try store.countActivityFrames(category: .chat), 2)
        XCTAssertEqual(try store.countActivityFrames(category: .work), 1)
    }

    func testDeleteActivityFramesBeforeDateIsRightOpen() throws {
        let store = try MemoryStore.inMemory()
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 99)))
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 100)))
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 101)))

        try store.deleteActivityFrames(beforeDate: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(
            try store.fetchActivityFrames().map(\.observedAt.timeIntervalSince1970),
            [101, 100]
        )
    }

    func testDeleteAllActivityFramesRemovesEverything() throws {
        let store = try MemoryStore.inMemory()
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 1)))
        try store.saveActivityFrame(makeFrame(observedAt: Date(timeIntervalSince1970: 2)))

        try store.deleteAllActivityFrames()

        XCTAssertEqual(try store.fetchActivityFrames().count, 0)
    }
}
