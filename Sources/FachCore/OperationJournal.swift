import Foundation
import CryptoKit
import CSQLite
import Darwin

struct Fingerprint: Codable, Equatable, Sendable {
    var identity: String
    var size: Int64
    var modified: Date
    var digest: String
    init(_ url: URL) throws {
        let snapshot = try FileSafety.snapshot(url)
        guard !snapshot.isDirectory, !snapshot.isProtected else { throw FachError.message("Nur einzelne, ungeschützte Dateien können verschoben werden.") }
        let info = try FileSafety.stat(url)
        guard (info.st_mode & S_IFMT) == S_IFREG, !FileSafety.placeholder(url) else { throw FachError.message("Datei ist nicht lokal verfügbar.") }
        identity = snapshot.resourceID ?? ""; size = snapshot.size; modified = snapshot.modifiedAt
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty { hash.update(data: block) }
        digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let after = try FileSafety.snapshot(url)
        guard after.resourceID == identity, after.size == size, after.modifiedAt == modified else { throw FachError.message("Datei wurde während der Prüfung geändert.") }
    }
    func sameContent(as other: Fingerprint) -> Bool { size == other.size && digest == other.digest }
}

struct JournalRecord: Codable, Sendable {
    var runID: UUID
    var operation: PlannedOperation
    var sourceRoot: URL
    var destinationRoot: URL
    var state: OperationState
    var before: Fingerprint?
    var after: Fingerprint?
    var stage: URL?
    var undoPrepared: Bool = false
    var createdIdentity: String?
    var undoFingerprint: Fingerprint?
    var backupURL: URL?
    var backupFingerprint: Fingerprint?
    var trashBookmark: Data?
    var undoUsedBackup: Bool?
}

// SQLite is accessed only by the owning FileOperationService actor.
final class OperationJournal {
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            throw FachError.message("Verlauf konnte nicht geöffnet werden.")
        }
        sqlite3_busy_timeout(database, 5_000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS operations (key TEXT PRIMARY KEY, payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB NOT NULL);")
    }
    deinit { sqlite3_close(database) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw FachError.message("Verlauf konnte nicht gespeichert werden.") }
    }
    private func bind(_ data: Data, to statement: OpaquePointer, index: Int32) throws {
        let result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard result == SQLITE_OK else { throw FachError.message("Verlauf konnte nicht gespeichert werden.") }
    }
    func save(_ record: JournalRecord, event: RunEvent? = nil) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO operations(key,payload) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK, let statement else { throw FachError.message("Verlauf konnte nicht gespeichert werden.") }
            defer { sqlite3_finalize(statement) }
            let key = "\(record.runID.uuidString):\(record.operation.id.uuidString)"
            guard sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw FachError.message("Verlauf konnte nicht gespeichert werden.") }
            try bind(encoder.encode(record), to: statement, index: 2)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw FachError.message("Verlauf konnte nicht gespeichert werden.") }
            if let event {
                var eventStatement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "INSERT INTO events(payload) VALUES(?)", -1, &eventStatement, nil) == SQLITE_OK, let eventStatement else { throw FachError.message("Verlauf konnte nicht gespeichert werden.") }
                defer { sqlite3_finalize(eventStatement) }
                try bind(encoder.encode(event), to: eventStatement, index: 1)
                guard sqlite3_step(eventStatement) == SQLITE_DONE else { throw FachError.message("Verlauf konnte nicht gespeichert werden.") }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func read<T: Decodable>(_ query: String, as type: T.Type) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else { throw FachError.message("Verlauf konnte nicht gelesen werden.") }
        defer { sqlite3_finalize(statement) }
        var values: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw FachError.message("Verlauf ist nicht lesbar.") }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            values.append(try decoder.decode(type, from: data))
        }
    }
    func records() throws -> [JournalRecord] { try read("SELECT payload FROM operations ORDER BY rowid", as: JournalRecord.self) }
    func events() throws -> [RunEvent] { try read("SELECT payload FROM events ORDER BY sequence", as: RunEvent.self) }
}
