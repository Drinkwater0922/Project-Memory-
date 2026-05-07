# Phase 2 — Activity Sessions, Project Attribution & Brief Integration: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the Phase 2 spec — aggregate Phase 1 `activity_frames` into `ActivitySession`, attribute to projects via rules + manual triage, integrate into brief / Q&A behind tightened privacy gates without breaking Phase 1 isolation.

**Architecture:** Three Core layers (`SessionAggregator` pure → `AssignmentResolver` pure → `ActivitySessionReconciler` side-effects), with App-layer `SessionPipeline` (@MainActor) as the only orchestrator. `SelectedSourceSnippet` refactor (Phase 2 前置手术) — every `SourceKind` flows through `[SelectedSourceSnippet]`; prompt path is forbidden from reading `MemorySource.extractedText` directly.

**Tech Stack:** Swift 5.9+, SwiftPM, SwiftUI, SQLite3 (existing `SQLiteDatabase` wrapper), XCTest. No new third-party deps.

**Spec:** `docs/superpowers/specs/2026-05-07-phase-2-activity-sessions.md`

## Pre-flight notes

1. **Existing table name is `sources`, not `memory_sources`.** Spec uses `memory_sources` as shorthand in §4 / §6.3 / §7.6. All DDL & SQL in this plan uses the real table name `sources`.
2. **Schema changes go into the existing `createSchema()` private method** in `Sources/ProjectMemoryCore/MemoryStore.swift`. SQLite's `CREATE TABLE IF NOT EXISTS` makes this idempotent for existing dogfood DBs.
3. **MemoryStore.swift is already ~400 lines.** Phase 2 introduces ~10 new APIs. Use a Swift extension file (`MemoryStore+ActivitySession.swift`) rather than appending to the main file. The existing `Phase 1 fetchActivityFrames` etc. stay in the main file.
4. **All new types go in `Sources/ProjectMemoryCore/Models.swift`** (existing convention) UNLESS they're tightly bound to a single algorithm file (e.g., `ActivitySessionCaps` lives next to `SourceSnippetSelector`).
5. **Build / test commands:**
   - `swift build` from repo root
   - `swift test` from repo root
   - Run a single test: `swift test --filter <TestSuiteName>.<testName>`

---

## Task 1: Add `SourceKind.activitySession` case + assignment types

**Files:**
- Modify: `Sources/ProjectMemoryCore/Models.swift`
- Create: `Tests/ProjectMemoryCoreTests/PhaseTwoTypesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PhaseTwoTypesTests`
Expected: build error — `activitySession` / `AssignmentStatus` / `PreservedAssignment` undefined.

- [ ] **Step 3: Add types to Models.swift**

Append to `Sources/ProjectMemoryCore/Models.swift`:

```swift
public enum AssignmentStatus: String, Codable, CaseIterable, Equatable {
    case unassigned
    case ruleAssigned
    case manualAssigned
    case ignored
}

public struct PreservedAssignment: Equatable {
    public let sessionID: UUID
    public let assignmentStatus: AssignmentStatus  // .manualAssigned 或 .ignored
    public let projectID: UUID?

    public init(sessionID: UUID, assignmentStatus: AssignmentStatus, projectID: UUID?) {
        self.sessionID = sessionID
        self.assignmentStatus = assignmentStatus
        self.projectID = projectID
    }
}
```

In the existing `SourceKind` enum, add the case:

```swift
public enum SourceKind: String, Codable, CaseIterable {
    case markdown
    case pdf
    case html
    case text
    case gitCommit
    case webCapture
    case activitySession   // <-- new in Phase 2
    case unsupported
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PhaseTwoTypesTests`
Expected: 3/3 PASS.

- [ ] **Step 5: Run full test suite**

