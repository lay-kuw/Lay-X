import Foundation
import SQLite3

/// Errors surfaced by the SQLite layer. Messages never include bound values (they may contain chat content).
public enum DatabaseError: Error, Equatable, Sendable {
    case open(code: Int32, message: String)
    case prepare(code: Int32, message: String)
    case step(code: Int32, message: String)
    case migration(version: Int, message: String)
    case closed
}

/// A value that can be bound to / read from a SQLite statement.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var int: Int64? { if case .int(let v) = self { v } else { nil } }
    public var double: Double? {
        switch self {
        case .double(let v): v
        case .int(let v): Double(v)
        default: nil
        }
    }
    public var text: String? { if case .text(let v) = self { v } else { nil } }
    public var blob: Data? { if case .blob(let v) = self { v } else { nil } }
}

/// One result row, addressed by column name.
public struct SQLRow: Sendable {
    public let values: [String: SQLValue]
    public subscript(_ column: String) -> SQLValue { values[column] ?? .null }
}

/// A schema migration. Versions are applied in ascending order inside one transaction each and
/// recorded in `PRAGMA user_version`.
public struct Migration: Sendable {
    public let version: Int
    public let sql: String
    public init(version: Int, sql: String) {
        self.version = version
        self.sql = sql
    }
}

/// Serialized access to one SQLite connection. All reads and writes go through this actor, so writes are
/// naturally ordered; the connection is opened in `SQLITE_OPEN_FULLMUTEX` mode as a second line of defense.
public actor SQLiteDatabase {
    private var handle: OpaquePointer?
    public nonisolated let location: Location

    public enum Location: Sendable, Equatable {
        case file(URL)
        case inMemory
    }

    /// SQLITE_TRANSIENT: tells SQLite to copy bound buffers before the call returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(location: Location, migrations: [Migration]) throws {
        self.location = location
        let path: String
        switch location {
        case .file(let url):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            path = url.path
        case .inMemory:
            path = ":memory:"
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw DatabaseError.open(code: rc, message: message)
        }
        handle = db
        try Self.exec(db, "PRAGMA foreign_keys = ON;")
        if case .file = location {
            try Self.exec(db, "PRAGMA journal_mode = WAL;")
            // Overwrite deleted content so unpinned/deleted chat text doesn't linger in free pages.
            try Self.exec(db, "PRAGMA secure_delete = ON;")
        }
        try Self.migrate(db, migrations)
    }

    isolated deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    // MARK: Public API

    /// Executes a statement that returns no rows.
    public func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        guard let db = handle else { throw DatabaseError.closed }
        let stmt = try Self.prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        try Self.bind(db, stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError.step(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Runs a query and returns all rows.
    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        guard let db = handle else { throw DatabaseError.closed }
        let stmt = try Self.prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        try Self.bind(db, stmt, params)
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DatabaseError.step(code: rc, message: String(cString: sqlite3_errmsg(db)))
            }
            rows.append(Self.readRow(stmt))
        }
        return rows
    }

    /// Runs `body` inside a transaction; rolls back if it throws.
    public func transaction<T: Sendable>(_ body: @Sendable (isolated SQLiteDatabase) throws -> T) throws -> T {
        guard let db = handle else { throw DatabaseError.closed }
        try Self.exec(db, "BEGIN IMMEDIATE;")
        do {
            let value = try body(self)
            try Self.exec(db, "COMMIT;")
            return value
        } catch {
            try? Self.exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// Writes a compact, consistent copy of the whole database to `url` (must not exist).
    public func copy(to url: URL) throws {
        try execute("VACUUM INTO ?", [.text(url.path)])
    }

    public func userVersion() throws -> Int {
        Int(try query("PRAGMA user_version;").first?["user_version"].int ?? 0)
    }

    public func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    // MARK: Internals

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.step(code: rc, message: message)
        }
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DatabaseError.prepare(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private static func bind(_ db: OpaquePointer, _ stmt: OpaquePointer, _ params: [SQLValue]) throws {
        for (i, value) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), transient) }
            }
            guard rc == SQLITE_OK else {
                throw DatabaseError.prepare(code: rc, message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private static func readRow(_ stmt: OpaquePointer) -> SQLRow {
        var values: [String: SQLValue] = [:]
        for i in 0..<sqlite3_column_count(stmt) {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(stmt, i))
            case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(stmt, i))
                if let ptr = sqlite3_column_blob(stmt, i), count > 0 {
                    values[name] = .blob(Data(bytes: ptr, count: count))
                } else {
                    values[name] = .blob(Data())
                }
            default: values[name] = .null
            }
        }
        return SQLRow(values: values)
    }

    private static func migrate(_ db: OpaquePointer, _ migrations: [Migration]) throws {
        let stmt = try prepare(db, "PRAGMA user_version;")
        let current: Int = sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        sqlite3_finalize(stmt)
        for migration in migrations.sorted(by: { $0.version < $1.version }) where migration.version > current {
            do {
                try exec(db, "BEGIN IMMEDIATE;")
                try exec(db, migration.sql)
                try exec(db, "PRAGMA user_version = \(migration.version);")
                try exec(db, "COMMIT;")
            } catch {
                try? exec(db, "ROLLBACK;")
                throw DatabaseError.migration(version: migration.version, message: "\(error)")
            }
        }
    }
}
