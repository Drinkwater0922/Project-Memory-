// Tests/ProjectMemoryCoreTests/AssignmentResolverTests.swift
import XCTest
@testable import ProjectMemoryCore

final class AssignmentResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDraft(bundleID: String = "com.x", host: String? = nil, frameIDs: [UUID] = [UUID()]) -> ActivitySessionDraft {
        ActivitySessionDraft(
            id: frameIDs[0], startedAt: now, endedAt: now.addingTimeInterval(60),
            bundleID: bundleID, appName: bundleID, browserHost: host,
            category: .work, titleSamples: [], frameCount: 2, frameIDs: frameIDs
        )
    }

    private func makeFrame(_ id: UUID, bundleID: String = "com.x", url: String? = nil, title: String? = nil) -> ActivityFrame {
        ActivityFrame(id: id, observedAt: now, bundleID: bundleID, appName: bundleID, windowTitle: title, browserURL: url, category: .work)
    }

    func testPreservedShortCircuitsRuleEvaluation() {
        let project = UUID()
        let draft = makeDraft()
        let preserved = PreservedAssignment(sessionID: draft.id, assignmentStatus: .manualAssigned, projectID: project)
        let unrelatedRule = ProjectActivityRule(projectID: UUID(), kind: .bundleIDEquals, pattern: "com.x", isEnabled: true)
        let resolved = AssignmentResolver.resolve(draft: draft, rules: [unrelatedRule], preserved: preserved, relatedFrames: [])
        XCTAssertEqual(resolved.assignmentStatus, .manualAssigned)
        XCTAssertEqual(resolved.projectID, project)
        XCTAssertEqual(resolved.assignmentSource, "manual")
    }

    func testPreservedIgnoredOverridesRule() {
        let draft = makeDraft()
        let preserved = PreservedAssignment(sessionID: draft.id, assignmentStatus: .ignored, projectID: nil)
        let rule = ProjectActivityRule(projectID: UUID(), kind: .bundleIDEquals, pattern: "com.x", isEnabled: true)
        let resolved = AssignmentResolver.resolve(draft: draft, rules: [rule], preserved: preserved, relatedFrames: [])
        XCTAssertEqual(resolved.assignmentStatus, .ignored)
        XCTAssertNil(resolved.projectID)
        XCTAssertEqual(resolved.assignmentSource, "manual")
    }

    func testNoPreservedNoRulesReturnsUnassigned() {
        let resolved = AssignmentResolver.resolve(draft: makeDraft(), rules: [], preserved: nil, relatedFrames: [])
        XCTAssertEqual(resolved.assignmentStatus, .unassigned)
        XCTAssertNil(resolved.projectID)
        XCTAssertNil(resolved.assignmentSource)
    }

    func testBundleIDEqualsCaseSensitive() {
        let draft = makeDraft(bundleID: "com.foo.Bar")
        let exactRule = ProjectActivityRule(projectID: UUID(), kind: .bundleIDEquals, pattern: "com.foo.Bar", isEnabled: true)
        let lowerRule = ProjectActivityRule(projectID: UUID(), kind: .bundleIDEquals, pattern: "com.foo.bar", isEnabled: true)
        XCTAssertEqual(AssignmentResolver.resolve(draft: draft, rules: [exactRule], preserved: nil, relatedFrames: []).assignmentStatus, .ruleAssigned)
        XCTAssertEqual(AssignmentResolver.resolve(draft: draft, rules: [lowerRule], preserved: nil, relatedFrames: []).assignmentStatus, .unassigned)
    }

    func testUrlContainsScansAllRelatedFrames() {
        // First frame is github.com homepage; later frame enters /myorg/repo
        let f1 = makeFrame(UUID(), url: "https://github.com/")
        let f2 = makeFrame(UUID(), url: "https://github.com/myorg/repo")
        let draft = makeDraft(host: "github.com", frameIDs: [f1.id, f2.id])
        let project = UUID()
        let rule = ProjectActivityRule(projectID: project, kind: .urlContains, pattern: "github.com/myorg", isEnabled: true)
        let resolved = AssignmentResolver.resolve(draft: draft, rules: [rule], preserved: nil, relatedFrames: [f1, f2])
        XCTAssertEqual(resolved.projectID, project)
        XCTAssertEqual(resolved.assignmentSource, "rule:\(rule.id.uuidString)")
    }

    func testUrlContainsCaseInsensitivePattern() {
        let f = makeFrame(UUID(), url: "https://GitHub.com/MyOrg/Repo")
        let draft = makeDraft(host: "github.com", frameIDs: [f.id])
        let rule = ProjectActivityRule(projectID: UUID(), kind: .urlContains, pattern: "myorg/repo", isEnabled: true)
        XCTAssertEqual(AssignmentResolver.resolve(draft: draft, rules: [rule], preserved: nil, relatedFrames: [f]).assignmentStatus, .ruleAssigned)
    }

    func testTitleContainsScansAllRelatedFramesSanitizedAndCaseInsensitive() {
        let f1 = makeFrame(UUID(), title: "Untitled — Cursor")
        let f2 = makeFrame(UUID(), title: "Project-Memory · ActivityCoordinator.swift\u{200B} — Cursor")
        let draft = makeDraft(frameIDs: [f1.id, f2.id])
        let rule = ProjectActivityRule(projectID: UUID(), kind: .titleContains, pattern: "project-memory", isEnabled: true)
        XCTAssertEqual(AssignmentResolver.resolve(draft: draft, rules: [rule], preserved: nil, relatedFrames: [f1, f2]).assignmentStatus, .ruleAssigned)
    }

    func testKindPriorityUrlBeatsTitleBeatsBundle() {
        let f = makeFrame(UUID(), url: "https://github.com/myorg/repo", title: "myproj — Cursor")
        let draft = makeDraft(bundleID: "com.x", host: "github.com", frameIDs: [f.id])
        let urlProject = UUID(), titleProject = UUID(), bundleProject = UUID()
        let rules = [
            ProjectActivityRule(projectID: bundleProject, kind: .bundleIDEquals, pattern: "com.x", isEnabled: true),
            ProjectActivityRule(projectID: titleProject, kind: .titleContains, pattern: "myproj", isEnabled: true),
            ProjectActivityRule(projectID: urlProject, kind: .urlContains, pattern: "github.com/myorg", isEnabled: true)
        ]
        let resolved = AssignmentResolver.resolve(draft: draft, rules: rules, preserved: nil, relatedFrames: [f])
        XCTAssertEqual(resolved.projectID, urlProject)
    }

    func testWithinKindCreatedAtAscFirstMatchWins() {
        let f = makeFrame(UUID(), url: "https://github.com/")
        let draft = makeDraft(host: "github.com", frameIDs: [f.id])
        let p1 = UUID(), p2 = UUID()
        let early = ProjectActivityRule(id: UUID(), projectID: p1, kind: .urlContains, pattern: "github.com", isEnabled: true, createdAt: Date(timeIntervalSince1970: 100))
        let late = ProjectActivityRule(id: UUID(), projectID: p2, kind: .urlContains, pattern: "github.com", isEnabled: true, createdAt: Date(timeIntervalSince1970: 200))
        let resolved = AssignmentResolver.resolve(draft: draft, rules: [late, early], preserved: nil, relatedFrames: [f])
        XCTAssertEqual(resolved.projectID, p1)  // earlier created wins
    }

    func testDisabledRuleSkipped() {
        let f = makeFrame(UUID(), url: "https://github.com/")
        let draft = makeDraft(host: "github.com", frameIDs: [f.id])
        let rule = ProjectActivityRule(projectID: UUID(), kind: .urlContains, pattern: "github.com", isEnabled: false)
        XCTAssertEqual(AssignmentResolver.resolve(draft: draft, rules: [rule], preserved: nil, relatedFrames: [f]).assignmentStatus, .unassigned)
    }
}