Run: `swift test`
Expected: ALL existing tests still pass. If any switch on `SourceKind` errors with non-exhaustive warning, find it via build output and add an explicit `case .activitySession: ...` branch (default behavior: treat as `.text` for any UI/parser switch that doesn't yet know about activity sessions).

- [ ] **Step 6: Commit**

```bash
git add Sources/ProjectMemoryCore/Models.swift Tests/ProjectMemoryCoreTests/PhaseTwoTypesTests.swift
git commit -m "feat(phase2): add SourceKind.activitySession + AssignmentStatus + PreservedAssignment"
```

---

## Task 2: Add `ProjectActivityRule` + draft / resolved / persisted session types

**Files:**
- Modify: `Sources/ProjectMemoryCore/Models.swift`
- Modify: `Tests/ProjectMemoryCoreTests/PhaseTwoTypesTests.swift`

- [ ] **Step 1: Add failing tests for new types**

Append to `PhaseTwoTypesTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test --filter PhaseTwoTypesTests`
Expected: build error — `ProjectActivityRule` / `ActivitySessionDraft` / `PersistedActivitySession` undefined.

- [ ] **Step 3: Add types to Models.swift**

```swift
public struct ProjectActivityRule: Identifiable, Codable, Equatable {
    public let id: UUID
    public let projectID: UUID
    public let kind: Kind
    /// Pattern is stored only after `trimmingCharacters(in: .whitespacesAndNewlines)`.
    /// Resolver applies kind-specific normalization at match time:
    ///   - urlContains:  normalizedURL.contains(pattern.lowercased())
    ///   - titleContains: stripInvisibleControls(title).lowercased().contains(pattern.lowercased())
    ///   - bundleIDEquals: pattern == draft.bundleID  (case-sensitive — macOS bundle IDs are case-sensitive)
    public let pattern: String
    public let isEnabled: Bool
    public let createdAt: Date

    public enum Kind: String, Codable, CaseIterable {
        case urlContains
        case titleContains
        case bundleIDEquals
    }

    public init(id: UUID = UUID(), projectID: UUID, kind: Kind, pattern: String, isEnabled: Bool, createdAt: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.pattern = pattern
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

public struct ActivitySessionDraft: Equatable {
    public let id: UUID                  // = firstFrame.id (Q4 锁定)
    public let startedAt: Date
    public let endedAt: Date
    public let bundleID: String
    public let appName: String
    public let browserHost: String?      // normalize 后的 host；非浏览器为 nil
    public let category: ActivityCategory
    /// max 5; first-seen order; sanitized via `TextSanitizer.stripInvisibleControls` then trimmed; empty strings dropped; deduped.
    public let titleSamples: [String]
    public let frameCount: Int
    public let frameIDs: [UUID]

    public init(id: UUID, startedAt: Date, endedAt: Date, bundleID: String, appName: String, browserHost: String?, category: ActivityCategory, titleSamples: [String], frameCount: Int, frameIDs: [UUID]) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bundleID = bundleID
        self.appName = appName
        self.browserHost = browserHost
        self.category = category
        self.titleSamples = titleSamples
        self.frameCount = frameCount
        self.frameIDs = frameIDs
    }
}

public struct ResolvedActivitySession: Equatable {
    public let draft: ActivitySessionDraft
    public let assignmentStatus: AssignmentStatus
    public let projectID: UUID?
    /// "manual" | "rule:<uuid>" | nil
    public let assignmentSource: String?

    public init(draft: ActivitySessionDraft, assignmentStatus: AssignmentStatus, projectID: UUID?, assignmentSource: String?) {
        self.draft = draft
        self.assignmentStatus = assignmentStatus
        self.projectID = projectID
        self.assignmentSource = assignmentSource
    }
}

public struct PersistedActivitySession: Identifiable, Equatable, Codable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let bundleID: String
    public let appName: String
    public let browserHost: String?
    public let category: ActivityCategory
    public let assignmentStatus: AssignmentStatus
    public let projectID: UUID?
    public let assignmentSource: String?
    public let titleSamples: [String]
    public let frameCount: Int

    public init(id: UUID, startedAt: Date, endedAt: Date, bundleID: String, appName: String, browserHost: String?, category: ActivityCategory, assignmentStatus: AssignmentStatus, projectID: UUID?, assignmentSource: String?, titleSamples: [String], frameCount: Int) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bundleID = bundleID
        self.appName = appName
        self.browserHost = browserHost
        self.category = category
        self.assignmentStatus = assignmentStatus
        self.projectID = projectID
        self.assignmentSource = assignmentSource
        self.titleSamples = titleSamples
        self.frameCount = frameCount
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `swift test --filter PhaseTwoTypesTests`
Expected: 7/7 PASS.

- [ ] **Step 5: Run full test suite**

Run: `swift test`
Expected: ALL pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ProjectMemoryCore/Models.swift Tests/ProjectMemoryCoreTests/PhaseTwoTypesTests.swift
git commit -m "feat(phase2): add ProjectActivityRule + ActivitySessionDraft + ResolvedActivitySession + PersistedActivitySession types"
```

---

## Task 3: `SessionAggregator` (pure) — slicing + identity + frameCount gate + titleSamples

**Files:**
- Create: `Sources/ProjectMemoryCore/SessionAggregator.swift`
- Create: `Tests/ProjectMemoryCoreTests/SessionAggregatorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/ProjectMemoryCoreTests/SessionAggregatorTests.swift
import XCTest
@testable import ProjectMemoryCore

final class SessionAggregatorTests: XCTestCase {
    private let chrome = "com.google.Chrome"
    private let cursor = "com.todesktop.230313mzl4w4u92"
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func frame(_ offset: TimeInterval, bundleID: String, host: String? = nil, title: String? = nil, category: ActivityCategory = .work) -> ActivityFrame {
        ActivityFrame(
            observedAt: t0.addingTimeInterval(offset),
            bundleID: bundleID,
            appName: bundleID,
            windowTitle: title,
            browserURL: host.map { "https://\($0)/some/path?q=1" },
            category: category
        )
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertEqual(SessionAggregator.aggregate([]), [])
    }

    func testSingleFrameDropped() {
        let f = frame(0, bundleID: cursor, title: "x")
        XCTAssertEqual(SessionAggregator.aggregate([f]), [])
    }

    func testSameIdentityWithinGapIsOneSession() {
        let f1 = frame(0, bundleID: cursor, title: "a")
        let f2 = frame(60, bundleID: cursor, title: "a")
        let f3 = frame(120, bundleID: cursor, title: "b")
        let drafts = SessionAggregator.aggregate([f1, f2, f3])
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].frameCount, 3)
        XCTAssertEqual(drafts[0].id, f1.id)  // = firstFrame.id
        XCTAssertEqual(drafts[0].titleSamples, ["a", "b"])
    }

    func testGapOver5MinSplitsSession() {
        let f1 = frame(0, bundleID: cursor, title: "a")
        let f2 = frame(60, bundleID: cursor, title: "a")
        let f3 = frame(60 + 301, bundleID: cursor, title: "b")
        let f4 = frame(60 + 361, bundleID: cursor, title: "b")
        let drafts = SessionAggregator.aggregate([f1, f2, f3, f4])
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].id, f1.id)
        XCTAssertEqual(drafts[1].id, f3.id)
    }

    func testDifferentBundleIDSplitsSession() {
        let f1 = frame(0, bundleID: cursor)
        let f2 = frame(60, bundleID: chrome, host: "github.com")
        XCTAssertEqual(SessionAggregator.aggregate([f1, f2]), [])  // both single-frame; both dropped
    }

    func testBrowserHostSplitsSession() {
        let f1 = frame(0, bundleID: chrome, host: "github.com")
        let f2 = frame(60, bundleID: chrome, host: "github.com")
        let f3 = frame(120, bundleID: chrome, host: "twitter.com")
        let f4 = frame(180, bundleID: chrome, host: "twitter.com")
        let drafts = SessionAggregator.aggregate([f1, f2, f3, f4])
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].browserHost, "github.com")
        XCTAssertEqual(drafts[1].browserHost, "twitter.com")
    }

    func testNonBrowserIgnoresHost() {
        // For non-browser bundle, browserURL should be nil from collector;
        // aggregator must not split on URL changes for non-browser frames.
        let f1 = frame(0, bundleID: cursor)
        let f2 = frame(60, bundleID: cursor)
        let drafts = SessionAggregator.aggregate([f1, f2])
        XCTAssertEqual(drafts.count, 1)
        XCTAssertNil(drafts[0].browserHost)
    }

    func testOutOfOrderInputIsSorted() {
        let f1 = frame(0, bundleID: cursor)
        let f2 = frame(60, bundleID: cursor)
        let f3 = frame(120, bundleID: cursor)
        let drafts = SessionAggregator.aggregate([f3, f1, f2])
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].startedAt, f1.observedAt)
        XCTAssertEqual(drafts[0].endedAt, f3.observedAt)
        XCTAssertEqual(drafts[0].id, f1.id)
    }

    func testTitleSamplesMaxFiveDedupSanitizeTrim() {
        // 6 distinct titles + 1 invisible-Cf char + 1 dupe + 1 whitespace-only
        let titles = ["t1", "t2", "t3", "t1", "  ", "t4\u{200B}", "t5", "t6", "t7"]
        let frames = titles.enumerated().map { idx, t in
            frame(TimeInterval(idx * 30), bundleID: cursor, title: t)
        }
        let drafts = SessionAggregator.aggregate(frames)
        XCTAssertEqual(drafts.count, 1)
        let samples = drafts[0].titleSamples
        XCTAssertEqual(samples.count, 5)
        XCTAssertEqual(samples, ["t1", "t2", "t3", "t4", "t5"])  // first-seen order; whitespace-only dropped; ​ stripped; t1 dedup
    }

    func testFrameCountAndFrameIDsPreserveOrder() {
        let f1 = frame(0, bundleID: cursor)
        let f2 = frame(60, bundleID: cursor)
        let f3 = frame(120, bundleID: cursor)
        let drafts = SessionAggregator.aggregate([f3, f2, f1])
        XCTAssertEqual(drafts[0].frameCount, 3)
        XCTAssertEqual(drafts[0].frameIDs, [f1.id, f2.id, f3.id])
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test --filter SessionAggregatorTests`
Expected: build error — `SessionAggregator` undefined.

- [ ] **Step 3: Implement SessionAggregator**

Create `Sources/ProjectMemoryCore/SessionAggregator.swift`:

```swift
import Foundation

public enum SessionAggregator {
    /// Maximum gap between two consecutive frames within one session.
    /// Spec §6.1 / known limitation: changing this is a breaking config change.
    public static let sessionGapThreshold: TimeInterval = 300  // 5 min

    public static func aggregate(_ frames: [ActivityFrame]) -> [ActivitySessionDraft] {
        let sorted = frames.sorted { $0.observedAt < $1.observedAt }
        guard !sorted.isEmpty else { return [] }

        var drafts: [ActivitySessionDraft] = []
        var current: [ActivityFrame] = []

        for frame in sorted {
            if let last = current.last,
               sameIdentity(last, frame),
               frame.observedAt.timeIntervalSince(last.observedAt) <= sessionGapThreshold {
                current.append(frame)
            } else {
                if let draft = makeDraft(from: current) { drafts.append(draft) }
                current = [frame]
            }
        }
        if let draft = makeDraft(from: current) { drafts.append(draft) }

        return drafts
    }

    private static func sameIdentity(_ a: ActivityFrame, _ b: ActivityFrame) -> Bool {
        guard a.bundleID == b.bundleID else { return false }
        return host(of: a) == host(of: b)
    }

    private static func host(of frame: ActivityFrame) -> String? {
        guard let urlString = frame.browserURL,
              let host = URLComponents(string: urlString)?.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        return host
    }

    private static func makeDraft(from frames: [ActivityFrame]) -> ActivitySessionDraft? {
        guard frames.count >= 2 else { return nil }   // frameCount gate: drop single-frame
        let first = frames[0]
        let last = frames[frames.count - 1]
        let titleSamples = collectTitleSamples(from: frames)
        return ActivitySessionDraft(
            id: first.id,
            startedAt: first.observedAt,
            endedAt: last.observedAt,
            bundleID: first.bundleID,
            appName: first.appName,
            browserHost: host(of: first),
            category: first.category,
            titleSamples: titleSamples,
            frameCount: frames.count,
            frameIDs: frames.map(\.id)
        )
    }

    private static func collectTitleSamples(from frames: [ActivityFrame]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for frame in frames {
            guard let raw = frame.windowTitle else { continue }
            let sanitized = TextSanitizer.stripInvisibleControls(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitized.isEmpty else { continue }
            guard !seen.contains(sanitized) else { continue }
            seen.insert(sanitized)
            result.append(sanitized)
            if result.count >= 5 { break }
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `swift test --filter SessionAggregatorTests`
Expected: 10/10 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectMemoryCore/SessionAggregator.swift Tests/ProjectMemoryCoreTests/SessionAggregatorTests.swift
git commit -m "feat(phase2): SessionAggregator pure function (frame slicing + titleSamples max 5)"
```

---

## Task 4: `AssignmentResolver` (pure) — preserved + rule resolution

**Files:**
- Create: `Sources/ProjectMemoryCore/AssignmentResolver.swift`
- Create: `Tests/ProjectMemoryCoreTests/AssignmentResolverTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
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
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test --filter AssignmentResolverTests`
Expected: build error — `AssignmentResolver` undefined.

- [ ] **Step 3: Implement AssignmentResolver**

Create `Sources/ProjectMemoryCore/AssignmentResolver.swift`:

```swift
import Foundation

public enum AssignmentResolver {
    public static func resolve(
        draft: ActivitySessionDraft,
        rules: [ProjectActivityRule],
        preserved: PreservedAssignment?,
        relatedFrames: [ActivityFrame]
    ) -> ResolvedActivitySession {
        if let preserved {
            return ResolvedActivitySession(
                draft: draft,
                assignmentStatus: preserved.assignmentStatus,
                projectID: preserved.projectID,
                assignmentSource: "manual"
            )
        }

        let enabled = rules.filter { $0.isEnabled }
        let kindOrder: [ProjectActivityRule.Kind] = [.urlContains, .titleContains, .bundleIDEquals]

        for kind in kindOrder {
            let bucket = enabled
                .filter { $0.kind == kind }
                .sorted { $0.createdAt < $1.createdAt }
            for rule in bucket {
                if matches(rule: rule, draft: draft, relatedFrames: relatedFrames) {
                    return ResolvedActivitySession(
                        draft: draft,
                        assignmentStatus: .ruleAssigned,
                        projectID: rule.projectID,
                        assignmentSource: "rule:\(rule.id.uuidString)"
                    )
                }
            }
        }

        return ResolvedActivitySession(draft: draft, assignmentStatus: .unassigned, projectID: nil, assignmentSource: nil)
    }

    private static func matches(rule: ProjectActivityRule, draft: ActivitySessionDraft, relatedFrames: [ActivityFrame]) -> Bool {
        let pattern = rule.pattern
        switch rule.kind {
        case .urlContains:
            let needle = pattern.lowercased()
            for frame in relatedFrames {
                guard let url = frame.browserURL,
                      let normalized = normalizeURLForMatch(url) else { continue }
                if normalized.contains(needle) { return true }
            }
            return false
        case .titleContains:
            let needle = pattern.lowercased()
            for frame in relatedFrames {
                guard let title = frame.windowTitle else { continue }
                let normalized = TextSanitizer.stripInvisibleControls(title).lowercased()
                if normalized.contains(needle) { return true }
            }
            return false
        case .bundleIDEquals:
            return draft.bundleID == pattern
        }
    }

    /// Lowercase host + drop query/fragment; preserve scheme + path for `contains` matching.
    private static func normalizeURLForMatch(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.host != nil
        else { return nil }
        components.host = components.host?.lowercased()
        components.fragment = nil
        components.queryItems = nil
        return components.string?.lowercased()
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `swift test --filter AssignmentResolverTests`
Expected: 10/10 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectMemoryCore/AssignmentResolver.swift Tests/ProjectMemoryCoreTests/AssignmentResolverTests.swift
git commit -m "feat(phase2): AssignmentResolver pure function (preserved + kind-priority rule matching)"
```

---

## Task 5: MemoryStore — schema migration for activity_sessions / activity_session_frames / project_activity_rules

**Files:**
- Modify: `Sources/ProjectMemoryCore/MemoryStore.swift` (existing `createSchema()` private method)
- Create: `Tests/ProjectMemoryCoreTests/ActivitySessionSchemaTests.swift`

- [ ] **Step 1: Write failing test verifying tables & indexes exist**

```swift
// Tests/ProjectMemoryCoreTests/ActivitySessionSchemaTests.swift
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
```

- [ ] **Step 2: Add the test-only helpers to MemoryStore**

In `Sources/ProjectMemoryCore/MemoryStore.swift`, add these helpers at the bottom of the class (or in a `#if DEBUG` block — keep public for test access):

```swift
public func executeRawForTest(_ sql: String) throws {
    _ = try database.query(sql)
}

public func fetchIndexNamesForTest(table: String) throws -> [String] {
    let rows = try database.query(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
        values: [.text(table)]
    )
    return try rows.map { try $0.text("name") }
}
```

- [ ] **Step 3: Run tests, verify they fail**

Run: `swift test --filter ActivitySessionSchemaTests`
Expected: FAIL — tables/indexes missing.

- [ ] **Step 4: Add DDL to `createSchema()`**

In the existing `private func createSchema()` of `MemoryStore.swift`, append after the existing `idx_activity_frames_*` indexes:

```swift
try database.execute("""
CREATE TABLE IF NOT EXISTS activity_sessions (
    id TEXT PRIMARY KEY,
    started_at TEXT NOT NULL,
    ended_at TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    app_name TEXT NOT NULL,
    browser_host TEXT,
    category TEXT NOT NULL,
    assignment_status TEXT NOT NULL,
    project_id TEXT,
    assignment_source TEXT,
    title_samples_json TEXT NOT NULL,
    frame_count INTEGER NOT NULL
)
""")
try database.execute("""
CREATE INDEX IF NOT EXISTS idx_sessions_ended_at
ON activity_sessions(ended_at DESC)
""")
try database.execute("""
CREATE INDEX IF NOT EXISTS idx_sessions_source_status_ended_at
ON activity_sessions(assignment_source, assignment_status, ended_at DESC)
""")
try database.execute("""
CREATE INDEX IF NOT EXISTS idx_sessions_status_ended_at
ON activity_sessions(assignment_status, ended_at DESC)
""")
try database.execute("""
CREATE INDEX IF NOT EXISTS idx_sessions_project_ended_at
ON activity_sessions(project_id, ended_at DESC)
""")
try database.execute("""
CREATE TABLE IF NOT EXISTS activity_session_frames (
    session_id TEXT NOT NULL,
    frame_id TEXT NOT NULL,
    PRIMARY KEY (session_id, frame_id)
)
""")
// SQLite foreign_keys not enabled in this codebase; cascade is application-enforced via reconciler.replaceWindow.
try database.execute("""
CREATE INDEX IF NOT EXISTS idx_session_frames_frame
ON activity_session_frames(frame_id)
""")
try database.execute("""
CREATE TABLE IF NOT EXISTS project_activity_rules (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    pattern TEXT NOT NULL,
    is_enabled INTEGER NOT NULL,
    created_at TEXT NOT NULL
)
""")
try database.execute("""
CREATE INDEX IF NOT EXISTS idx_rules_project
ON project_activity_rules(project_id)
""")
try database.execute("""
CREATE INDEX IF NOT EXISTS idx_rules_kind_enabled
ON project_activity_rules(kind, is_enabled)
""")
```

- [ ] **Step 5: Run tests, verify they pass**

Run: `swift test --filter ActivitySessionSchemaTests`
Expected: 2/2 PASS.

- [ ] **Step 6: Run full test suite**

Run: `swift test`
Expected: all existing tests pass; existing dogfood DBs upgrade cleanly because `IF NOT EXISTS`.

- [ ] **Step 7: Commit**

```bash
git add Sources/ProjectMemoryCore/MemoryStore.swift Tests/ProjectMemoryCoreTests/ActivitySessionSchemaTests.swift
git commit -m "feat(phase2): schema migration for activity_sessions + session_frames + project_activity_rules"
```

---

## Task 6: MemoryStore — `activity_sessions` write/read APIs

**Files:**
- Create: `Sources/ProjectMemoryCore/MemoryStore+ActivitySession.swift`
- Create: `Tests/ProjectMemoryCoreTests/ActivitySessionStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/ProjectMemoryCoreTests/ActivitySessionStoreTests.swift
import XCTest
@testable import ProjectMemoryCore

final class ActivitySessionStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeResolved(id: UUID = UUID(), endedAtOffset: TimeInterval = 60, status: AssignmentStatus = .unassigned, projectID: UUID? = nil, source: String? = nil, frameIDs: [UUID] = [UUID(), UUID()]) -> ResolvedActivitySession {
        let draft = ActivitySessionDraft(
            id: id, startedAt: now, endedAt: now.addingTimeInterval(endedAtOffset),
            bundleID: "com.x", appName: "X", browserHost: nil,
            category: .work, titleSamples: ["a"], frameCount: frameIDs.count, frameIDs: frameIDs
        )
        return ResolvedActivitySession(draft: draft, assignmentStatus: status, projectID: projectID, assignmentSource: source)
    }

    func testWriteAndFetchActivitySession() throws {
        let store = try MemoryStore.inMemory()
        let resolved = makeResolved(status: .ruleAssigned, projectID: UUID(), source: "rule:\(UUID().uuidString)")
        try store.writeActivitySession(resolved)
        let rows = try store.fetchActivitySessions(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(120))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, resolved.draft.id)
        XCTAssertEqual(rows[0].assignmentStatus, .ruleAssigned)
        XCTAssertEqual(rows[0].titleSamples, ["a"])
    }

    func testFetchActivitySessionIDsWindow() throws {
        let store = try MemoryStore.inMemory()
        try store.writeActivitySession(makeResolved(endedAtOffset: 30))
        try store.writeActivitySession(makeResolved(endedAtOffset: 600))   // outside upper bound
        let ids = try store.fetchActivitySessionIDs(since: now, until: now.addingTimeInterval(120))
        XCTAssertEqual(ids.count, 1)
    }

    func testDeleteActivitySessionsAlsoClearsJoinTable() throws {
        let store = try MemoryStore.inMemory()
        let resolved = makeResolved(frameIDs: [UUID(), UUID(), UUID()])
        try store.writeActivitySession(resolved)
        try store.deleteActivitySessions(ids: [resolved.draft.id])
        let remaining = try store.fetchActivitySessions(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(120))
        XCTAssertEqual(remaining.count, 0)
        // join table cleared
        let joinRows = try store.executeRawCountForTest("SELECT count(*) AS n FROM activity_session_frames")
        XCTAssertEqual(joinRows, 0)
    }

    func testUpdateActivitySessionAssignment() throws {
        let store = try MemoryStore.inMemory()
        let resolved = makeResolved()
        try store.writeActivitySession(resolved)
        let projectID = UUID()
        try store.updateActivitySessionAssignment(
            sessionID: resolved.draft.id,
            assignmentStatus: .manualAssigned,
            projectID: projectID,
            assignmentSource: "manual"
        )
        let updated = try store.fetchActivitySessions(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(120))
        XCTAssertEqual(updated[0].assignmentStatus, .manualAssigned)
        XCTAssertEqual(updated[0].projectID, projectID)
        XCTAssertEqual(updated[0].assignmentSource, "manual")
    }

    func testFetchActivitySessionAssignmentsOnlyManual() throws {
        let store = try MemoryStore.inMemory()
        let manual = makeResolved(status: .manualAssigned, projectID: UUID(), source: "manual")
        let ignored = makeResolved(status: .ignored, projectID: nil, source: "manual")
        let rule = makeResolved(status: .ruleAssigned, projectID: UUID(), source: "rule:\(UUID().uuidString)")
        let unassigned = makeResolved(status: .unassigned, projectID: nil, source: nil)
        try store.writeActivitySession(manual)
        try store.writeActivitySession(ignored)
        try store.writeActivitySession(rule)
        try store.writeActivitySession(unassigned)
        let preserved = try store.fetchActivitySessionAssignments(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(120))
        let ids = Set(preserved.map(\.sessionID))
        XCTAssertTrue(ids.contains(manual.draft.id))
        XCTAssertTrue(ids.contains(ignored.draft.id))
        XCTAssertFalse(ids.contains(rule.draft.id))
        XCTAssertFalse(ids.contains(unassigned.draft.id))
    }
}
```

Add this test helper to `MemoryStore`:

```swift
public func executeRawCountForTest(_ sql: String) throws -> Int {
    let rows = try database.query(sql)
    if let row = rows.first, case .integer(let n) = row["n"] ?? .null {
        return Int(n)
    }
    return 0
}
```

- [ ] **Step 2: Run tests, verify they fail (build error: APIs undefined)**

Run: `swift test --filter ActivitySessionStoreTests`

- [ ] **Step 3: Implement APIs in `MemoryStore+ActivitySession.swift`**

Create the new file. The `ProjectActivityRule` APIs will be added in Task 7; this file holds the `activity_sessions` and `activity_session_frames` APIs only.

```swift
import Foundation

extension MemoryStore {
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    public func writeActivitySession(_ resolved: ResolvedActivitySession) throws {
        let draft = resolved.draft
        let titleSamplesJSON = try String(data: JSONEncoder().encode(draft.titleSamples), encoding: .utf8) ?? "[]"

        try database.execute(
            """
            INSERT OR REPLACE INTO activity_sessions
            (id, started_at, ended_at, bundle_id, app_name, browser_host, category,
             assignment_status, project_id, assignment_source, title_samples_json, frame_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            values: [
                .text(draft.id.uuidString),
                .text(Self.iso8601.string(from: draft.startedAt)),
                .text(Self.iso8601.string(from: draft.endedAt)),
                .text(draft.bundleID),
                .text(draft.appName),
                draft.browserHost.map { .text($0) } ?? .null,
                .text(draft.category.rawValue),
                .text(resolved.assignmentStatus.rawValue),
                resolved.projectID.map { .text($0.uuidString) } ?? .null,
                resolved.assignmentSource.map { .text($0) } ?? .null,
                .text(titleSamplesJSON),
                .integer(Int64(draft.frameCount))
            ]
        )

        // join: replace all frame links for this session
        try database.execute(
            "DELETE FROM activity_session_frames WHERE session_id = ?",
            values: [.text(draft.id.uuidString)]
        )
        for frameID in draft.frameIDs {
            try database.execute(
                "INSERT OR IGNORE INTO activity_session_frames (session_id, frame_id) VALUES (?, ?)",
                values: [.text(draft.id.uuidString), .text(frameID.uuidString)]
            )
        }
    }

    public func fetchActivitySessions(since: Date, until: Date) throws -> [PersistedActivitySession] {
        let rows = try database.query(
            """
            SELECT * FROM activity_sessions
            WHERE ended_at >= ? AND started_at <= ?
            ORDER BY ended_at DESC
            """,
            values: [
                .text(Self.iso8601.string(from: since)),
                .text(Self.iso8601.string(from: until))
            ]
        )
        return try rows.map(persistedSession(from:))
    }

    public func fetchActivitySessionIDs(since: Date, until: Date) throws -> [UUID] {
        let rows = try database.query(
            """
            SELECT id FROM activity_sessions
            WHERE ended_at >= ? AND started_at <= ?
            """,
            values: [
                .text(Self.iso8601.string(from: since)),
                .text(Self.iso8601.string(from: until))
            ]
        )
        return try rows.map { try $0.uuid("id") }
    }

    public func deleteActivitySessions(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            try database.execute(
                "DELETE FROM activity_session_frames WHERE session_id = ?",
                values: [.text(id.uuidString)]
            )
            try database.execute(
                "DELETE FROM activity_sessions WHERE id = ?",
                values: [.text(id.uuidString)]
            )
        }
    }

    public func updateActivitySessionAssignment(
        sessionID: UUID,
        assignmentStatus: AssignmentStatus,
        projectID: UUID?,
        assignmentSource: String?
    ) throws {
        try database.execute(
            """
            UPDATE activity_sessions
            SET assignment_status = ?, project_id = ?, assignment_source = ?
            WHERE id = ?
            """,
            values: [
                .text(assignmentStatus.rawValue),
                projectID.map { .text($0.uuidString) } ?? .null,
                assignmentSource.map { .text($0) } ?? .null,
                .text(sessionID.uuidString)
            ]
        )
    }

    public func fetchActivitySessionAssignments(since: Date, until: Date) throws -> [PreservedAssignment] {
        let rows = try database.query(
            """
            SELECT id, assignment_status, project_id FROM activity_sessions
            WHERE ended_at >= ? AND started_at <= ?
              AND assignment_source = 'manual'
              AND assignment_status IN ('manualAssigned', 'ignored')
            """,
            values: [
                .text(Self.iso8601.string(from: since)),
                .text(Self.iso8601.string(from: until))
            ]
        )
        return try rows.map { row in
            let statusRaw = try row.text("assignment_status")
            guard let status = AssignmentStatus(rawValue: statusRaw) else {
                throw MemoryStoreError.invalidRow("assignment_status")
            }
            return PreservedAssignment(
                sessionID: try row.uuid("id"),
                assignmentStatus: status,
                projectID: try row.optionalUUID("project_id")
            )
        }
    }

    private func persistedSession(from row: [String: SQLiteValue]) throws -> PersistedActivitySession {
        let titleJSON = try row.text("title_samples_json")
        let titles = (try? JSONDecoder().decode([String].self, from: Data(titleJSON.utf8))) ?? []
        guard let category = ActivityCategory(rawValue: try row.text("category")) else {
            throw MemoryStoreError.invalidRow("category")
        }
        guard let status = AssignmentStatus(rawValue: try row.text("assignment_status")) else {
            throw MemoryStoreError.invalidRow("assignment_status")
        }
        return PersistedActivitySession(
            id: try row.uuid("id"),
            startedAt: try row.date("started_at", formatter: Self.iso8601),
            endedAt: try row.date("ended_at", formatter: Self.iso8601),
            bundleID: try row.text("bundle_id"),
            appName: try row.text("app_name"),
            browserHost: try row.optionalText("browser_host"),
            category: category,
            assignmentStatus: status,
            projectID: try row.optionalUUID("project_id"),
            assignmentSource: try row.optionalText("assignment_source"),
            titleSamples: titles,
            frameCount: Int(try row.integer("frame_count"))
        )
    }
}
```

Note: `row.integer(_:)` may not exist in the existing helpers. If it doesn't, use the existing pattern from `MemoryStore.swift` (`SQLiteValue.integer` switch) — replicate from `countActivityFrames` which already does this.

- [ ] **Step 4: Run tests, verify they pass**

Run: `swift test --filter ActivitySessionStoreTests`
Expected: 5/5 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectMemoryCore/MemoryStore+ActivitySession.swift Sources/ProjectMemoryCore/MemoryStore.swift Tests/ProjectMemoryCoreTests/ActivitySessionStoreTests.swift
git commit -m "feat(phase2): MemoryStore activity_sessions read/write APIs"
```

---

## Task 7: MemoryStore — `project_activity_rules` APIs + `findSourceByPath` + `fetchActivitySessionSources`

**Files:**
- Modify: `Sources/ProjectMemoryCore/MemoryStore+ActivitySession.swift`
- Create: `Tests/ProjectMemoryCoreTests/ActivityRuleAndSourceLookupTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ProjectMemoryCore

final class ActivityRuleAndSourceLookupTests: XCTestCase {
    func testRuleUpsertFetchDelete() throws {
        let store = try MemoryStore.inMemory()
        let rule = ProjectActivityRule(projectID: UUID(), kind: .urlContains, pattern: "github.com/myorg", isEnabled: true)
        try store.upsertRule(rule)
        var fetched = try store.fetchRules()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0], rule)

        let updated = ProjectActivityRule(id: rule.id, projectID: rule.projectID, kind: .urlContains, pattern: "github.com/other", isEnabled: false, createdAt: rule.createdAt)
        try store.upsertRule(updated)
        fetched = try store.fetchRules()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].pattern, "github.com/other")
        XCTAssertFalse(fetched[0].isEnabled)

        try store.deleteRule(id: rule.id)
        fetched = try store.fetchRules()
        XCTAssertTrue(fetched.isEmpty)
    }

    func testFindSourceByPath() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)
        let now = Date()
        let src = MemorySource(
            projectID: project.id, kind: .activitySession,
            title: "t", path: "activity-sessions/\(UUID().uuidString)",
            extractedText: "x", modifiedAt: now
        )
        try store.saveSource(src)
        let found = try store.findSourceByPath(src.path)
        XCTAssertEqual(found?.id, src.id)
        XCTAssertNil(try store.findSourceByPath("nonexistent/path"))
    }

    func testFetchActivitySessionSources() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)
        let now = Date()

        let inWindow = MemorySource(projectID: project.id, kind: .activitySession, title: "in", path: "activity-sessions/\(UUID().uuidString)", extractedText: "x", modifiedAt: now)
        let outOfWindow = MemorySource(projectID: project.id, kind: .activitySession, title: "out", path: "activity-sessions/\(UUID().uuidString)", extractedText: "x", modifiedAt: now.addingTimeInterval(-3600 * 24 * 30))
        let nonActivity = MemorySource(projectID: project.id, kind: .markdown, title: "md", path: "/tmp/p/notes.md", extractedText: "x", modifiedAt: now)

        try store.saveSource(inWindow)
        try store.saveSource(outOfWindow)
        try store.saveSource(nonActivity)

        let found = try store.fetchActivitySessionSources(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(60))
        XCTAssertEqual(found.map(\.id), [inWindow.id])
    }
}
```

- [ ] **Step 2: Run tests, verify failure (build error)**

Run: `swift test --filter ActivityRuleAndSourceLookupTests`

- [ ] **Step 3: Add APIs to `MemoryStore+ActivitySession.swift`**

```swift
extension MemoryStore {
    public func upsertRule(_ rule: ProjectActivityRule) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO project_activity_rules
            (id, project_id, kind, pattern, is_enabled, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            values: [
                .text(rule.id.uuidString),
                .text(rule.projectID.uuidString),
                .text(rule.kind.rawValue),
                .text(rule.pattern),
                .integer(rule.isEnabled ? 1 : 0),
                .text(Self.iso8601.string(from: rule.createdAt))
            ]
        )
    }

    public func fetchRules() throws -> [ProjectActivityRule] {
        let rows = try database.query("SELECT * FROM project_activity_rules ORDER BY created_at ASC")
        return try rows.map { row in
            guard let kind = ProjectActivityRule.Kind(rawValue: try row.text("kind")) else {
                throw MemoryStoreError.invalidRow("kind")
            }
            let isEnabled = (try row.integer("is_enabled")) != 0
            return ProjectActivityRule(
                id: try row.uuid("id"),
                projectID: try row.uuid("project_id"),
                kind: kind,
                pattern: try row.text("pattern"),
                isEnabled: isEnabled,
                createdAt: try row.date("created_at", formatter: Self.iso8601)
            )
        }
    }

    public func deleteRule(id: UUID) throws {
        try database.execute(
            "DELETE FROM project_activity_rules WHERE id = ?",
            values: [.text(id.uuidString)]
        )
    }

    public func findSourceByPath(_ path: String) throws -> MemorySource? {
        let rows = try database.query(
            "SELECT * FROM sources WHERE path = ? LIMIT 1",
            values: [.text(path)]
        )
        return try rows.first.map(memorySource(from:))
    }

    public func fetchActivitySessionSources(since: Date, until: Date) throws -> [MemorySource] {
        let rows = try database.query(
            """
            SELECT * FROM sources
            WHERE kind = 'activitySession'
              AND modified_at >= ? AND modified_at <= ?
            """,
            values: [
                .text(Self.iso8601.string(from: since)),
                .text(Self.iso8601.string(from: until))
            ]
        )
        return try rows.map(memorySource(from:))
    }

    private func memorySource(from row: [String: SQLiteValue]) throws -> MemorySource {
        return MemorySource(
            id: try row.uuid("id"),
            projectID: try row.optionalUUID("project_id"),
            kind: SourceKind(rawValue: try row.text("kind")) ?? .unsupported,
            title: try row.text("title"),
            path: try row.text("path"),
            url: try row.optionalText("url"),
            extractedText: try row.text("extracted_text"),
            modifiedAt: try row.date("modified_at", formatter: Self.iso8601),
            indexedAt: try row.date("indexed_at", formatter: Self.iso8601)
        )
    }
}
```

If `row.integer(_:)` doesn't exist as a typed helper, add it to the existing extensions or inline a switch on `SQLiteValue.integer` (look at `countActivityFrames` for the pattern).

- [ ] **Step 4: Run tests, verify they pass**

Run: `swift test --filter ActivityRuleAndSourceLookupTests`
Expected: 3/3 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectMemoryCore/MemoryStore+ActivitySession.swift Tests/ProjectMemoryCoreTests/ActivityRuleAndSourceLookupTests.swift
git commit -m "feat(phase2): MemoryStore project_activity_rules + findSourceByPath + fetchActivitySessionSources"
```

