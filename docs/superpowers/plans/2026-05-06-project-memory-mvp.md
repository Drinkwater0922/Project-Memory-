# Project Memory MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a dogfoodable SwiftUI Mac app that indexes local project folders, Markdown/PDF/web captures, and Git activity, then generates OpenRouter-powered daily briefs and project-scoped Q&A with source references.

**Architecture:** Use a native SwiftUI menu-bar-plus-window Mac app backed by focused Swift modules for source scanning, parsing, project memory storage, brief generation, and question answering. Store local metadata in SQLite through a tiny system SQLite wrapper, keep extracted text snapshots under Application Support, and call OpenRouter only with retrieved project-scoped context.

**Tech Stack:** Swift 5.10+, SwiftUI, Swift Package Manager, XCTest, SQLite3 system library, PDFKit, Foundation `URLSession`, OpenRouter Chat Completions API.

---

## Scope

This plan implements the first founder-only dogfood version. It intentionally excludes Feishu/DingTalk/WeCom API connectors, multi-user sync, full browser extensions, email/chat ingestion, local model support, and autonomous task execution.

Browser capture in this first round means:

- A native "Add Web Capture" form where the user pastes URL, title, and selected page text.
- An import flow for saved `.html` files from a watched folder.

This gives the app web-source memory immediately without waiting for Safari/Chrome extension packaging.

## File Structure

Create this repository structure from the empty workspace:

- `Package.swift`: SwiftPM package definition for app and tests.
- `Sources/ProjectMemoryApp/ProjectMemoryApp.swift`: SwiftUI app entry, menu bar extra, and window scene.
- `Sources/ProjectMemoryApp/AppState.swift`: Observable app state, selected project, brief text, and loading state.
- `Sources/ProjectMemoryApp/Views/RootView.swift`: Main window shell with Today, Projects, Sources, Ask, and Settings tabs.
- `Sources/ProjectMemoryApp/Views/TodayView.swift`: Daily brief UI and refresh action.
- `Sources/ProjectMemoryApp/Views/ProjectsView.swift`: Project list, project detail, and timeline surface.
- `Sources/ProjectMemoryApp/Views/SourcesView.swift`: Indexed source list and source import controls.
- `Sources/ProjectMemoryApp/Views/AskView.swift`: Project-scoped Q&A UI.
- `Sources/ProjectMemoryApp/Views/SettingsView.swift`: OpenRouter API key and local storage settings.
- `Sources/ProjectMemoryCore/Models.swift`: Domain models shared by parser, store, and UI.
- `Sources/ProjectMemoryCore/SQLiteDatabase.swift`: Minimal SQLite open/execute/query wrapper.
- `Sources/ProjectMemoryCore/MemoryStore.swift`: Schema creation and CRUD for projects, sources, events, settings, and answers.
- `Sources/ProjectMemoryCore/SourceScanner.swift`: Folder scan and supported file discovery.
- `Sources/ProjectMemoryCore/Parsers.swift`: Markdown/text/HTML/PDF text extraction.
- `Sources/ProjectMemoryCore/GitActivityReader.swift`: Recent Git commit and working-tree event extraction.
- `Sources/ProjectMemoryCore/ProjectResolver.swift`: Explicit folder/repo-to-project assignment and simple path-based resolver.
- `Sources/ProjectMemoryCore/OpenRouterClient.swift`: OpenRouter chat completion client.
- `Sources/ProjectMemoryCore/BriefGenerator.swift`: Daily/project brief prompt assembly and generation.
- `Sources/ProjectMemoryCore/AnswerEngine.swift`: Project-scoped retrieval and Q&A generation.
- `Tests/ProjectMemoryCoreTests/MemoryStoreTests.swift`: Storage and schema tests.
- `Tests/ProjectMemoryCoreTests/ParserTests.swift`: Markdown, HTML, and text extraction tests.
- `Tests/ProjectMemoryCoreTests/ProjectResolverTests.swift`: Project assignment tests.
- `Tests/ProjectMemoryCoreTests/PromptTests.swift`: Brief and Q&A prompt construction tests.

## Task 1: Scaffold Swift Package and Core Models

**Files:**

- Create: `Package.swift`
- Create: `Sources/ProjectMemoryCore/Models.swift`
- Create: `Tests/ProjectMemoryCoreTests/ProjectResolverTests.swift`

- [ ] **Step 1: Create the Swift package manifest**

Write `Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ProjectMemory",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ProjectMemoryApp", targets: ["ProjectMemoryApp"]),
        .library(name: "ProjectMemoryCore", targets: ["ProjectMemoryCore"])
    ],
    targets: [
        .target(
            name: "ProjectMemoryCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ProjectMemoryApp",
            dependencies: ["ProjectMemoryCore"]
        ),
        .testTarget(
            name: "ProjectMemoryCoreTests",
            dependencies: ["ProjectMemoryCore"]
        )
    ]
)
```

- [ ] **Step 2: Create domain models**

