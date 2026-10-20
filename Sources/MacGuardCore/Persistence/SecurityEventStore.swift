import Foundation
import SQLite3

public enum StoreError: Error { case open(String), exec(String) }

public struct OutboxItem: Equatable, Sendable {
    public var id: String          // idempotency key, e.g. "<incident>:initial"
    public var incidentID: UUID
    public var kind: String        // initial | location | status | test
    public var payload: Data
    public var attempts: Int
    public var nextAttempt: Date
    public var state: String       // pending | accepted | failed
    public var lastError: String?
}

/// SQLite persistence for events, incidents, the notification outbox, and last-known location.
/// Database directory is 0700 and the file 0600.
public final class SecurityEventStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL?) throws {
        if let path {
            let dir = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard sqlite3_open(path.path, &db) == SQLITE_OK else { throw StoreError.open(Self.msg(db)) }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } else {
            guard sqlite3_open(":memory:", &db) == SQLITE_OK else { throw StoreError.open(Self.msg(db)) }
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, ts REAL, type TEXT, result TEXT, incident TEXT, test INTEGER);
        CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
        CREATE TABLE IF NOT EXISTS incidents(id TEXT PRIMARY KEY, ts REAL, json BLOB);
        CREATE TABLE IF NOT EXISTS outbox(id TEXT PRIMARY KEY, incident TEXT, kind TEXT, payload BLOB, attempts INTEGER,
                                          next REAL, state TEXT, err TEXT);
        CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v BLOB);
        CREATE TABLE IF NOT EXISTS locations(ts REAL PRIMARY KEY, json BLOB);
        """)
    }
    deinit { sqlite3_close(db) }

    private static func msg(_ db: OpaquePointer?) -> String { db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown" }

    private func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.exec(Self.msg(db)) }
    }

    private func run(_ sql: String, _ bind: (OpaquePointer) -> Void = { _ in }) throws {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { throw StoreError.exec(Self.msg(db)) }
        defer { sqlite3_finalize(st) }
        bind(st)
        guard sqlite3_step(st) == SQLITE_DONE else { throw StoreError.exec(Self.msg(db)) }
    }

    private func query<T>(_ sql: String, _ bind: (OpaquePointer) -> Void = { _ in }, row: (OpaquePointer) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { throw StoreError.exec(Self.msg(db)) }
        defer { sqlite3_finalize(st) }
        bind(st)
        var out: [T] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(row(st)) }
        return out
    }

    private func text(_ st: OpaquePointer, _ i: Int32, _ v: String) { sqlite3_bind_text(st, i, v, -1, SQLITE_TRANSIENT) }
    private func blob(_ st: OpaquePointer, _ i: Int32, _ d: Data) {
        _ = d.withUnsafeBytes { sqlite3_bind_blob(st, i, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
    }
    private static func col(_ st: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
    private static func data(_ st: OpaquePointer, _ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(st, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(st, i)))
    }

    // MARK: Events
    public func append(_ e: SecurityEvent) throws {
        try run("INSERT OR REPLACE INTO events VALUES(?,?,?,?,?,?)") { st in
            text(st, 1, e.id.uuidString); sqlite3_bind_double(st, 2, e.timestamp.timeIntervalSince1970)
            text(st, 3, e.type.rawValue); text(st, 4, e.result)
            if let i = e.incidentID { text(st, 5, i.uuidString) } else { sqlite3_bind_null(st, 5) }
            sqlite3_bind_int(st, 6, e.isTest ? 1 : 0)
        }
    }

    public func events(limit: Int = 500) throws -> [SecurityEvent] {
        try query("SELECT id,ts,type,result,incident,test FROM events ORDER BY ts DESC LIMIT ?", { sqlite3_bind_int($0, 1, Int32(limit)) }) { st in
            SecurityEvent(id: UUID(uuidString: Self.col(st, 0)) ?? UUID(),
                          timestamp: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                          type: SecurityEventType(rawValue: Self.col(st, 2)) ?? .testEvent,
                          result: Self.col(st, 3), incidentID: UUID(uuidString: Self.col(st, 4)),
                          isTest: sqlite3_column_int(st, 5) == 1)
        }
    }

    public func purgeEvents(olderThan days: Int) throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        try run("DELETE FROM events WHERE ts < ?") { sqlite3_bind_double($0, 1, cutoff) }
    }
    public func clearEvents() throws { try exec("DELETE FROM events; DELETE FROM incidents;") }

    // MARK: Incidents
    public func save(_ i: Incident) throws {
        let d = try JSONEncoder.iso.encode(i)
        try run("INSERT OR REPLACE INTO incidents VALUES(?,?,?)") { st in
            text(st, 1, i.id.uuidString); sqlite3_bind_double(st, 2, i.createdAt.timeIntervalSince1970); blob(st, 3, d)
        }
    }
    public func incident(id: UUID) throws -> Incident? {
        try query("SELECT json FROM incidents WHERE id=?", { text($0, 1, id.uuidString) }) { st in
            try? JSONDecoder.iso.decode(Incident.self, from: Self.data(st, 0))
        }.compactMap { $0 }.first
    }
    public func incidents(limit: Int = 100) throws -> [Incident] {
        try query("SELECT json FROM incidents ORDER BY ts DESC LIMIT ?", { sqlite3_bind_int($0, 1, Int32(limit)) }) { st in
            try? JSONDecoder.iso.decode(Incident.self, from: Self.data(st, 0))
        }.compactMap { $0 }
    }

    // MARK: Outbox
    public func enqueue(_ item: OutboxItem) throws {
        try run("INSERT OR IGNORE INTO outbox VALUES(?,?,?,?,?,?,?,?)") { st in
            text(st, 1, item.id); text(st, 2, item.incidentID.uuidString); text(st, 3, item.kind); blob(st, 4, item.payload)
            sqlite3_bind_int(st, 5, Int32(item.attempts)); sqlite3_bind_double(st, 6, item.nextAttempt.timeIntervalSince1970)
            text(st, 7, item.state); sqlite3_bind_null(st, 8)
        }
    }
    public func outbox(state: String? = nil) throws -> [OutboxItem] {
        let sql = "SELECT id,incident,kind,payload,attempts,next,state,err FROM outbox" + (state == nil ? "" : " WHERE state=?") + " ORDER BY next"
        return try query(sql, { st in if let state { self.text(st, 1, state) } }) { st in
            OutboxItem(id: Self.col(st, 0), incidentID: UUID(uuidString: Self.col(st, 1)) ?? UUID(), kind: Self.col(st, 2),
                       payload: Self.data(st, 3), attempts: Int(sqlite3_column_int(st, 4)),
                       nextAttempt: Date(timeIntervalSince1970: sqlite3_column_double(st, 5)), state: Self.col(st, 6),
                       lastError: sqlite3_column_type(st, 7) == SQLITE_NULL ? nil : Self.col(st, 7))
        }
    }
    public func updateOutbox(id: String, state: String, attempts: Int, next: Date, error: String?) throws {
        try run("UPDATE outbox SET state=?,attempts=?,next=?,err=? WHERE id=?") { st in
            text(st, 1, state); sqlite3_bind_int(st, 2, Int32(attempts)); sqlite3_bind_double(st, 3, next.timeIntervalSince1970)
            if let error { text(st, 4, error) } else { sqlite3_bind_null(st, 4) }
            text(st, 5, id)
        }
    }

    // MARK: Key/value + location history
    public func setValue(_ key: String, _ value: Data?) throws {
        if let value { try run("INSERT OR REPLACE INTO kv VALUES(?,?)") { self.text($0, 1, key); self.blob($0, 2, value) } }
        else { try run("DELETE FROM kv WHERE k=?") { self.text($0, 1, key) } }
    }
    public func value(_ key: String) throws -> Data? {
        try query("SELECT v FROM kv WHERE k=?", { self.text($0, 1, key) }) { Self.data($0, 0) }.first
    }

    public func saveLocation(_ r: LocationRecord) throws {
        try run("INSERT OR REPLACE INTO locations VALUES(?,?)") { st in
            sqlite3_bind_double(st, 1, r.acquiredAt.timeIntervalSince1970)
            self.blob(st, 2, (try? JSONEncoder.iso.encode(r)) ?? Data())
        }
    }
    public func lastLocation() throws -> LocationRecord? {
        try query("SELECT json FROM locations ORDER BY ts DESC LIMIT 1", { _ in }) { try? JSONDecoder.iso.decode(LocationRecord.self, from: Self.data($0, 0)) }.compactMap { $0 }.first
    }
    public func purgeLocations(olderThan days: Int) throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        try run("DELETE FROM locations WHERE ts < ?") { sqlite3_bind_double($0, 1, cutoff) }
    }
    public func clearLocations() throws { try exec("DELETE FROM locations;") }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacGuard", isDirectory: true).appendingPathComponent("macguard.sqlite")
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
