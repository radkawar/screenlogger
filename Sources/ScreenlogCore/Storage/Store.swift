import Foundation
import SQLite3

/// Cancellation token shared between a Swift task and Store's serial read
/// executor. SQLite work that is already stepping cannot be interrupted safely
/// on the shared connection, but superseded reads that are still queued should
/// never run ahead of the user's newest query.
private final class StoreReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

public enum StoreStartupError: Error, Equatable, Sendable {
    case databaseUnavailable(detail: String)
    case integrityCheckFailed(detail: String)
    case schemaMigrationFailed(detail: String)
    case schemaValidationFailed(detail: String)
    case orphanRecoveryFailed(detail: String)
}

extension StoreStartupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return "Screenlogger couldn't open your library database. Capture has not started."
        case .integrityCheckFailed:
            return "Your library database did not pass its integrity check. Capture has not started."
        case .schemaMigrationFailed:
            return "Screenlogger couldn't safely update your library. Capture has not started."
        case .schemaValidationFailed:
            return "Your library database has inconsistent relationships. Capture has not started."
        case .orphanRecoveryFailed:
            return "Screenlogger couldn't finish recovering your local library. Capture has not started."
        }
    }
}

/// High-level local store: frames, OCR, segments, FTS, usage queries.
public final class Store: @unchecked Sendable {
    public let db: SQLiteDatabase
    public let root: URL
    public let framesDirectory: URL
    /// Serial queue for UI-facing reads so MainActor never blocks on SQLite/FTS.
    private let readQueue = DispatchQueue(label: "dev.screenlog.store.read", qos: .userInitiated)

    public init(root: URL) throws {
        self.root = root
        try ScreenlogPaths.ensureDirectories(root: root)
        self.framesDirectory = ScreenlogPaths.framesDirectory(root: root)
        let dbPath = ScreenlogPaths.databaseURL(root: root).path
        do {
            self.db = try SQLiteDatabase(path: dbPath)
        } catch {
            throw StoreStartupError.databaseUnavailable(detail: String(describing: error))
        }
        try validateDatabaseBeforeMigration()
        do {
            try Schema.migrate(db)
        } catch {
            throw StoreStartupError.schemaMigrationFailed(detail: String(describing: error))
        }
        try validateMigratedDatabase()
        // A process can stop between removing canonical capture files and committing
        // (or cleaning up after) a reviewed library deletion. Reconcile its durable
        // manifest before exposing the Store so DB rows never remain pointed at missing
        // bytes after relaunch.
        try LibraryDeletionService().recoverPendingOperations(store: self)
        try recoverOrphanedManagedVideos()
        try recoverOrphanedManagedStills()
    }