Write `Sources/ProjectMemoryCore/Models.swift`:

```swift
import Foundation

public struct Project: Identifiable, Equatable, Codable {
    public let id: UUID
    public var name: String
    public var rootPath: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, rootPath: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
    }
}

public enum SourceKind: String, Codable, CaseIterable {
    case markdown
    case pdf
    case html
    case text
    case gitCommit
    case webCapture
    case unsupported
}

public struct MemorySource: Identifiable, Equatable, Codable {
    public let id: UUID
    public var projectID: UUID?
    public var kind: SourceKind
    public var title: String
    public var path: String
    public var url: String?
    public var extractedText: String
    public var modifiedAt: Date
    public var indexedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID?,
        kind: SourceKind,
        title: String,
        path: String,
        url: String? = nil,
        extractedText: String,
        modifiedAt: Date,
        indexedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.title = title
        self.path = path
        self.url = url
        self.extractedText = extractedText
        self.modifiedAt = modifiedAt
        self.indexedAt = indexedAt
    }
}

public enum TimelineEventKind: String, Codable {
    case sourceAdded
    case sourceUpdated
    case gitCommit
    case questionAnswered
}

public struct TimelineEvent: Identifiable, Equatable, Codable {
    public let id: UUID
    public var projectID: UUID
    public var sourceID: UUID?
    public var kind: TimelineEventKind
    public var title: String
    public var summary: String
    public var occurredAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        sourceID: UUID?,
        kind: TimelineEventKind,
        title: String,
        summary: String,
        occurredAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.sourceID = sourceID
        self.kind = kind
        self.title = title
        self.summary = summary
        self.occurredAt = occurredAt
    }
}

public struct Brief: Identifiable, Equatable, Codable {
    public let id: UUID
    public var projectID: UUID?
    public var title: String
    public var body: String
    public var sourceIDs: [UUID]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID?,
        title: String,
        body: String,
        sourceIDs: [UUID],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.body = body
        self.sourceIDs = sourceIDs
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 3: Add a first resolver test that compiles the package**

Write `Tests/ProjectMemoryCoreTests/ProjectResolverTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryCore

final class ProjectResolverTests: XCTestCase {
    func testProjectModelKeepsRootPath() {
        let project = Project(name: "Project Memory", rootPath: "/Users/me/work/project-memory")

        XCTAssertEqual(project.name, "Project Memory")
        XCTAssertEqual(project.rootPath, "/Users/me/work/project-memory")
    }
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
swift test
```

Expected: package builds and `testProjectModelKeepsRootPath` passes.

## Task 2: Implement SQLite Storage

**Files:**

- Create: `Sources/ProjectMemoryCore/SQLiteDatabase.swift`
- Create: `Sources/ProjectMemoryCore/MemoryStore.swift`
- Create: `Tests/ProjectMemoryCoreTests/MemoryStoreTests.swift`

- [ ] **Step 1: Write storage tests**

Write `Tests/ProjectMemoryCoreTests/MemoryStoreTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryCore

final class MemoryStoreTests: XCTestCase {
    func testCreateAndFetchProject() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "Alpha", rootPath: "/tmp/alpha")

        try store.saveProject(project)
        let projects = try store.fetchProjects()

        XCTAssertEqual(projects, [project])
    }

    func testCreateSourceAndTimelineEvent() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "Alpha", rootPath: "/tmp/alpha")
        try store.saveProject(project)

        let source = MemorySource(
            projectID: project.id,
            kind: .markdown,
            title: "Plan",
            path: "/tmp/alpha/plan.md",
            extractedText: "Ship the first dogfood build.",
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        try store.saveSource(source)

        let event = TimelineEvent(
            projectID: project.id,
            sourceID: source.id,
            kind: .sourceAdded,
            title: "Plan indexed",
            summary: "Plan was indexed.",
            occurredAt: Date(timeIntervalSince1970: 101)
        )
        try store.saveTimelineEvent(event)

        XCTAssertEqual(try store.fetchSources(projectID: project.id), [source])
        XCTAssertEqual(try store.fetchTimeline(projectID: project.id), [event])
    }
}
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
swift test --filter MemoryStoreTests
```

Expected: FAIL because `MemoryStore` does not exist.

- [ ] **Step 3: Implement SQLite wrapper**

Write `Sources/ProjectMemoryCore/SQLiteDatabase.swift`:

```swift
import Foundation
import SQLite3

public enum SQLiteError: Error, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
}

public final class SQLiteDatabase {
    private var db: OpaquePointer?

    public init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw SQLiteError.openFailed(Self.message(db))
        }
    }

    deinit {
        sqlite3_close(db)
    }

    public func execute(_ sql: String, values: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(Self.message(db))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(Self.message(db))
        }
    }

    public func query(_ sql: String, values: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(Self.message(db))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)

        var rows: [[String: SQLiteValue]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                row[name] = SQLiteValue(statement: statement, index: index)
            }
            rows.append(row)
        }
        return rows
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let string):
                result = sqlite3_bind_text(statement, index, string, -1, SQLITE_TRANSIENT)
            case .integer(let int):
                result = sqlite3_bind_int64(statement, index, int)
            case .real(let double):
                result = sqlite3_bind_double(statement, index, double)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw SQLiteError.bindFailed(Self.message(db))
            }
        }
    }

    private static func message(_ db: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(db) else { return "Unknown SQLite error" }
        return String(cString: message)
    }
}

