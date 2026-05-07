# Activity Metadata Capture (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a metadata-only background activity capture pipeline (no screenshots, no OCR) to Project Memory, behind two hard gates (env flag + user toggle), recording frontmost app + window title + browser URL + auto-classified category to a new `activity_frames` SQLite table — without touching brief / Q&A / OpenRouter paths.

**Architecture:** App-side `ActivityCoordinator` (`@MainActor`) drives a 60s heartbeat + NSWorkspace listeners. Each tick passes through guards (idle / lock / self-frontmost), then a pure-function chain `ActivityCandidateCollector` → `ActivityGate` → `ActivityClassifier` → `MemoryStore.saveActivityFrame`. Pure logic lives in `ProjectMemoryCore`; macOS side effects live in `ProjectMemoryApp` and are injected as protocols so coordinator tests are deterministic and offline.

**Tech Stack:** Swift 5.10 / SwiftPM / SwiftUI / SQLite3 / `NSWorkspace` / `CGEventSource` / `CGSessionCopyCurrentDictionary` / `osascript`. **No Vision, no ScreenCaptureKit, no CGWindowListCreateImage, no OpenRouter.**

---

## Plan Notes

- **Spec reference**: `docs/superpowers/specs/2026-05-07-activity-metadata-capture-design.md`
- **Project is not a git repo**. Commit steps below are written for completeness but are no-ops in current state. Skip them or convert to your preferred snapshot mechanism.
- **Test target reality**: existing 47 tests must remain passing throughout. Each task adds new tests; nothing existing should break unless explicitly modified by that task.
- **Codex review note carried in**: Core classifier and App's supported-browser bundleID list must share a single source of truth — handled in Task 7 (`SupportedBrowsers`).
- **Sanitization placement**: `MemoryStore.saveActivityFrame` does **not** sanitize. `ActivityCandidateCollector` is the single sanitize point for activity data.

## Scope

This plan covers only Phase 1 from the spec. Out of scope:
- Vision OCR / screenshots (Phase 1.5)
- Session aggregation / brief integration / project assignment / triage UI (Phase 2)
- Tier 2 capture-but-local-only (Phase 3)
- Enabling SQLite `PRAGMA foreign_keys=ON` (independent change)

## File Structure

### Core target (`Sources/ProjectMemoryCore/`)

| File | Status | Responsibility |
|---|---|---|
| `URLDenyList.swift` | NEW (migrated from App) | URL deny rules + `normalizeForDedup` |
| `SupportedBrowsers.swift` | NEW (extracted from App) | Single source of truth: bundleID set + dialect mapping |
| `ActivityDenyList.swift` | NEW | App-level deny rules (default + extra) |
| `ActivityGate.swift` | NEW | Pure decision: capture vs skip + reason |
| `ActivityClassifier.swift` | NEW | Pure classification: bundle → category, browser+URL host → category |
| `Models.swift` | MODIFIED | Append `ActivityCategory`, `ActivityCandidate`, `ActivityFrame`, `ProjectFilter` |
| `MemoryStore.swift` | MODIFIED | Add `activity_frames` schema + 4 methods |

### App target (`Sources/ProjectMemoryApp/`)

| File | Status | Responsibility |
|---|---|---|
| `BrowserTabReader.swift` | NEW | osascript → (title, url) for supported browsers; updates AutomationAttemptLog |
| `AutoWebCaptureDenyList.swift` | DELETED | Migrated to Core/URLDenyList.swift |
| `AutoWebCaptureService.swift` | MODIFIED | Use injected `BrowserTabReader` and Core `SupportedBrowsers`; remove duplicated routing |
| `AppState.swift` | MODIFIED | Activity toggle + extraDenied state, coordinator lifecycle, GC trigger |
| `Activity/ActivityCoordinator.swift` | NEW | `@MainActor` orchestrator: gates + tick + collector chain |
| `Activity/ActivityCandidateCollector.swift` | NEW | `ActivityCandidateCollecting` protocol + macOS impl with browser title binding rule + sanitize |
| `Activity/ActivityTickScheduler.swift` | NEW | Protocol + Timer-based impl |
| `Activity/Providers.swift` | NEW | `IdleStateProvider` / `ScreenLockStateProvider` / `FrontmostAppProvider` protocols + macOS impls |
| `Activity/AutomationAttemptLog.swift` | NEW | Per-browser last-attempt outcome, UserDefaults-persisted |
| `Activity/ActivityRetentionGC.swift` | NEW | Startup +5s + every 24h GC trigger |
| `Views/Settings/ActivitySection.swift` | NEW | SwiftUI section: toggle + extraDenied + permission status + debug readout + clear button |
| `Views/SettingsView.swift` | MODIFIED | Embed `ActivitySection` |

### Tests

#### Core (`Tests/ProjectMemoryCoreTests/`)

| File | Status |
|---|---|
| `URLDenyListTests.swift` | NEW (migrated) |
| `SupportedBrowsersTests.swift` | NEW |
| `ActivityDenyListTests.swift` | NEW |
| `ActivityGateTests.swift` | NEW |
| `ActivityClassifierTests.swift` | NEW |
| `ActivityFramesStoreTests.swift` | NEW |
| `BriefGeneratorIsolationTests.swift` | NEW |

#### App (`Tests/ProjectMemoryAppTests/`)

| File | Status |
|---|---|
| `AutoWebCaptureTests.swift` | MODIFIED — drop deny-list / normalize cases (migrated), add BrowserTabReader composition case |
| `BrowserTabReaderTests.swift` | NEW |
| `AutomationAttemptLogTests.swift` | NEW |
| `ActivityCoordinatorTests.swift` | NEW |
| `ActivitySettingsTests.swift` | NEW |

---

## Task 1: Migrate `AutoWebCaptureDenyList` → `Core/URLDenyList`

**Files:**
- Create: `Sources/ProjectMemoryCore/URLDenyList.swift`
- Create: `Tests/ProjectMemoryCoreTests/URLDenyListTests.swift`
- Modify: `Sources/ProjectMemoryApp/AppState.swift` (callsites)
- Delete: `Sources/ProjectMemoryApp/AutoWebCaptureDenyList.swift`
- Modify: `Tests/ProjectMemoryAppTests/AutoWebCaptureTests.swift` (drop migrated tests)

- [ ] **Step 1: Read the existing file to preserve logic**

Run:
```bash
cat "Sources/ProjectMemoryApp/AutoWebCaptureDenyList.swift"
```

Capture all rules (host substring matches, RFC1918 detection, normalize logic). They will be re-emitted under the new name verbatim, function for function, but with the namespace `URLDenyList` and the free function `normalizeURLForDedup` collapsed into a static method `URLDenyList.normalizeForDedup(_:)`.

- [ ] **Step 2: Write the migrated tests in Core**

Create `Tests/ProjectMemoryCoreTests/URLDenyListTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryCore

final class URLDenyListTests: XCTestCase {
    func testIsDeniedBlocksSensitiveHosts() {
        XCTAssertTrue(URLDenyList.isDenied("https://bank.example.com/account"))
        XCTAssertTrue(URLDenyList.isDenied("https://accounts.google.com/o/oauth2/v2/auth"))
        XCTAssertTrue(URLDenyList.isDenied("https://login.example.com/sso"))
    }

    func testIsDeniedBlocksPrivateNetworks() {
        XCTAssertTrue(URLDenyList.isDenied("http://192.168.1.10/admin"))
        XCTAssertTrue(URLDenyList.isDenied("http://10.0.0.5/router"))
        XCTAssertTrue(URLDenyList.isDenied("http://172.20.10.5/admin"))
        XCTAssertTrue(URLDenyList.isDenied("http://localhost:3000/debug"))
        XCTAssertTrue(URLDenyList.isDenied("http://router.lan/status"))
    }

    func testIsDeniedReturnsTrueForUnparseableURL() {
        XCTAssertTrue(URLDenyList.isDenied("not a url"))
        XCTAssertTrue(URLDenyList.isDenied(""))
    }

    func testIsDeniedAllowsBenignHosts() {
        XCTAssertFalse(URLDenyList.isDenied("https://example.com/article"))
        XCTAssertFalse(URLDenyList.isDenied("https://swift.org/documentation"))
    }

    func testNormalizeForDedupRemovesTrackingAndFragment() {
        let a = URLDenyList.normalizeForDedup(
            "https://EXAMPLE.com/article/?utm_source=newsletter&fbclid=abc&keep=1#section"
        )
        let b = URLDenyList.normalizeForDedup("https://example.com/article/?keep=1")
        XCTAssertEqual(a, b)
    }

    func testNormalizeForDedupTreatsTrailingSlashAsEquivalent() {
        XCTAssertEqual(
            URLDenyList.normalizeForDedup("https://Example.com/article/"),
            URLDenyList.normalizeForDedup("https://example.com/article")
        )
    }
}
```

- [ ] **Step 3: Run tests to verify FAIL (URLDenyList not yet defined)**

Run:
```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter URLDenyListTests
```

Expected: FAIL with "cannot find 'URLDenyList' in scope" or similar.