    /// Run a read on the store's background queue (awaitable from UI).
    public func readAsync<T: Sendable>(_ body: @escaping @Sendable (Store) throws -> T) async throws -> T {
        let cancellation = StoreReadCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: T = try await withCheckedThrowingContinuation { continuation in
                readQueue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        // WAL only keeps readers off the writer's back when
                        // they run on their own connection. Mutations nested in
                        // `body` still pin themselves to the writer.
                        continuation.resume(returning: try self.db.withReadConnection { try body(self) })
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Serialize a SQLite mutation or managed-filesystem operation with capture,
    /// compaction, retention, and reviewed deletion.
    public func withSerializedMutation<T>(_ body: () throws -> T) rethrows -> T {
        try db.withExclusiveMutation(body)
    }

    /// Compatibility spelling for maintenance services. Maintenance uses the
    /// same executor as live capture writes; it is not a separate lock domain.
    public func withExclusiveMaintenance<T>(_ body: () throws -> T) rethrows -> T {
        try withSerializedMutation(body)
    }

    /// Run a read on a connection separate from the writer's, without leaving
    /// the caller's thread. Use this for a synchronous read that must not queue
    /// behind capture; `readAsync` already applies it.
    public func withReadConnection<T>(_ body: () throws -> T) throws -> T {
        try db.withReadConnection(body)
    }

    // MARK: - Storage reclamation

    /// Give pages freed by retention or reviewed deletion back to the
    /// filesystem. Bounded so it can share the executor that runs capture.
    @discardableResult
    public func reclaimFreeDatabasePages(maxPages: Int = 2_000) throws -> SQLiteFreeSpaceReclaim {
        try withExclusiveMaintenance {
            try db.reclaimFreePages(maxPages: maxPages)
        }
    }

    /// User-initiated full rebuild of the database file. This is the only way
    /// to shrink a library created before incremental auto-vacuum, and it
    /// refuses to start unless the volume has room for a temporary copy.
    @discardableResult
    public func compactDatabaseFile() throws -> SQLiteCompactionReport {
        try withExclusiveMaintenance {
            try db.compactDatabaseFile()
        }
    }

    /// Convenience for production location (or SCREENLOG_DATA_DIR).
    public static func openDefault(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Store {
        let root = ScreenlogPaths.resolvedRoot(environment: environment)
        return try Store(root: root)
    }

    // MARK: - Startup integrity

    private func validateDatabaseBeforeMigration() throws {
        do {
            let failures = try db.quickCheckFailures()
            guard failures.isEmpty else {
                throw StoreStartupError.integrityCheckFailed(detail: failures.joined(separator: "; "))
            }
        } catch let error as StoreStartupError {
            throw error
        } catch {
            throw StoreStartupError.integrityCheckFailed(detail: String(describing: error))
        }
    }

    private func validateMigratedDatabase() throws {
        do {
            try Schema.validate(db)
            let integrityFailures = try db.quickCheckFailures()
            guard integrityFailures.isEmpty else {
                throw StoreStartupError.integrityCheckFailed(
                    detail: integrityFailures.joined(separator: "; ")
                )
            }
            let violations = try db.foreignKeyViolations()
            guard violations.isEmpty else {
                let detail = violations.prefix(20).map {
                    "\($0.table)[\($0.rowID.map(String.init) ?? "nil")] -> \($0.parentTable)#\($0.constraintIndex)"
                }.joined(separator: "; ")
                throw StoreStartupError.schemaValidationFailed(detail: detail)
            }
        } catch let error as StoreStartupError {
            throw error
        } catch {
            throw StoreStartupError.schemaValidationFailed(detail: String(describing: error))
        }
    }

    /// Remove only direct-child stills with Screenlogger's canonical generated
    /// filename that are not referenced by any frame. Hidden recovery folders,
    /// symlinks, directories, and noncanonical user files are never touched.
    private func recoverOrphanedManagedStills() throws {
        do {
            try withExclusiveMaintenance {
                // The immediate transaction coordinates with writers using other
                // Store instances or processes. Capture begins its transaction
                // before writing a still, so a partial write cannot race this scan.
                try db.transaction {
                    let referencedPaths = try referencedImagePaths()
                    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
                    let candidates = try FileManager.default.contentsOfDirectory(
                        at: framesDirectory,
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles]
                    )
                    for candidate in candidates {
                        guard Self.isCanonicalManagedStill(candidate) else { continue }
                        let values = try candidate.resourceValues(forKeys: keys)
                        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                        let path = candidate.standardizedFileURL.path
                        guard !referencedPaths.contains(path) else { continue }
                        try FileManager.default.removeItem(at: candidate)
                    }
                }
            }
        } catch {
            throw StoreStartupError.orphanRecoveryFailed(detail: String(describing: error))
        }
    }

    /// Remove only compaction files with Screenlogger's generated filename
    /// that are not referenced by `video`. A process can stop after promoting
    /// an encoded temporary file but before committing its database row.
    /// Arbitrary files, directories, symlinks, and hidden recovery data remain
    /// untouched.
    private func recoverOrphanedManagedVideos() throws {
        do {
            try withExclusiveMaintenance {
                try db.transaction {
                    let referencedPaths = try referencedVideoPaths()
                    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
                    let videosDirectory = ScreenlogPaths.videosDirectory(root: root)
                    let candidates = try FileManager.default.contentsOfDirectory(
                        at: videosDirectory,
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles]
                    )
                    for candidate in candidates {
                        guard Self.isCanonicalManagedVideo(candidate) else { continue }
                        let values = try candidate.resourceValues(forKeys: keys)
                        guard values.isRegularFile == true, values.isSymbolicLink != true else {
                            continue
                        }
                        let path = candidate.standardizedFileURL.path
                        guard !referencedPaths.contains(path) else { continue }
                        try FileManager.default.removeItem(at: candidate)
                    }
                }
            }
        } catch {
            throw StoreStartupError.orphanRecoveryFailed(detail: String(describing: error))
        }
    }

    private func referencedImagePaths() throws -> Set<String> {
        let stmt = try db.prepare(
            "SELECT image_path FROM frame WHERE image_path IS NOT NULL AND image_path != ''"
        )
        defer { sqlite3_finalize(stmt) }
        var paths = Set<String>()
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            if let path = SQLiteColumn.text(stmt, 0), !path.isEmpty {
                paths.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else {
            throw SQLiteError.step("referenced image path scan failed")
        }
        return paths
    }

    private func referencedVideoPaths() throws -> Set<String> {
        let stmt = try db.prepare("SELECT path FROM video WHERE path != ''")
        defer { sqlite3_finalize(stmt) }
        var paths = Set<String>()
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            if let path = SQLiteColumn.text(stmt, 0), !path.isEmpty {
                paths.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else {
            throw SQLiteError.step("referenced video path scan failed")
        }
        return paths
    }

    private static func isCanonicalManagedStill(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        guard stem.count == 16,
            !ext.isEmpty,
            ext.count <= 10,
            stem.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }),
            ext.utf8.allSatisfy({ byte in
                (48...57).contains(byte)
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
            })
        else { return false }
        return true
    }

    private static func isCanonicalManagedVideo(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let suffix: String
        if name.hasSuffix(".tmp.mp4") {
            suffix = ".tmp.mp4"
        } else if name.hasSuffix(".mp4") {
            suffix = ".mp4"
        } else {
            return false
        }
        let stem = String(name.dropLast(suffix.count))
        let parts = stem.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 4,
            parts[0] == "v",
            Int64(parts[1]).map({ $0 > 0 }) == true,
            Int(parts[2]).map({ $0 > 0 }) == true,
            parts[3].utf8.count == 8,
            parts[3].utf8.allSatisfy({ byte in
                (48...57).contains(byte)
                    || (65...70).contains(byte)
                    || (97...102).contains(byte)
            })
        else { return false }
        return true
    }

    // MARK: - Write path

    @discardableResult
    public func store(payload: CapturePayload) throws -> Int64 {
        try withSerializedMutation {
            var writtenImageURL: URL?
            do {
                return try db.transaction {
                    let appID = try upsertApplication(
                        bundleID: payload.bundleID,
                        version: payload.bundleVersion,
                        displayName: payload.displayName
                    )
                    let domainID = try upsertDomain(normalized: payload.domain)
                    let frameID = try insertFrame(payload: payload, segmentID: nil)

                    // Segment: continue if same app/domain/url, else open new.
                    let segmentID = try resolveSegment(
                        frameID: frameID,
                        applicationID: appID,
                        domainID: domainID,
                        url: payload.url
                    )
                    try setFrameSegment(frameID: frameID, segmentID: segmentID)

                    // Persist image. Remember it until commit so a later SQL failure
                    // cannot leave unmanaged bytes after the transaction rolls back.
                    let imageName = String(format: "%016llx.\(payload.imageFileExtension)", frameID)
                    let imageURL = framesDirectory.appendingPathComponent(imageName)
                    try payload.imageData.write(to: imageURL, options: .atomic)
                    writtenImageURL = imageURL
                    try setFrameImagePath(frameID: frameID, path: imageURL.path)

                    try insertOCRBoxes(frameID: frameID, boxes: payload.ocrBoxes)
                    try insertWindowBounds(frameID: frameID, bounds: payload.windowBounds, fallbackAppID: appID)
                    return frameID
                }
            } catch {
                if let writtenImageURL {
                    try? FileManager.default.removeItem(at: writtenImageURL)
                }
                throw error
            }
        }
    }

    /// Seed helper used by tests - insert without requiring image capture.
    @discardableResult
    public func insertSeedFrame(
        timestampMs: Int64,
        foreground: String,
        background: String = "",
        title: String = "",
        bundleID: String? = nil,
        displayName: String? = nil,
        domain: String? = nil,
        url: String? = nil,
        imagePath: String? = nil,
        width: Int = 100,
        height: Int = 100,
        captureDisplay: CaptureDisplayRect? = nil
    ) throws -> Int64 {
        try withSerializedMutation {
            let payload = CapturePayload(
                imageData: Data([0x89, 0x50, 0x4E, 0x47]),  // minimal placeholder
                timestampMs: timestampMs,
                width: width,
                height: height,
                foreground: foreground,
                background: background,
                title: title,
                bundleID: bundleID,
                displayName: displayName,
                url: url,
                domain: domain,
                ocrBoxes: [
                    OCRBox(x: 0, y: 0, width: width, height: 20, textOffset: 0, textLength: foreground.count)
                ],
                imageFileExtension: "bin",
                captureDisplay: captureDisplay
            )
            let id = try store(payload: payload)
            if let imagePath {
                try setFrameImagePath(frameID: id, path: imagePath)
            }
            return id
        }
    }

    // MARK: - Frames

    private func insertFrame(payload: CapturePayload, segmentID: Int64?) throws -> Int64 {
        let sql = """
            INSERT INTO frame(
                timestamp, image_path, width, height,
                foreground, background, title, segment, is_inactive,
                capture_display_x, capture_display_y, capture_display_width, capture_display_height,
                index_search
            ) VALUES(?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, payload.timestampMs)
        SQLiteBind.int(stmt, 2, payload.width)
        SQLiteBind.int(stmt, 3, payload.height)
        SQLiteBind.text(stmt, 4, payload.foreground)
        SQLiteBind.text(stmt, 5, payload.background)
        SQLiteBind.text(stmt, 6, payload.title)
        SQLiteBind.int64(stmt, 7, segmentID)
        SQLiteBind.bool(stmt, 8, payload.isInactive)
        SQLiteBind.double(stmt, 9, payload.captureDisplay?.x)
        SQLiteBind.double(stmt, 10, payload.captureDisplay?.y)
        SQLiteBind.double(stmt, 11, payload.captureDisplay?.width)
        SQLiteBind.double(stmt, 12, payload.captureDisplay?.height)
        SQLiteBind.bool(stmt, 13, payload.indexSearch)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw SQLiteError.step("insert frame failed")
        }
        return db.lastInsertRowID()
    }

    private func setFrameImagePath(frameID: Int64, path: String) throws {
        let stmt = try db.prepare("UPDATE frame SET image_path = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.text(stmt, 1, path)
        SQLiteBind.int64(stmt, 2, frameID)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw SQLiteError.step("set image_path failed")
        }
    }

    private func setFrameSegment(frameID: Int64, segmentID: Int64) throws {
        let stmt = try db.prepare("UPDATE frame SET segment = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, segmentID)
        SQLiteBind.int64(stmt, 2, frameID)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw SQLiteError.step("set segment failed")
        }
    }

    private func resolveSegment(
        frameID: Int64,
        applicationID: Int64?,
        domainID: Int64?,
        url: String?
    ) throws -> Int64 {
        // Load last segment
        let stmt = try db.prepare(
            """
            SELECT id, application, domain, url
            FROM segment
            ORDER BY id DESC
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            let lastID = SQLiteColumn.int64(stmt, 0)
            let lastApp = SQLiteColumn.int64Optional(stmt, 1)
            let lastDomain = SQLiteColumn.int64Optional(stmt, 2)
            let lastURL = SQLiteColumn.text(stmt, 3)
            if lastApp == applicationID && lastDomain == domainID && lastURL == url {
                return lastID
            }
        }
        let ins = try db.prepare(
            """
            INSERT INTO segment(start_frame_id, application, domain, url)
            VALUES(?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(ins) }
        SQLiteBind.int64(ins, 1, frameID)
        SQLiteBind.int64(ins, 2, applicationID)
        SQLiteBind.int64(ins, 3, domainID)
        SQLiteBind.text(ins, 4, url)
        if sqlite3_step(ins) != SQLITE_DONE {
            throw SQLiteError.step("insert segment failed")
        }
        return db.lastInsertRowID()
    }

    private func insertOCRBoxes(frameID: Int64, boxes: [OCRBox]) throws {
        guard !boxes.isEmpty else { return }
        let sql = """
            INSERT INTO ocr(frame, x, y, width, height, text_offset, text_length)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            """
        for box in boxes {
            let stmt = try db.prepare(sql)
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.int64(stmt, 1, frameID)
            SQLiteBind.int(stmt, 2, box.x)
            SQLiteBind.int(stmt, 3, box.y)
            SQLiteBind.int(stmt, 4, box.width)
            SQLiteBind.int(stmt, 5, box.height)
            SQLiteBind.int(stmt, 6, box.textOffset)
            SQLiteBind.int(stmt, 7, box.textLength)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw SQLiteError.step("insert ocr failed")
            }
        }
    }

    private func insertWindowBounds(frameID: Int64, bounds: [WindowBound], fallbackAppID: Int64?) throws {
        guard !bounds.isEmpty else { return }
        let sql = """
            INSERT INTO window_bound(
                frame, application, window_title, x, y, width, height, window_layer, z_order, url
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        for b in bounds {
            // Schema requires application NOT NULL - resolve via window bundle ID or fallback.
            var appID = b.applicationID ?? fallbackAppID
            if appID == nil, let bid = b.bundleID, !bid.isEmpty {
                appID = try upsertApplication(bundleID: bid, version: "", displayName: nil)
            }
            guard let appID else { continue }

            let stmt = try db.prepare(sql)
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.int64(stmt, 1, frameID)
            SQLiteBind.int64(stmt, 2, appID)
            SQLiteBind.text(stmt, 3, b.windowTitle)
            SQLiteBind.int(stmt, 4, b.x)
            SQLiteBind.int(stmt, 5, b.y)
            SQLiteBind.int(stmt, 6, b.width)
            SQLiteBind.int(stmt, 7, b.height)
            SQLiteBind.int(stmt, 8, b.windowLayer)
            SQLiteBind.int(stmt, 9, b.zOrder)
            SQLiteBind.text(stmt, 10, b.url)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw SQLiteError.step("insert window_bound failed")
            }
        }
    }

    public func ocrBoxes(frameID: Int64) throws -> [OCRBox] {
        let stmt = try db.prepare(
            """
            SELECT x, y, width, height, text_offset, text_length
            FROM ocr WHERE frame = ? ORDER BY text_offset
            """
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, frameID)
        var boxes: [OCRBox] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            boxes.append(
                OCRBox(
                    x: Int(SQLiteColumn.int64(stmt, 0)),
                    y: Int(SQLiteColumn.int64(stmt, 1)),
                    width: Int(SQLiteColumn.int64(stmt, 2)),
                    height: Int(SQLiteColumn.int64(stmt, 3)),
                    textOffset: Int(SQLiteColumn.int64(stmt, 4)),
                    textLength: Int(SQLiteColumn.int64(stmt, 5))
                )
            )
        }
        return boxes
    }