public enum SQLiteValue: Equatable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null

    init(statement: OpaquePointer?, index: Int32) {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_TEXT:
            self = .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_INTEGER:
            self = .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            self = .real(sqlite3_column_double(statement, index))
        default:
            self = .null
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
```

- [ ] **Step 4: Implement MemoryStore**

Write `Sources/ProjectMemoryCore/MemoryStore.swift`:

```swift
import Foundation

public final class MemoryStore {
    private let database: SQLiteDatabase
    private let iso = ISO8601DateFormatter()

    public init(path: String) throws {
        self.database = try SQLiteDatabase(path: path)
        try createSchema()
    }

    public static func inMemory() throws -> MemoryStore {
        try MemoryStore(path: ":memory:")
    }

    public func saveProject(_ project: Project) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO projects (id, name, root_path, created_at)
            VALUES (?, ?, ?, ?)
            """,
            values: [
                .text(project.id.uuidString),
                .text(project.name),
                .text(project.rootPath),
                .text(iso.string(from: project.createdAt))
            ]
        )
    }

    public func fetchProjects() throws -> [Project] {
        try database.query("SELECT * FROM projects ORDER BY created_at ASC").map { row in
            Project(
                id: UUID(uuidString: row.text("id"))!,
                name: row.text("name"),
                rootPath: row.text("root_path"),
                createdAt: iso.date(from: row.text("created_at"))!
            )
        }
    }

    public func saveSource(_ source: MemorySource) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO sources
            (id, project_id, kind, title, path, url, extracted_text, modified_at, indexed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            values: [
                .text(source.id.uuidString),
                source.projectID.map { .text($0.uuidString) } ?? .null,
                .text(source.kind.rawValue),
                .text(source.title),
                .text(source.path),
                source.url.map { .text($0) } ?? .null,
                .text(source.extractedText),
                .text(iso.string(from: source.modifiedAt)),
                .text(iso.string(from: source.indexedAt))
            ]
        )
    }

    public func fetchSources(projectID: UUID? = nil) throws -> [MemorySource] {
        let rows: [[String: SQLiteValue]]
        if let projectID {
            rows = try database.query("SELECT * FROM sources WHERE project_id = ? ORDER BY modified_at DESC", values: [.text(projectID.uuidString)])
        } else {
            rows = try database.query("SELECT * FROM sources ORDER BY modified_at DESC")
        }
        return rows.map { row in
            MemorySource(
                id: UUID(uuidString: row.text("id"))!,
                projectID: row.optionalText("project_id").flatMap(UUID.init(uuidString:)),
                kind: SourceKind(rawValue: row.text("kind")) ?? .unsupported,
                title: row.text("title"),
                path: row.text("path"),
                url: row.optionalText("url"),
                extractedText: row.text("extracted_text"),
                modifiedAt: iso.date(from: row.text("modified_at"))!,
                indexedAt: iso.date(from: row.text("indexed_at"))!
            )
        }
    }

    public func saveTimelineEvent(_ event: TimelineEvent) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO timeline_events
            (id, project_id, source_id, kind, title, summary, occurred_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            values: [
                .text(event.id.uuidString),
                .text(event.projectID.uuidString),
                event.sourceID.map { .text($0.uuidString) } ?? .null,
                .text(event.kind.rawValue),
                .text(event.title),
                .text(event.summary),
                .text(iso.string(from: event.occurredAt))
            ]
        )
    }

    public func fetchTimeline(projectID: UUID) throws -> [TimelineEvent] {
        try database.query(
            "SELECT * FROM timeline_events WHERE project_id = ? ORDER BY occurred_at DESC",
            values: [.text(projectID.uuidString)]
        ).map { row in
            TimelineEvent(
                id: UUID(uuidString: row.text("id"))!,
                projectID: UUID(uuidString: row.text("project_id"))!,
                sourceID: row.optionalText("source_id").flatMap(UUID.init(uuidString:)),
                kind: TimelineEventKind(rawValue: row.text("kind")) ?? .sourceUpdated,
                title: row.text("title"),
                summary: row.text("summary"),
                occurredAt: iso.date(from: row.text("occurred_at"))!
            )
        }
    }

    private func createSchema() throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            root_path TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS sources (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            path TEXT NOT NULL,
            url TEXT,
            extracted_text TEXT NOT NULL,
            modified_at TEXT NOT NULL,
            indexed_at TEXT NOT NULL
        )
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS timeline_events (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            source_id TEXT,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            occurred_at TEXT NOT NULL
        )
        """)
    }
}

