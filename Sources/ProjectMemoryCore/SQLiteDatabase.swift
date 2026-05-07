import Foundation
import SQLite3

public enum SQLiteError: Error, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
}

public enum SQLiteValue: Equatable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null

    init(statement: OpaquePointer?, index: Int32) {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else {
                self = .null
                return
            }
            self = .text(String(cString: text))
        case SQLITE_INTEGER:
            self = .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            self = .real(sqlite3_column_double(statement, index))
        case SQLITE_NULL:
            self = .null
        default:
            self = .null
        }
    }
}

public final class SQLiteDatabase {
    private var db: OpaquePointer?

    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let message = Self.message(db)
            sqlite3_close(db)
            db = nil
            throw SQLiteError.openFailed(message)
        }
        sqlite3_busy_timeout(db, 5_000)
        _ = try? query("PRAGMA journal_mode=WAL")
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
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                var row: [String: SQLiteValue] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    row[name] = SQLiteValue(statement: statement, index: index)
                }
                rows.append(row)
            case SQLITE_DONE:
                return rows
            default:
                throw SQLiteError.stepFailed(Self.message(db))
            }
        }
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32

            switch value {
            case .text(let string):
                result = sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
            case .integer(let integer):
                result = sqlite3_bind_int64(statement, index, integer)
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
        guard let message = sqlite3_errmsg(db) else {
            return "Unknown SQLite error"
        }
        return String(cString: message)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