    /// Full OCR text for a frame: `foreground || background` (the box-offset address space).
    /// Returns `nil` when the frame is missing or both layers are empty.
    public func ocrText(frameID: Int64) throws -> String? {
        let stmt = try db.prepare(
            "SELECT foreground, background FROM frame WHERE id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, frameID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let fg = SQLiteColumn.text(stmt, 0) ?? ""
        let bg = SQLiteColumn.text(stmt, 1) ?? ""
        let concat = fg + bg
        return concat.isEmpty ? nil : concat
    }

    /// Per-box OCR slices addressed into `foreground || background` (cheap one-frame load).
    /// Empty when frame missing; text may be empty if offsets are out of range.
    public func ocrBoxTexts(frameID: Int64) throws -> [(box: OCRBox, text: String)] {
        guard try frame(id: frameID) != nil else { return [] }
        let concat = try ocrText(frameID: frameID) ?? ""
        let boxes = try ocrBoxes(frameID: frameID)
        return boxes.map { box in
            (box, Self.sliceUTF16(concat, offset: box.textOffset, length: box.textLength))
        }
    }

    /// UTF-16 offset/length slice (matches Vision / OCRService box addressing).
    private static func sliceUTF16(_ text: String, offset: Int, length: Int) -> String {
        guard length > 0, offset >= 0 else { return "" }
        let u = text.utf16
        guard offset < u.count else { return "" }
        let start = u.index(u.startIndex, offsetBy: offset)
        let endOffset = min(offset + length, u.count)
        let end = u.index(u.startIndex, offsetBy: endOffset)
        return String(utf16CodeUnits: Array(u[start..<end]), count: endOffset - offset)
    }

}
