import Foundation

public enum MemoryStoreError: Error, Equatable {
    case invalidRow(String)
}

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
                id: try row.uuid("id"),
                name: try row.text("name"),
                rootPath: try row.text("root_path"),
                createdAt: try row.date("created_at", formatter: iso)
            )
        }
    }

    public func findProject(rootPath: String) throws -> Project? {
        try fetchProjects().first { project in
            URL(fileURLWithPath: project.rootPath).standardizedFileURL.path ==
                URL(fileURLWithPath: rootPath).standardizedFileURL.path
        }
    }

    public func deleteProject(id: UUID) throws {
        try database.execute("DELETE FROM briefs WHERE project_id = ?", values: [.text(id.uuidString)])
        try database.execute("DELETE FROM timeline_events WHERE project_id = ?", values: [.text(id.uuidString)])
        try database.execute("DELETE FROM sources WHERE project_id = ?", values: [.text(id.uuidString)])
        try database.execute("DELETE FROM projects WHERE id = ?", values: [.text(id.uuidString)])
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
            rows = try database.query(
                "SELECT * FROM sources WHERE project_id = ? ORDER BY modified_at DESC",
                values: [.text(projectID.uuidString)]
            )
        } else {
            rows = try database.query("SELECT * FROM sources ORDER BY modified_at DESC")
        }

        return try rows.map { row in
            MemorySource(
                id: try row.uuid("id"),
                projectID: try row.optionalUUID("project_id"),
                kind: SourceKind(rawValue: try row.text("kind")) ?? .unsupported,
                title: try row.text("title"),
                path: try row.text("path"),
                url: try row.optionalText("url"),
                extractedText: try row.text("extracted_text"),
                modifiedAt: try row.date("modified_at", formatter: iso),
                indexedAt: try row.date("indexed_at", formatter: iso)
            )
        }
    }

    public func findSource(projectID: UUID, path: String) throws -> MemorySource? {
        try fetchSources(projectID: projectID).first { source in
            source.path == path
        }
    }

    public func deleteSource(id: UUID) throws {
        try database.execute("DELETE FROM timeline_events WHERE source_id = ?", values: [.text(id.uuidString)])
        try database.execute("DELETE FROM sources WHERE id = ?", values: [.text(id.uuidString)])
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

    public func fetchTimeline(projectID: UUID, limit: Int? = nil, since: Date? = nil) throws -> [TimelineEvent] {
        var sql = "SELECT * FROM timeline_events WHERE project_id = ?"
        var values: [SQLiteValue] = [.text(projectID.uuidString)]
        if let since {
            sql += " AND occurred_at >= ?"
            values.append(.text(iso.string(from: since)))
        }
        sql += " ORDER BY occurred_at DESC"
        if let limit {
            sql += " LIMIT ?"
            values.append(.integer(Int64(limit)))
        }

        return try database.query(sql, values: values).map { row in
            TimelineEvent(
                id: try row.uuid("id"),
                projectID: try row.uuid("project_id"),
                sourceID: try row.optionalUUID("source_id"),
                kind: TimelineEventKind(rawValue: try row.text("kind")) ?? .sourceUpdated,
                title: try row.text("title"),
                summary: try row.text("summary"),
                occurredAt: try row.date("occurred_at", formatter: iso)
            )
        }
    }

    public func saveBrief(_ brief: Brief) throws {
        let sourceIDs = try JSONEncoder().encode(brief.sourceIDs.map(\.uuidString))
        try database.execute(
            """
            INSERT OR REPLACE INTO briefs
            (id, project_id, title, body, source_ids, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            values: [
                .text(brief.id.uuidString),
                brief.projectID.map { .text($0.uuidString) } ?? .null,
                .text(brief.title),
                .text(brief.body),
                .text(String(data: sourceIDs, encoding: .utf8) ?? "[]"),
                .text(iso.string(from: brief.createdAt))
            ]
        )
    }

    public func fetchLatestBrief(projectID: UUID? = nil) throws -> Brief? {
        let rows: [[String: SQLiteValue]]
        if let projectID {
            rows = try database.query(
                "SELECT * FROM briefs WHERE project_id = ? ORDER BY created_at DESC LIMIT 1",
                values: [.text(projectID.uuidString)]
            )
        } else {
            rows = try database.query("SELECT * FROM briefs ORDER BY created_at DESC LIMIT 1")
        }
        return try rows.first.map(brief(from:))
    }

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

    public func deleteActivityFrames(beforeDate: Date) throws {
        try database.execute(
            "DELETE FROM activity_frames WHERE observed_at < ?",
            values: [.text(iso.string(from: beforeDate))]
        )
    }

    public func deleteAllActivityFrames() throws {
        try database.execute("DELETE FROM activity_frames")
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
        try database.execute("""
        CREATE TABLE IF NOT EXISTS briefs (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            source_ids TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
        """)
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
    }

    private func brief(from row: [String: SQLiteValue]) throws -> Brief {
        let rawSourceIDs = try row.text("source_ids")
        guard let sourceIDStrings = try? JSONDecoder().decode([String].self, from: Data(rawSourceIDs.utf8)) else {
            throw MemoryStoreError.invalidRow("source_ids")
        }
        return Brief(
            id: try row.uuid("id"),
            projectID: try row.optionalUUID("project_id"),
            title: try row.text("title"),
            body: try row.text("body"),
            sourceIDs: sourceIDStrings.compactMap(UUID.init(uuidString:)),
            createdAt: try row.date("created_at", formatter: iso)
        )
    }
}

private extension Dictionary where Key == String, Value == SQLiteValue {
    func text(_ key: String) throws -> String {
        guard case .text(let value) = self[key] else {
            throw MemoryStoreError.invalidRow(key)
        }
        return value
    }

    func optionalText(_ key: String) throws -> String? {
        guard let value = self[key] else {
            throw MemoryStoreError.invalidRow(key)
        }
        switch value {
        case .text(let string):
            return string
        case .null:
            return nil
        case .integer, .real:
            throw MemoryStoreError.invalidRow(key)
        }
    }

    func uuid(_ key: String) throws -> UUID {
        let value = try text(key)
        guard let uuid = UUID(uuidString: value) else {
            throw MemoryStoreError.invalidRow(key)
        }
        return uuid
    }

    func optionalUUID(_ key: String) throws -> UUID? {
        guard let value = try optionalText(key) else {
            return nil
        }
        guard let uuid = UUID(uuidString: value) else {
            throw MemoryStoreError.invalidRow(key)
        }
        return uuid
    }

    func date(_ key: String, formatter: ISO8601DateFormatter) throws -> Date {
        let value = try text(key)
        guard let date = formatter.date(from: value) else {
            throw MemoryStoreError.invalidRow(key)
        }
        return date
    }
}
