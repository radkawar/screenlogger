import Foundation
import SQLite3

public enum SQLiteError: Error, CustomStringConvertible, Sendable {
    case open(String)
    case exec(String)
    case prepare(String)
    case step(String)
    case bind(String)
    case notFound

    public var description: String {
        switch self {
        case .open(let m), .exec(let m), .prepare(let m), .step(let m), .bind(let m):
            return m
        case .notFound:
            return "row not found"
        }
    }
}

public struct SQLiteForeignKeyViolation: Equatable, Sendable {
    public let table: String
    public let rowID: Int64?
    public let parentTable: String
    public let constraintIndex: Int64
}

public struct SQLiteReadOnlyValidation: Equatable, Sendable {
    public let schemaVersion: Int
    public let integrityFailures: [String]
    public let foreignKeyViolationCount: Int

    public var isValid: Bool {
        integrityFailures.isEmpty && foreignKeyViolationCount == 0
    }
}

/// How SQLite returns pages that deletion freed. Libraries created before
/// Screenlogger enabled incremental auto-vacuum report `.none` and can only be
/// shrunk by `compactDatabaseFile()`.
public enum SQLiteAutoVacuumMode: Int, Sendable {
    case none = 0
    case full = 1
    case incremental = 2
}

public struct SQLiteFreeSpaceReclaim: Equatable, Sendable {
    /// Bytes handed back to the filesystem by this bounded pass.
    public let reclaimedBytes: Int64
    /// Bytes still parked on the free list after the pass.
    public let remainingFreeBytes: Int64
    /// False when the library predates incremental auto-vacuum, so a bounded
    /// pass can never reclaim anything until the file is rebuilt.
    public let isIncrementalVacuumAvailable: Bool
}

public struct SQLiteCompactionReport: Equatable, Sendable {
    public let bytesBefore: Int64
    public let bytesAfter: Int64

    public var reclaimedBytes: Int64 { max(0, bytesBefore - bytesAfter) }
}

public enum SQLiteMaintenanceError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case insufficientFreeSpace(requiredBytes: Int64, availableBytes: Int64)
    case freeSpaceUnavailable(String)
    case checkpointBlocked

    public var description: String {
        switch self {
        case .insufficientFreeSpace(let required, let available):
            return "Compacting needs \(required) free bytes; only \(available) are available"
        case .freeSpaceUnavailable(let detail):
            return "Could not measure free disk space before compacting: \(detail)"
        case .checkpointBlocked:
            return
                "An active reader prevented the database checkpoint. Space reclamation will retry later. Your history remains available."
        }
    }

    public var errorDescription: String? { description }
}

/// Connection the running thread must use. A `nil` handle pins the thread to
/// the writer, which is how a mutation keeps reading its own uncommitted rows
/// even when it is nested inside a read scope.
private final class SQLiteConnectionScope {
    let handle: OpaquePointer?

    init(handle: OpaquePointer?) {
        self.handle = handle
    }
}

/// Thin SQLite3 wrapper used by Screenlogger (no GRDB dependency).
public final class SQLiteDatabase: @unchecked Sendable {
    public private(set) var db: OpaquePointer?
    public let path: String
    /// Recursive because transactions call `exec`, and Store mutation helpers
    /// may compose inside maintenance transactions.
    private let mutationExecutor = NSRecursiveLock()
    /// WAL lets readers run while the writer commits, but only across separate
    /// connections. These are handed out for the duration of a read scope.
    private let readConnections = NSCondition()
    private var idleReadConnections: [OpaquePointer] = []
    private var openReadConnectionCount = 0
    private var readConnectionsClosed = false
    private let allowsSeparateReadConnections: Bool
    /// Store's read executor is serial, so one connection covers the UI path.
    /// The spare absorbs a read issued from another executor without letting a
    /// stall fan out into unbounded connections, each of which carries its own
    /// page cache.
    private static let maximumReadConnections = 2
    /// Thread-local connection scopes belong to one database instance. A
    /// process can briefly own two stores during import, restore, or tests; a
    /// shared key would let a nested read use the other store's handle.
    private let connectionScopeKey = "dev.screenlog.sqlite.connection-scope.\(UUID().uuidString)"
    private let writerConnectionScope = SQLiteConnectionScope(handle: nil)