private extension Dictionary where Key == String, Value == SQLiteValue {
    func text(_ key: String) -> String {
        guard case .text(let value) = self[key] else { return "" }
        return value
    }

    func optionalText(_ key: String) -> String? {
        guard case .text(let value) = self[key] else { return nil }
        return value
    }
}
```

- [ ] **Step 5: Run storage tests**

Run:

```bash
swift test --filter MemoryStoreTests
```

Expected: PASS.

## Task 3: Parse Local Files and Web Captures

**Files:**

- Create: `Sources/ProjectMemoryCore/Parsers.swift`
- Create: `Sources/ProjectMemoryCore/SourceScanner.swift`
- Create: `Tests/ProjectMemoryCoreTests/ParserTests.swift`

- [ ] **Step 1: Write parser tests**

Write `Tests/ProjectMemoryCoreTests/ParserTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryCore

final class ParserTests: XCTestCase {
    func testMarkdownParserKeepsReadableText() throws {
        let parser = SourceParser()
        let result = try parser.extractText(
            from: "Title\n\n- Ship MVP\n- Review sources".data(using: .utf8)!,
            fileExtension: "md"
        )

        XCTAssertTrue(result.contains("Ship MVP"))
        XCTAssertTrue(result.contains("Review sources"))
    }

    func testHTMLParserRemovesTags() throws {
        let parser = SourceParser()
        let result = try parser.extractText(
            from: "<html><body><h1>Article</h1><p>Useful context</p></body></html>".data(using: .utf8)!,
            fileExtension: "html"
        )

        XCTAssertTrue(result.contains("Article"))
        XCTAssertTrue(result.contains("Useful context"))
        XCTAssertFalse(result.contains("<p>"))
    }

    func testScannerFindsSupportedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try "ignore".write(to: root.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)

        let scanner = SourceScanner()
        let files = try scanner.scan(root: root)

        XCTAssertEqual(files.map(\.lastPathComponent), ["note.md"])
    }
}
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
swift test --filter ParserTests
```

Expected: FAIL because parser and scanner do not exist.

- [ ] **Step 3: Implement parsers**

Write `Sources/ProjectMemoryCore/Parsers.swift`:

```swift
import Foundation
import PDFKit

public enum ParserError: Error, Equatable {
    case unsupported(String)
    case unreadable
}

public final class SourceParser {
    public init() {}

