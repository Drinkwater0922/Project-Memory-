import Foundation

extension MemoryStore {
    public func writeActivitySession(_ resolved: ResolvedActivitySession) throws {
        let draft = resolved.draft
        let encodedTitleSamples = try JSONEncoder().encode(draft.titleSamples)
        guard let titleSamplesJSON = String(data: encodedTitleSamples, encoding: .utf8) else {
            throw MemoryStoreError.invalidRow("title_samples_json")
        }

        try database.execute(
            """
            INSERT OR REPLACE INTO activity_sessions
            (id, started_at, ended_at, bundle_id, app_name, browser_host, category,
             assignment_status, project_id, assignment_source, title_samples_json, frame_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            values: [
                .text(draft.id.uuidString),
                .text(iso.string(from: draft.startedAt)),
                .text(iso.string(from: draft.endedAt)),
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
                .text(iso.string(from: since)),
                .text(iso.string(from: until))
            ]
        )
        return try rows.map(persistedActivitySession(from:))
    }

    public func fetchActivitySessionIDs(since: Date, until: Date) throws -> [UUID] {
        let rows = try database.query(
            """
            SELECT id FROM activity_sessions
            WHERE ended_at >= ? AND started_at <= ?
            """,
            values: [
                .text(iso.string(from: since)),
                .text(iso.string(from: until))
            ]
        )
        return try rows.map { try activitySessionUUID("id", in: $0) }
    }

    public func deleteActivitySessions(ids: [UUID]) throws {
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
            ORDER BY ended_at DESC
            """,
            values: [
                .text(iso.string(from: since)),
                .text(iso.string(from: until))
            ]
        )

        return try rows.map { row in
            let statusRaw = try activitySessionText("assignment_status", in: row)
            guard let status = AssignmentStatus(rawValue: statusRaw) else {
                throw MemoryStoreError.invalidRow("assignment_status")
            }
            return PreservedAssignment(
                sessionID: try activitySessionUUID("id", in: row),
                assignmentStatus: status,
                projectID: try activitySessionOptionalUUID("project_id", in: row)
            )
        }
    }

    public func executeRawCountForTest(_ sql: String) throws -> Int {
        let rows = try database.query(sql)
        guard let row = rows.first, case .integer(let n) = row["n"] ?? .null else {
            return 0
        }
        return Int(n)
    }

    private func persistedActivitySession(from row: [String: SQLiteValue]) throws -> PersistedActivitySession {
        let titleSamplesRaw = try activitySessionText("title_samples_json", in: row)
        guard let titleSamples = try? JSONDecoder().decode([String].self, from: Data(titleSamplesRaw.utf8)) else {
            throw MemoryStoreError.invalidRow("title_samples_json")
        }
        guard let category = ActivityCategory(rawValue: try activitySessionText("category", in: row)) else {
            throw MemoryStoreError.invalidRow("category")
        }
        guard let status = AssignmentStatus(rawValue: try activitySessionText("assignment_status", in: row)) else {
            throw MemoryStoreError.invalidRow("assignment_status")
        }

        return PersistedActivitySession(
            id: try activitySessionUUID("id", in: row),
            startedAt: try activitySessionDate("started_at", in: row, formatter: iso),
            endedAt: try activitySessionDate("ended_at", in: row, formatter: iso),
            bundleID: try activitySessionText("bundle_id", in: row),
            appName: try activitySessionText("app_name", in: row),
            browserHost: try activitySessionOptionalText("browser_host", in: row),
            category: category,
            assignmentStatus: status,
            projectID: try activitySessionOptionalUUID("project_id", in: row),
            assignmentSource: try activitySessionOptionalText("assignment_source", in: row),
            titleSamples: titleSamples,
            frameCount: try activitySessionInt("frame_count", in: row)
        )
    }
}

private func activitySessionText(_ key: String, in row: [String: SQLiteValue]) throws -> String {
    guard case .text(let value) = row[key] else {
        throw MemoryStoreError.invalidRow(key)
    }
    return value
}

private func activitySessionOptionalText(_ key: String, in row: [String: SQLiteValue]) throws -> String? {
    guard let value = row[key] else {
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

private func activitySessionUUID(_ key: String, in row: [String: SQLiteValue]) throws -> UUID {
    let raw = try activitySessionText(key, in: row)
    guard let uuid = UUID(uuidString: raw) else {
        throw MemoryStoreError.invalidRow(key)
    }
    return uuid
}

private func activitySessionOptionalUUID(_ key: String, in row: [String: SQLiteValue]) throws -> UUID? {
    guard let raw = try activitySessionOptionalText(key, in: row) else {
        return nil
    }
    guard let uuid = UUID(uuidString: raw) else {
        throw MemoryStoreError.invalidRow(key)
    }
    return uuid
}

private func activitySessionDate(_ key: String, in row: [String: SQLiteValue], formatter: ISO8601DateFormatter) throws -> Date {
    let raw = try activitySessionText(key, in: row)
    guard let date = formatter.date(from: raw) else {
        throw MemoryStoreError.invalidRow(key)
    }
    return date
}

private func activitySessionInt(_ key: String, in row: [String: SQLiteValue]) throws -> Int {
    guard case .integer(let value) = row[key] else {
        throw MemoryStoreError.invalidRow(key)
    }
    return Int(value)
}