---

## Task 8: `ActivitySessionReconciler.replaceWindow` — pure-ish side-effect layer

**Files:**
- Create: `Sources/ProjectMemoryCore/ActivitySessionReconciler.swift`
- Create: `Tests/ProjectMemoryCoreTests/ActivitySessionReconcilerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ProjectMemoryCore

final class ActivitySessionReconcilerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func draft(id: UUID = UUID(), endedAtOffset: TimeInterval = 60, category: ActivityCategory = .work) -> ActivitySessionDraft {
        ActivitySessionDraft(
            id: id, startedAt: now, endedAt: now.addingTimeInterval(endedAtOffset),
            bundleID: "com.x", appName: "X", browserHost: nil,
            category: category, titleSamples: ["sample"], frameCount: 2, frameIDs: [UUID(), UUID()]
        )
    }

    func testReplaceWindowReadsStaleIDsBeforeDelete() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)
        let oldDraft = draft()
        let oldResolved = ResolvedActivitySession(draft: oldDraft, assignmentStatus: .manualAssigned, projectID: project.id, assignmentSource: "manual")
        try store.writeActivitySession(oldResolved)
        let oldSourcePath = "activity-sessions/\(oldDraft.id.uuidString)"
        try store.saveSource(MemorySource(projectID: project.id, kind: .activitySession, title: "old", path: oldSourcePath, extractedText: "old", modifiedAt: oldDraft.endedAt))

        // replaceWindow with empty resolved → all old sessions should disappear, source too
        try ActivitySessionReconciler.replaceWindow(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(120), with: [], in: store)

        XCTAssertNil(try store.findSourceByPath(oldSourcePath))
        XCTAssertEqual(try store.fetchActivitySessions(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(120)).count, 0)
    }

    func testReplaceWindowOrphanCleanupViaFetchActivitySessionSources() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)
        // Orphan: a source with no matching activity_sessions row
        let orphanPath = "activity-sessions/\(UUID().uuidString)"
        try store.saveSource(MemorySource(projectID: project.id, kind: .activitySession, title: "orphan", path: orphanPath, extractedText: "x", modifiedAt: now))

        try ActivitySessionReconciler.replaceWindow(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(120), with: [], in: store)

        XCTAssertNil(try store.findSourceByPath(orphanPath))
    }

    func testMaterializationGateRequiresAssignedWorkAndProjectID() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)

        // Case 1: unassigned + .work + projectID nil → no materialize
        let d1 = draft()
        let r1 = ResolvedActivitySession(draft: d1, assignmentStatus: .unassigned, projectID: nil, assignmentSource: nil)
        // Case 2: manualAssigned + .socialMedia + projectID set → no materialize (category fail)
        let d2 = draft(category: .socialMedia)
        let r2 = ResolvedActivitySession(draft: d2, assignmentStatus: .manualAssigned, projectID: project.id, assignmentSource: "manual")
        // Case 3: manualAssigned + .work + projectID nil → no materialize (project fail; theoretically impossible but defensive)
        let d3 = draft()
        let r3 = ResolvedActivitySession(draft: d3, assignmentStatus: .manualAssigned, projectID: nil, assignmentSource: "manual")
        // Case 4: manualAssigned + .work + projectID set → materialize ✓
        let d4 = draft()
        let r4 = ResolvedActivitySession(draft: d4, assignmentStatus: .manualAssigned, projectID: project.id, assignmentSource: "manual")

        try ActivitySessionReconciler.replaceWindow(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(120), with: [r1, r2, r3, r4], in: store)

        XCTAssertNil(try store.findSourceByPath("activity-sessions/\(d1.id.uuidString)"))
        XCTAssertNil(try store.findSourceByPath("activity-sessions/\(d2.id.uuidString)"))
        XCTAssertNil(try store.findSourceByPath("activity-sessions/\(d3.id.uuidString)"))
        XCTAssertNotNil(try store.findSourceByPath("activity-sessions/\(d4.id.uuidString)"))
    }

    func testMaterializedSourceContainsHostAndDuration() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)

        let browserDraft = ActivitySessionDraft(
            id: UUID(), startedAt: now, endedAt: now.addingTimeInterval(600),
            bundleID: "com.google.Chrome", appName: "Chrome", browserHost: "github.com",
            category: .work, titleSamples: ["GitHub", "Pull Request"], frameCount: 11, frameIDs: [UUID(), UUID()]
        )
        let resolved = ResolvedActivitySession(draft: browserDraft, assignmentStatus: .manualAssigned, projectID: project.id, assignmentSource: "manual")

        try ActivitySessionReconciler.replaceWindow(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(700), with: [resolved], in: store)

        let materialized = try store.findSourceByPath("activity-sessions/\(browserDraft.id.uuidString)")
        XCTAssertNotNil(materialized)
        XCTAssertTrue(materialized!.extractedText.contains("github.com"))
        XCTAssertFalse(materialized!.extractedText.contains("GitHub"))   // browser session: titleSamples NOT included
        XCTAssertEqual(materialized!.projectID, project.id)
        XCTAssertEqual(materialized!.kind, .activitySession)
    }

    func testNonBrowserWorkSessionContainsTitleSamples() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)

        let nonBrowserDraft = ActivitySessionDraft(
            id: UUID(), startedAt: now, endedAt: now.addingTimeInterval(600),
            bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor", browserHost: nil,
            category: .work, titleSamples: ["project-memory · ActivityCoordinator.swift", "Cursor"], frameCount: 11, frameIDs: [UUID(), UUID()]
        )
        let resolved = ResolvedActivitySession(draft: nonBrowserDraft, assignmentStatus: .manualAssigned, projectID: project.id, assignmentSource: "manual")

        try ActivitySessionReconciler.replaceWindow(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(700), with: [resolved], in: store)

        let materialized = try store.findSourceByPath("activity-sessions/\(nonBrowserDraft.id.uuidString)")
        XCTAssertNotNil(materialized)
        XCTAssertTrue(materialized!.extractedText.contains("ActivityCoordinator.swift"))
    }
}
```

- [ ] **Step 2: Run tests, verify they fail (build error)**

Run: `swift test --filter ActivitySessionReconcilerTests`