    public func extractText(from data: Data, fileExtension: String) throws -> String {
        switch fileExtension.lowercased() {
        case "md", "markdown", "txt":
            return String(data: data, encoding: .utf8) ?? ""
        case "html", "htm":
            let html = String(data: data, encoding: .utf8) ?? ""
            return stripHTML(html)
        case "pdf":
            guard let document = PDFDocument(data: data) else { throw ParserError.unreadable }
            return (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
        default:
            throw ParserError.unsupported(fileExtension)
        }
    }

    private func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Implement source scanner**

Write `Sources/ProjectMemoryCore/SourceScanner.swift`:

```swift
import Foundation

public final class SourceScanner {
    private let supportedExtensions = Set(["md", "markdown", "txt", "pdf", "html", "htm"])

    public init() {}

    public func scan(root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    public func kind(for url: URL) -> SourceKind {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": return .markdown
        case "txt": return .text
        case "pdf": return .pdf
        case "html", "htm": return .html
        default: return .unsupported
        }
    }
}
```

- [ ] **Step 5: Run parser tests**

Run:

```bash
swift test --filter ParserTests
```

Expected: PASS.

## Task 4: Resolve Projects and Import Sources

**Files:**

- Create: `Sources/ProjectMemoryCore/ProjectResolver.swift`
- Modify: `Tests/ProjectMemoryCoreTests/ProjectResolverTests.swift`

- [ ] **Step 1: Replace resolver tests**

Write `Tests/ProjectMemoryCoreTests/ProjectResolverTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryCore

final class ProjectResolverTests: XCTestCase {
    func testResolverUsesProjectRootPath() {
        let project = Project(name: "Alpha", rootPath: "/Users/me/work/alpha")
        let resolver = ProjectResolver(projects: [project])

        let resolved = resolver.resolve(path: "/Users/me/work/alpha/notes/plan.md")

        XCTAssertEqual(resolved, project.id)
    }

    func testResolverReturnsNilForUnmatchedPath() {
        let project = Project(name: "Alpha", rootPath: "/Users/me/work/alpha")
        let resolver = ProjectResolver(projects: [project])

        XCTAssertNil(resolver.resolve(path: "/Users/me/other/beta.md"))
    }
}
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
swift test --filter ProjectResolverTests
```

Expected: FAIL because `ProjectResolver` does not exist.

- [ ] **Step 3: Implement project resolver**

Write `Sources/ProjectMemoryCore/ProjectResolver.swift`:

```swift
import Foundation

public final class ProjectResolver {
    private let projects: [Project]

    public init(projects: [Project]) {
        self.projects = projects
    }

    public func resolve(path: String) -> UUID? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return projects
            .sorted { $0.rootPath.count > $1.rootPath.count }
            .first { project in
                let root = URL(fileURLWithPath: project.rootPath).standardizedFileURL.path
                return standardized == root || standardized.hasPrefix(root + "/")
            }?
            .id
    }
}
```

- [ ] **Step 4: Run resolver tests**

Run:

```bash
swift test --filter ProjectResolverTests
```

Expected: PASS.

## Task 5: Read Git Activity

**Files:**

- Create: `Sources/ProjectMemoryCore/GitActivityReader.swift`

- [ ] **Step 1: Add Git activity reader**

Write `Sources/ProjectMemoryCore/GitActivityReader.swift`:

```swift
import Foundation

public final class GitActivityReader {
    public init() {}

    public func recentEvents(project: Project, limit: Int = 20) throws -> [TimelineEvent] {
        let repo = URL(fileURLWithPath: project.rootPath)
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) else {
            return []
        }

        let output = try runGit(
            arguments: ["log", "--pretty=format:%H%x1f%ad%x1f%s", "--date=iso-strict", "-n", "\(limit)"],
            directory: repo
        )

        return output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                guard parts.count == 3 else { return nil }
                let hash = String(parts[0])
                let date = ISO8601DateFormatter().date(from: String(parts[1])) ?? Date()
                let subject = String(parts[2])
                return TimelineEvent(
                    projectID: project.id,
                    sourceID: nil,
                    kind: .gitCommit,
                    title: subject,
                    summary: "Commit \(hash.prefix(8)): \(subject)",
                    occurredAt: date
                )
            }
    }

    private func runGit(arguments: [String], directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 2: Run all core tests**

Run:

```bash
swift test
```

Expected: PASS.

## Task 6: Add OpenRouter Client and Prompt Builders

**Files:**

- Create: `Sources/ProjectMemoryCore/OpenRouterClient.swift`
- Create: `Sources/ProjectMemoryCore/BriefGenerator.swift`
- Create: `Sources/ProjectMemoryCore/AnswerEngine.swift`
- Create: `Tests/ProjectMemoryCoreTests/PromptTests.swift`

- [ ] **Step 1: Write prompt tests**

Write `Tests/ProjectMemoryCoreTests/PromptTests.swift`:

```swift
import XCTest
@testable import ProjectMemoryCore

final class PromptTests: XCTestCase {
    func testDailyBriefPromptIncludesEvidence() {
        let project = Project(name: "Alpha", rootPath: "/tmp/alpha")
        let source = MemorySource(
            projectID: project.id,
            kind: .markdown,
            title: "Plan",
            path: "/tmp/alpha/plan.md",
            extractedText: "Need browser capture in first dogfood.",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )

        let prompt = BriefGenerator.makeDailyBriefPrompt(projects: [project], sources: [source], events: [])

        XCTAssertTrue(prompt.contains("Alpha"))
        XCTAssertTrue(prompt.contains("Need browser capture"))
        XCTAssertTrue(prompt.contains("来源"))
    }

    func testQuestionPromptIncludesQuestionAndSources() {
        let source = MemorySource(
            projectID: UUID(),
            kind: .html,
            title: "Article",
            path: "/tmp/article.html",
            url: "https://example.com",
            extractedText: "This project should restore context.",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )

        let prompt = AnswerEngine.makeQuestionPrompt(question: "上次做到哪了？", sources: [source])

        XCTAssertTrue(prompt.contains("上次做到哪了"))
        XCTAssertTrue(prompt.contains("This project should restore context"))
        XCTAssertTrue(prompt.contains("https://example.com"))
    }
}
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
swift test --filter PromptTests
```

Expected: FAIL because prompt builders do not exist.

- [ ] **Step 3: Implement OpenRouter client**

Write `Sources/ProjectMemoryCore/OpenRouterClient.swift`:

```swift
import Foundation

public struct OpenRouterClient {
    public var apiKey: String
    public var model: String
    public var appTitle: String

    public init(apiKey: String, model: String = "openai/gpt-4.1-mini", appTitle: String = "Project Memory") {
        self.apiKey = apiKey
        self.model = model
        self.appTitle = appTitle
    }

    public func complete(prompt: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appTitle, forHTTPHeaderField: "X-Title")

        let body = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: "你是 Project Memory，本地优先的项目记忆助手。回答必须简洁、具体，并引用来源。"),
                .init(role: "user", content: prompt)
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "OpenRouter request failed"
            throw OpenRouterError.requestFailed(message)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public enum OpenRouterError: Error, Equatable {
    case requestFailed(String)
}

private struct ChatRequest: Encodable {
    var model: String
    var messages: [ChatMessage]
}

private struct ChatMessage: Codable {
    var role: String
    var content: String
}

private struct ChatResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: ChatMessage
    }
}
```

- [ ] **Step 4: Implement prompt builders**

Write `Sources/ProjectMemoryCore/BriefGenerator.swift`:

```swift
import Foundation

