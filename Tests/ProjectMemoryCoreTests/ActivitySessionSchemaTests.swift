import XCTest
@testable import ProjectMemoryCore

final class ActivitySessionSchemaTests: XCTestCase {
    func testActivitySessionTablesExist() throws {
        let store = try MemoryStore.inMemory()
        // Smoke: try a no-op SELECT on each new table; SQLite will throw if missing.
        XCTAssertNoThrow(try store.executeRawForTest("SELECT count(*) FROM activity_sessions"))
        XCTAssertNoThrow(try store.executeRawForTest("SELECT count(*) FROM activity_session_frames"))
        XCTAssertNoThrow(try store.executeRawForTest("SELECT count(*) FROM project_activity_rules"))
    }

    func testActivitySessionIndexesExist() throws {
        let store = try MemoryStore.inMemory()
        let names = try store.fetchIndexNamesForTest(table: "activity_sessions")
        XCTAssertTrue(names.contains("idx_sessions_ended_at"))
        XCTAssertTrue(names.contains("idx_sessions_source_status_ended_at"))
        XCTAssertTrue(names.contains("idx_sessions_status_ended_at"))
        XCTAssertTrue(names.contains("idx_sessions_project_ended_at"))
    }
}
