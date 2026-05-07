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

    func testProjectActivityRuleCodableRoundTrip() throws {
        let rule = ProjectActivityRule(
            id: UUID(),
            projectID: UUID(),
            kind: .urlContains,
            pattern: "github.com/myorg",
            isEnabled: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(ProjectActivityRule.self, from: data)
        XCTAssertEqual(decoded, rule)
    }

    func testProjectActivityRuleKindRawValues() {
        XCTAssertEqual(ProjectActivityRule.Kind.urlContains.rawValue, "urlContains")
        XCTAssertEqual(ProjectActivityRule.Kind.titleContains.rawValue, "titleContains")
        XCTAssertEqual(ProjectActivityRule.Kind.bundleIDEquals.rawValue, "bundleIDEquals")
    }

    func testActivitySessionDraftEquatable() {
        let id = UUID()
        let f1 = UUID()
        let now = Date()
        let a = ActivitySessionDraft(
            id: id, startedAt: now, endedAt: now.addingTimeInterval(60),
            bundleID: "com.x", appName: "X", browserHost: "github.com",
            category: .work, titleSamples: ["t"], frameCount: 2, frameIDs: [f1]
        )
        let b = ActivitySessionDraft(
            id: id, startedAt: now, endedAt: now.addingTimeInterval(60),
            bundleID: "com.x", appName: "X", browserHost: "github.com",
            category: .work, titleSamples: ["t"], frameCount: 2, frameIDs: [f1]
        )
        XCTAssertEqual(a, b)
    }

    func testPersistedActivitySessionFieldsRoundTrip() throws {
        let session = PersistedActivitySession(
            id: UUID(), startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 60),
            bundleID: "com.x", appName: "X", browserHost: nil,
            category: .work, assignmentStatus: .manualAssigned, projectID: UUID(),
            assignmentSource: "manual", titleSamples: ["a", "b"], frameCount: 3
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(PersistedActivitySession.self, from: data)
        XCTAssertEqual(decoded, session)
    }
}