- [ ] **Step 3: Implement the reconciler**

Create `Sources/ProjectMemoryCore/ActivitySessionReconciler.swift`:

```swift
import Foundation

public enum ActivitySessionReconciler {
    /// Atomic-ish window replace. Step ORDER IS LOAD-BEARING — see spec §6.3.
    public static func replaceWindow(
        since: Date,
        until: Date,
        with resolved: [ResolvedActivitySession],
        in store: MemoryStore
    ) throws {
        // 1. Read stale IDs BEFORE deleting sessions (so we can resolve their source paths).
        let staleIDs = try store.fetchActivitySessionIDs(since: since, until: until)

        // 2. Delete sessions + join rows for the window.
        try store.deleteActivitySessions(ids: staleIDs)

        // 3a. Path-stable cleanup: lookup by activity-sessions/<id> and delete by id.
        for sid in staleIDs {
            if let src = try store.findSourceByPath("activity-sessions/\(sid.uuidString)") {
                try store.deleteSource(id: src.id)
            }
        }

        // 3b. Orphan sweep: any leftover .activitySession source in this window (e.g. session row
        //      already gone due to earlier bug) → delete by id.
        let orphans = try store.fetchActivitySessionSources(since: since, until: until)
        for orphan in orphans {
            try store.deleteSource(id: orphan.id)
        }

        // 4. Write new sessions + join rows.
        for r in resolved {
            try store.writeActivitySession(r)
        }

        // 5. Materialize eligible: assigned + .work + projectID != nil
        for r in resolved {
            guard shouldMaterialize(r),
                  let projectID = r.projectID,
                  let extractedText = makeExtractedText(r.draft)
            else { continue }
            let path = "activity-sessions/\(r.draft.id.uuidString)"
            let source = MemorySource(
                id: UUID(),
                projectID: projectID,
                kind: .activitySession,
                title: makeTitle(r.draft),
                path: path,
                url: nil,
                extractedText: extractedText,
                modifiedAt: r.draft.endedAt
            )
            try store.saveSource(source)
        }
    }

    private static func shouldMaterialize(_ resolved: ResolvedActivitySession) -> Bool {
        let statusOK = resolved.assignmentStatus == .ruleAssigned || resolved.assignmentStatus == .manualAssigned
        let workOK = resolved.draft.category == .work
        let projectOK = resolved.projectID != nil
        return statusOK && workOK && projectOK
    }

    /// Spec §6.5: privacy gate for prompt-bound text.
    static func makeExtractedText(_ draft: ActivitySessionDraft) -> String? {
        guard draft.category == .work else { return nil }
        var lines: [String] = []
        lines.append("应用：\(draft.appName)")
        lines.append("时长：\(formatDuration(draft.startedAt, draft.endedAt))")
        lines.append("时间：\(formatTimeRange(draft.startedAt, draft.endedAt))")

        if let host = draft.browserHost {
            // browser work session: host only — no titleSamples, no URL path/query
            lines.append("网址：\(host)")
        } else {
            // non-browser work session: titleSamples allowed
            let topTitles = draft.titleSamples.prefix(3).map { String($0.prefix(120)) }
            if !topTitles.isEmpty {
                lines.append("窗口：")
                for t in topTitles { lines.append("  - \(t)") }
            }
        }

        let raw = lines.joined(separator: "\n")
        return TextSanitizer.stripInvisibleControls(raw)
    }

    private static func makeTitle(_ draft: ActivitySessionDraft) -> String {
        if let host = draft.browserHost {
            return "\(draft.appName) · \(host)"
        }
        return draft.appName
    }

    private static func formatDuration(_ start: Date, _ end: Date) -> String {
        let seconds = Int(end.timeIntervalSince(start))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private static let timeRangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func formatTimeRange(_ start: Date, _ end: Date) -> String {
        "\(timeRangeFormatter.string(from: start)) — \(timeRangeFormatter.string(from: end))"
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `swift test --filter ActivitySessionReconcilerTests`
Expected: 5/5 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectMemoryCore/ActivitySessionReconciler.swift Tests/ProjectMemoryCoreTests/ActivitySessionReconcilerTests.swift
git commit -m "feat(phase2): ActivitySessionReconciler.replaceWindow with materialization gate"
```

---

## Task 9: `SelectedSourceSnippet` + `ActivitySessionCaps` + `SelectionTotals` types

**Files:**
- Modify: `Sources/ProjectMemoryCore/Models.swift` (or new `Sources/ProjectMemoryCore/SelectedSourceSnippet.swift` if preferred)
- Create: `Tests/ProjectMemoryCoreTests/SelectedSourceSnippetTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ProjectMemoryCore

final class SelectedSourceSnippetTests: XCTestCase {
    func testActivitySessionCapsDefault() {
        let caps = ActivitySessionCaps.default
        XCTAssertEqual(caps.maxSourcesPerBrief, 4)
        XCTAssertEqual(caps.maxSourcesPerAnswer, 2)
        XCTAssertEqual(caps.maxCharsPerSource, 400)
        XCTAssertEqual(caps.maxTotalBriefActivityChars, 900)
        XCTAssertEqual(caps.maxTotalAnswerActivityChars, 600)
    }

    func testSelectionTotalsDefault() {
        let totals = SelectionTotals.default
        XCTAssertEqual(totals.maxSourcesPerBrief, 12)
        XCTAssertEqual(totals.maxSourcesPerAnswer, 8)
        XCTAssertEqual(totals.maxSourcesPerProject, 3)
    }

    func testSelectedSourceSnippetEquatable() {
        let src = MemorySource(projectID: nil, kind: .text, title: "t", path: "/p", extractedText: "x", modifiedAt: Date())
        let a = SelectedSourceSnippet(source: src, snippet: "y", truncated: false)
        let b = SelectedSourceSnippet(source: src, snippet: "y", truncated: false)
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test --filter SelectedSourceSnippetTests`

- [ ] **Step 3: Add types to Models.swift**

```swift
public struct SelectedSourceSnippet: Equatable {
    public let source: MemorySource
    public let snippet: String
    public let truncated: Bool

    public init(source: MemorySource, snippet: String, truncated: Bool) {
        self.source = source
        self.snippet = snippet
        self.truncated = truncated
    }
}

public struct ActivitySessionCaps: Equatable {
    public let maxSourcesPerBrief: Int
    public let maxSourcesPerAnswer: Int
    public let maxCharsPerSource: Int
    public let maxTotalBriefActivityChars: Int
    public let maxTotalAnswerActivityChars: Int

    public init(maxSourcesPerBrief: Int, maxSourcesPerAnswer: Int, maxCharsPerSource: Int, maxTotalBriefActivityChars: Int, maxTotalAnswerActivityChars: Int) {
        self.maxSourcesPerBrief = maxSourcesPerBrief
        self.maxSourcesPerAnswer = maxSourcesPerAnswer
        self.maxCharsPerSource = maxCharsPerSource
        self.maxTotalBriefActivityChars = maxTotalBriefActivityChars
        self.maxTotalAnswerActivityChars = maxTotalAnswerActivityChars
    }

    public static let `default` = ActivitySessionCaps(
        maxSourcesPerBrief: 4,
        maxSourcesPerAnswer: 2,
        maxCharsPerSource: 400,
        maxTotalBriefActivityChars: 900,
        maxTotalAnswerActivityChars: 600
    )
}

public struct SelectionTotals: Equatable {
    public let maxSourcesPerBrief: Int
    public let maxSourcesPerAnswer: Int
    public let maxSourcesPerProject: Int

    public init(maxSourcesPerBrief: Int, maxSourcesPerAnswer: Int, maxSourcesPerProject: Int) {
        self.maxSourcesPerBrief = maxSourcesPerBrief
        self.maxSourcesPerAnswer = maxSourcesPerAnswer
        self.maxSourcesPerProject = maxSourcesPerProject
    }

    public static let `default` = SelectionTotals(
        maxSourcesPerBrief: 12,
        maxSourcesPerAnswer: 8,
        maxSourcesPerProject: 3
    )
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `swift test --filter SelectedSourceSnippetTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectMemoryCore/Models.swift Tests/ProjectMemoryCoreTests/SelectedSourceSnippetTests.swift
git commit -m "feat(phase2): SelectedSourceSnippet + ActivitySessionCaps + SelectionTotals types"
```

---

## Task 10: Refactor `SourceSnippetSelector` to return `[SelectedSourceSnippet]` (前置手术 part 1)

**Note:** This is a refactor that will temporarily break `BriefGenerator` / `AnswerEngine` callers. Task 11 fixes them. Keep this task scoped to the selector and its tests.

**Files:**
- Modify: `Sources/ProjectMemoryCore/SourceSnippetSelector.swift`
- Modify: `Tests/ProjectMemoryCoreTests/SourceSnippetSelectorTests.swift`

- [ ] **Step 1: Modify the existing tests to expect `[SelectedSourceSnippet]`**

Open `Tests/ProjectMemoryCoreTests/SourceSnippetSelectorTests.swift` (existing). Adapt every test that asserts on `[MemorySource]` returns to assert on `[SelectedSourceSnippet]` returns. Pattern:

```swift
// Before:
let result = SourceSnippetSelector.selectForBrief(...)
XCTAssertEqual(result.map(\.id), [src1.id, src2.id])

// After:
let result = SourceSnippetSelector.selectForBrief(...)
XCTAssertEqual(result.map(\.source.id), [src1.id, src2.id])
XCTAssertTrue(result.allSatisfy { !$0.snippet.isEmpty })
```

For each existing test, also assert that the snippet text appears truncated/sanitized as expected.

- [ ] **Step 2: Run tests, verify failure (signature mismatch)**

Run: `swift test --filter SourceSnippetSelectorTests`

- [ ] **Step 3: Refactor selector signatures**

Rewrite `Sources/ProjectMemoryCore/SourceSnippetSelector.swift`:

```swift
import Foundation

public enum SourceSnippetSelector {
    public static let nonActivityCharCap: Int = 1200
    public static let activityTruncationMarker = "\n[内容已截断，仅发送相关片段]"

    // Convenience overload preserving the legacy 1-arg signature for callers without project context.
    public static func selectForBrief(
        _ sources: [MemorySource],
        limit: Int = SelectionTotals.default.maxSourcesPerBrief,
        caps: ActivitySessionCaps = .default
    ) -> [SelectedSourceSnippet] {
        selectForBrief(projects: [], sources: sources, totals: SelectionTotals(maxSourcesPerBrief: limit, maxSourcesPerAnswer: SelectionTotals.default.maxSourcesPerAnswer, maxSourcesPerProject: SelectionTotals.default.maxSourcesPerProject), caps: caps)
    }