public enum BriefGenerator {
    public static func makeDailyBriefPrompt(projects: [Project], sources: [MemorySource], events: [TimelineEvent]) -> String {
        let projectSection = projects.map { "- \($0.name): \($0.rootPath)" }.joined(separator: "\n")
        let sourceSection = sources.prefix(20).map { source in
            """
            来源: \(source.title)
            路径: \(source.path)
            内容片段: \(source.extractedText.prefix(1200))
            """
        }.joined(separator: "\n\n")
        let eventSection = events.prefix(30).map { event in
            "- \(event.title): \(event.summary)"
        }.joined(separator: "\n")

        return """
        请基于以下本地项目资料生成今日项目简报。

        要求：
        - 用中文输出。
        - 先列出 1-3 个今天最值得继续的项目动作。
        - 说明每个项目最近发生了什么。
        - 标出可能被遗忘的 TODO 或未闭环问题。
        - 每条关键结论都要写出来源标题或路径。
        - 不要编造来源中没有的信息。

        项目：
        \(projectSection)

        时间线事件：
        \(eventSection)

        来源资料：
        \(sourceSection)
        """
    }
}
```

Write `Sources/ProjectMemoryCore/AnswerEngine.swift`:

```swift
import Foundation

public enum AnswerEngine {
    public static func makeQuestionPrompt(question: String, sources: [MemorySource]) -> String {
        let sourceSection = sources.prefix(12).map { source in
            """
            标题: \(source.title)
            路径: \(source.path)
            URL: \(source.url ?? "无")
            内容片段: \(source.extractedText.prefix(1500))
            """
        }.joined(separator: "\n\n")

        return """
        用户问题：\(question)

        请只基于下列项目来源回答。要求：
        - 用中文回答。
        - 直接回答问题，不要泛泛解释。
        - 如果证据不足，明确说证据不足。
        - 每个关键结论后写出来源标题、路径或 URL。

        项目来源：
        \(sourceSection)
        """
    }
}
```

- [ ] **Step 5: Run prompt tests**

Run:

```bash
swift test --filter PromptTests
```

Expected: PASS.

## Task 7: Build SwiftUI App Shell

**Files:**

- Create: `Sources/ProjectMemoryApp/ProjectMemoryApp.swift`
- Create: `Sources/ProjectMemoryApp/AppState.swift`
- Create: `Sources/ProjectMemoryApp/Views/RootView.swift`
- Create: `Sources/ProjectMemoryApp/Views/TodayView.swift`
- Create: `Sources/ProjectMemoryApp/Views/ProjectsView.swift`
- Create: `Sources/ProjectMemoryApp/Views/SourcesView.swift`
- Create: `Sources/ProjectMemoryApp/Views/AskView.swift`
- Create: `Sources/ProjectMemoryApp/Views/SettingsView.swift`

- [ ] **Step 1: Create app state**

Write `Sources/ProjectMemoryApp/AppState.swift`:

```swift
import Foundation
import ProjectMemoryCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [Project] = []
    @Published var sources: [MemorySource] = []
    @Published var selectedProjectID: UUID?
    @Published var dailyBrief: String = "还没有生成今日简报。"
    @Published var question: String = ""
    @Published var answer: String = ""
    @Published var openRouterAPIKey: String = UserDefaults.standard.string(forKey: "openrouter_api_key") ?? ""
    @Published var isLoading: Bool = false

    let store: MemoryStore

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProjectMemory", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.store = try! MemoryStore(path: appSupport.appendingPathComponent("memory.sqlite").path)
        reload()
    }

    func reload() {
        projects = (try? store.fetchProjects()) ?? []
        sources = (try? store.fetchSources()) ?? []
        if selectedProjectID == nil {
            selectedProjectID = projects.first?.id
        }
    }

    func saveAPIKey() {
        UserDefaults.standard.set(openRouterAPIKey, forKey: "openrouter_api_key")
    }
}
```

- [ ] **Step 2: Create app entry**

Write `Sources/ProjectMemoryApp/ProjectMemoryApp.swift`:

```swift
import SwiftUI

@main
struct ProjectMemoryApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 680)
        }

        MenuBarExtra("Project Memory", systemImage: "brain.head.profile") {
            Button("打开 Project Memory") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Text(state.dailyBrief.prefix(180))
            Divider()
            Button("刷新数据") {
                state.reload()
            }
        }
    }
}
```

- [ ] **Step 3: Create root and views**

Write `Sources/ProjectMemoryApp/Views/RootView.swift`:

```swift
import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("今日", systemImage: "sun.max") }
            ProjectsView()
                .tabItem { Label("项目", systemImage: "folder") }
            SourcesView()
                .tabItem { Label("来源", systemImage: "doc.text") }
            AskView()
                .tabItem { Label("提问", systemImage: "questionmark.bubble") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gear") }
        }
        .padding()
    }
}
```

Write `Sources/ProjectMemoryApp/Views/TodayView.swift`:

```swift
import ProjectMemoryCore
import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            H1("今日项目记忆")
            ScrollView {
                Text(state.dailyBrief)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            Button(state.isLoading ? "生成中..." : "生成今日简报") {
                Task { await generateBrief() }
            }
            .disabled(state.isLoading || state.openRouterAPIKey.isEmpty)
        }
    }

    private func generateBrief() async {
        state.isLoading = true
        defer { state.isLoading = false }
        let prompt = BriefGenerator.makeDailyBriefPrompt(projects: state.projects, sources: state.sources, events: [])
        do {
            state.dailyBrief = try await OpenRouterClient(apiKey: state.openRouterAPIKey).complete(prompt: prompt)
        } catch {
            state.dailyBrief = "生成失败：\(error.localizedDescription)"
        }
    }
}