- [ ] **Step 4: Create `Sources/ProjectMemoryCore/URLDenyList.swift`**

```swift
import Foundation

public enum URLDenyList {
    public static func isDenied(_ url: String) -> Bool {
        guard let host = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?
            .lowercased(),
            !host.isEmpty
        else {
            return true
        }

        if host == "localhost" || host == "127.0.0.1" {
            return true
        }
        if host.hasSuffix(".lan") || host.hasSuffix(".local") {
            return true
        }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") {
            return true
        }
        if is172PrivateHost(host) {
            return true
        }

        let keywords = [
            "bank", "accounts.", "mail.", "oauth",
            "login.", "signin.", "auth.", "password"
        ]
        return keywords.contains { host.contains($0) }
    }

    public static func normalizeForDedup(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.host != nil
        else {
            return trimmed
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil

        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        if let queryItems = components.queryItems {
            let filtered = queryItems
                .filter { item in
                    let name = item.name.lowercased()
                    return !name.hasPrefix("utm_")
                        && name != "fbclid"
                        && name != "gclid"
                }
                .sorted { lhs, rhs in
                    if lhs.name == rhs.name {
                        return (lhs.value ?? "") < (rhs.value ?? "")
                    }
                    return lhs.name < rhs.name
                }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }

        return components.string ?? trimmed
    }

    private static func is172PrivateHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count >= 2,
              parts[0] == "172",
              let second = Int(parts[1])
        else {
            return false
        }
        return (16...31).contains(second)
    }
}
```

- [ ] **Step 5: Update `AppState.swift` callsites**

In `Sources/ProjectMemoryApp/AppState.swift`, replace:
```swift
guard !AutoWebCaptureDenyList.isDenied(sanitizedURL) else {
```
with:
```swift
guard !URLDenyList.isDenied(sanitizedURL) else {
```

And replace:
```swift
let normalizedURL = normalizeURLForDedup(sanitizedURL)
```
with:
```swift
let normalizedURL = URLDenyList.normalizeForDedup(sanitizedURL)
```

- [ ] **Step 6: Delete the old file**

Run:
```bash
rm "Sources/ProjectMemoryApp/AutoWebCaptureDenyList.swift"
```

- [ ] **Step 7: Drop migrated tests from `AutoWebCaptureTests.swift`**

Open `Tests/ProjectMemoryAppTests/AutoWebCaptureTests.swift` and delete:
- `testDenyListBlocksSensitiveAndPrivateURLs`
- `testNormalizeURLForDedupRemovesTrackingAndFragment`
- `testNormalizeURLForDedupTreatsTrailingSlashAsEquivalent`

Keep `testSupportedBrowserRoutesKnownBundleIDs` for now (will move in Task 7).

- [ ] **Step 8: Run all tests + build, verify clean**

Run:
```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build --disable-sandbox --scratch-path .build
```

Expected: all tests pass; build clean.

Run:
```bash
rg "AutoWebCaptureDenyList" Sources Tests Package.swift
rg "normalizeURLForDedup" Sources Tests Package.swift
```

Expected: 0 matches each.

- [ ] **Step 9: Commit (skip if not a git repo)**

```bash
git add -A && git commit -m "refactor: migrate AutoWebCaptureDenyList → Core/URLDenyList"
```

---

## Task 2: Extend `Models.swift` with activity types

**Files:**
- Modify: `Sources/ProjectMemoryCore/Models.swift`

- [ ] **Step 1: Append the four new public types**

Open `Sources/ProjectMemoryCore/Models.swift` and append at the end of file:

```swift
public enum ActivityCategory: String, Codable, CaseIterable {
    case work
    case socialMedia
    case chat
    case other
}

public struct ActivityCandidate: Equatable {
    public let observedAt: Date
    public let bundleID: String
    public let appName: String
    public let windowTitle: String?
    public let browserURL: String?

    public init(
        observedAt: Date,
        bundleID: String,
        appName: String,
        windowTitle: String?,
        browserURL: String?
    ) {
        self.observedAt = observedAt
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.browserURL = browserURL
    }
}

public struct ActivityFrame: Identifiable, Equatable, Codable {
    public let id: UUID
    public let observedAt: Date
    public let bundleID: String
    public let appName: String
    public let windowTitle: String?
    public let browserURL: String?
    public let category: ActivityCategory
    public let projectID: UUID?

    public init(
        id: UUID = UUID(),
        observedAt: Date,
        bundleID: String,
        appName: String,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        category: ActivityCategory,
        projectID: UUID? = nil
    ) {
        self.id = id
        self.observedAt = observedAt
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.category = category
        self.projectID = projectID
    }
}

public enum ProjectFilter: Equatable {
    case any
    case unassigned
    case project(UUID)
}
```

- [ ] **Step 2: Verify build**

Run:
```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build --disable-sandbox --scratch-path .build
```

Expected: build clean.

- [ ] **Step 3: Commit (skip if not a git repo)**

```bash
git add Sources/ProjectMemoryCore/Models.swift && git commit -m "feat(core): add ActivityCategory, ActivityCandidate, ActivityFrame, ProjectFilter"
```

---

## Task 3: Extend `MemoryStore` with `activity_frames` schema

**Files:**
- Modify: `Sources/ProjectMemoryCore/MemoryStore.swift`
- Create: `Tests/ProjectMemoryCoreTests/ActivityFramesStoreTests.swift`

- [ ] **Step 1: Write a failing test for save + fetch round-trip**

Create `Tests/ProjectMemoryCoreTests/ActivityFramesStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run, verify FAIL**

Run:
```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter ActivityFramesStoreTests
```

Expected: FAIL — `saveActivityFrame` does not exist.

- [ ] **Step 3: Add schema in `createSchema`**

In `Sources/ProjectMemoryCore/MemoryStore.swift`, find `private func createSchema() throws` and append after the existing `briefs` table block:

```swift
        try database.execute("""
        CREATE TABLE IF NOT EXISTS activity_frames (
            id TEXT PRIMARY KEY,
            observed_at TEXT NOT NULL,
            bundle_id TEXT NOT NULL,
            app_name TEXT NOT NULL,
            window_title TEXT,
            browser_url TEXT,
            category TEXT NOT NULL,
            project_id TEXT REFERENCES projects(id) ON DELETE SET NULL
        )
        """)
        try database.execute("""
        CREATE INDEX IF NOT EXISTS idx_activity_frames_observed_at
        ON activity_frames(observed_at DESC)
        """)
        try database.execute("""
        CREATE INDEX IF NOT EXISTS idx_activity_frames_category_observed
        ON activity_frames(category, observed_at DESC)
        """)
        try database.execute("""
        CREATE INDEX IF NOT EXISTS idx_activity_frames_project_observed
        ON activity_frames(project_id, observed_at DESC)
        """)