    public static func selectForBrief(
        projects: [Project],
        sources: [MemorySource],
        totals: SelectionTotals = .default,
        caps: ActivitySessionCaps = .default
    ) -> [SelectedSourceSnippet] {
        // Phase 2 caps & per-project logic implemented in Task 12.
        // For Task 10 we preserve current behavior but emit SelectedSourceSnippet:
        //   - existing per-project sort + perProjectLimit applied
        //   - non-activity sources get the legacy 1200-char snippet
        //   - activity sources get caps.maxCharsPerSource truncation
        let limit = totals.maxSourcesPerBrief
        let perProject = totals.maxSourcesPerProject

        var selected: [MemorySource] = []
        var seen = Set<UUID>()
        for project in projects {
            let bucket = sources
                .filter { $0.projectID == project.id }
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(perProject)
            for s in bucket where selected.count < limit {
                selected.append(s)
                seen.insert(s.id)
            }
        }
        let remaining = sources
            .filter { !seen.contains($0.id) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(max(0, limit - selected.count))
        selected.append(contentsOf: remaining)

        return selected.map { makeSnippet(for: $0, caps: caps) }
    }

    public static func selectForQuestion(
        _ sources: [MemorySource],
        question: String,
        selectedProjectID: UUID? = nil,
        totals: SelectionTotals = .default,
        caps: ActivitySessionCaps = .default
    ) -> [SelectedSourceSnippet] {
        // Phase 2 hard rule: activitySession sources are excluded if no project selected;
        // otherwise filtered to selectedProjectID. Implemented fully in Task 12; here we
        // wire the filter so subsequent tasks can rely on the contract.
        let filtered = sources.filter { source in
            guard source.kind == .activitySession else { return true }
            guard let pid = selectedProjectID else { return false }
            return source.projectID == pid
        }
        let terms = Set(
            question
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 2 }
        )
        let scored = filtered.map { (source: $0, score: score(source: $0, terms: terms)) }
        let sortedSources = scored
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.source.modifiedAt > rhs.source.modifiedAt }
                return lhs.score > rhs.score
            }
            .prefix(totals.maxSourcesPerAnswer)
            .map(\.source)
        return sortedSources.map { makeSnippet(for: $0, caps: caps) }
    }

    public static func snippet(_ text: String, maxLength: Int = nonActivityCharCap) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + activityTruncationMarker
    }

    static func makeSnippet(for source: MemorySource, caps: ActivitySessionCaps) -> SelectedSourceSnippet {
        let cap = source.kind == .activitySession ? caps.maxCharsPerSource : nonActivityCharCap
        let trimmed = source.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= cap {
            return SelectedSourceSnippet(source: source, snippet: trimmed, truncated: false)
        }
        let snippet = String(trimmed.prefix(cap)) + activityTruncationMarker
        return SelectedSourceSnippet(source: source, snippet: snippet, truncated: true)
    }

    private static func score(source: MemorySource, terms: Set<String>) -> Int {
        guard !terms.isEmpty else { return 0 }
        let haystack = "\(source.title) \(source.path) \(source.url ?? "") \(source.extractedText)"
            .lowercased()
        return terms.reduce(0) { partial, term in
            haystack.contains(term) ? partial + 1 : partial
        }
    }
}
```

- [ ] **Step 4: Run selector tests**

Run: `swift test --filter SourceSnippetSelectorTests`
Expected: PASS.

- [ ] **Step 5: Run full test suite — observe BriefGenerator / AnswerEngine breakage**

Run: `swift test`
Expected: BriefGenerator / AnswerEngine compile errors (signature mismatch). This is intentional — Task 11 fixes them.

- [ ] **Step 6: Commit (broken-but-isolated state — fix in next task)**

This is a deliberate intermediate commit. Mark the broken state with the message and resolve fully in Task 11.

```bash
git add Sources/ProjectMemoryCore/SourceSnippetSelector.swift Tests/ProjectMemoryCoreTests/SourceSnippetSelectorTests.swift
git commit -m "refactor(phase2): SourceSnippetSelector returns [SelectedSourceSnippet] (BriefGenerator/AnswerEngine broken; fixed in Task 11)"
```

---

## Task 11: Refactor `BriefGenerator` + `AnswerEngine` to consume `[SelectedSourceSnippet]`

**Files:**
- Modify: `Sources/ProjectMemoryCore/BriefGenerator.swift`
- Modify: `Sources/ProjectMemoryCore/AnswerEngine.swift`
- Modify: any caller in `Sources/ProjectMemoryApp/Views/*` (TodayView / AskView / etc.)
- Modify: existing tests `BriefGeneratorIsolationTests.swift`, `PromptTests.swift`, `PrivacyBoundaryTests.swift` if they break

- [ ] **Step 1: Update BriefGenerator**

Replace `Sources/ProjectMemoryCore/BriefGenerator.swift`:

```swift
import Foundation

public struct BriefGenerator {
    public init() {}

    public static func makeDailyBriefPrompt(
        projects: [Project],
        sources: [MemorySource],
        events: [TimelineEvent],
        totals: SelectionTotals = .default,
        caps: ActivitySessionCaps = .default
    ) -> String {
        let snippets = SourceSnippetSelector.selectForBrief(projects: projects, sources: sources, totals: totals, caps: caps)
        return BriefGenerator().buildPrompt(projects: projects, snippets: snippets, events: events)
    }

    /// Test-friendly entry point: callers can pass pre-selected snippets directly.
    public static func buildPrompt(
        projects: [Project],
        snippets: [SelectedSourceSnippet],
        events: [TimelineEvent]
    ) -> String {
        BriefGenerator().buildPrompt(projects: projects, snippets: snippets, events: events)
    }

    public func buildPrompt(
        projects: [Project],
        snippets: [SelectedSourceSnippet],
        events: [TimelineEvent]
    ) -> String {
        """
        请基于下列项目、来源和时间线事件生成中文每日简报。

        输出要求：
        - 只使用列出的证据，不要编造事实；如果证据不足，请明确说明。
        - 必须包含最近变化。
        - 必须指出被遗忘的 TODO 或开放问题。
        - 必须给出 1-3 个下一步行动。
        - 必须逐个覆盖"项目"列表中的每个项目；某个项目证据不足时，单独写"证据不足"。
        - 引用证据时使用来源标题和路径，格式如：来源：《标题》 路径：/path/file.md。

        项目：
        \(formatProjects(projects))

        来源片段（已在本地按项目配额和最近修改筛选并截断，不代表完整文件）：
        \(formatSnippets(snippets))

        时间线事件：
        \(formatEvents(events))
        """
    }

    private func formatProjects(_ projects: [Project]) -> String {
        guard !projects.isEmpty else { return "- 无项目记录" }
        return projects.map { p in "- \(p.name)（路径：\(p.rootPath)）" }.joined(separator: "\n")
    }

    private func formatSnippets(_ snippets: [SelectedSourceSnippet]) -> String {
        guard !snippets.isEmpty else { return "- 无来源证据" }
        return snippets.map { s in
            """
            - 来源：《\(s.source.title)》
              路径：\(s.source.path)
              URL：\(s.source.url ?? "无")
              内容片段：\(s.snippet)
            """
        }.joined(separator: "\n")
    }

    private func formatEvents(_ events: [TimelineEvent]) -> String {
        guard !events.isEmpty else { return "- 无时间线事件" }
        return events.map { e in "- \(e.title)\n  摘要：\(e.summary)" }.joined(separator: "\n")
    }
}
```

- [ ] **Step 2: Update AnswerEngine**

Replace `Sources/ProjectMemoryCore/AnswerEngine.swift`:

```swift
import Foundation

public struct AnswerEngine {
    public init() {}

    public static func makeQuestionPrompt(
        question: String,
        sources: [MemorySource],
        selectedProjectID: UUID? = nil,
        totals: SelectionTotals = .default,
        caps: ActivitySessionCaps = .default
    ) -> String {
        let snippets = SourceSnippetSelector.selectForQuestion(
            sources, question: question, selectedProjectID: selectedProjectID,
            totals: totals, caps: caps
        )
        return AnswerEngine().buildPrompt(question: question, snippets: snippets)
    }

    public static func buildPrompt(question: String, snippets: [SelectedSourceSnippet]) -> String {
        AnswerEngine().buildPrompt(question: question, snippets: snippets)
    }

    public func buildPrompt(question: String, snippets: [SelectedSourceSnippet]) -> String {
        """
        请用中文回答问题，并严格遵守：
        - 只能根据下面列出的来源回答。
        - 如果来源证据不足，请回答"证据不足"，并说明还缺少什么信息。
        - 回答中必须引用来源标题、路径和 URL；没有 URL 时写"URL：无"。
        - 不要编造未在来源中出现的事实。

        问题：
        \(question)

        来源片段（已在本地按问题相关性筛选并截断，不代表完整文件）：
        \(formatSnippets(snippets))
        """
    }

    private func formatSnippets(_ snippets: [SelectedSourceSnippet]) -> String {
        guard !snippets.isEmpty else { return "- 无来源证据" }
        return snippets.map { s in
            """
            - 来源：《\(s.source.title)》
              路径：\(s.source.path)
              URL：\(s.source.url ?? "无")
              内容片段：\(s.snippet)
            """
        }.joined(separator: "\n")
    }
}
```

- [ ] **Step 3: Update App-layer callers**

Search for `selectForBrief\|selectForQuestion\|makeDailyBriefPrompt\|makeQuestionPrompt`:

```bash
grep -rn "selectForBrief\|selectForQuestion\|makeDailyBriefPrompt\|makeQuestionPrompt" \
  "Sources/ProjectMemoryApp" "Sources/ProjectMemoryCore"
```

For each App-layer caller (likely `TodayView.swift`, `AskView.swift`, view models), the signature `makeDailyBriefPrompt(projects:sources:events:)` is preserved; `makeQuestionPrompt(question:sources:)` now takes optional `selectedProjectID:` — no caller break unless `AskView` wants to pass project filter (do this in Task 16; Task 11 just keeps callers compiling).

- [ ] **Step 4: Run full test suite**

Run: `swift test`
Expected: ALL pass — no regressions in existing brief / answer behavior for the legacy code paths.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectMemoryCore/BriefGenerator.swift Sources/ProjectMemoryCore/AnswerEngine.swift Sources/ProjectMemoryApp
git commit -m "refactor(phase2): BriefGenerator + AnswerEngine consume [SelectedSourceSnippet]"
```

---

## Task 12: Activity caps + per-project cap + total cap in `SourceSnippetSelector`

**Files:**
- Modify: `Sources/ProjectMemoryCore/SourceSnippetSelector.swift`
- Create: `Tests/ProjectMemoryCoreTests/SelectorActivityCapsTests.swift`

- [ ] **Step 1: Write failing tests for caps**

```swift
import XCTest
@testable import ProjectMemoryCore

final class SelectorActivityCapsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func activitySource(projectID: UUID, offset: TimeInterval, longText: Bool = false) -> MemorySource {
        let text = longText ? String(repeating: "x", count: 600) : "short"
        return MemorySource(
            projectID: projectID, kind: .activitySession,
            title: "act", path: "activity-sessions/\(UUID().uuidString)",
            extractedText: text, modifiedAt: now.addingTimeInterval(offset)
        )
    }

    func testBriefActivityKindCap4() {
        let p = UUID()
        let project = Project(id: p, name: "p", rootPath: "/tmp/p")
        // 6 activity sources, all assigned to same project
        let sources = (0..<6).map { activitySource(projectID: p, offset: TimeInterval($0)) }
        let snippets = SourceSnippetSelector.selectForBrief(projects: [project], sources: sources)
        let activityCount = snippets.filter { $0.source.kind == .activitySession }.count
        // §4 cap: ≤ 4 activity in brief
        XCTAssertLessThanOrEqual(activityCount, 4)
    }

    func testBriefActivityCharsCap900() {
        let p = UUID()
        let project = Project(id: p, name: "p", rootPath: "/tmp/p")
        // 4 activity sources, each long → each truncates to 400; sum = 1600 → must cut to ≤ 900
        let sources = (0..<4).map { activitySource(projectID: p, offset: TimeInterval($0), longText: true) }
        let snippets = SourceSnippetSelector.selectForBrief(projects: [project], sources: sources)
        let activitySnippets = snippets.filter { $0.source.kind == .activitySession }
        let total = activitySnippets.reduce(0) { $0 + $1.snippet.count }
        XCTAssertLessThanOrEqual(total, 900)
    }

    func testAnswerNoProjectExcludesActivity() {
        let p = UUID()
        let sources = [activitySource(projectID: p, offset: 0)]
        let snippets = SourceSnippetSelector.selectForQuestion(sources, question: "什么", selectedProjectID: nil)
        XCTAssertEqual(snippets.filter { $0.source.kind == .activitySession }.count, 0)
    }

    func testAnswerWithProjectFiltersActivity() {
        let pa = UUID(), pb = UUID()
        let sources = [
            activitySource(projectID: pa, offset: 0),
            activitySource(projectID: pb, offset: 1)
        ]
        let snippets = SourceSnippetSelector.selectForQuestion(sources, question: "什么", selectedProjectID: pa)
        XCTAssertEqual(snippets.filter { $0.source.kind == .activitySession }.count, 1)
        XCTAssertEqual(snippets.first { $0.source.kind == .activitySession }?.source.projectID, pa)
    }

    func testAnswerActivityKindCap2AndChars600() {
        let p = UUID()
        let sources = (0..<5).map { activitySource(projectID: p, offset: TimeInterval($0), longText: true) }
        let snippets = SourceSnippetSelector.selectForQuestion(sources, question: "什么", selectedProjectID: p)
        let activitySnippets = snippets.filter { $0.source.kind == .activitySession }
        XCTAssertLessThanOrEqual(activitySnippets.count, 2)
        XCTAssertLessThanOrEqual(activitySnippets.reduce(0) { $0 + $1.snippet.count }, 600)
    }

    func testPerProjectCap3Brief() {
        let p1 = UUID(), p2 = UUID()
        let proj1 = Project(id: p1, name: "p1", rootPath: "/p1")
        let proj2 = Project(id: p2, name: "p2", rootPath: "/p2")
        // 5 markdown sources for project 1
        let s1 = (0..<5).map { _ in
            MemorySource(projectID: p1, kind: .markdown, title: "m", path: "/p1/\(UUID().uuidString).md", extractedText: "x", modifiedAt: Date())
        }
        let s2 = (0..<2).map { _ in
            MemorySource(projectID: p2, kind: .markdown, title: "m", path: "/p2/\(UUID().uuidString).md", extractedText: "x", modifiedAt: Date())
        }
        let snippets = SourceSnippetSelector.selectForBrief(projects: [proj1, proj2], sources: s1 + s2)
        let p1Count = snippets.filter { $0.source.projectID == p1 }.count
        XCTAssertLessThanOrEqual(p1Count, 3)
    }

    func testTruncationMarkerOnLongActivitySnippet() {
        let p = UUID()
        let project = Project(id: p, name: "p", rootPath: "/tmp/p")
        let long = activitySource(projectID: p, offset: 0, longText: true)
        let snippets = SourceSnippetSelector.selectForBrief(projects: [project], sources: [long])
        let s = snippets.first(where: { $0.source.kind == .activitySession })!
        XCTAssertTrue(s.truncated)
        XCTAssertTrue(s.snippet.contains("[内容已截断"))
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test --filter SelectorActivityCapsTests`

- [ ] **Step 3: Update selector to apply caps in the order specified by spec §7.3 / §7.4**

Replace `selectForBrief(projects:sources:totals:caps:)` and `selectForQuestion(...)` bodies in `SourceSnippetSelector.swift` with the algorithm:

```swift
public static func selectForBrief(
    projects: [Project],
    sources: [MemorySource],
    totals: SelectionTotals = .default,
    caps: ActivitySessionCaps = .default
) -> [SelectedSourceSnippet] {
    // Step 1-2: bucket activity vs other; activity sorted by recency, take ≤ kind cap
    let activity = sources
        .filter { $0.kind == .activitySession }
        .sorted { $0.modifiedAt > $1.modifiedAt }
        .prefix(caps.maxSourcesPerBrief)
    let other = sources.filter { $0.kind != .activitySession }

    // Step 3: per-project bucket for non-activity, recency-weighted within project
    var nonActivitySelected: [MemorySource] = []
    var seen = Set<UUID>()
    for project in projects {
        let bucket = other
            .filter { $0.projectID == project.id }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(totals.maxSourcesPerProject)
        for s in bucket {
            nonActivitySelected.append(s)
            seen.insert(s.id)
        }
    }
    let unprojectedTail = other
        .filter { !seen.contains($0.id) }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    nonActivitySelected.append(contentsOf: unprojectedTail)

    // Step 4: merge + sort by recency
    var merged = Array(activity) + nonActivitySelected
    merged.sort { $0.modifiedAt > $1.modifiedAt }

    // Step 5: per-project cap (3) — note: activitySession has projectID by gate, non-nil grouping safe
    var perProject: [UUID?: Int] = [:]
    var afterPerProject: [MemorySource] = []
    for s in merged {
        let count = perProject[s.projectID, default: 0]
        if count < totals.maxSourcesPerProject {
            afterPerProject.append(s)
            perProject[s.projectID] = count + 1
        }
    }

    // Step 6: total source cap (12)
    let limited = Array(afterPerProject.prefix(totals.maxSourcesPerBrief))

    // Step 7: snippet generation
    var snippets = limited.map { makeSnippet(for: $0, caps: caps) }

    // Step 8: activity total chars cap (900) — drop tail (oldest) activity snippets
    snippets = applyActivityCharCap(snippets, totalChars: caps.maxTotalBriefActivityChars)
    return snippets
}

public static func selectForQuestion(
    _ sources: [MemorySource],
    question: String,
    selectedProjectID: UUID? = nil,
    totals: SelectionTotals = .default,
    caps: ActivitySessionCaps = .default
) -> [SelectedSourceSnippet] {
    // Hard rule: activitySession excluded if no project; filtered to selectedProjectID otherwise.
    let activity: [MemorySource]
    if let pid = selectedProjectID {
        activity = sources.filter { $0.kind == .activitySession && $0.projectID == pid }
    } else {
        activity = []
    }
    let activityKindCapped = activity.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(caps.maxSourcesPerAnswer)

    // Other kinds: keyword-scored existing logic
    let other = sources.filter { $0.kind != .activitySession }
    let terms = Set(
        question.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
    )
    let scored = other.map { (source: $0, score: score(source: $0, terms: terms)) }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.source.modifiedAt > rhs.source.modifiedAt }
            return lhs.score > rhs.score
        }
        .map(\.source)

    // Merge: activity first (recency), then keyword-scored other
    var merged = Array(activityKindCapped) + scored

    // Per-project cap
    var perProject: [UUID?: Int] = [:]
    var afterPerProject: [MemorySource] = []
    for s in merged {
        let count = perProject[s.projectID, default: 0]
        if count < totals.maxSourcesPerProject {
            afterPerProject.append(s)
            perProject[s.projectID] = count + 1
        }
    }

    // Total source cap (8)
    let limited = Array(afterPerProject.prefix(totals.maxSourcesPerAnswer))

    // Snippets
    var snippets = limited.map { makeSnippet(for: $0, caps: caps) }
    // Activity total char cap (600)
    snippets = applyActivityCharCap(snippets, totalChars: caps.maxTotalAnswerActivityChars)
    return snippets
}

private static func applyActivityCharCap(_ snippets: [SelectedSourceSnippet], totalChars: Int) -> [SelectedSourceSnippet] {
    var total = 0
    var keepActivity: [SelectedSourceSnippet] = []
    let nonActivity = snippets.filter { $0.source.kind != .activitySession }
    let activitySorted = snippets.filter { $0.source.kind == .activitySession }
        .sorted { $0.source.modifiedAt > $1.source.modifiedAt }
    for s in activitySorted {
        if total + s.snippet.count <= totalChars {
            keepActivity.append(s)
            total += s.snippet.count
        }
    }
    // Preserve original ordering: rebuild by intersecting with keepActivity
    let kept = Set(keepActivity.map(\.source.id))
    return snippets.filter { snip in
        if snip.source.kind == .activitySession {
            return kept.contains(snip.source.id)
        }
        return true
    }
}
```

- [ ] **Step 4: Run all selector tests**

Run: `swift test --filter SelectorActivityCapsTests SourceSnippetSelectorTests`
Expected: ALL pass. Some legacy `SourceSnippetSelectorTests` may need re-baseline if their fixtures rely on the old per-project allocator details — adapt to the new merge order while keeping the documented outcome.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectMemoryCore/SourceSnippetSelector.swift Tests/ProjectMemoryCoreTests/SelectorActivityCapsTests.swift Tests/ProjectMemoryCoreTests/SourceSnippetSelectorTests.swift
git commit -m "feat(phase2): activity caps + per-project + total caps in SourceSnippetSelector"
```

---

## Task 13: Mechanical privacy guards (source-byte scans, load-bearing)

**Files:**
- Modify: `Tests/ProjectMemoryCoreTests/BriefGeneratorIsolationTests.swift` (or create `PromptPathPrivacyGuardsTests.swift` if cleaner)
- Modify: `Tests/ProjectMemoryCoreTests/CoreSourceLeakGuardTests.swift`

- [ ] **Step 1: Write failing guards (or extend existing)**

Create `Tests/ProjectMemoryCoreTests/PromptPathPrivacyGuardsTests.swift`:

```swift
import XCTest

final class PromptPathPrivacyGuardsTests: XCTestCase {
    /// Resolve repo root via the test bundle / file location.
    private func sourcePath(relative: String) -> String {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // .../Tests/ProjectMemoryCoreTests/
            .deletingLastPathComponent()      // .../Tests/
            .deletingLastPathComponent()      // repo root
        return here.appendingPathComponent(relative).path
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOfFile: sourcePath(relative: relative), encoding: .utf8)
    }

    // Files where prompt strings are assembled — these MUST NOT touch ActivityFrame / activity_frames
    // and MUST NOT read source.extractedText (must go through SelectedSourceSnippet.snippet).
    private let promptPathFiles: [String] = [
        "Sources/ProjectMemoryCore/BriefGenerator.swift",
        "Sources/ProjectMemoryCore/AnswerEngine.swift"
    ]

    func testPromptPathDoesNotReferenceActivityFrame() throws {
        for path in promptPathFiles {
            let src = try read(path)
            XCTAssertFalse(src.contains("ActivityFrame"), "\(path) must not reference ActivityFrame")
            XCTAssertFalse(src.contains("activity_frames"), "\(path) must not reference activity_frames table")
        }
    }

    func testPromptPathDoesNotReadExtractedText() throws {
        for path in promptPathFiles {
            let src = try read(path)
            XCTAssertFalse(src.contains(".extractedText"), "\(path) must read snippet, not source.extractedText")
        }
    }

    // SourceSnippetSelector LEGITIMATELY reads extractedText; it just must not touch frames.
    func testSelectorDoesNotTouchActivityFramesTable() throws {
        let src = try read("Sources/ProjectMemoryCore/SourceSnippetSelector.swift")
        XCTAssertFalse(src.contains("ActivityFrame"))
        XCTAssertFalse(src.contains("activity_frames"))
    }
}
```

- [ ] **Step 2: Run guards, verify they pass against current codebase**

Run: `swift test --filter PromptPathPrivacyGuardsTests`
Expected: PASS — Task 11's refactor already removed `.extractedText` reads from BriefGenerator/AnswerEngine.

- [ ] **Step 3: Sanity check — deliberately introduce a violation, verify it's caught**

Open `BriefGenerator.swift`, change one snippet read to `s.source.extractedText`, run test, verify FAIL. Revert.

- [ ] **Step 4: Commit**

```bash
git add Tests/ProjectMemoryCoreTests/PromptPathPrivacyGuardsTests.swift
git commit -m "test(phase2): mechanical privacy guards (source-byte scans for prompt path)"
```

---

## Task 14: Runtime sentinel privacy tests

**Files:**
- Create: `Tests/ProjectMemoryCoreTests/PromptPathSentinelTests.swift`

- [ ] **Step 1: Write the sentinel tests**

```swift
import XCTest
@testable import ProjectMemoryCore

final class PromptPathSentinelTests: XCTestCase {
    func testBriefBuildPromptOnlyReadsSnippetNotSourceExtractedText() {
        let leak = "LEAK_SENTINEL_\(UUID().uuidString)"
        let safe = "SAFE_SNIPPET_\(UUID().uuidString)"
        let src = MemorySource(
            projectID: nil, kind: .markdown, title: "t", path: "/p",
            extractedText: leak, modifiedAt: Date()
        )
        let snippet = SelectedSourceSnippet(source: src, snippet: safe, truncated: false)
        let prompt = BriefGenerator.buildPrompt(projects: [], snippets: [snippet], events: [])
        XCTAssertTrue(prompt.contains(safe))
        XCTAssertFalse(prompt.contains(leak))
    }

    func testAnswerBuildPromptOnlyReadsSnippetNotSourceExtractedText() {
        let leak = "LEAK_SENTINEL_\(UUID().uuidString)"
        let safe = "SAFE_SNIPPET_\(UUID().uuidString)"
        let src = MemorySource(
            projectID: nil, kind: .markdown, title: "t", path: "/p",
            extractedText: leak, modifiedAt: Date()
        )
        let snippet = SelectedSourceSnippet(source: src, snippet: safe, truncated: false)
        let prompt = AnswerEngine.buildPrompt(question: "Q?", snippets: [snippet])
        XCTAssertTrue(prompt.contains(safe))
        XCTAssertFalse(prompt.contains(leak))
    }

    func testAnswerPromptNeverContainsActivityFromOtherProject() {
        let pa = UUID(), pb = UUID()
        let now = Date()
        let pbHostMarker = "OTHER_PROJECT_HOST_\(UUID().uuidString)"
        let activityA = MemorySource(projectID: pa, kind: .activitySession, title: "A", path: "activity-sessions/\(UUID().uuidString)", extractedText: "应用：X\n网址：projecta.example.com", modifiedAt: now)
        let activityB = MemorySource(projectID: pb, kind: .activitySession, title: "B", path: "activity-sessions/\(UUID().uuidString)", extractedText: "应用：X\n网址：\(pbHostMarker)", modifiedAt: now)
        let prompt = AnswerEngine.makeQuestionPrompt(question: "进度", sources: [activityA, activityB], selectedProjectID: pa)
        XCTAssertFalse(prompt.contains(pbHostMarker))
    }

    func testAnswerPromptNoActivityWhenNoProjectSelected() {
        let p = UUID()
        let marker = "NO_PROJECT_MARKER_\(UUID().uuidString)"
        let activity = MemorySource(projectID: p, kind: .activitySession, title: "A", path: "activity-sessions/\(UUID().uuidString)", extractedText: marker, modifiedAt: Date())
        let prompt = AnswerEngine.makeQuestionPrompt(question: "问题", sources: [activity], selectedProjectID: nil)
        XCTAssertFalse(prompt.contains(marker))
    }
}
```

- [ ] **Step 2: Run tests, verify they pass**

Run: `swift test --filter PromptPathSentinelTests`
Expected: 4/4 PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/ProjectMemoryCoreTests/PromptPathSentinelTests.swift
git commit -m "test(phase2): runtime sentinel tests proving prompt path doesn't bypass snippet"
```

---

## Task 15: `SessionPipeline` (App layer, @MainActor) — orchestrator

**Files:**
- Create: `Sources/ProjectMemoryApp/Activity/SessionPipeline.swift`
- Create: `Tests/ProjectMemoryAppTests/SessionPipelineTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ProjectMemoryApp
@testable import ProjectMemoryCore

@MainActor
final class SessionPipelineTests: XCTestCase {
    func testPipelinePreservesManualOverRule() async throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/p")
        try store.saveProject(project)

        // 2 frames, same bundleID, within gap → 1 session candidate
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let f1 = ActivityFrame(observedAt: now, bundleID: "com.x", appName: "X", windowTitle: "t", browserURL: nil, category: .work)
        let f2 = ActivityFrame(observedAt: now.addingTimeInterval(60), bundleID: "com.x", appName: "X", windowTitle: "t", browserURL: nil, category: .work)
        try store.saveActivityFrame(f1)
        try store.saveActivityFrame(f2)

        // Pre-write a session for f1.id with manual assignment
        let preDraft = ActivitySessionDraft(id: f1.id, startedAt: now, endedAt: now.addingTimeInterval(60),
            bundleID: "com.x", appName: "X", browserHost: nil, category: .work,
            titleSamples: ["t"], frameCount: 2, frameIDs: [f1.id, f2.id])
        let manual = ResolvedActivitySession(draft: preDraft, assignmentStatus: .manualAssigned, projectID: project.id, assignmentSource: "manual")
        try store.writeActivitySession(manual)

        // Add a rule that would also match
        let rule = ProjectActivityRule(projectID: UUID(), kind: .bundleIDEquals, pattern: "com.x", isEnabled: true)
        try store.upsertRule(rule)

        let pipeline = SessionPipeline(store: store)
        try pipeline.run(window: DateInterval(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(120)))

        let sessions = try store.fetchActivitySessions(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(120))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].assignmentStatus, .manualAssigned)
        XCTAssertEqual(sessions[0].projectID, project.id)
        XCTAssertEqual(sessions[0].assignmentSource, "manual")
    }

    func testPipelineUndoIgnoreReevaluatesRules() async throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/p")
        try store.saveProject(project)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let f1 = ActivityFrame(observedAt: now, bundleID: "com.x", appName: "X", windowTitle: "t", browserURL: nil, category: .work)
        let f2 = ActivityFrame(observedAt: now.addingTimeInterval(60), bundleID: "com.x", appName: "X", windowTitle: "t", browserURL: nil, category: .work)
        try store.saveActivityFrame(f1)
        try store.saveActivityFrame(f2)

        let rule = ProjectActivityRule(projectID: project.id, kind: .bundleIDEquals, pattern: "com.x", isEnabled: true)
        try store.upsertRule(rule)

        let pipeline = SessionPipeline(store: store)
        let window = DateInterval(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(120))
        try pipeline.run(window: window)

        // After run, session should be ruleAssigned to project
        var sessions = try store.fetchActivitySessions(since: window.start, until: window.end)
        XCTAssertEqual(sessions[0].assignmentStatus, .ruleAssigned)

        // User undoIgnore-equivalent path: write status=.unassigned, source=nil
        try store.updateActivitySessionAssignment(sessionID: sessions[0].id, assignmentStatus: .unassigned, projectID: nil, assignmentSource: nil)
        try pipeline.run(window: window)

        sessions = try store.fetchActivitySessions(since: window.start, until: window.end)
        XCTAssertEqual(sessions[0].assignmentStatus, .ruleAssigned)
        XCTAssertEqual(sessions[0].projectID, project.id)
    }
}
```

- [ ] **Step 2: Run, verify failure (build error)**

Run: `swift test --filter SessionPipelineTests`

- [ ] **Step 3: Implement SessionPipeline**

Create `Sources/ProjectMemoryApp/Activity/SessionPipeline.swift`:

```swift
import Foundation
import ProjectMemoryCore

@MainActor
internal final class SessionPipeline {
    private let store: MemoryStore

    init(store: MemoryStore) {
        self.store = store
    }

    func run(window: DateInterval) throws {
        let preserved = try store.fetchActivitySessionAssignments(since: window.start, until: window.end)
        let preservedByID = Dictionary(uniqueKeysWithValues: preserved.map { ($0.sessionID, $0) })

        let frames = try store.fetchActivityFrames(since: window.start, until: window.end)
        let framesByID = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0) })

        let drafts = SessionAggregator.aggregate(frames)
        let rules = try store.fetchRules()

        let resolved = drafts.map { draft -> ResolvedActivitySession in
            let related = draft.frameIDs.compactMap { framesByID[$0] }
            return AssignmentResolver.resolve(
                draft: draft,
                rules: rules,
                preserved: preservedByID[draft.id],
                relatedFrames: related
            )
        }

        try ActivitySessionReconciler.replaceWindow(
            since: window.start, until: window.end,
            with: resolved, in: store
        )
    }
}
```

Note: `internal` access — App-internal only. Tests use `@testable import ProjectMemoryApp`.

- [ ] **Step 4: Run, verify pass**

Run: `swift test --filter SessionPipelineTests`
Expected: 2/2 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectMemoryApp/Activity/SessionPipeline.swift Tests/ProjectMemoryAppTests/SessionPipelineTests.swift
git commit -m "feat(phase2): SessionPipeline orchestrator (App, @MainActor)"
```

---

## Task 16: `TriageListViewModel` — observable state for待归属 tab

**Files:**
- Create: `Sources/ProjectMemoryApp/Activity/TriageListViewModel.swift`
- Create: `Tests/ProjectMemoryAppTests/TriageListViewModelTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ProjectMemoryApp
@testable import ProjectMemoryCore

@MainActor
final class TriageListViewModelTests: XCTestCase {
    private func writeSession(_ store: MemoryStore, status: AssignmentStatus, category: ActivityCategory, endedOffset: TimeInterval, projectID: UUID? = nil, source: String? = nil, frameIDs: [UUID] = [UUID(), UUID()]) throws -> UUID {
        let now = Date()
        let draft = ActivitySessionDraft(
            id: UUID(), startedAt: now.addingTimeInterval(endedOffset - 60), endedAt: now.addingTimeInterval(endedOffset),
            bundleID: "com.x", appName: "X", browserHost: nil,
            category: category, titleSamples: ["t"], frameCount: 2, frameIDs: frameIDs
        )
        let r = ResolvedActivitySession(draft: draft, assignmentStatus: status, projectID: projectID, assignmentSource: source)
        try store.writeActivitySession(r)
        return draft.id
    }

    func testDefaultFilterIsUnassignedAndWork() throws {
        let store = try MemoryStore.inMemory()
        let unassignedWorkID = try writeSession(store, status: .unassigned, category: .work, endedOffset: -60)
        _ = try writeSession(store, status: .unassigned, category: .socialMedia, endedOffset: -60)
        _ = try writeSession(store, status: .ruleAssigned, category: .work, endedOffset: -60, projectID: UUID(), source: "rule:\(UUID().uuidString)")

        let vm = TriageListViewModel(store: store)
        vm.refresh()

        XCTAssertEqual(vm.unassignedSessions.count, 1)
        XCTAssertEqual(vm.unassignedSessions[0].id, unassignedWorkID)
    }

    func testBadgeCountMatchesUnassignedWorkCount() throws {
        let store = try MemoryStore.inMemory()
        _ = try writeSession(store, status: .unassigned, category: .work, endedOffset: -60)
        _ = try writeSession(store, status: .unassigned, category: .work, endedOffset: -120)
        _ = try writeSession(store, status: .ignored, category: .work, endedOffset: -60, source: "manual")

        let vm = TriageListViewModel(store: store)
        vm.refresh()

        XCTAssertEqual(vm.badgeCount, 2)
    }

    func testIgnoredFolderShowsIgnoredSessions() throws {
        let store = try MemoryStore.inMemory()
        let ignoredID = try writeSession(store, status: .ignored, category: .work, endedOffset: -60, source: "manual")

        let vm = TriageListViewModel(store: store)
        vm.refresh()

        XCTAssertEqual(vm.ignoredSessions.count, 1)
        XCTAssertEqual(vm.ignoredSessions[0].id, ignoredID)
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement TriageListViewModel**

```swift
// Sources/ProjectMemoryApp/Activity/TriageListViewModel.swift
import Foundation
import ProjectMemoryCore

@MainActor
internal final class TriageListViewModel: ObservableObject {
    @Published private(set) var unassignedSessions: [PersistedActivitySession] = []
    @Published private(set) var ignoredSessions: [PersistedActivitySession] = []

    private let store: MemoryStore
    private let lookback: TimeInterval = 7 * 24 * 3600

    init(store: MemoryStore) {
        self.store = store
    }

    var badgeCount: Int { unassignedSessions.count }

    func refresh() {
        let until = Date()
        let since = until.addingTimeInterval(-lookback)
        do {
            let all = try store.fetchActivitySessions(since: since, until: until)
            unassignedSessions = all.filter { $0.assignmentStatus == .unassigned && $0.category == .work }
            ignoredSessions = all.filter { $0.assignmentStatus == .ignored }
        } catch {
            unassignedSessions = []
            ignoredSessions = []
        }
    }
}
```

- [ ] **Step 4: Run, verify pass**

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectMemoryApp/Activity/TriageListViewModel.swift Tests/ProjectMemoryAppTests/TriageListViewModelTests.swift
git commit -m "feat(phase2): TriageListViewModel"
```

---

## Task 17: Triage actions (assign / ignore / undoIgnore) wired to pipeline.run

**Files:**
- Modify: `Sources/ProjectMemoryApp/Activity/TriageListViewModel.swift`
- Modify: `Tests/ProjectMemoryAppTests/TriageListViewModelTests.swift`

- [ ] **Step 1: Write failing tests for actions**

```swift
func testAssignActionSetsManualStatusAndRunsPipeline() async throws {
    let store = try MemoryStore.inMemory()
    let project = Project(name: "p", rootPath: "/p")
    try store.saveProject(project)
    let id = try writeSession(store, status: .unassigned, category: .work, endedOffset: -60)

    let pipeline = SessionPipeline(store: store)
    let vm = TriageListViewModel(store: store, pipeline: pipeline)
    vm.refresh()
    try await vm.assign(sessionID: id, projectID: project.id)

    let session = try store.fetchActivitySessions(since: Date(timeIntervalSince1970: 0), until: Date(timeIntervalSinceNow: 3600))
        .first { $0.id == id }
    XCTAssertEqual(session?.assignmentStatus, .manualAssigned)
    XCTAssertEqual(session?.projectID, project.id)
    XCTAssertEqual(session?.assignmentSource, "manual")
}

func testIgnoreActionAndUndoIgnore() async throws {
    let store = try MemoryStore.inMemory()
    let id = try writeSession(store, status: .unassigned, category: .work, endedOffset: -60)
    let vm = TriageListViewModel(store: store, pipeline: SessionPipeline(store: store))
    vm.refresh()

    try await vm.ignore(sessionID: id)
    var session = try store.fetchActivitySessions(since: Date(timeIntervalSince1970: 0), until: Date(timeIntervalSinceNow: 3600)).first { $0.id == id }
    XCTAssertEqual(session?.assignmentStatus, .ignored)
    XCTAssertEqual(session?.assignmentSource, "manual")

    try await vm.undoIgnore(sessionID: id)
    session = try store.fetchActivitySessions(since: Date(timeIntervalSince1970: 0), until: Date(timeIntervalSinceNow: 3600)).first { $0.id == id }
    XCTAssertEqual(session?.assignmentStatus, .unassigned)
    XCTAssertNil(session?.assignmentSource)
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Extend TriageListViewModel**

```swift
@MainActor
internal final class TriageListViewModel: ObservableObject {
    // ... existing fields ...
    private let pipeline: SessionPipeline

    init(store: MemoryStore, pipeline: SessionPipeline? = nil) {
        self.store = store
        self.pipeline = pipeline ?? SessionPipeline(store: store)
    }

    func assign(sessionID: UUID, projectID: UUID) async throws {
        try await applyAndRerun(sessionID: sessionID, status: .manualAssigned, projectID: projectID, source: "manual")
    }

    func ignore(sessionID: UUID) async throws {
        try await applyAndRerun(sessionID: sessionID, status: .ignored, projectID: nil, source: "manual")
    }

    func undoIgnore(sessionID: UUID) async throws {
        try await applyAndRerun(sessionID: sessionID, status: .unassigned, projectID: nil, source: nil)
    }

    private func applyAndRerun(sessionID: UUID, status: AssignmentStatus, projectID: UUID?, source: String?) async throws {
        // Look up session window before mutation (for pipeline.run scope)
        let all = try store.fetchActivitySessions(since: Date(timeIntervalSince1970: 0), until: Date(timeIntervalSinceNow: 3600))
        guard let session = all.first(where: { $0.id == sessionID }) else { return }

        try store.updateActivitySessionAssignment(
            sessionID: sessionID,
            assignmentStatus: status,
            projectID: projectID,
            assignmentSource: source
        )
        // Window is exactly the session's bounds; preserved fetch will pick up the just-written manual row.
        try pipeline.run(window: DateInterval(start: session.startedAt, end: session.endedAt))
        refresh()
    }
}
```

- [ ] **Step 4: Run, verify pass**

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectMemoryApp/Activity/TriageListViewModel.swift Tests/ProjectMemoryAppTests/TriageListViewModelTests.swift
git commit -m "feat(phase2): TriageListViewModel actions (assign/ignore/undoIgnore) wired to pipeline.run"
```

---

## Task 18: TriageView SwiftUI scaffolding

**Files:**
- Create: `Sources/ProjectMemoryApp/Views/TriageView.swift`
- Create: `Sources/ProjectMemoryApp/Views/TriageRowView.swift`

This task is UI-only. No automated tests beyond the existing ViewModel tests. Manual smoke verification at end of plan.

- [ ] **Step 1: TriageView**

```swift
// Sources/ProjectMemoryApp/Views/TriageView.swift
import SwiftUI
import ProjectMemoryCore

struct TriageView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel: TriageListViewModel

    init(store: MemoryStore) {
        _viewModel = StateObject(wrappedValue: TriageListViewModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading) {
            if viewModel.unassignedSessions.isEmpty {
                Spacer()
                HStack { Spacer(); Text("暂无待归属的工作时段。").foregroundStyle(.secondary); Spacer() }
                Spacer()
            } else {
                List(viewModel.unassignedSessions, id: \.id) { session in
                    TriageRowView(session: session, projects: appState.projects) { action in
                        Task { await handle(action: action, sessionID: session.id) }
                    }
                }
            }

            if !viewModel.ignoredSessions.isEmpty {
                DisclosureGroup("已忽略（\(viewModel.ignoredSessions.count)）") {
                    List(viewModel.ignoredSessions, id: \.id) { session in
                        HStack {
                            Text("\(session.appName) · \(formatRange(session.startedAt, session.endedAt))")
                            Spacer()
                            Button("撤销忽略") {
                                Task { try? await viewModel.undoIgnore(sessionID: session.id) }
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 240)
                }
                .padding(.horizontal)
            }
        }
        .onAppear { viewModel.refresh() }
    }

    private enum Action {
        case assign(UUID)
        case ignore
    }

    private func handle(action: Action, sessionID: UUID) async {
        do {
            switch action {
            case .assign(let projectID): try await viewModel.assign(sessionID: sessionID, projectID: projectID)
            case .ignore: try await viewModel.ignore(sessionID: sessionID)
            }
        } catch {
            // best-effort; future task: surface an error banner
        }
    }

    private func formatRange(_ start: Date, _ end: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "\(f.string(from: start))–\(f.string(from: end))"
    }
}
```

- [ ] **Step 2: TriageRowView**

```swift
// Sources/ProjectMemoryApp/Views/TriageRowView.swift
import SwiftUI
import ProjectMemoryCore

struct TriageRowView: View {
    let session: PersistedActivitySession
    let projects: [Project]
    let onAction: (Action) -> Void

    enum Action { case assign(UUID); case ignore }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(timeRange).font(.headline)
                Text("· \(formatDuration) · \(session.frameCount) 帧").foregroundStyle(.secondary)
            }
            HStack {
                Text(session.appName).font(.subheadline.bold())
                Text(session.bundleID).font(.caption).foregroundStyle(.secondary)
            }
            if let host = session.browserHost {
                Text("浏览器：\(host)").font(.caption)
            }
            if !session.titleSamples.isEmpty {
                Text("标题样本：").font(.caption).foregroundStyle(.secondary)
                ForEach(session.titleSamples.prefix(3), id: \.self) { t in
                    Text("• \(String(t.prefix(80)))").font(.caption2)
                }
            }
            HStack {
                Menu("归属到项目") {
                    ForEach(projects) { p in
                        Button(p.name) { onAction(.assign(p.id)) }
                    }
                }
                Button("忽略") { onAction(.ignore) }
            }.buttonStyle(.bordered)
        }
        .padding(8)
    }

    private var timeRange: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: session.startedAt))–\(f.string(from: session.endedAt))"
    }

    private var formatDuration: String {
        let s = Int(session.endedAt.timeIntervalSince(session.startedAt))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
```

- [ ] **Step 3: Run build to confirm SwiftUI compiles**

Run: `swift build`
Expected: clean (no SwiftUI compile errors).

- [ ] **Step 4: Commit**

```bash
git add Sources/ProjectMemoryApp/Views/TriageView.swift Sources/ProjectMemoryApp/Views/TriageRowView.swift
git commit -m "feat(phase2): TriageView + TriageRowView UI scaffolding"
```

---

## Task 19: Add Triage tab to RootView with badge count

**Files:**
- Modify: `Sources/ProjectMemoryApp/Views/RootView.swift`
- Modify: `Sources/ProjectMemoryApp/AppState.swift` (add reference to MemoryStore exposure if needed)

- [ ] **Step 1: Read AppState to find how the existing store is exposed**

Run:
```bash
grep -n "MemoryStore\|memoryStore\|store" Sources/ProjectMemoryApp/AppState.swift | head -20
```

Use that pattern (e.g., `appState.memoryStore`) when constructing the TriageView.

- [ ] **Step 2: Modify RootView**

Replace the existing `TabView` body:

```swift
TabView {
    TodayView()
        .tabItem { Label("Today", systemImage: "sun.max") }

    ProjectsView()
        .tabItem { Label("Projects", systemImage: "folder") }

    SourcesView()
        .tabItem { Label("Sources", systemImage: "doc.text") }

    TriageView(store: appState.memoryStore)   // <-- adapt name to actual property
        .tabItem {
            Label("Triage", systemImage: "questionmark.square")
        }
        .badge(appState.triageBadgeCount)     // <-- AppState must expose count

    AskView()
        .tabItem { Label("Ask", systemImage: "questionmark.bubble") }

    SettingsView()
        .tabItem { Label("Settings", systemImage: "gearshape") }
}
```

In `AppState`, add:

```swift
@Published var triageBadgeCount: Int = 0

func refreshTriageBadge() {
    let until = Date()
    let since = until.addingTimeInterval(-7 * 24 * 3600)
    do {
        let sessions = try memoryStore.fetchActivitySessions(since: since, until: until)
        triageBadgeCount = sessions.filter { $0.assignmentStatus == .unassigned && $0.category == .work }.count
    } catch {
        triageBadgeCount = 0
    }
}
```

Call `refreshTriageBadge()` in the existing `reload()` method.

- [ ] **Step 3: Run build**

Run: `swift build`
Expected: clean.

- [ ] **Step 4: Run full test suite**

Run: `swift test`
Expected: ALL pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectMemoryApp/Views/RootView.swift Sources/ProjectMemoryApp/AppState.swift
git commit -m "feat(phase2): wire Triage tab into RootView with badge count"
```

---

## Task 20: Pipeline triggers — wire `pipeline.run` into Brief / Q&A / Triage entry points (on-demand)

**Files:**
- Modify: `Sources/ProjectMemoryApp/Views/TodayView.swift` (or its view model — Brief generation entry point)
- Modify: `Sources/ProjectMemoryApp/Views/AskView.swift` (or its view model — Answer entry point)
- Modify: `Sources/ProjectMemoryApp/Views/TriageView.swift` (already calls `viewModel.refresh()` on appear; add pipeline.run before refresh)

The spec §1 / Q4 chose **on-demand** scheduling. Pipeline runs at three entry points:

1. **Brief generation:** before assembling the brief, call `pipeline.run(window: lastNHoursBriefWindow)` so freshly-arrived frames become sessions before selector picks them up.
2. **Answer query:** before assembling the answer prompt, call `pipeline.run(window: lastNHoursAnswerWindow)`.
3. **Triage tab opens:** `TriageView.onAppear` calls `pipeline.run(window: last7Days)` then `viewModel.refresh()`.

- [ ] **Step 1: Define windows in a shared constants file**

Add to `Sources/ProjectMemoryApp/Activity/SessionPipeline.swift`:

```swift
extension SessionPipeline {
    static func briefWindow(now: Date = Date()) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-24 * 3600), end: now)
    }
    static func answerWindow(now: Date = Date()) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-7 * 24 * 3600), end: now)
    }
    static func triageWindow(now: Date = Date()) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-7 * 24 * 3600), end: now)
    }
}
```

- [ ] **Step 2: Wire into TodayView's brief flow**

Find the brief-generation function in `TodayView.swift` (or its view model). Before calling `BriefGenerator.makeDailyBriefPrompt(...)`, run:

```swift
try? SessionPipeline(store: appState.memoryStore).run(window: SessionPipeline.briefWindow())
```

- [ ] **Step 3: Wire into AskView**

Same pattern: before generating the answer prompt:

```swift
try? SessionPipeline(store: appState.memoryStore).run(window: SessionPipeline.answerWindow())
```

Also pass `selectedProjectID` to `AnswerEngine.makeQuestionPrompt`. If AskView already has a project filter (check existing UI), pass it; otherwise leave `nil` for now and add a project selector dropdown (out of scope for this plan; record in the Phase 2.5 backlog).

- [ ] **Step 4: Wire into TriageView**

In `TriageView.body.onAppear`:

```swift
.onAppear {
    try? SessionPipeline(store: appState.memoryStore).run(window: SessionPipeline.triageWindow())
    viewModel.refresh()
}
```

- [ ] **Step 5: Run full test suite**

Run: `swift test`
Expected: ALL pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ProjectMemoryApp
git commit -m "feat(phase2): on-demand pipeline.run at Brief/Answer/Triage entry points"
```

---

## Task 21: Triage durability matrix tests

**Files:**
- Create: `Tests/ProjectMemoryAppTests/TriageDurabilityTests.swift`

These translate spec §8.5 manual-persistence matrix into runtime tests (excluding the `gap threshold` row, which spec §10 lists as known limitation only).

- [ ] **Step 1: Write 7 durability tests**

```swift
import XCTest
@testable import ProjectMemoryApp
@testable import ProjectMemoryCore

@MainActor
final class TriageDurabilityTests: XCTestCase {
    private func setupSession(_ store: MemoryStore, frames: [ActivityFrame]) throws -> ActivitySessionDraft {
        for f in frames { try store.saveActivityFrame(f) }
        return ActivitySessionDraft(
            id: frames[0].id, startedAt: frames.first!.observedAt, endedAt: frames.last!.observedAt,
            bundleID: frames[0].bundleID, appName: frames[0].appName, browserHost: nil,
            category: .work, titleSamples: [frames[0].windowTitle ?? ""].filter { !$0.isEmpty }, frameCount: frames.count, frameIDs: frames.map(\.id)
        )
    }

    private func makeFrames(count: Int, bundleID: String = "com.x", host: String? = nil) -> [ActivityFrame] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map { i in
            ActivityFrame(
                observedAt: base.addingTimeInterval(TimeInterval(i * 60)),
                bundleID: bundleID, appName: bundleID, windowTitle: "t",
                browserURL: host.map { "https://\($0)/" }, category: .work
            )
        }
    }

    func testManualAssignSurvivesRestart() async throws {
        let path = NSTemporaryDirectory() + "phase2-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let frames = makeFrames(count: 3)
        let project = Project(name: "p", rootPath: "/p")

        do {
            let store1 = try MemoryStore(path: path)
            try store1.saveProject(project)
            for f in frames { try store1.saveActivityFrame(f) }
            try SessionPipeline(store: store1).run(window: DateInterval(start: frames.first!.observedAt.addingTimeInterval(-60), end: frames.last!.observedAt.addingTimeInterval(60)))
            let sessions = try store1.fetchActivitySessions(since: frames.first!.observedAt.addingTimeInterval(-60), until: frames.last!.observedAt.addingTimeInterval(60))
            XCTAssertEqual(sessions.count, 1)
            try store1.updateActivitySessionAssignment(sessionID: sessions[0].id, assignmentStatus: .manualAssigned, projectID: project.id, assignmentSource: "manual")
        }

        let store2 = try MemoryStore(path: path)
        let sessions = try store2.fetchActivitySessions(since: frames.first!.observedAt.addingTimeInterval(-60), until: frames.last!.observedAt.addingTimeInterval(60))
        XCTAssertEqual(sessions[0].assignmentStatus, .manualAssigned)
        XCTAssertEqual(sessions[0].projectID, project.id)
    }

    func testManualAssignSurvivesRuleChange() async throws {
        let store = try MemoryStore.inMemory()
        let pManual = Project(name: "manual", rootPath: "/m"); try store.saveProject(pManual)
        let pRule = Project(name: "rule", rootPath: "/r"); try store.saveProject(pRule)
        let frames = makeFrames(count: 3)
        for f in frames { try store.saveActivityFrame(f) }

        let pipeline = SessionPipeline(store: store)
        let window = DateInterval(start: frames.first!.observedAt.addingTimeInterval(-60), end: frames.last!.observedAt.addingTimeInterval(60))
        try pipeline.run(window: window)
        let sessions = try store.fetchActivitySessions(since: window.start, until: window.end)
        try store.updateActivitySessionAssignment(sessionID: sessions[0].id, assignmentStatus: .manualAssigned, projectID: pManual.id, assignmentSource: "manual")

        // Now add a rule that would otherwise grab this session for pRule
        try store.upsertRule(ProjectActivityRule(projectID: pRule.id, kind: .bundleIDEquals, pattern: "com.x", isEnabled: true))
        try pipeline.run(window: window)

        let after = try store.fetchActivitySessions(since: window.start, until: window.end)
        XCTAssertEqual(after[0].projectID, pManual.id)
        XCTAssertEqual(after[0].assignmentSource, "manual")
    }

    func testManualAssignSurvivesEndedAtExtension() async throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/p"); try store.saveProject(project)
        let initialFrames = makeFrames(count: 3)
        for f in initialFrames { try store.saveActivityFrame(f) }

        let pipeline = SessionPipeline(store: store)
        let window1 = DateInterval(start: initialFrames.first!.observedAt.addingTimeInterval(-60), end: initialFrames.last!.observedAt.addingTimeInterval(60))
        try pipeline.run(window: window1)
        let session = try store.fetchActivitySessions(since: window1.start, until: window1.end)[0]
        try store.updateActivitySessionAssignment(sessionID: session.id, assignmentStatus: .manualAssigned, projectID: project.id, assignmentSource: "manual")

        // Append more frames within gap → endedAt extends
        let extra = (0..<2).map { i in
            ActivityFrame(observedAt: initialFrames.last!.observedAt.addingTimeInterval(TimeInterval((i + 1) * 60)),
                bundleID: "com.x", appName: "com.x", windowTitle: "t", browserURL: nil, category: .work)
        }
        for f in extra { try store.saveActivityFrame(f) }
        let window2 = DateInterval(start: window1.start, end: extra.last!.observedAt.addingTimeInterval(60))
        try pipeline.run(window: window2)

        let after = try store.fetchActivitySessions(since: window2.start, until: window2.end)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].id, session.id)
        XCTAssertEqual(after[0].assignmentStatus, .manualAssigned)
        XCTAssertEqual(after[0].projectID, project.id)
        XCTAssertGreaterThan(after[0].endedAt, session.endedAt)
    }

    func testIgnoredSurvivesRuleMatch() async throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/p"); try store.saveProject(project)
        let frames = makeFrames(count: 3)
        for f in frames { try store.saveActivityFrame(f) }
        try store.upsertRule(ProjectActivityRule(projectID: project.id, kind: .bundleIDEquals, pattern: "com.x", isEnabled: true))

        let pipeline = SessionPipeline(store: store)
        let window = DateInterval(start: frames.first!.observedAt.addingTimeInterval(-60), end: frames.last!.observedAt.addingTimeInterval(60))
        try pipeline.run(window: window)
        let session = try store.fetchActivitySessions(since: window.start, until: window.end)[0]

        try store.updateActivitySessionAssignment(sessionID: session.id, assignmentStatus: .ignored, projectID: nil, assignmentSource: "manual")
        try pipeline.run(window: window)

        let after = try store.fetchActivitySessions(since: window.start, until: window.end)
        XCTAssertEqual(after[0].assignmentStatus, .ignored)
        XCTAssertNil(after[0].projectID)
    }

    func testUndoIgnoreReevaluatesRules() async throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/p"); try store.saveProject(project)
        let frames = makeFrames(count: 3)
        for f in frames { try store.saveActivityFrame(f) }
        try store.upsertRule(ProjectActivityRule(projectID: project.id, kind: .bundleIDEquals, pattern: "com.x", isEnabled: true))

        let pipeline = SessionPipeline(store: store)
        let window = DateInterval(start: frames.first!.observedAt.addingTimeInterval(-60), end: frames.last!.observedAt.addingTimeInterval(60))
        try pipeline.run(window: window)
        var session = try store.fetchActivitySessions(since: window.start, until: window.end)[0]
        try store.updateActivitySessionAssignment(sessionID: session.id, assignmentStatus: .ignored, projectID: nil, assignmentSource: "manual")
        try pipeline.run(window: window)

        // Undo
        try store.updateActivitySessionAssignment(sessionID: session.id, assignmentStatus: .unassigned, projectID: nil, assignmentSource: nil)
        try pipeline.run(window: window)
        session = try store.fetchActivitySessions(since: window.start, until: window.end)[0]
        XCTAssertEqual(session.assignmentStatus, .ruleAssigned)
        XCTAssertEqual(session.projectID, project.id)
    }

    func testIgnoreThenAssignOverwrites() async throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/p"); try store.saveProject(project)
        let frames = makeFrames(count: 3)
        for f in frames { try store.saveActivityFrame(f) }

        let pipeline = SessionPipeline(store: store)
        let window = DateInterval(start: frames.first!.observedAt.addingTimeInterval(-60), end: frames.last!.observedAt.addingTimeInterval(60))
        try pipeline.run(window: window)
        let session = try store.fetchActivitySessions(since: window.start, until: window.end)[0]

        try store.updateActivitySessionAssignment(sessionID: session.id, assignmentStatus: .ignored, projectID: nil, assignmentSource: "manual")
        try store.updateActivitySessionAssignment(sessionID: session.id, assignmentStatus: .manualAssigned, projectID: project.id, assignmentSource: "manual")
        try pipeline.run(window: window)
        let after = try store.fetchActivitySessions(since: window.start, until: window.end)[0]
        XCTAssertEqual(after.assignmentStatus, .manualAssigned)
        XCTAssertEqual(after.projectID, project.id)
    }

    func testRuleAssignmentReevaluatedOnRuleChange() async throws {
        let store = try MemoryStore.inMemory()
        let p1 = Project(name: "p1", rootPath: "/p1"); try store.saveProject(p1)
        let p2 = Project(name: "p2", rootPath: "/p2"); try store.saveProject(p2)
        let frames = makeFrames(count: 3)
        for f in frames { try store.saveActivityFrame(f) }
        let rule1 = ProjectActivityRule(projectID: p1.id, kind: .bundleIDEquals, pattern: "com.x", isEnabled: true)
        try store.upsertRule(rule1)
        let pipeline = SessionPipeline(store: store)
        let window = DateInterval(start: frames.first!.observedAt.addingTimeInterval(-60), end: frames.last!.observedAt.addingTimeInterval(60))
        try pipeline.run(window: window)
        XCTAssertEqual(try store.fetchActivitySessions(since: window.start, until: window.end)[0].projectID, p1.id)

        // Disable rule1, add rule2 for p2
        try store.upsertRule(ProjectActivityRule(id: rule1.id, projectID: p1.id, kind: .bundleIDEquals, pattern: "com.x", isEnabled: false, createdAt: rule1.createdAt))
        try store.upsertRule(ProjectActivityRule(projectID: p2.id, kind: .bundleIDEquals, pattern: "com.x", isEnabled: true))
        try pipeline.run(window: window)
        XCTAssertEqual(try store.fetchActivitySessions(since: window.start, until: window.end)[0].projectID, p2.id)
    }
}
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter TriageDurabilityTests`
Expected: 7/7 PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/ProjectMemoryAppTests/TriageDurabilityTests.swift
git commit -m "test(phase2): triage durability matrix (7 cases)"
```

---

## Task 22: Final integration & manual smoke test prep

**Files:**
- Create: `docs/superpowers/runbooks/2026-05-07-phase-2-smoke-test.md`

This task produces a smoke runbook the user follows manually after the code lands. No new code.

- [ ] **Step 1: Write the runbook**

```markdown
# Phase 2 Smoke Test Runbook

Prerequisites: env flag `PROJECT_MEMORY_ENABLE_ACTIVITY_CAPTURE=1` set; Phase 1 dogfood already passed.

## Step 1: Generate frames
1. Launch app, enable activity capture in Settings if not already.
2. Use Cursor + Chrome (github.com) for ~5 minutes each on different content.
3. Wait until next 60s tick to ensure both have 3+ frames.

## Step 2: Triage tab
1. Open the new "Triage" tab. Confirm it shows the Cursor session and the Chrome (github.com) session as unassigned.
2. Badge count on the tab matches the visible row count.
3. Click 归属到项目 → pick "project-memory" for the Cursor row. Row disappears from list.
4. Click 忽略 on the Chrome row. Row moves to 已忽略 折叠区. Open it, click 撤销忽略 — row returns to main list.

## Step 3: Manual durability
1. Quit the app.
2. Reopen. Confirm the previously-assigned session is no longer in the待归属 list (still assigned in DB).

## Step 4: Brief integration
1. Trigger a brief generation (TodayView → 生成简报).
2. Confirm the generated brief includes a reference to the assigned activity session (e.g., "应用：Cursor" or similar via snippet).
3. The OpenRouter request body must NOT contain ActivityFrame raw data — only snippet text. (Inspect via network log or sample print before send.)

## Step 5: Q&A integration
1. Ask "我今天在 project-memory 上做了什么？" with project-memory selected as scope.
2. Confirm the answer prompt cites the activity snippet.
3. Ask the same question with NO project scope — confirm the answer prompt does NOT cite any activity session.

## Step 6: Long-snippet truncation marker
1. Manually craft a session with long titleSamples (e.g., open a non-browser app with a >800-char title via test fixture or scripting).
2. Confirm the brief snippet for that session ends with `[内容已截断，仅发送相关片段]`.
3. (Optional) Compare a short session — should NOT have the marker.

## Step 7: Privacy review
1. Run `swift test --filter PromptPathPrivacyGuardsTests PromptPathSentinelTests` — both must pass.
2. `grep -rn "ActivityFrame\|activity_frames" Sources/ProjectMemoryCore/BriefGenerator.swift Sources/ProjectMemoryCore/AnswerEngine.swift` should return nothing.
3. `grep -n "extractedText" Sources/ProjectMemoryCore/BriefGenerator.swift Sources/ProjectMemoryCore/AnswerEngine.swift` should return nothing.

## Step 8: Coverage gate
1. `swift build` — clean, 0 deprecated warnings.
2. `swift test` — all green.
3. Test count should be 150+ (Phase 1 baseline 108 + ~40 Phase 2).
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/runbooks/2026-05-07-phase-2-smoke-test.md
git commit -m "docs(phase2): manual smoke test runbook"
```

---

## Self-Review (run before handoff)

Before declaring the plan complete, walk through this checklist with a fresh read of the spec.

### Spec coverage check

| Spec section | Implementing task(s) |
|---|---|
| §3 Q1 rules + manual fallback | Task 2 (rule type), Task 4 (resolver), Task 7 (rule store APIs), Task 17 (manual triage) |
| §3 Q2 session identity (bundleID + browser host) | Task 3 (aggregator) |
| §3 Q3 materialization gate (3 conditions) | Task 8 (reconciler `shouldMaterialize`), Task 13/14 (guards) |
| §3 Q4 session.id = firstFrame.id | Task 3 (`makeDraft.id = first.id`) |
| §3 Q5 triage assign/ignore/undoIgnore | Task 17 |
| §3 Q6 caps (4/12, 2/8, 400, 900/600) | Task 9 (types), Task 12 (algorithm) |
| §5.1 Core types | Tasks 1, 2, 9 |
| §5.2 SQLite schema | Task 5 |
| §5.3 new MemoryStore APIs | Tasks 6, 7 |
| §5.4 SourceKind.activitySession | Task 1 |
| §5.5 MemorySource via path "activity-sessions/<id>" | Task 8 (reconciler materialize) |
| §6.1 SessionAggregator | Task 3 |
| §6.2 AssignmentResolver | Task 4 |
| §6.3 Reconciler (step ordering, double cleanup) | Task 8 |
| §6.4 SessionPipeline orchestration | Task 15 |
| §6.5 makeExtractedText (privacy gate) | Task 8 |
| §7.1 SelectedSourceSnippet types | Task 9 |
| §7.2 BriefGenerator/AnswerEngine refactor | Task 11 |
| §7.3/§7.4 caps & per-project algorithm | Task 12 |
| §7.6 privacy boundary table | Task 13 (guards), Task 14 (sentinels) |
| §8 Triage UI (tab, list, actions, durability) | Tasks 16, 17, 18, 19 |
| §9.1 pure unit tests | Tasks 3, 4 |
| §9.2 integration tests | Tasks 6, 7, 8, 15 |
| §9.3 mechanical guards | Task 13 |
| §9.4 sentinel tests | Task 14 |
| §9.5 caps tests | Task 12 |
| §9.6 triage durability | Task 21 |
| §9.7 UI smoke (ViewModel) | Tasks 16, 17 |
| §12 Acceptance criteria | Task 22 (runbook) |

### Pipeline scheduling

§4 says SessionPipeline is the only orchestrator. §1 / Q4 chose **on-demand** scheduling. Task 20 wires `pipeline.run` into Brief / Answer / Triage entry points. ✅

### Type / signature consistency check

- `ActivitySessionDraft.frameIDs: [UUID]` (Task 2) ↔ `relatedFrames: [ActivityFrame]` in Resolver (Task 4) ↔ Pipeline rebuilds via `frameIDs.compactMap { framesByID[$0] }` (Task 15). ✅
- `assignment_source` values consistent: `"manual"` / `"rule:<uuid>"` / `nil` across Tasks 4, 6, 8, 17. ✅
- `MemoryStore` table name `sources` used everywhere — spec's `memory_sources` shorthand resolved at top of plan. ✅
- `TextSanitizer.stripInvisibleControls(_:)` actual API name used in Tasks 3, 4, 8. No reference to the spec's earlier `TextSanitizer.sanitize`. ✅
- `fetchActivityFrames(category:project:since:until:limit:)` actual API used in Task 15. No reference to `fetchFrames`. ✅

### Placeholder scan

No "TBD" / "TODO" / "implement later" / "similar to Task N" found. Each step that touches code shows the code.

### Known limitations (carried from spec §10)

- `sessionGapThreshold` change is a breaking config change (no test for "should fail" — docs only).
- Frame retention deletes by time window only (never single frames) — relies on session-scoped retention.
- bundleID + host crossover: short tab-switching is split into multiple sessions intentionally.

### Phase 2.5 backlog (not in this plan)

- Quick "create rule from this session" button in Triage UI
- Rule editor preview (sample matches before saving)
- Activity timeline visualization
- Per-project session digest
- Phase 1.5 optional OCR lane

---

## Plan complete

Plan saved to `docs/superpowers/plans/2026-05-07-phase-2-activity-sessions.md`.

**Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Phase 1 used this pattern with success (17 tasks → 5 stage-2 findings + 2 polish rounds).

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints for review.

Which approach?