    public init(path: String) throws {
        self.path = path
        self.allowsSeparateReadConnections = Self.pathSupportsSeparateConnections(path)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.open("Failed to open \(path): \(msg)")
        }
        db = handle
        // Must precede the first table: SQLite only records auto-vacuum in the
        // header of an empty database, and converting an existing library needs
        // a full VACUUM. New libraries therefore start able to return deleted
        // pages to the filesystem in bounded chunks; on an existing library the
        // pragma is a documented no-op.
        try exec("PRAGMA auto_vacuum = INCREMENTAL;")
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA busy_timeout = 5000;")
        try exec("PRAGMA foreign_keys = ON;")
        // Performance: larger page cache + mmap for timeline/FTS scans (local SSD typical).
        try exec("PRAGMA cache_size = -20000;")  // ~20MB
        try exec("PRAGMA temp_store = MEMORY;")
        try exec("PRAGMA mmap_size = 268435456;")  // 256MB
        try exec("PRAGMA recursive_triggers = ON;")
    }

    deinit {
        for handle in idleReadConnections {
            sqlite3_close(handle)
        }
        if let db {
            sqlite3_close(db)
        }
    }

    /// Close the connection deterministically before a coordinated Library
    /// replacement. Callers must first stop every operation that can prepare a
    /// statement or use this connection.
    public func close() throws {
        try withExclusiveMutation {
            try closeReadConnections()
            guard let handle = db else { return }
            let result = sqlite3_close(handle)
            guard result == SQLITE_OK else {
                throw SQLiteError.exec("Failed to close database: \(String(cString: sqlite3_errmsg(handle)))")
            }
            db = nil
        }
    }

    /// Execute a complete logical mutation while excluding every other writer
    /// using this database connection.
    public func withExclusiveMutation<T>(_ body: () throws -> T) rethrows -> T {
        mutationExecutor.lock()
        // Pin even an outermost mutation: a read scope opened by its body must
        // see uncommitted rows instead of checking out a separate connection.
        // Reuse the marker so nested exec/transaction calls do not allocate.
        let scopes = Thread.current.threadDictionary
        let enclosing = scopes[connectionScopeKey] as? SQLiteConnectionScope
        let needsScope = enclosing !== writerConnectionScope
        if needsScope {
            scopes[connectionScopeKey] = writerConnectionScope
        }
        defer {
            if needsScope {
                if let enclosing {
                    scopes[connectionScopeKey] = enclosing
                } else {
                    scopes.removeObject(forKey: connectionScopeKey)
                }
            }
            mutationExecutor.unlock()
        }
        return try body()
    }

    /// Run reads on a connection of their own so a long search never queues
    /// behind capture's writes. Statements prepared inside `body` must not
    /// outlive it, and a transaction must never span the scope boundary.
    public func withReadConnection<T>(_ body: () throws -> T) throws -> T {
        let scopes = Thread.current.threadDictionary
        // Already bound: a nested read reuses the enclosing connection, and a
        // read inside a mutation stays on the writer.
        guard scopes[connectionScopeKey] == nil else { return try body() }
        guard let handle = checkOutReadConnection() else { return try body() }
        scopes[connectionScopeKey] = SQLiteConnectionScope(handle: handle)
        defer {
            scopes.removeObject(forKey: connectionScopeKey)
            checkInReadConnection(handle)
        }
        return try body()
    }

    /// The handle the running thread must use: its read connection when it is
    /// inside a read scope, otherwise the single writer.
    private var activeHandle: OpaquePointer? {
        guard let scope = Thread.current.threadDictionary[connectionScopeKey] as? SQLiteConnectionScope
        else { return db }
        return scope.handle ?? db
    }

    public func exec(_ sql: String) throws {
        try withExclusiveMutation {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let message = err.map { String(cString: $0) } ?? "sqlite error \(rc)"
                sqlite3_free(err)
                throw SQLiteError.exec(message)
            }
        }
    }

    public func prepare(_ sql: String) throws -> OpaquePointer {
        let handle = activeHandle
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        return stmt!
    }

    public func lastInsertRowID() -> Int64 {
        sqlite3_last_insert_rowid(db)
    }

    public func changes() -> Int32 {
        sqlite3_changes(db)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try withExclusiveMutation {
            try exec("BEGIN IMMEDIATE;")
            do {
                let value = try body()
                try exec("COMMIT;")
                return value
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: - Read connections

    /// A `:memory:` (or unnamed temporary) database belongs to the connection
    /// that opened it, so a second handle would open an empty database instead
    /// of the one under test. Shared-cache memory URIs are excluded too rather
    /// than depending on the caller's cache settings.
    private static func pathSupportsSeparateConnections(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let lowered = path.lowercased()
        return !lowered.contains(":memory:") && !lowered.contains("mode=memory")
    }

    /// Returns `nil` when reads must fall back to the writer connection.
    private func checkOutReadConnection() -> OpaquePointer? {
        guard allowsSeparateReadConnections else { return nil }
        readConnections.lock()
        defer { readConnections.unlock() }
        while true {
            guard !readConnectionsClosed, db != nil else { return nil }
            if let handle = idleReadConnections.popLast() { return handle }
            if openReadConnectionCount < Self.maximumReadConnections {
                guard let handle = try? Self.openReadConnection(path: path) else {
                    // Degrade to the writer rather than failing a user's read.
                    return nil
                }
                openReadConnectionCount += 1
                return handle
            }
            readConnections.wait()
        }
    }

    private func checkInReadConnection(_ handle: OpaquePointer) {
        readConnections.lock()
        if readConnectionsClosed {
            sqlite3_close(handle)
            openReadConnectionCount -= 1
        } else {
            idleReadConnections.append(handle)
        }
        readConnections.signal()
        readConnections.unlock()
    }

    private func closeReadConnections() throws {
        readConnections.lock()
        defer {
            readConnections.broadcast()
            readConnections.unlock()
        }
        readConnectionsClosed = true
        guard openReadConnectionCount == idleReadConnections.count else {
            throw SQLiteError.exec("Failed to close database: a read is still in progress")
        }
        for handle in idleReadConnections {
            sqlite3_close(handle)
        }
        idleReadConnections.removeAll()
        openReadConnectionCount = 0
    }

    private static func openReadConnection(path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        // No SQLITE_OPEN_CREATE: a reader must never materialize a library.
        // Read/write is still requested because a WAL reader has to be able to
        // attach the shared-memory index; `query_only` supplies the actual
        // single-writer guarantee.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.open("Failed to open read connection for \(path): \(message)")
        }
        do {
            // Readers only ever wait on the brief exclusive locks a commit or a
            // checkpoint takes, so a longer timeout than the writer's is cheap
            // insurance against a spurious SQLITE_BUSY during a scan.
            try execute("PRAGMA busy_timeout = 10000;", on: opened)
            try execute("PRAGMA cache_size = -20000;", on: opened)
            try execute("PRAGMA temp_store = MEMORY;", on: opened)
            try execute("PRAGMA mmap_size = 268435456;", on: opened)
            try execute("PRAGMA query_only = ON;", on: opened)
        } catch {
            sqlite3_close(opened)
            throw error
        }
        return opened
    }

    private static func execute(_ sql: String, on handle: OpaquePointer) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        guard rc != SQLITE_OK else { return }
        let message = err.map { String(cString: $0) } ?? "sqlite error \(rc)"
        sqlite3_free(err)
        throw SQLiteError.exec(message)
    }

    // MARK: - Free space

    public func autoVacuumMode() throws -> SQLiteAutoVacuumMode {
        try withExclusiveMutation {
            SQLiteAutoVacuumMode(rawValue: Int(try integerScalar("PRAGMA auto_vacuum"))) ?? .none
        }
    }

    /// Hand pages freed by retention or reviewed deletion back to the
    /// filesystem, bounded so this can share the executor that runs capture.
    ///
    /// Libraries created before Screenlogger enabled incremental auto-vacuum
    /// have no pointer map, so SQLite ignores `incremental_vacuum` on them.
    /// That is reported rather than treated as an error; `compactDatabaseFile()`
    /// is the deliberate, user-initiated way to convert one.
    @discardableResult
    public func reclaimFreePages(maxPages: Int = 2_000) throws -> SQLiteFreeSpaceReclaim {
        try withExclusiveMutation {
            let pageSize = try integerScalar("PRAGMA page_size")
            let before = try integerScalar("PRAGMA freelist_count")
            guard SQLiteAutoVacuumMode(rawValue: Int(try integerScalar("PRAGMA auto_vacuum"))) == .incremental
            else {
                return SQLiteFreeSpaceReclaim(
                    reclaimedBytes: 0,
                    remainingFreeBytes: before * pageSize,
                    isIncrementalVacuumAvailable: false
                )
            }
            try exec("PRAGMA incremental_vacuum(\(max(1, maxPages)));")
            let after = try integerScalar("PRAGMA freelist_count")
            if after < before {
                // WAL records the shorter file in the log, so the bytes only
                // leave the filesystem once a checkpoint copies them back.
                // PASSIVE never waits on a live reader.
                try exec("PRAGMA wal_checkpoint(PASSIVE);")
            }
            return SQLiteFreeSpaceReclaim(
                reclaimedBytes: max(0, before - after) * pageSize,
                remainingFreeBytes: after * pageSize,
                isIncrementalVacuumAvailable: true
            )
        }
    }

    /// Rebuild a legacy database off-main at a safe maintenance opportunity.
    /// The caller must keep this connection open until the operation returns.
    /// The mutation executor excludes writers throughout the file rewrite.
    @discardableResult
    public func compactDatabaseFile(freeSpaceMarginBytes: Int64 = 256 * 1024 * 1024) throws
        -> SQLiteCompactionReport
    {
        try withExclusiveMutation {
            let bytesBefore = try requireCompactionHeadroom(freeSpaceMarginBytes: freeSpaceMarginBytes)
            // Do not start a full rewrite when an existing reader pins the WAL.
            // A reader that starts later can still defer the final checkpoint.
            sqlite3_busy_timeout(db, 0)
            defer { sqlite3_busy_timeout(db, 5_000) }
            let initialCheckpoint = sqlite3_wal_checkpoint_v2(
                db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil
            )
            guard initialCheckpoint == SQLITE_OK else {
                if initialCheckpoint == SQLITE_BUSY || initialCheckpoint == SQLITE_LOCKED {
                    throw SQLiteMaintenanceError.checkpointBlocked
                }
                throw SQLiteError.exec("Database checkpoint failed (SQLite \(initialCheckpoint))")
            }
            // The pragma only reaches the header when VACUUM rewrites the file,
            // which is exactly what makes this the conversion step for legacy
            // libraries; afterwards retention can reclaim incrementally.
            try exec("PRAGMA auto_vacuum = INCREMENTAL;")
            try exec("VACUUM;")
            let checkpoint = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            guard checkpoint == SQLITE_OK else {
                if checkpoint == SQLITE_BUSY || checkpoint == SQLITE_LOCKED {
                    throw SQLiteMaintenanceError.checkpointBlocked
                }
                throw SQLiteError.exec("Database compaction checkpoint failed (SQLite \(checkpoint))")
            }
            let pageSizeAfter = try integerScalar("PRAGMA page_size")
            let bytesAfter = try integerScalar("PRAGMA page_count") * pageSizeAfter
            return SQLiteCompactionReport(bytesBefore: bytesBefore, bytesAfter: bytesAfter)
        }
    }

    /// A full rewrite needs space for a temporary copy and its journal.
    func requireCompactionHeadroom(freeSpaceMarginBytes: Int64) throws -> Int64 {
        try withExclusiveMutation {
            let pageSize = try integerScalar("PRAGMA page_size")
            let bytes = try integerScalar("PRAGMA page_count") * pageSize
            let available = try availableCapacityBytes()
            // VACUUM needs both a temporary database and a rollback journal or
            // rebuilt WAL: SQLite documents up to twice the original size free.
            let copies = bytes.multipliedReportingOverflow(by: 2)
            let required = copies.partialValue.addingReportingOverflow(max(0, freeSpaceMarginBytes))
            let requiredBytes = copies.overflow || required.overflow ? Int64.max : required.partialValue
            guard available >= requiredBytes else {
                throw SQLiteMaintenanceError.insufficientFreeSpace(
                    requiredBytes: requiredBytes,
                    availableBytes: available
                )
            }
            return bytes
        }
    }

    private func availableCapacityBytes() throws -> Int64 {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            let values = try directory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
                throw SQLiteMaintenanceError.freeSpaceUnavailable("volume reported no capacity")
            }
            return capacity
        } catch let error as SQLiteMaintenanceError {
            throw error
        } catch {
            throw SQLiteMaintenanceError.freeSpaceUnavailable(String(describing: error))
        }
    }

    private func integerScalar(_ sql: String) throws -> Int64 {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw SQLiteError.step("scalar query returned no row: \(sql)")
        }
        return SQLiteColumn.int64(stmt, 0)
    }

    /// Create a consistent standalone database without copying WAL/SHM files.
    /// Callers that also snapshot managed media must hold Store's serialized
    /// mutation executor across this backup and the corresponding file copies.
    public func backup(to destination: URL) throws {
        try withExclusiveMutation {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw SQLiteError.exec("Backup destination already exists: \(destination.path)")
            }
            var destinationHandle: OpaquePointer?
            let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(destination.path, &destinationHandle, flags, nil) == SQLITE_OK,
                let destinationHandle
            else {
                let message = destinationHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                if let destinationHandle { sqlite3_close(destinationHandle) }
                throw SQLiteError.open("Failed to create backup database: \(message)")
            }
            defer {
                sqlite3_close(destinationHandle)
                // A read of a WAL-mode header can create an empty shared-memory
                // coordination pair. The online backup has already materialized
                // every committed page in the main file; these new sidecars
                // carry no database content and are never archive data.
                try? FileManager.default.removeItem(atPath: destination.path + "-shm")
                try? FileManager.default.removeItem(atPath: destination.path + "-wal")
            }
            guard let backup = sqlite3_backup_init(destinationHandle, "main", db, "main") else {
                throw SQLiteError.exec("Failed to initialize SQLite backup: \(String(cString: sqlite3_errmsg(destinationHandle)))")
            }
            let stepResult = sqlite3_backup_step(backup, -1)
            let finishResult = sqlite3_backup_finish(backup)
            guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
                throw SQLiteError.exec("SQLite backup failed (step \(stepResult), finish \(finishResult))")
            }
            func schemaVersion(_ handle: OpaquePointer?) throws -> Int {
                var statement: OpaquePointer?
                guard
                    sqlite3_prepare_v2(
                        handle,
                        "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
                        -1,
                        &statement,
                        nil
                    ) == SQLITE_OK,
                    let statement
                else {
                    throw SQLiteError.prepare("Could not inspect backup schema version")
                }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    throw SQLiteError.step("Could not read backup schema version")
                }
                return Int(sqlite3_column_int64(statement, 0))
            }
            let sourceVersion = try schemaVersion(db)
            let copiedVersion = try schemaVersion(destinationHandle)
            guard copiedVersion == sourceVersion else {
                throw SQLiteError.exec(
                    "SQLite backup schema version mismatch (source \(sourceVersion), copy \(copiedVersion))"
                )
            }
        }
    }

    /// Validate an export candidate without opening it read/write or creating
    /// journal sidecars.
    public static func validateReadOnly(at databaseURL: URL) throws -> SQLiteReadOnlyValidation {
        var handle: OpaquePointer?
        // Backup copies can retain WAL mode in the database header even though
        // the online backup API has already materialized every committed page
        // into the standalone file. Immutable URI mode prevents a read-only
        // verifier from trying to create unnecessary WAL/SHM sidecars.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        let immutableURI = databaseURL.absoluteString + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(immutableURI, &handle, flags, nil) == SQLITE_OK,
            let handle
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.open("Failed to open backup database read-only: \(message)")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5_000)

        func integerScalar(_ sql: String) throws -> Int {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                let statement
            else {
                throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw SQLiteError.step("Read-only validation query returned no row: \(sql)")
            }
            return Int(sqlite3_column_int64(statement, 0))
        }

        var quickCheck: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA quick_check(100)", -1, &quickCheck, nil) == SQLITE_OK,
            let quickCheck
        else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(quickCheck) }
        var integrityFailures: [String] = []
        var sawOK = false
        var step = sqlite3_step(quickCheck)
        while step == SQLITE_ROW {
            let message = sqlite3_column_text(quickCheck, 0).map { String(cString: $0) } ?? ""
            if message == "ok" { sawOK = true } else { integrityFailures.append(message.isEmpty ? "empty quick_check result" : message) }
            step = sqlite3_step(quickCheck)
        }
        guard step == SQLITE_DONE else {
            throw SQLiteError.step("Read-only quick_check failed")
        }
        if integrityFailures.isEmpty, !sawOK { integrityFailures.append("quick_check returned no result") }

        var foreignKeys: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA foreign_key_check", -1, &foreignKeys, nil) == SQLITE_OK,
            let foreignKeys
        else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(foreignKeys) }
        var violationCount = 0
        step = sqlite3_step(foreignKeys)
        while step == SQLITE_ROW {
            violationCount += 1
            step = sqlite3_step(foreignKeys)
        }
        guard step == SQLITE_DONE else { throw SQLiteError.step("Read-only foreign-key check failed") }

        return SQLiteReadOnlyValidation(
            schemaVersion: try integerScalar(
                "SELECT COALESCE(MAX(version), 0) FROM schema_migrations"
            ),
            integrityFailures: integrityFailures,
            foreignKeyViolationCount: violationCount
        )
    }

    /// Returns every non-`ok` result from SQLite's bounded startup check.
    public func quickCheckFailures() throws -> [String] {
        try withExclusiveMutation {
            let stmt = try prepare("PRAGMA quick_check(100)")
            defer { sqlite3_finalize(stmt) }
            var failures: [String] = []
            var sawSuccess = false
            var result = sqlite3_step(stmt)
            while result == SQLITE_ROW {
                guard let message = SQLiteColumn.text(stmt, 0) else {
                    failures.append("quick_check returned an empty result")
                    result = sqlite3_step(stmt)
                    continue
                }
                if message == "ok" {
                    sawSuccess = true
                    result = sqlite3_step(stmt)
                    continue
                }
                failures.append(message)
                result = sqlite3_step(stmt)
            }
            guard result == SQLITE_DONE else {
                throw SQLiteError.step("quick_check failed while reading results")
            }
            if failures.isEmpty, !sawSuccess {
                failures.append("quick_check returned no result")
            }
            return failures
        }
    }

    /// Foreign-key validation is separate from `quick_check` in SQLite.
    public func foreignKeyViolations() throws -> [SQLiteForeignKeyViolation] {
        try withExclusiveMutation {
            let stmt = try prepare("PRAGMA foreign_key_check")
            defer { sqlite3_finalize(stmt) }
            var violations: [SQLiteForeignKeyViolation] = []
            var result = sqlite3_step(stmt)
            while result == SQLITE_ROW {
                violations.append(
                    SQLiteForeignKeyViolation(
                        table: SQLiteColumn.text(stmt, 0) ?? "unknown",
                        rowID: SQLiteColumn.int64Optional(stmt, 1),
                        parentTable: SQLiteColumn.text(stmt, 2) ?? "unknown",
                        constraintIndex: SQLiteColumn.int64(stmt, 3)
                    )
                )
                result = sqlite3_step(stmt)
            }
            guard result == SQLITE_DONE else {
                throw SQLiteError.step("foreign_key_check failed while reading results")
            }
            return violations
        }
    }
}

