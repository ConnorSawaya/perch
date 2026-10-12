// SQLiteDatabase.swift — a very small wrapper around the SQLite library that ships with macOS.
//
// The usage ledger (UsageLedger.swift) keeps one row per API response and must stay small in
// memory however long the history gets, so it lives in a SQLite file instead of a JSON file.
// This wrapper only covers what the ledger needs: open, run a statement, bind values, read rows.
// It is not thread-safe; the ledger uses it from one queue.

import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    var message: String
    var description: String { "SQLite: \(message)" }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?
    /// Compiled statements, reused because the ledger runs the same few statements for every line.
    private var cache: [String: SQLiteStatement] = [:]

    /// Opens (creating if needed) the database at `path`. Pass ":memory:" for a throw-away one.
    init(path: String) throws {
        var db: OpaquePointer?
        let code = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(path)"
            sqlite3_close(db)
            throw SQLiteError(message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit { close() }

    func close() {
        cache.values.forEach { $0.finalize() }
        cache.removeAll()
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    /// Runs one or more statements that return nothing (schema, PRAGMA, BEGIN / COMMIT).
    func execute(_ sql: String) throws {
        guard let handle else { throw SQLiteError(message: "database is closed") }
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK { throw lastError() }
    }

    /// A compiled statement for `sql`, reset and ready for new bindings.
    func statement(_ sql: String) throws -> SQLiteStatement {
        if let cached = cache[sql] {
            cached.reset()
            return cached
        }
        guard let handle else { throw SQLiteError(message: "database is closed") }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &raw, nil) == SQLITE_OK, let raw else { throw lastError() }
        let statement = SQLiteStatement(raw: raw, database: self)
        cache[sql] = statement
        return statement
    }

    /// Runs `body` inside one transaction; rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    fileprivate func lastError() -> SQLiteError {
        SQLiteError(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed")
    }
}

/// One compiled statement. Bind with `bind`, then call `step()` until it returns false.
final class SQLiteStatement {
    private var raw: OpaquePointer?
    private unowned let database: SQLiteDatabase
    /// Tells SQLite to copy bound text, because Swift strings do not outlive the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate init(raw: OpaquePointer, database: SQLiteDatabase) {
        self.raw = raw
        self.database = database
    }

    fileprivate func finalize() {
        sqlite3_finalize(raw)
        raw = nil
    }

    /// Stops reading rows and makes the statement ready for reuse. Call it when leaving a
    /// result early; `step()` does it by itself after the last row.
    func reset() {
        sqlite3_reset(raw)
        sqlite3_clear_bindings(raw)
    }

    /// Binds values to the statement's "?" placeholders, in order.
    @discardableResult
    func bind(_ values: SQLiteValue...) -> SQLiteStatement {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(raw, index)
            case .int(let number): sqlite3_bind_int64(raw, index, number)
            case .real(let number): sqlite3_bind_double(raw, index, number)
            case .text(let text): sqlite3_bind_text(raw, index, text, -1, Self.transient)
            }
        }
        return self
    }

    /// Advances to the next row. Returns false when there are no more rows (or for a finished write).
    func step() throws -> Bool {
        switch sqlite3_step(raw) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            sqlite3_reset(raw)
            return false
        default:
            let error = database.lastError()
            sqlite3_reset(raw)
            throw error
        }
    }

    /// Runs a statement that returns no rows.
    func run() throws {
        while try step() {}
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(raw, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(raw, column) }
    func text(_ column: Int32) -> String { sqlite3_column_text(raw, column).map { String(cString: $0) } ?? "" }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(raw, column) == SQLITE_NULL }
}

enum SQLiteValue {
    case null
    case int(Int64)
    case real(Double)
    case text(String)

    static func integer(_ value: Int) -> SQLiteValue { .int(Int64(value)) }
    static func optionalText(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
}
