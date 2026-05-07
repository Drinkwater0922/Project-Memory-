// Tests/ProjectMemoryCoreTests/PhaseTwoTypesTests.swift
import XCTest
@testable import ProjectMemoryCore

final class PhaseTwoTypesTests: XCTestCase {
    func testSourceKindIncludesActivitySession() {
        XCTAssertEqual(SourceKind(rawValue: "activitySession"), .activitySession)
        XCTAssertTrue(SourceKind.allCases.contains(.activitySession))
    }

    func testAssignmentStatusCodableRoundTrip() throws {
        let cases: [AssignmentStatus] = [.unassigned, .ruleAssigned, .manualAssigned, .ignored]
        for value in cases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(AssignmentStatus.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }

    func testPreservedAssignmentEquatable() {
        let id = UUID()
        let p = UUID()
        let a = PreservedAssignment(sessionID: id, assignmentStatus: .manualAssigned, projectID: p)
        let b = PreservedAssignment(sessionID: id, assignmentStatus: .manualAssigned, projectID: p)
        XCTAssertEqual(a, b)
    }
}
