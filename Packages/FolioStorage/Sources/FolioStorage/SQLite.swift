import Foundation
import CSQLite

public struct SQLiteError: Error, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

public enum SQLiteValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLiteBindable {
    var sqliteValue: SQLiteValue { get }
}

extension Int: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(Int64(self)) } }
extension Int64: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(self) } }
extension Double: SQLiteBindable { public var sqliteValue: SQLiteValue { .real(self) } }
extension String: SQLiteBindable { public var sqliteValue: SQLiteValue { .text(self) } }
extension Bool: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(self ? 1 : 0) } }
extension Data: SQLiteBindable { public var sqliteValue: SQLiteValue { .blob(self) } }
extension Date: SQLiteBindable { public var sqliteValue: SQLiteValue { .real(timeIntervalSince1970) } }
extension URL: SQLiteBindable { public var sqliteValue: SQLiteValue { .text(absoluteString) } }
extension Optional: SQLiteBindable where Wrapped: SQLiteBindable {
    public var sqliteValue: SQLiteValue { self?.sqliteValue ?? .null }
}

// SQLite copies bound text and blobs immediately with this destructor.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite connection. Not thread-safe by itself: `ArticleStore` (an
/// actor) owns it and serialises every call.
final class SQLiteConnection {
    private let db: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(code: status, message: message)
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL;")
        _ = try query("PRAGMA journal_mode = WAL") { $0.string(0) }
    }

    deinit { sqlite3_close_v2(db) }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version") { $0.int(0) }.first) ?? 0 }
    }

    func setUserVersion(_ version: Int) throws { try execute("PRAGMA user_version = \(version)") }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        if status != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw SQLiteError(code: status, message: message)
        }
    }

    func run(_ sql: String, _ bindings: [any SQLiteBindable] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw lastError(status) }
    }

    func query<T>(_ sql: String, _ bindings: [any SQLiteBindable] = [], _ map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw lastError(status) }
            results.append(try map(Row(statement: statement)))
        }
        return results
    }

    /// Prepares once and runs for every element; much faster for bulk writes.
    func runBatch<S: Sequence>(_ sql: String, _ items: S, bind: (S.Element) -> [any SQLiteBindable]) throws {
        var raw: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &raw, nil)
        guard status == SQLITE_OK, let statement = raw else { throw lastError(status) }
        defer { sqlite3_finalize(statement) }
        for item in items {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bindAll(statement, bind(item))
            let step = sqlite3_step(statement)
            guard step == SQLITE_DONE || step == SQLITE_ROW else { throw lastError(step) }
        }
    }

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

    var changes: Int { Int(sqlite3_changes(db)) }

    private func prepare(_ sql: String, _ bindings: [any SQLiteBindable]) throws -> OpaquePointer {
        var raw: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &raw, nil)
        guard status == SQLITE_OK, let statement = raw else { throw lastError(status) }
        do {
            try bindAll(statement, bindings)
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
        return statement
    }

    private func bindAll(_ statement: OpaquePointer, _ bindings: [any SQLiteBindable]) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value.sqliteValue {
            case .null: status = sqlite3_bind_null(statement, index)
            case .integer(let v): status = sqlite3_bind_int64(statement, index, v)
            case .real(let v): status = sqlite3_bind_double(statement, index, v)
            case .text(let v): status = sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                status = v.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
                }
            }
            guard status == SQLITE_OK else { throw lastError(status) }
        }
    }

    private func lastError(_ status: Int32) -> SQLiteError {
        SQLiteError(code: status, message: String(cString: sqlite3_errmsg(db)))
    }
}

struct Row {
    let statement: OpaquePointer

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(statement, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
    func bool(_ i: Int32) -> Bool { sqlite3_column_int64(statement, i) != 0 }

    func string(_ i: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, i) else { return nil }
        return String(cString: text)
    }

    func date(_ i: Int32) -> Date? { isNull(i) ? nil : Date(timeIntervalSince1970: double(i)) }
    func url(_ i: Int32) -> URL? { string(i).flatMap(URL.init(string:)) }
}