// MARK: - Statement helpers

public enum SQLiteBind {
    public static func text(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    public static func int64(_ stmt: OpaquePointer, _ index: Int32, _ value: Int64?) {
        if let value {
            sqlite3_bind_int64(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    public static func int(_ stmt: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int64(stmt, index, Int64(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    public static func bool(_ stmt: OpaquePointer, _ index: Int32, _ value: Bool) {
        sqlite3_bind_int(stmt, index, value ? 1 : 0)
    }

    public static func double(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    public static func blob(_ stmt: OpaquePointer, _ index: Int32, _ value: Data?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        value.withUnsafeBytes { raw in
            let ptr = raw.baseAddress
            // SQLITE_TRANSIENT: copy blob bytes so Data lifetime is independent of the bind.
            sqlite3_bind_blob(stmt, index, ptr, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}

public enum SQLiteColumn {
    public static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    public static func int64(_ stmt: OpaquePointer, _ index: Int32) -> Int64 {
        sqlite3_column_int64(stmt, index)
    }

    public static func int64Optional(_ stmt: OpaquePointer, _ index: Int32) -> Int64? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(stmt, index)
    }

    public static func intOptional(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        int64Optional(stmt, index).map { Int($0) }
    }

    public static func bool(_ stmt: OpaquePointer, _ index: Int32) -> Bool {
        sqlite3_column_int(stmt, index) != 0
    }

    public static func doubleOptional(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, index)
    }

    public static func data(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0, let ptr = sqlite3_column_blob(stmt, index) else {
            return Data()
        }
        return Data(bytes: ptr, count: count)
    }
}