struct H1: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title.bold())
    }
}
```

Write `Sources/ProjectMemoryApp/Views/ProjectsView.swift`:

```swift
import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            List(state.projects, selection: $state.selectedProjectID) { project in
                Text(project.name)
            }
        } detail: {
            if let project = state.projects.first(where: { $0.id == state.selectedProjectID }) {
                VStack(alignment: .leading, spacing: 12) {
                    H1(project.name)
                    Text(project.rootPath).foregroundStyle(.secondary).textSelection(.enabled)
                    List(state.sources.filter { $0.projectID == project.id }) { source in
                        VStack(alignment: .leading) {
                            Text(source.title).font(.headline)
                            Text(source.path).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            } else {
                ContentUnavailableView("还没有项目", systemImage: "folder.badge.plus")
            }
        }
    }
}
```

Write `Sources/ProjectMemoryApp/Views/SourcesView.swift`:

```swift
import SwiftUI

struct SourcesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            H1("来源")
            List(state.sources) { source in
                VStack(alignment: .leading) {
                    Text(source.title).font(.headline)
                    Text(source.kind.rawValue).font(.caption)
                    Text(source.path).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

Write `Sources/ProjectMemoryApp/Views/AskView.swift`:

```swift
import ProjectMemoryCore
import SwiftUI

struct AskView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            H1("项目提问")
            TextField("例如：这个项目我上次做到哪了？", text: $state.question)
                .textFieldStyle(.roundedBorder)
            Button(state.isLoading ? "回答中..." : "提问") {
                Task { await ask() }
            }
            .disabled(state.question.isEmpty || state.openRouterAPIKey.isEmpty || state.isLoading)
            ScrollView {
                Text(state.answer)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func ask() async {
        state.isLoading = true
        defer { state.isLoading = false }
        let scoped = state.selectedProjectID.map { id in state.sources.filter { $0.projectID == id } } ?? state.sources
        let prompt = AnswerEngine.makeQuestionPrompt(question: state.question, sources: scoped)
        do {
            state.answer = try await OpenRouterClient(apiKey: state.openRouterAPIKey).complete(prompt: prompt)
        } catch {
            state.answer = "回答失败：\(error.localizedDescription)"
        }
    }
}
```

Write `Sources/ProjectMemoryApp/Views/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            SecureField("OpenRouter API Key", text: $state.openRouterAPIKey)
            Button("保存 API Key") {
                state.saveAPIKey()
            }
            Text("本地索引默认存储在 Application Support/ProjectMemory。调用 OpenRouter 时只发送当前项目检索到的片段。")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
```

- [ ] **Step 4: Build app**

Run:

```bash
swift build
```

Expected: PASS.

## Task 8: Add Import Flows for Folder and Web Capture

**Files:**

- Modify: `Sources/ProjectMemoryApp/Views/SourcesView.swift`
- Modify: `Sources/ProjectMemoryApp/AppState.swift`

- [ ] **Step 1: Add import methods to AppState**

Modify `Sources/ProjectMemoryApp/AppState.swift` by adding these methods inside `AppState`:

```swift
func importFolder(_ url: URL, projectName: String) {
    do {
        let project = Project(name: projectName, rootPath: url.path)
        try store.saveProject(project)
        let scanner = SourceScanner()
        let parser = SourceParser()
        for file in try scanner.scan(root: url) {
            let data = try Data(contentsOf: file)
            let text = try parser.extractText(from: data, fileExtension: file.pathExtension)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            let modified = attrs[.modificationDate] as? Date ?? Date()
            let source = MemorySource(
                projectID: project.id,
                kind: scanner.kind(for: file),
                title: file.deletingPathExtension().lastPathComponent,
                path: file.path,
                extractedText: text,
                modifiedAt: modified
            )
            try store.saveSource(source)
            try store.saveTimelineEvent(TimelineEvent(
                projectID: project.id,
                sourceID: source.id,
                kind: .sourceAdded,
                title: source.title,
                summary: "索引来源：\(source.path)",
                occurredAt: modified
            ))
        }
        for event in try GitActivityReader().recentEvents(project: project) {
            try store.saveTimelineEvent(event)
        }
        reload()
    } catch {
        dailyBrief = "导入失败：\(error.localizedDescription)"
    }
}

func addWebCapture(title: String, url: String, text: String) {
    guard let selectedProjectID else { return }
    do {
        let source = MemorySource(
            projectID: selectedProjectID,
            kind: .webCapture,
            title: title.isEmpty ? url : title,
            path: "web-capture://\(UUID().uuidString)",
            url: url,
            extractedText: text,
            modifiedAt: Date()
        )
        try store.saveSource(source)
        try store.saveTimelineEvent(TimelineEvent(
            projectID: selectedProjectID,
            sourceID: source.id,
            kind: .sourceAdded,
            title: source.title,
            summary: "新增网页捕获：\(url)",
            occurredAt: Date()
        ))
        reload()
    } catch {
        dailyBrief = "保存网页捕获失败：\(error.localizedDescription)"
    }
}
```

- [ ] **Step 2: Replace SourcesView with import UI**

Write `Sources/ProjectMemoryApp/Views/SourcesView.swift`:

```swift
import SwiftUI

struct SourcesView: View {
    @EnvironmentObject private var state: AppState
    @State private var projectName: String = ""
    @State private var webTitle: String = ""
    @State private var webURL: String = ""
    @State private var webText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            H1("来源")
            HStack {
                TextField("项目名", text: $projectName)
                    .textFieldStyle(.roundedBorder)
                Button("导入文件夹") {
                    chooseFolder()
                }
                .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            GroupBox("网页捕获") {
                VStack(alignment: .leading) {
                    TextField("标题", text: $webTitle)
                    TextField("URL", text: $webURL)
                    TextEditor(text: $webText).frame(minHeight: 120)
                    Button("保存到当前项目") {
                        state.addWebCapture(title: webTitle, url: webURL, text: webText)
                        webTitle = ""
                        webURL = ""
                        webText = ""
                    }
                    .disabled(state.selectedProjectID == nil || webText.isEmpty)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.vertical, 6)
            }

            List(state.sources) { source in
                VStack(alignment: .leading) {
                    Text(source.title).font(.headline)
                    Text(source.kind.rawValue).font(.caption)
                    Text(source.path).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.importFolder(url, projectName: projectName)
            projectName = ""
        }
    }
}
```

- [ ] **Step 3: Build app**

Run:

```bash
swift build
```

Expected: PASS.

## Task 9: Dogfood Runbook

**Files:**

- Create: `docs/dogfood/project-memory-mvp-runbook.md`

- [ ] **Step 1: Create dogfood runbook**

Write `docs/dogfood/project-memory-mvp-runbook.md`:

```markdown
# Project Memory MVP Dogfood Runbook

## Goal

Verify whether Project Memory can answer: "Before I resume a project, where did I leave off and what evidence supports that?"

## Setup

1. Build the app with `swift build`.
2. Run the app with `swift run ProjectMemoryApp`.
3. Open Settings and save an OpenRouter API key.
4. Choose one real active project folder that contains a Git repo and Markdown notes.
5. Import the folder from Sources.
6. Save 3-5 web captures related to the project.

## Daily Test

Before starting work, generate Today's brief and answer these questions:

- Does it correctly identify what changed recently?
- Does it mention sources I recognize?
- Does it avoid inventing facts?
- Does it suggest at least one useful next action?
- Does the Ask tab answer "这个项目我上次做到哪了？" better than my memory alone?

## Pass Criteria

- I open it at least 3 times in 7 days.
- At least 60% of briefs are worth reading.
- At least one answer saves 10+ minutes of context reconstruction.
- Wrong project/source assignment can be explained by missing or bad input, not random behavior.

## Notes Template

Date:
Project:
Brief usefulness, 1-5:
Best line:
Wrong or fabricated line:
Missing source:
Would I have paid for this moment:
```

- [ ] **Step 2: Run final checks**

Run:

```bash
swift test
swift build
```

Expected: both PASS.

## Self-Review

Spec coverage:

- SwiftUI native Mac app: Task 7.
- Local folders, Markdown/Obsidian, PDF, HTML/web capture, Git repo: Tasks 3, 5, 8.
- OpenRouter API key: Tasks 6, 7.
- Daily brief and Q&A together: Tasks 6, 7.
- Founder-only dogfood: Task 9.
- Local-first storage: Task 2.

Intentional gaps:

- Browser extension packaging is not included; MVP uses native web capture form and saved HTML import.
- Vector search is not included in the first dogfood build; prompt context uses the latest project sources. Add hybrid retrieval after dogfood confirms the brief is valuable.
- Feishu/DingTalk/WeCom connectors are excluded per MVP scope.

Placeholder scan:

- No TBD/TODO/FIXME placeholders are required for implementation.

Type consistency:

- `Project`, `MemorySource`, `TimelineEvent`, `Brief`, `MemoryStore`, `SourceScanner`, `SourceParser`, `BriefGenerator`, and `AnswerEngine` names are consistent across tasks.