```

- [ ] **Step 4: Add `saveActivityFrame` method**

In the same file, add a new public method after `saveBrief`:

```swift
public func saveActivityFrame(_ frame: ActivityFrame) throws {
    try database.execute(
        """
        INSERT OR REPLACE INTO activity_frames
        (id, observed_at, bundle_id, app_name, window_title, browser_url, category, project_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        values: [
            .text(frame.id.uuidString),
            .text(iso.string(from: frame.observedAt)),
            .text(frame.bundleID),
            .text(frame.appName),
            frame.windowTitle.map { .text($0) } ?? .null,
            frame.browserURL.map { .text($0) } ?? .null,
            .text(frame.category.rawValue),
            frame.projectID.map { .text($0.uuidString) } ?? .null
        ]
    )
}
```

- [ ] **Step 5: Add `fetchActivityFrames` method with full filter support**

```swift
public func fetchActivityFrames(
    category: ActivityCategory? = nil,
    project: ProjectFilter = .any,
    since: Date? = nil,
    until: Date? = nil,
    limit: Int? = nil
) throws -> [ActivityFrame] {
    var sql = "SELECT * FROM activity_frames"
    var clauses: [String] = []
    var values: [SQLiteValue] = []

    if let category {
        clauses.append("category = ?")
        values.append(.text(category.rawValue))
    }
    switch project {
    case .any:
        break
    case .unassigned:
        clauses.append("project_id IS NULL")
    case .project(let id):
        clauses.append("project_id = ?")
        values.append(.text(id.uuidString))
    }
    if let since {
        clauses.append("observed_at >= ?")
        values.append(.text(iso.string(from: since)))
    }
    if let until {
        clauses.append("observed_at < ?")
        values.append(.text(iso.string(from: until)))
    }

    if !clauses.isEmpty {
        sql += " WHERE " + clauses.joined(separator: " AND ")
    }
    sql += " ORDER BY observed_at DESC"
    if let limit {
        sql += " LIMIT ?"
        values.append(.integer(Int64(limit)))
    }

    return try database.query(sql, values: values).map { row in
        ActivityFrame(
            id: try row.uuid("id"),
            observedAt: try row.date("observed_at", formatter: iso),
            bundleID: try row.text("bundle_id"),
            appName: try row.text("app_name"),
            windowTitle: try row.optionalText("window_title"),
            browserURL: try row.optionalText("browser_url"),
            category: ActivityCategory(rawValue: try row.text("category")) ?? .other,
            projectID: try row.optionalUUID("project_id")
        )
    }
}
```

- [ ] **Step 6: Add `countActivityFrames` method**

```swift
public func countActivityFrames(
    category: ActivityCategory? = nil,
    project: ProjectFilter = .any,
    since: Date? = nil,
    until: Date? = nil
) throws -> Int {
    var sql = "SELECT COUNT(*) AS n FROM activity_frames"
    var clauses: [String] = []
    var values: [SQLiteValue] = []

    if let category {
        clauses.append("category = ?")
        values.append(.text(category.rawValue))
    }
    switch project {
    case .any:
        break
    case .unassigned:
        clauses.append("project_id IS NULL")
    case .project(let id):
        clauses.append("project_id = ?")
        values.append(.text(id.uuidString))
    }
    if let since {
        clauses.append("observed_at >= ?")
        values.append(.text(iso.string(from: since)))
    }
    if let until {
        clauses.append("observed_at < ?")
        values.append(.text(iso.string(from: until)))
    }

    if !clauses.isEmpty {
        sql += " WHERE " + clauses.joined(separator: " AND ")
    }

    let rows = try database.query(sql, values: values)
    guard let row = rows.first, case .integer(let n) = row["n"] ?? .null else {
        return 0
    }
    return Int(n)
}
```

- [ ] **Step 7: Add `deleteActivityFrames` method**

```swift
public func deleteActivityFrames(beforeDate: Date) throws {
    try database.execute(
        "DELETE FROM activity_frames WHERE observed_at < ?",
        values: [.text(iso.string(from: beforeDate))]
    )
}
```

- [ ] **Step 8: Run round-trip test, verify PASS**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter ActivityFramesStoreTests
```

Expected: PASS.

- [ ] **Step 9: Add filter / boundary / count / delete tests**

Append to `ActivityFramesStoreTests.swift`:

```swift
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
}
```

- [ ] **Step 10: Run all tests, verify PASS**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter ActivityFramesStoreTests
```

Expected: PASS, 9 cases.

- [ ] **Step 11: Commit**

```bash
git add -A && git commit -m "feat(core): add activity_frames schema + save/fetch/count/delete API"
```

---

## Task 4: `ActivityDenyList`

**Files:**
- Create: `Sources/ProjectMemoryCore/ActivityDenyList.swift`
- Create: `Tests/ProjectMemoryCoreTests/ActivityDenyListTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/ProjectMemoryCoreTests/ActivityDenyListTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryCore

final class ActivityDenyListTests: XCTestCase {
    func testIsDeniedMatchesDefaultBundleIDs() {
        XCTAssertTrue(ActivityDenyList.isDenied(bundleID: "com.1password.1password"))
        XCTAssertTrue(ActivityDenyList.isDenied(bundleID: "com.bitwarden.desktop"))
        XCTAssertTrue(ActivityDenyList.isDenied(bundleID: "org.keepassxc.keepassxc"))
        XCTAssertTrue(ActivityDenyList.isDenied(bundleID: "com.apple.keychainaccess"))
    }

    func testIsDeniedMatchesExtraDenied() {
        XCTAssertTrue(
            ActivityDenyList.isDenied(
                bundleID: "com.example.private",
                extraDenied: ["com.example.private"]
            )
        )
    }

    func testIsDeniedFalseForUnknownAndEmptyExtra() {
        XCTAssertFalse(ActivityDenyList.isDenied(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(
            ActivityDenyList.isDenied(
                bundleID: "com.tinyspeck.slackmacgap",
                extraDenied: []
            )
        )
    }

    func testIsDeniedTrueWhenBothDefaultAndExtra() {
        XCTAssertTrue(
            ActivityDenyList.isDenied(
                bundleID: "com.1password.1password",
                extraDenied: ["com.1password.1password"]
            )
        )
    }

    func testDefaultBundleIDsContainsExpectedHighConfidenceSet() {
        let expected: Set<String> = [
            "com.agilebits.onepassword7",
            "com.agilebits.onepassword4",
            "com.1password.1password",
            "com.bitwarden.desktop",
            "org.keepassxc.keepassxc",
            "com.apple.keychainaccess"
        ]
        XCTAssertEqual(ActivityDenyList.defaultBundleIDs, expected)
    }

    func testIsDeniedDoesNotMatchEmptyBundleIDStringEvenWithEmptyExtra() {
        XCTAssertFalse(ActivityDenyList.isDenied(bundleID: ""))
    }
}
```

- [ ] **Step 2: Run, verify FAIL**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter ActivityDenyListTests
```

Expected: FAIL — `ActivityDenyList` undefined.

- [ ] **Step 3: Implement**

Create `Sources/ProjectMemoryCore/ActivityDenyList.swift`:

```swift
import Foundation

public enum ActivityDenyList {
    public static let defaultBundleIDs: Set<String> = [
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword4",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.keychainaccess"
    ]

    public static func isDenied(bundleID: String, extraDenied: Set<String> = []) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return defaultBundleIDs.contains(bundleID) || extraDenied.contains(bundleID)
    }
}
```

- [ ] **Step 4: Run, verify PASS**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter ActivityDenyListTests
```

Expected: PASS, 6 cases.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): add ActivityDenyList with high-confidence default bundle IDs"
```

---

## Task 5: `ActivityGate`

**Files:**
- Create: `Sources/ProjectMemoryCore/ActivityGate.swift`
- Create: `Tests/ProjectMemoryCoreTests/ActivityGateTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/ProjectMemoryCoreTests/ActivityGateTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryCore

final class ActivityGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func candidate(
        bundleID: String = "com.tinyspeck.slackmacgap",
        browserURL: String? = nil
    ) -> ActivityCandidate {
        ActivityCandidate(
            observedAt: now,
            bundleID: bundleID,
            appName: "App",
            windowTitle: nil,
            browserURL: browserURL
        )
    }

    func testCaptureWhenAllChecksPass() {
        let decision = ActivityGate.decide(
            candidate: candidate(),
            now: now,
            lastCaptureAt: nil,
            extraDenied: []
        )
        XCTAssertEqual(decision, .capture)
    }

    func testSkipWhenBundleIDInDefaultDeny() {
        let decision = ActivityGate.decide(
            candidate: candidate(bundleID: "com.1password.1password"),
            now: now,
            lastCaptureAt: nil,
            extraDenied: []
        )
        XCTAssertEqual(decision, .skip(reason: "app_denied"))
    }

    func testSkipWhenBundleIDInExtraDenied() {
        let decision = ActivityGate.decide(
            candidate: candidate(bundleID: "com.example.private"),
            now: now,
            lastCaptureAt: nil,
            extraDenied: ["com.example.private"]
        )
        XCTAssertEqual(decision, .skip(reason: "app_denied"))
    }

    func testSkipWhenBrowserURLDenied() {
        let decision = ActivityGate.decide(
            candidate: candidate(browserURL: "https://accounts.google.com/login"),
            now: now,
            lastCaptureAt: nil,
            extraDenied: []
        )
        XCTAssertEqual(decision, .skip(reason: "url_denied"))
    }

    func testSkipWhenWithinRateLimitWindow() {
        let decision = ActivityGate.decide(
            candidate: candidate(),
            now: now,
            lastCaptureAt: now.addingTimeInterval(-3),
            extraDenied: []
        )
        XCTAssertEqual(decision, .skip(reason: "rate_limited"))
    }

    func testCaptureWhenLastCaptureBeforeRateLimit() {
        let decision = ActivityGate.decide(
            candidate: candidate(),
            now: now,
            lastCaptureAt: now.addingTimeInterval(-6),
            extraDenied: []
        )
        XCTAssertEqual(decision, .capture)
    }

    func testCaptureWhenBrowserURLIsNil() {
        let decision = ActivityGate.decide(
            candidate: candidate(bundleID: "com.apple.Safari", browserURL: nil),
            now: now,
            lastCaptureAt: nil,
            extraDenied: []
        )
        XCTAssertEqual(decision, .capture)
    }
}
```

- [ ] **Step 2: Run, verify FAIL**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter ActivityGateTests
```

Expected: FAIL.

- [ ] **Step 3: Implement**

Create `Sources/ProjectMemoryCore/ActivityGate.swift`:

```swift
import Foundation

public enum ActivityGate {
    public enum Decision: Equatable {
        case capture
        case skip(reason: String)
    }

    public static let rateLimitInterval: TimeInterval = 5

    public static func decide(
        candidate: ActivityCandidate,
        now: Date,
        lastCaptureAt: Date?,
        extraDenied: Set<String>
    ) -> Decision {
        if ActivityDenyList.isDenied(bundleID: candidate.bundleID, extraDenied: extraDenied) {
            return .skip(reason: "app_denied")
        }
        if let url = candidate.browserURL, URLDenyList.isDenied(url) {
            return .skip(reason: "url_denied")
        }
        if let last = lastCaptureAt, now.timeIntervalSince(last) < rateLimitInterval {
            return .skip(reason: "rate_limited")
        }
        return .capture
    }
}
```

- [ ] **Step 4: Run, verify PASS**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter ActivityGateTests
```

Expected: PASS, 7 cases.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): add ActivityGate pure decision function"
```

---

## Task 6: `ActivityClassifier`

**Files:**
- Create: `Sources/ProjectMemoryCore/ActivityClassifier.swift`
- Create: `Tests/ProjectMemoryCoreTests/ActivityClassifierTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/ProjectMemoryCoreTests/ActivityClassifierTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryCore

final class ActivityClassifierTests: XCTestCase {
    private func candidate(
        bundleID: String,
        browserURL: String? = nil
    ) -> ActivityCandidate {
        ActivityCandidate(
            observedAt: Date(),
            bundleID: bundleID,
            appName: "App",
            windowTitle: nil,
            browserURL: browserURL
        )
    }

    func testSlackBundleIDIsChat() {
        XCTAssertEqual(
            ActivityClassifier.classify(candidate(bundleID: "com.tinyspeck.slackmacgap")),
            .chat
        )
    }

    func testIMessageBundleIDIsChat() {
        XCTAssertEqual(
            ActivityClassifier.classify(candidate(bundleID: "com.apple.MobileSMS")),
            .chat
        )
    }

    func testVSCodeBundleIDIsWork() {
        XCTAssertEqual(
            ActivityClassifier.classify(candidate(bundleID: "com.microsoft.VSCode")),
            .work
        )
    }

    func testXcodeBundleIDIsWork() {
        XCTAssertEqual(
            ActivityClassifier.classify(candidate(bundleID: "com.apple.dt.Xcode")),
            .work
        )
    }

    func testChromeWithTwitterURLIsSocialMedia() {
        XCTAssertEqual(
            ActivityClassifier.classify(
                candidate(bundleID: "com.google.Chrome", browserURL: "https://twitter.com/user")
            ),
            .socialMedia
        )
    }

    func testChromeWithSwiftOrgURLIsWork() {
        XCTAssertEqual(
            ActivityClassifier.classify(
                candidate(bundleID: "com.google.Chrome", browserURL: "https://swift.org/docs")
            ),
            .work
        )
    }

    func testChromeWithSlackURLIsChat() {
        XCTAssertEqual(
            ActivityClassifier.classify(
                candidate(bundleID: "com.google.Chrome", browserURL: "https://acme.slack.com/messages")
            ),
            .chat
        )
    }

    func testBrowserWithUnknownHostIsOther() {
        XCTAssertEqual(
            ActivityClassifier.classify(
                candidate(bundleID: "com.google.Chrome", browserURL: "https://example.com/page")
            ),
            .other
        )
    }

    func testBrowserWithNilURLIsOther() {
        XCTAssertEqual(
            ActivityClassifier.classify(
                candidate(bundleID: "com.apple.Safari", browserURL: nil)
            ),
            .other
        )
    }

    func testUnknownBundleIDIsOther() {
        XCTAssertEqual(
            ActivityClassifier.classify(candidate(bundleID: "com.unknown.app")),
            .other
        )
    }
}
```

- [ ] **Step 2: Run, verify FAIL**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter ActivityClassifierTests
```

Expected: FAIL.

- [ ] **Step 3: Implement**

Create `Sources/ProjectMemoryCore/ActivityClassifier.swift`:

```swift
import Foundation

public enum ActivityClassifier {
    private static let chatBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.apple.MobileSMS",
        "ru.keepcoder.Telegram",
        "com.tencent.xinWeChat",
        "com.alibaba.DingTalk",
        "com.hnc.Discord"
    ]

    private static let socialBundleIDs: Set<String> = [
        "com.atebits.Tweetie2",
        "com.bilibili.bilibili-mac"
    ]

    private static let workBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "md.obsidian"
    ]

    private static let chatHosts: [String] = [
        "slack.com", "discord.com", "telegram.org", "wx.qq.com", "web.dingtalk.com"
    ]

    private static let socialHosts: [String] = [
        "twitter.com", "x.com", "weibo.com", "reddit.com",
        "bilibili.com", "xiaohongshu.com", "instagram.com"
    ]

    private static let workHosts: [String] = [
        "github.com", "swift.org", "developer.apple.com",
        "stackoverflow.com", "notion.so", "linear.app"
    ]

    public static func classify(_ candidate: ActivityCandidate) -> ActivityCategory {
        if chatBundleIDs.contains(candidate.bundleID) { return .chat }
        if socialBundleIDs.contains(candidate.bundleID) { return .socialMedia }
        if workBundleIDs.contains(candidate.bundleID) { return .work }

        if SupportedBrowsers.bundleIDs.contains(candidate.bundleID) {
            if let url = candidate.browserURL,
               let host = URLComponents(string: url)?.host?.lowercased() {
                if chatHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return .chat
                }
                if socialHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return .socialMedia
                }
                if workHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return .work
                }
            }
            return .other
        }

        return .other
    }
}
```

> Note: this references `SupportedBrowsers` which is created in Task 7. The test build will fail until Task 7 lands. To unblock incremental development, add a temporary local set first; replace with `SupportedBrowsers.bundleIDs` in Task 7.

For the temporary version, replace the `SupportedBrowsers.bundleIDs.contains(candidate.bundleID)` line with:

```swift
let temporaryBrowserBundleIDs: Set<String> = [
    "com.apple.Safari",
    "com.google.Chrome",
    "com.brave.Browser",
    "com.microsoft.edgemac",
    "company.thebrowser.Browser"
]
if temporaryBrowserBundleIDs.contains(candidate.bundleID) {
```

Task 7 will reference this and remove the local copy.

- [ ] **Step 4: Run, verify PASS**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter ActivityClassifierTests
```

Expected: PASS, 10 cases.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): add ActivityClassifier with bundle + URL host priority"
```

---

## Task 7: Extract `SupportedBrowsers` to Core (single source of truth)

**Files:**
- Create: `Sources/ProjectMemoryCore/SupportedBrowsers.swift`
- Create: `Tests/ProjectMemoryCoreTests/SupportedBrowsersTests.swift`
- Modify: `Sources/ProjectMemoryCore/ActivityClassifier.swift` (remove temporary local set)
- Modify: `Sources/ProjectMemoryApp/AutoWebCaptureService.swift` (delete struct `SupportedBrowser`, use Core enum)
- Modify: `Tests/ProjectMemoryAppTests/AutoWebCaptureTests.swift` (drop the routing test, will live in Core tests)

- [ ] **Step 1: Write failing tests in Core**

Create `Tests/ProjectMemoryCoreTests/SupportedBrowsersTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryCore

final class SupportedBrowsersTests: XCTestCase {
    func testBundleIDsContainsExpectedBrowsers() {
        XCTAssertTrue(SupportedBrowsers.bundleIDs.contains("com.apple.Safari"))
        XCTAssertTrue(SupportedBrowsers.bundleIDs.contains("com.google.Chrome"))
        XCTAssertTrue(SupportedBrowsers.bundleIDs.contains("com.brave.Browser"))
        XCTAssertTrue(SupportedBrowsers.bundleIDs.contains("com.microsoft.edgemac"))
        XCTAssertTrue(SupportedBrowsers.bundleIDs.contains("company.thebrowser.Browser"))
    }

    func testDialectForSafariReturnsSafari() {
        XCTAssertEqual(SupportedBrowsers.dialect(for: "com.apple.Safari"), .safari)
    }

    func testDialectForChromeFamilyReturnsChromium() {
        XCTAssertEqual(SupportedBrowsers.dialect(for: "com.google.Chrome"), .chromium)
        XCTAssertEqual(SupportedBrowsers.dialect(for: "com.brave.Browser"), .chromium)
        XCTAssertEqual(SupportedBrowsers.dialect(for: "com.microsoft.edgemac"), .chromium)
        XCTAssertEqual(SupportedBrowsers.dialect(for: "company.thebrowser.Browser"), .chromium)
    }

    func testDialectForUnknownReturnsNil() {
        XCTAssertNil(SupportedBrowsers.dialect(for: "com.unknown.app"))
    }
}
```

- [ ] **Step 2: Run, verify FAIL**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter SupportedBrowsersTests
```

Expected: FAIL.

- [ ] **Step 3: Create `SupportedBrowsers.swift`**

```swift
import Foundation

public enum SupportedBrowsers {
    public enum Dialect: Equatable {
        case safari
        case chromium
    }

    public static let safariBundleID = "com.apple.Safari"

    public static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser"
    ]

    public static let bundleIDs: Set<String> = chromiumBundleIDs.union([safariBundleID])

    public static func dialect(for bundleID: String) -> Dialect? {
        if bundleID == safariBundleID { return .safari }
        if chromiumBundleIDs.contains(bundleID) { return .chromium }
        return nil
    }
}
```

- [ ] **Step 4: Replace temporary set in `ActivityClassifier`**

In `Sources/ProjectMemoryCore/ActivityClassifier.swift`, find the `temporaryBrowserBundleIDs` block and replace:

```swift
let temporaryBrowserBundleIDs: Set<String> = [...]
if temporaryBrowserBundleIDs.contains(candidate.bundleID) {
```

with:

```swift
if SupportedBrowsers.bundleIDs.contains(candidate.bundleID) {
```

- [ ] **Step 5: Update `AutoWebCaptureService.swift` — delete `struct SupportedBrowser`, route via Core**

Open `Sources/ProjectMemoryApp/AutoWebCaptureService.swift`. Delete the entire `struct SupportedBrowser` block (the one defined inside that file).

Update `captureActiveBrowser()` to use Core's `SupportedBrowsers`. Replace the body of `captureActiveBrowser()`:

```swift
func captureActiveBrowser() throws -> AutoWebCaptureResult {
    guard let app = NSWorkspace.shared.frontmostApplication,
          let bundleID = app.bundleIdentifier,
          let dialect = SupportedBrowsers.dialect(for: bundleID)
    else {
        throw AutoWebCaptureError.noSupportedBrowser
    }

    let displayName = app.localizedName
        ?? app.bundleURL?.lastPathComponent
        ?? "Browser"

    let tab = try activeTab(bundleID: bundleID, dialect: dialect)
    return AutoWebCaptureResult(
        title: tab.title,
        url: tab.url,
        browserName: displayName,
        capturedAt: Date()
    )
}
```

Update `activeTab` to take `(bundleID:, dialect:)` instead of `browser: SupportedBrowser`:

```swift
private func activeTab(bundleID: String, dialect: SupportedBrowsers.Dialect) throws -> (title: String, url: String) {
    let script: String
    switch dialect {
    case .safari:
        script = """
        tell application id "\(bundleID)"
            if not (exists front document) then return ""
            return (name of front document) & linefeed & (URL of front document)
        end tell
        """
    case .chromium:
        script = """
        tell application id "\(bundleID)"
            if not (exists front window) then return ""
            set activeTab to active tab of front window
            return (title of activeTab) & linefeed & (URL of activeTab)
        end tell
        """
    }

    let output = try runOSA(script)
    let lines = output
        .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        .map(String.init)
    guard lines.count == 2,
          !lines[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        throw AutoWebCaptureError.noActiveTab
    }
    return (
        title: lines[0].trimmingCharacters(in: .whitespacesAndNewlines),
        url: lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
    )
}
```

`import ProjectMemoryCore` is already present in App target via shared dependencies.

- [ ] **Step 6: Drop `testSupportedBrowserRoutesKnownBundleIDs` from `AutoWebCaptureTests`**

In `Tests/ProjectMemoryAppTests/AutoWebCaptureTests.swift`, delete the entire `testSupportedBrowserRoutesKnownBundleIDs` function — `SupportedBrowsersTests` in Core covers it now.

- [ ] **Step 7: Run all tests + build, verify PASS**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build --disable-sandbox --scratch-path .build
```

Expected: all tests pass, build clean.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "refactor: extract SupportedBrowsers to Core as single source of truth"
```

---

## Task 8: `BriefGeneratorIsolationTests` guard

**Files:**
- Create: `Tests/ProjectMemoryCoreTests/BriefGeneratorIsolationTests.swift`

- [ ] **Step 1: Write the guard test**

Create `Tests/ProjectMemoryCoreTests/BriefGeneratorIsolationTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryCore

final class BriefGeneratorIsolationTests: XCTestCase {
    func testDailyBriefPromptDoesNotIncludeActivityFrameContent() throws {
        let store = try MemoryStore.inMemory()
        try store.saveActivityFrame(
            ActivityFrame(
                observedAt: Date(timeIntervalSince1970: 1),
                bundleID: "com.tinyspeck.slackmacgap",
                appName: "Slack",
                windowTitle: "私人对话 alice",
                browserURL: nil,
                category: .chat,
                projectID: nil
            )
        )
        try store.saveActivityFrame(
            ActivityFrame(
                observedAt: Date(timeIntervalSince1970: 2),
                bundleID: "com.google.Chrome",
                appName: "Chrome",
                windowTitle: nil,
                browserURL: "https://example.com/secret",
                category: .other,
                projectID: nil
            )
        )

        let prompt = BriefGenerator.makeDailyBriefPrompt(
            projects: [],
            sources: [],
            events: []
        )

        XCTAssertFalse(prompt.contains("com.tinyspeck.slackmacgap"))
        XCTAssertFalse(prompt.contains("私人对话 alice"))
        XCTAssertFalse(prompt.contains("https://example.com/secret"))
        XCTAssertFalse(prompt.contains("com.google.Chrome"))
    }
}
```

- [ ] **Step 2: Run, verify PASS**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter BriefGeneratorIsolationTests
```

Expected: PASS — `BriefGenerator` does not read `activity_frames`.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "test(core): add BriefGeneratorIsolationTests as future-proof guard"
```

---

## Task 9: Extract `BrowserTabReader` from `AutoWebCaptureService`

**Files:**
- Create: `Sources/ProjectMemoryApp/BrowserTabReader.swift`
- Create: `Sources/ProjectMemoryApp/Activity/AutomationAttemptLog.swift`
- Modify: `Sources/ProjectMemoryApp/AutoWebCaptureService.swift`
- Create: `Tests/ProjectMemoryAppTests/BrowserTabReaderTests.swift`
- Create: `Tests/ProjectMemoryAppTests/AutomationAttemptLogTests.swift`

- [ ] **Step 1: Create `Activity/` directory**

```bash
mkdir -p "Sources/ProjectMemoryApp/Activity"
```

- [ ] **Step 2: Write failing tests for `AutomationAttemptLog`**

Create `Tests/ProjectMemoryAppTests/AutomationAttemptLogTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryApp

final class AutomationAttemptLogTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "AutomationAttemptLogTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testInitialOutcomeIsNotAttempted() {
        let log = AutomationAttemptLog(defaults: defaults)
        XCTAssertEqual(log.outcome(forBundleID: "com.apple.Safari"), .notAttempted)
    }

    func testRecordSuccessThenFailureOverwrites() {
        let log = AutomationAttemptLog(defaults: defaults)
        log.recordSuccess(bundleID: "com.apple.Safari", at: Date(timeIntervalSince1970: 1))
        log.recordFailure(bundleID: "com.apple.Safari", at: Date(timeIntervalSince1970: 2), reason: "denied")

        if case .failure(let at, let reason) = log.outcome(forBundleID: "com.apple.Safari") {
            XCTAssertEqual(at.timeIntervalSince1970, 2)
            XCTAssertEqual(reason, "denied")
        } else {
            XCTFail("Expected .failure outcome")
        }
    }

    func testMultipleBrowsersIsolated() {
        let log = AutomationAttemptLog(defaults: defaults)
        log.recordSuccess(bundleID: "com.apple.Safari", at: Date(timeIntervalSince1970: 1))
        log.recordFailure(bundleID: "com.google.Chrome", at: Date(timeIntervalSince1970: 2), reason: "x")

        if case .success(let at) = log.outcome(forBundleID: "com.apple.Safari") {
            XCTAssertEqual(at.timeIntervalSince1970, 1)
        } else { XCTFail() }
        if case .failure(let at, _) = log.outcome(forBundleID: "com.google.Chrome") {
            XCTAssertEqual(at.timeIntervalSince1970, 2)
        } else { XCTFail() }
    }

    func testPersistsAcrossInstances() {
        do {
            let log = AutomationAttemptLog(defaults: defaults)
            log.recordSuccess(bundleID: "com.apple.Safari", at: Date(timeIntervalSince1970: 5))
        }
        let log2 = AutomationAttemptLog(defaults: defaults)
        if case .success(let at) = log2.outcome(forBundleID: "com.apple.Safari") {
            XCTAssertEqual(at.timeIntervalSince1970, 5)
        } else { XCTFail() }
    }
}
```

- [ ] **Step 3: Run, verify FAIL**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter AutomationAttemptLogTests
```

Expected: FAIL.

- [ ] **Step 4: Implement `AutomationAttemptLog`**

Create `Sources/ProjectMemoryApp/Activity/AutomationAttemptLog.swift`:

```swift
import Foundation

internal enum AutomationOutcome: Equatable, Codable {
    case notAttempted
    case success(at: Date)
    case failure(at: Date, reason: String)
}

internal final class AutomationAttemptLog {
    private static let defaultsKey = "ProjectMemory.automationAttemptLog"

    private let defaults: UserDefaults
    private var cache: [String: AutomationOutcome]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: AutomationOutcome].self, from: data) {
            self.cache = decoded
        } else {
            self.cache = [:]
        }
    }

    func outcome(forBundleID bundleID: String) -> AutomationOutcome {
        cache[bundleID] ?? .notAttempted
    }

    func recordSuccess(bundleID: String, at: Date = Date()) {
        cache[bundleID] = .success(at: at)
        persist()
    }

    func recordFailure(bundleID: String, at: Date = Date(), reason: String) {
        cache[bundleID] = .failure(at: at, reason: reason)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
```

- [ ] **Step 5: Run, verify PASS**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter AutomationAttemptLogTests
```

Expected: PASS, 4 cases.

- [ ] **Step 6: Write failing tests for `BrowserTabReader`**

Create `Tests/ProjectMemoryAppTests/BrowserTabReaderTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryApp
@testable import ProjectMemoryCore

final class BrowserTabReaderTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "BrowserTabReaderTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testUnsupportedBundleIDThrows() {
        let log = AutomationAttemptLog(defaults: defaults)
        let reader = OSABrowserTabReader(attemptLog: log)
        XCTAssertThrowsError(try reader.readActiveTab(bundleID: "com.unknown.app"))
    }
}
```

> Note: real osascript success/failure paths can only be exercised against a live macOS environment with a target browser running and Automation permission granted/denied. Those paths are covered by the manual smoke test (Task 17). Here we only test the structurally testable case (unsupported bundle ID).

- [ ] **Step 7: Run, verify FAIL**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter BrowserTabReaderTests
```

Expected: FAIL — `BrowserTabReader` undefined.

- [ ] **Step 8: Create `BrowserTabReader.swift`**

Create `Sources/ProjectMemoryApp/BrowserTabReader.swift`:

```swift
import Foundation
import ProjectMemoryCore

internal protocol BrowserTabReader {
    func readActiveTab(bundleID: String) throws -> (title: String, url: String)
}

internal enum BrowserTabReaderError: LocalizedError, Equatable {
    case unsupportedBrowser
    case noActiveTab
    case osaFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .unsupportedBrowser:
            return "当前 bundle ID 不在支持的浏览器列表中。"
        case .noActiveTab:
            return "无法读取当前浏览器标签页，请检查自动化权限。"
        case .osaFailed(let s):
            return "osascript 执行失败 (status=\(s))。"
        }
    }
}

internal final class OSABrowserTabReader: BrowserTabReader {
    private let attemptLog: AutomationAttemptLog

    init(attemptLog: AutomationAttemptLog) {
        self.attemptLog = attemptLog
    }

    func readActiveTab(bundleID: String) throws -> (title: String, url: String) {
        guard let dialect = SupportedBrowsers.dialect(for: bundleID) else {
            throw BrowserTabReaderError.unsupportedBrowser
        }

        let script: String
        switch dialect {
        case .safari:
            script = """
            tell application id "\(bundleID)"
                if not (exists front document) then return ""
                return (name of front document) & linefeed & (URL of front document)
            end tell
            """
        case .chromium:
            script = """
            tell application id "\(bundleID)"
                if not (exists front window) then return ""
                set activeTab to active tab of front window
                return (title of activeTab) & linefeed & (URL of activeTab)
            end tell
            """
        }

        do {
            let output = try runOSA(script)
            let lines = output
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .map(String.init)
            guard lines.count == 2,
                  !lines[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                attemptLog.recordFailure(bundleID: bundleID, reason: "no active tab")
                throw BrowserTabReaderError.noActiveTab
            }
            attemptLog.recordSuccess(bundleID: bundleID)
            return (
                title: lines[0].trimmingCharacters(in: .whitespacesAndNewlines),
                url: lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch let BrowserTabReaderError.osaFailed(status) {
            attemptLog.recordFailure(bundleID: bundleID, reason: "osascript failed status=\(status)")
            throw BrowserTabReaderError.osaFailed(status: status)
        } catch {
            attemptLog.recordFailure(bundleID: bundleID, reason: "\(error)")
            throw error
        }
    }

    private func runOSA(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BrowserTabReaderError.osaFailed(status: process.terminationStatus)
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 9: Run, verify PASS**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter BrowserTabReaderTests
```

Expected: PASS, 1 case.

- [ ] **Step 10: Refactor `AutoWebCaptureService` to use `BrowserTabReader`**

Open `Sources/ProjectMemoryApp/AutoWebCaptureService.swift`. Replace the entire content with:

```swift
import AppKit
import Foundation
import ProjectMemoryCore

struct AutoWebCaptureResult: Equatable {
    var title: String
    var url: String
    var browserName: String
    var capturedAt: Date

    var textSnapshot: String {
        """
        自动网页捕获
        浏览器：\(browserName)
        标题：\(title)
        URL：\(url)
        捕获时间：\(ISO8601DateFormatter().string(from: capturedAt))
        """
    }
}

enum AutoWebCaptureError: LocalizedError {
    case noSupportedBrowser
    case readerFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noSupportedBrowser:
            return "当前前台应用不是受支持的浏览器。"
        case .readerFailed(let underlying):
            return (underlying as? LocalizedError)?.errorDescription
                ?? "无法读取当前浏览器标签页。"
        }
    }
}

struct AutoWebCaptureService {
    private let reader: BrowserTabReader

    init(reader: BrowserTabReader) {
        self.reader = reader
    }

    func captureActiveBrowser() throws -> AutoWebCaptureResult {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              SupportedBrowsers.dialect(for: bundleID) != nil
        else {
            throw AutoWebCaptureError.noSupportedBrowser
        }

        let displayName = app.localizedName
            ?? app.bundleURL?.lastPathComponent
            ?? "Browser"

        do {
            let tab = try reader.readActiveTab(bundleID: bundleID)
            return AutoWebCaptureResult(
                title: tab.title,
                url: tab.url,
                browserName: displayName,
                capturedAt: Date()
            )
        } catch {
            throw AutoWebCaptureError.readerFailed(error)
        }
    }
}
```

- [ ] **Step 11: Update `AppState` to construct `AutoWebCaptureService` with reader**

In `Sources/ProjectMemoryApp/AppState.swift`, add a private property:

```swift
private let automationAttemptLog = AutomationAttemptLog()
private lazy var browserTabReader: BrowserTabReader = OSABrowserTabReader(attemptLog: automationAttemptLog)
```

Find the call site of `AutoWebCaptureService()` (in `captureActiveBrowserOnce`):

```swift
Result { try AutoWebCaptureService().captureActiveBrowser() }
```

Replace with:

```swift
Result { try AutoWebCaptureService(reader: self.browserTabReader).captureActiveBrowser() }
```

- [ ] **Step 12: Update `AutoWebCaptureTests` to use stub reader composition**

In `Tests/ProjectMemoryAppTests/AutoWebCaptureTests.swift`, the file should currently retain only one or two test functions after Task 1 + Task 7 cleanup. Add at the end:

```swift
final class StubBrowserTabReader: BrowserTabReader {
    var result: Result<(title: String, url: String), Error>
    init(result: Result<(title: String, url: String), Error>) { self.result = result }
    func readActiveTab(bundleID: String) throws -> (title: String, url: String) {
        try result.get()
    }
}
```

Make sure `import ProjectMemoryApp` is present (with `@testable`).

- [ ] **Step 13: Run all tests + build**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build --disable-sandbox --scratch-path .build
```

Expected: all green.

- [ ] **Step 14: Commit**

```bash
git add -A && git commit -m "refactor(app): extract BrowserTabReader + AutomationAttemptLog, AutoWebCaptureService uses injected reader"
```

---

## Task 10: Provider protocols (Idle / ScreenLock / FrontmostApp)

**Files:**
- Create: `Sources/ProjectMemoryApp/Activity/Providers.swift`

- [ ] **Step 1: Create `Providers.swift`**

```swift
import AppKit
import CoreGraphics
import Foundation

internal protocol IdleStateProvider {
    func secondsSinceLastUserInput() -> TimeInterval
}

internal protocol ScreenLockStateProvider {
    var isScreenLocked: Bool { get }
}

internal protocol FrontmostAppProvider {
    var frontmostBundleID: String? { get }
}

internal final class CGEventIdleStateProvider: IdleStateProvider {
    func secondsSinceLastUserInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)
    }
}

internal final class CGSessionScreenLockStateProvider: ScreenLockStateProvider {
    var isScreenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        return false
    }
}

internal final class WorkspaceFrontmostAppProvider: FrontmostAppProvider {
    var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
```

> Note: `secondsSinceLastEventType` API is wrapped here so tests inject stubs and don't depend on raw flags. Spec §6.4 explicitly does not lock the raw value into the design.

- [ ] **Step 2: Verify build**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build --disable-sandbox --scratch-path .build
```

Expected: build clean.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(app): add IdleStateProvider / ScreenLockStateProvider / FrontmostAppProvider"
```

---

## Task 11: `ActivityTickScheduler`

**Files:**
- Create: `Sources/ProjectMemoryApp/Activity/ActivityTickScheduler.swift`

- [ ] **Step 1: Create the scheduler protocol + Timer impl**

```swift
import Foundation

internal protocol ActivityTickScheduler {
    func start(onTick: @escaping () -> Void)
    func stop()
}

internal final class TimerTickScheduler: ActivityTickScheduler {
    private let interval: TimeInterval
    private var timer: Timer?

    init(interval: TimeInterval = 60) {
        self.interval = interval
    }

    func start(onTick: @escaping () -> Void) {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { _ in onTick() }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
```

- [ ] **Step 2: Verify build**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build --disable-sandbox --scratch-path .build
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(app): add ActivityTickScheduler protocol + TimerTickScheduler"
```

---

## Task 12: `ActivityCandidateCollector`

**Files:**
- Create: `Sources/ProjectMemoryApp/Activity/ActivityCandidateCollector.swift`

- [ ] **Step 1: Define protocol + macOS impl**

Create `Sources/ProjectMemoryApp/Activity/ActivityCandidateCollector.swift`:

```swift
import AppKit
import ApplicationServices
import Foundation
import ProjectMemoryCore

internal protocol ActivityCandidateCollecting {
    func collect(now: Date) -> ActivityCandidate?
}

internal final class MacOSActivityCandidateCollector: ActivityCandidateCollecting {
    private let frontmostAppProvider: FrontmostAppProvider
    private let browserTabReader: BrowserTabReader

    init(
        frontmostAppProvider: FrontmostAppProvider,
        browserTabReader: BrowserTabReader
    ) {
        self.frontmostAppProvider = frontmostAppProvider
        self.browserTabReader = browserTabReader
    }

    func collect(now: Date) -> ActivityCandidate? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else {
            return nil
        }
        let appName = app.localizedName
            ?? app.bundleURL?.lastPathComponent
            ?? bundleID

        var windowTitle: String? = nil
        var browserURL: String? = nil

        if SupportedBrowsers.dialect(for: bundleID) != nil {
            // Browser branch — title and URL are bound. If URL read fails, drop both.
            if let tab = try? browserTabReader.readActiveTab(bundleID: bundleID) {
                windowTitle = tab.title
                browserURL = tab.url
            }
        } else {
            // Non-browser branch — title from AX, best-effort.
            windowTitle = readFrontWindowTitle(for: app.processIdentifier)
        }

        return ActivityCandidate(
            observedAt: now,
            bundleID: bundleID,
            appName: TextSanitizer.stripInvisibleControls(appName),
            windowTitle: windowTitle.map { TextSanitizer.stripInvisibleControls($0) },
            browserURL: browserURL.map { TextSanitizer.stripInvisibleControls($0) }
        )
    }

    private func readFrontWindowTitle(for pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused
        else {
            return nil
        }
        let windowElement = window as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String,
              !title.isEmpty
        else {
            return nil
        }
        return title
    }
}
```

- [ ] **Step 2: Verify build**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build --disable-sandbox --scratch-path .build
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(app): add ActivityCandidateCollecting + macOS impl with browser title binding + sanitize"
```

---

## Task 13: `ActivityCoordinator`

**Files:**
- Create: `Sources/ProjectMemoryApp/Activity/ActivityCoordinator.swift`
- Create: `Tests/ProjectMemoryAppTests/ActivityCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests (with all stubs)**

Create `Tests/ProjectMemoryAppTests/ActivityCoordinatorTests.swift`:

```swift
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
    var bundleID: String?
    var frontmostBundleID: String? { bundleID }
}

private final class StubActivityCandidateCollector: ActivityCandidateCollecting {
    var nextCandidate: ActivityCandidate?
    init(nextCandidate: ActivityCandidate? = nil) { self.nextCandidate = nextCandidate }
    func collect(now: Date) -> ActivityCandidate? { nextCandidate }
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
        let coordinator = ActivityCoordinator(
            isRuntimeEnabled: { runtimeEnabled },
            isUserEnabled: { userEnabled },
            scheduler: scheduler,
            idleStateProvider: StubIdleStateProvider(seconds: idleSeconds),
            screenLockStateProvider: StubScreenLockStateProvider(locked: locked),
            frontmostAppProvider: StubFrontmostAppProvider(bundleID: frontmost),
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

    func testCollectorReturnsNilSkipsWrite() throws {
        let store = try MemoryStore.inMemory()
        let (coordinator, scheduler, _) = makeCoordinator(
            candidate: nil,
            store: store
        )
        coordinator.start()
        scheduler.fire()
        XCTAssertEqual(try store.fetchActivityFrames().count, 0)
    }
}
```

- [ ] **Step 2: Run, verify FAIL**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter ActivityCoordinatorTests
```

Expected: FAIL — `ActivityCoordinator` undefined.

- [ ] **Step 3: Implement `ActivityCoordinator`**

Create `Sources/ProjectMemoryApp/Activity/ActivityCoordinator.swift`:

```swift
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
            Task { @MainActor in self?.tick() }
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
        guard frontmostAppProvider.frontmostBundleID != selfBundleID else { return }

        let currentNow = now()
        guard let candidate = collector.collect(now: currentNow) else { return }

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
```

- [ ] **Step 4: Run, verify PASS**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter ActivityCoordinatorTests
```

Expected: PASS, 8 cases.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(app): add @MainActor ActivityCoordinator with full guard chain"
```

---

## Task 14: `ActivityRetentionGC`

**Files:**
- Create: `Sources/ProjectMemoryApp/Activity/ActivityRetentionGC.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import ProjectMemoryCore

internal final class ActivityRetentionGC {
    static let defaultRetentionDays = 30

    private let store: MemoryStore
    private let retentionDays: Int
    private let now: () -> Date

    init(
        store: MemoryStore,
        retentionDays: Int = ActivityRetentionGC.defaultRetentionDays,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.retentionDays = retentionDays
        self.now = now
    }

    /// Synchronously delete frames older than retention window. Safe to call from main actor.
    func runOnce() {
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        try? store.deleteActivityFrames(beforeDate: cutoff)
    }
}
```

- [ ] **Step 2: Verify build**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build --disable-sandbox --scratch-path .build
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(app): add ActivityRetentionGC.runOnce()"
```

---

## Task 15: `AppState` integration — toggle, extraDenied, coordinator lifecycle, GC

**Files:**
- Modify: `Sources/ProjectMemoryApp/AppState.swift`
- Create: `Tests/ProjectMemoryAppTests/ActivitySettingsTests.swift`

- [ ] **Step 1: Write failing tests for `extraDenied` input validation**

Create `Tests/ProjectMemoryAppTests/ActivitySettingsTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryApp
@testable import ProjectMemoryCore

@MainActor
final class ActivitySettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "ActivitySettingsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAddRejectsEmptyAfterTrim() {
        var list: [String] = []
        let result = ActivitySettings.tryAddExtraDeniedBundleID("   \n", current: list)
        if case .rejectedEmpty = result {} else { XCTFail("\(result)") }
        if case .added(_, let next) = result { list = next }
        XCTAssertEqual(list, [])
    }

    func testAddRejectsAlreadyInDefaults() {
        let result = ActivitySettings.tryAddExtraDeniedBundleID("com.1password.1password", current: [])
        if case .rejectedAlreadyInDefaults = result {} else { XCTFail("\(result)") }
    }

    func testAddRejectsDuplicate() {
        let result = ActivitySettings.tryAddExtraDeniedBundleID("com.example.private",
                                                                current: ["com.example.private"])
        if case .rejectedDuplicate = result {} else { XCTFail("\(result)") }
    }

    func testAddSuccessTrimsAndSanitizes() {
        let result = ActivitySettings.tryAddExtraDeniedBundleID("  com.example.x\u{200B}\n", current: [])
        if case .added(let cleaned, let next) = result {
            XCTAssertEqual(cleaned, "com.example.x")
            XCTAssertEqual(next, ["com.example.x"])
        } else { XCTFail("\(result)") }
    }
}
```

- [ ] **Step 2: Run, verify FAIL**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter ActivitySettingsTests
```

Expected: FAIL — `ActivitySettings` undefined.

- [ ] **Step 3: Add `ActivitySettings` namespace + integrate into `AppState`**

In `Sources/ProjectMemoryApp/AppState.swift`, add at the top (or in a new file `Sources/ProjectMemoryApp/Activity/ActivitySettings.swift` if you prefer; for this plan we keep it inline in AppState.swift for simplicity):

```swift
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
```

Then add `@Published` state + lifecycle methods in `AppState`. Append:

```swift
// In AppState class:

@Published var activityCaptureEnabled: Bool = false
@Published var activityExtraDenied: [String] = []

private static let activityToggleKey = "ProjectMemory.activityCaptureEnabled"
private static let activityExtraDeniedKey = "ProjectMemory.activityExtraDeniedBundleIDs"

private var activityCoordinator: ActivityCoordinator?
private lazy var activityRetentionGC = ActivityRetentionGC(store: store)

var isActivityFeatureEnvOn: Bool {
    Self.isActivityFeatureEnvOn
}

private static var isActivityFeatureEnvOn: Bool {
    ProcessInfo.processInfo.environment["PROJECT_MEMORY_ENABLE_ACTIVITY_CAPTURE"] == "1"
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
        let log = automationAttemptLog
        let reader = browserTabReader
        let collector = MacOSActivityCandidateCollector(
            frontmostAppProvider: frontmost,
            browserTabReader: reader
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
        // ensure log unused warning suppressed
        _ = log
    case (false, .some(let coordinator)):
        coordinator.stop()
        activityCoordinator = nil
    default:
        break
    }
}

func clearAllActivityFrames() {
    do {
        try store.deleteActivityFrames(beforeDate: Date.distantFuture)
    } catch {
        errorMessage = "Could not clear activity frames: \(error.localizedDescription)"
    }
}
```

In `init()`, after the existing `reload()` call, append:
```swift
loadActivitySettings()
syncActivityCoordinator()
DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
    self?.activityRetentionGC.runOnce()
}
```

(The `DispatchQueue` 5s delay matches spec §6.10.)

- [ ] **Step 4: Run, verify PASS**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build --filter ActivitySettingsTests
```

Expected: PASS, 4 cases.

- [ ] **Step 5: Run all tests + build**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build --disable-sandbox --scratch-path .build
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(app): wire ActivityCoordinator + extraDenied + retention GC into AppState"
```

---

## Task 16: Settings UI — `ActivitySection`

**Files:**
- Create: `Sources/ProjectMemoryApp/Views/Settings/ActivitySection.swift`
- Modify: `Sources/ProjectMemoryApp/Views/SettingsView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI
import ProjectMemoryCore

struct ActivitySection: View {
    @EnvironmentObject private var appState: AppState
    @State private var newBundleID: String = ""
    @State private var addError: String?
    @State private var debugReadout: String = "—"

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

            Text("Phase 1 调试")
                .font(.subheadline.bold())
            Text(debugReadout).font(.caption)
            Button("刷新") { refreshDebug() }

            Divider()

            Button(role: .destructive) {
                appState.clearAllActivityFrames()
                refreshDebug()
            } label: {
                Label("清除所有活动记录", systemImage: "trash")
            }
        }
        .onAppear { refreshDebug() }
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
```

- [ ] **Step 2: Embed in `SettingsView.swift`**

In `Sources/ProjectMemoryApp/Views/SettingsView.swift`, add:

```swift
ActivitySection()
```

inside the existing `Form` (place it after the existing OpenRouter / Storage sections).

- [ ] **Step 3: Verify build**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build --disable-sandbox --scratch-path .build
```

Expected: build clean.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(app): add ActivitySection settings UI with toggle, extraDenied, debug readout"
```

---

## Task 17: Final verification + manual smoke test prep

**Files:** none (verification only)

- [ ] **Step 1: Full test run**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift test --disable-sandbox --scratch-path .build 2>&1 | tail -5
```

Expected: total approximately 47 (existing) + ~46 (new) = ~93 tests, 0 failures.

- [ ] **Step 2: Build clean**

```bash
env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build --disable-sandbox --scratch-path .build 2>&1 | grep -iE "warning|error" | grep -v "user.*cache" || echo "build clean"
```

Expected: `build clean` (no deprecated warnings, no errors).

- [ ] **Step 3: Migration completeness checks**

```bash
rg "AutoWebCaptureDenyList" Sources Tests Package.swift
rg "normalizeURLForDedup" Sources Tests Package.swift
rg "struct SupportedBrowser " Sources Tests
```

Expected: 0 matches each.

- [ ] **Step 4: Existing dogfood path unbroken (regression sanity)**

Set the existing auto-web-capture flag and confirm Phase A behavior is unchanged:

```bash
PROJECT_MEMORY_ENABLE_AUTO_WEB_CAPTURE=1 env CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift run ProjectMemoryApp --help 2>&1 | head -5 || true
```

(This invocation is informational only — the app is GUI; the goal is no link errors at startup. If it crashes immediately, it's a regression.)

- [ ] **Step 5: Manual smoke test — the part requiring a real Mac**

Per spec §7.5:

```bash
# 1. Clean slate
sqlite3 "$HOME/Library/Application Support/ProjectMemory/memory.sqlite" "DELETE FROM activity_frames;"

# 2. Run with both env flags on (so manual web capture also still works during smoke)
PROJECT_MEMORY_ENABLE_ACTIVITY_CAPTURE=1 swift run ProjectMemoryApp
```

Walk through:
1. Settings → 启用活动记录 (toggle on)
2. Switch to Chrome on `https://swift.org`, stay 60+ seconds
3. Switch to Slack, stay 60+ seconds
4. Switch back to ProjectMemoryApp; debug readout should show ≥2 frames; SQLite query:
   ```sql
   SELECT bundle_id, app_name, category, browser_url
   FROM activity_frames ORDER BY observed_at DESC LIMIT 5;
   ```
   Expect Slack row `category='chat'` and Chrome row `category='work'`, `browser_url='https://swift.org'` (or normalized form).
5. Stay in ProjectMemoryApp 60s. SQLite count should NOT increase (self-pause).
6. Switch to Slack and stay idle (no input) 6 minutes. The first ~5 min should produce frames; after idle ≥ 5min the next tick should NOT add a row. Verify last Slack frame `observed_at` is at most ~5min after entering Slack.
7. Quit, restart without env flag: Settings should not show Activity toggle (or show it disabled with the env flag banner).

- [ ] **Step 6: Commit final verification status**

```bash
git add -A && git commit --allow-empty -m "chore: Phase 1 activity metadata capture verification complete"
```

---

## Self-Review

### Spec coverage check

Tracing each spec section against tasks:

- **§2 Non-goals**: enforced by Tasks 1-17 not introducing OCR / screenshots / brief integration / project assignment / etc.
- **§3 Decision Log**: each decision is materialized in code by specific tasks (Q1 by Task 15 wiring; Q2 by Task 2 `projectID: UUID?`; Q3 by Task 6 classifier; Q4 by absence of OCR; Q5 by Task 13 coordinator guards; Q6 by Task 3 schema; Q7 by Tasks 1, 4)
- **§4 Architecture**: implemented across Tasks 9-15
- **§5.1 types**: Task 2 ✓
- **§5.2 SQLite schema**: Task 3 ✓
- **§5.4 store API + filter semantics**: Task 3 (with explicit boundary tests)
- **§5.5 URLDenyList migration**: Task 1 ✓
- **§5.6 ActivityDenyList**: Task 4 ✓
- **§5.7 skip not persisted**: enforced by `ActivityCoordinator.tick` (Task 13) — only writes on `.capture`
- **§6.1-6.4 hard / capability gates, providers**: Task 10 + Task 13 ✓
- **§6.5 AutomationAttemptLog**: Task 9 ✓
- **§6.6 BrowserTabReader**: Task 9 ✓
- **§6.7 Settings UI**: Task 16 ✓
- **§6.8 extraDenied input validation**: Task 15 ✓
- **§6.9 live start/stop**: Task 15 (`syncActivityCoordinator`) ✓
- **§6.10 retention GC**: Task 14 + Task 15 ✓
- **§6.11/§6.12 Phase 2/1.5 placeholders**: deliberately NOT implemented; spec acknowledges
- **§7.4 done criteria**: Task 17 covers all 6 items
- **§7.5 manual smoke**: Task 17 step 5 ✓
- **§8.2 BriefGeneratorIsolationTests**: Task 8 ✓
- **§8.3 mock catalog**: provided inline in Task 13 tests
- **§8.4 collector protocol injection**: Task 13 init signature ✓
- **§9 implementation reminders**: Coordinator `@MainActor` (Task 13), `internal` visibility throughout (Tasks 9-13), smoke test pre-clear (Task 17 step 5)

No gaps identified.

### Placeholder scan

Searched the plan for "TBD", "TODO", "implement later", "fill in", "similar to", "appropriate". Found one self-reference in Task 6 Step 3 ("Note: this references `SupportedBrowsers` which is created in Task 7") but that ships actual fallback code inline. Acceptable.

### Type consistency

- `ActivityCandidate` field names (`observedAt`, `bundleID`, `appName`, `windowTitle`, `browserURL`) — same across Tasks 2, 5, 6, 12, 13
- `ActivityFrame` field names (`id`, `observedAt`, `bundleID`, `appName`, `windowTitle`, `browserURL`, `category`, `projectID`) — same across Tasks 2, 3, 13
- `ActivityCategory` cases (`work`, `socialMedia`, `chat`, `other`) — consistent
- `ProjectFilter` (`any`, `unassigned`, `project(UUID)`) — consistent
- `ActivityGate.Decision` (`capture`, `skip(reason: String)`) — consistent
- `URLDenyList.isDenied(_:)` / `URLDenyList.normalizeForDedup(_:)` — consistent
- `ActivityDenyList.defaultBundleIDs` / `ActivityDenyList.isDenied(bundleID:extraDenied:)` — consistent
- `SupportedBrowsers.bundleIDs` / `SupportedBrowsers.dialect(for:)` / `SupportedBrowsers.Dialect` — consistent
- `BrowserTabReader.readActiveTab(bundleID:)` returning `(title: String, url: String)` — consistent
- `AutomationAttemptLog.recordSuccess(bundleID:at:)` / `.recordFailure(bundleID:at:reason:)` / `.outcome(forBundleID:)` — consistent
- `ActivityTickScheduler.start(onTick:)` / `.stop()` — consistent
- `ActivityCandidateCollecting.collect(now:)` — consistent
- `ActivityCoordinator` init signature — consistent across Task 13 tests and impl

No drift detected.
