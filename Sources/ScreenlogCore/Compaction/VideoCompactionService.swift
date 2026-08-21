import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import OSLog
import SQLite3
import VideoToolbox

private let log = Logger(subsystem: "dev.screenlog", category: "compaction")

/// HEVC (H.264 fallback) compaction of unfinalized stills.
/// Uses VideoToolbox directly through `AVAssetWriter`.
///
/// Integrity rules:
/// 1. Group each display into chronological runs of the same resolution.
/// 2. Split runs on large timestamp gaps - never stitch unrelated timeslices into one video.
/// 3. Only mark/delete frames that were **actually** successfully encoded.
/// 4. On encode failure: leave frames untouched, remove incomplete video, continue next run.
///
/// Concurrency: encoding is a blocking AVAssetWriter pipeline that can run for
/// minutes. It must never occupy a Swift concurrency cooperative thread, and it
/// must not hold the database mutation lock while it works, because live
/// capture takes that same lock for every stored frame. Async callers use
/// `compact(store:)`, which runs the pass on a dedicated serial queue; the
/// database lock is taken only for the short load and commit steps.
public final class VideoCompactionService: @unchecked Sendable {
    /// Minimum unfinalized stills before a compaction pass starts.
    public var minBatchSize: Int = 30
    /// Minimum frames in one display run to encode (need >=2 for a meaningful segment).
    public var minRunSize: Int = 2
    /// Max gap between consecutive frames in a run. Larger gaps start a new run.
    /// Default 60s ~ 30 capture intervals at ~2s/frame.
    public var maxGapMs: Int64 = 60_000
    /// Presentation duration per compacted frame (matches `FrameExtractor.defaultFrameDuration`).
    public var frameDuration: CMTime = FrameExtractor.defaultFrameDuration
    /// Max frames loaded per compaction pass.
    public var loadLimit: Int = 500
    /// Max wall time to wait for `isReadyForMoreMediaData` per frame.
    public var readyTimeout: TimeInterval = 10

    /// One compaction pass at a time for the whole process. Every call site
    /// builds its own service instance, so an instance flag could never keep
    /// the background maintenance pass and a user-initiated pass off the same
    /// unfinalized frames. Compaction no longer holds the database mutation
    /// lock end to end, so this gate is what serializes passes.
    private static let passGate = CompactionPassGate()

    /// Encoding blocks its thread for as long as the pass runs. Async callers
    /// are moved here so no cooperative thread is parked on AVFoundation.
    private static let passQueue = DispatchQueue(
        label: "dev.screenlog.compaction",
        qos: .utility
    )

    public init() {}

    /// Compact eligible unfinalized stills without occupying the caller's
    /// executor. Preferred entry point from any Swift concurrency context.
    @discardableResult
    public func compact(store: Store) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            Self.passQueue.async { [self] in
                do {
                    continuation.resume(returning: try compactIfNeeded(store: store))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Compact eligible unfinalized stills. Returns number of frames successfully compacted.
    ///
    /// Blocking: this runs the whole encode on the calling thread. Call it only
    /// from a thread you own (a dispatch queue, the CLI, or a test). From an
    /// async context use `compact(store:)` instead.
    @discardableResult
    public func compactIfNeeded(store: Store) throws -> Int {
        guard Self.passGate.begin() else {
            log.info("Compact already in progress, skipping")
            return 0
        }
        defer { Self.passGate.end() }
        return try compactExclusively(store: store)
    }

    private func compactExclusively(store: Store) throws -> Int {
        // Short critical section: reading the candidate rows excludes writers,
        // encoding them does not.
        let unfinalized = try store.withExclusiveMaintenance {
            try loadUnfinalized(store: store)
        }
        guard unfinalized.count >= minBatchSize else {
            log.debug(
                "compaction skipped: unfinalized=\(unfinalized.count) < minBatchSize=\(self.minBatchSize)"
            )
            return 0
        }

        log.info(
            "Starting compaction (unfinalized count: \(unfinalized.count), minBatchSize: \(self.minBatchSize))"
        )

        let runs = Self.buildResolutionRuns(
            frames: unfinalized,
            maxGapMs: maxGapMs
        )
        log.info(
            "processChunk: built \(runs.count) resolution run(s) from \(unfinalized.count) frames"
        )

        var compacted = 0
        var skipped = 0
        for (runIndex, run) in runs.enumerated() {
            guard run.count >= minRunSize else {
                skipped += run.count
                continue
            }
            let first = run[0]
            log.info(
                "run[\(runIndex)]: \(first.width)x\(first.height), \(run.count) frames (ids \(first.id)..\(run[run.count - 1].id))"
            )
            do {
                let n = try compactRun(frames: run, store: store)
                compacted += n
                skipped += run.count - n
            } catch {
                // Leave all frames in this run untouched; continue other runs.
                skipped += run.count
                log.error(
                    "compaction run failed (\(first.width)x\(first.height), ids \(first.id)..\(run[run.count - 1].id)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        log.info("Compacted \(compacted) frames into video(s) (skipped=\(skipped))")
        return compacted
    }

    // MARK: - Load / group

    /// One unfinalized still eligible for compaction.
    public struct UnfinalizedFrame: Sendable, Equatable {
        public var id: Int64
        public var path: String
        public var width: Int
        public var height: Int
        public var timestampMs: Int64
        /// Stable display identity from `capture_display_*` (nil when unknown).
        public var displayKey: String?

        public init(
            id: Int64,
            path: String,
            width: Int,
            height: Int,
            timestampMs: Int64,
            displayKey: String? = nil
        ) {
            self.id = id
            self.path = path
            self.width = width
            self.height = height
            self.timestampMs = timestampMs
            self.displayKey = displayKey
        }

        public var resolutionKey: String { "\(width)x\(height)" }
    }

    /// Chronological runs sharing resolution and display without large gaps.
    /// Frames from simultaneous multi-display captures are interleaved in the
    /// database, so each display stream must be grouped independently.
    public static func buildResolutionRuns(
        frames: [UnfinalizedFrame],
        maxGapMs: Int64
    ) -> [[UnfinalizedFrame]] {
        guard !frames.isEmpty else { return [] }

        struct StreamKey: Hashable {
            var display: String?
        }

        var streams: [StreamKey: [UnfinalizedFrame]] = [:]
        for frame in frames {
            let key = StreamKey(display: frame.displayKey)
            streams[key, default: []].append(frame)
        }

        var runs: [[UnfinalizedFrame]] = []
        for stream in streams.values {
            let ordered = stream.sorted {
                ($0.timestampMs, $0.id) < ($1.timestampMs, $1.id)
            }
            guard let first = ordered.first else { continue }
            var current = [first]
            for frame in ordered.dropFirst() {
                guard let previous = current.last else { continue }
                let gap = frame.timestampMs - previous.timestampMs
                let sameResolution =
                    frame.width == previous.width && frame.height == previous.height
                if sameResolution, gap >= 0, gap <= maxGapMs {
                    current.append(frame)
                } else {
                    runs.append(current)
                    current = [frame]
                }
            }
            runs.append(current)
        }

        return runs.sorted { lhs, rhs in
            guard let left = lhs.first, let right = rhs.first else { return !lhs.isEmpty }
            return (left.timestampMs, left.id) < (right.timestampMs, right.id)
        }
    }

    private func loadUnfinalized(store: Store) throws -> [UnfinalizedFrame] {
        let sql = """
            SELECT id, image_path, width, height, timestamp,
                   capture_display_x, capture_display_y,
                   capture_display_width, capture_display_height
            FROM frame
            WHERE image_path IS NOT NULL AND video IS NULL
            ORDER BY timestamp ASC, id ASC
            LIMIT ?
            """
        let stmt = try store.db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int(stmt, 1, loadLimit)

        var rows: [UnfinalizedFrame] = []
        var missingIDs: [Int64] = []
        var noDimensions = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = SQLiteColumn.int64(stmt, 0)
            guard let path = SQLiteColumn.text(stmt, 1) else { continue }
            let w = SQLiteColumn.intOptional(stmt, 2) ?? 0
            let h = SQLiteColumn.intOptional(stmt, 3) ?? 0
            let ts = SQLiteColumn.int64(stmt, 4)

            if w <= 0 || h <= 0 {
                noDimensions += 1
                continue
            }
            if !FileManager.default.fileExists(atPath: path) {
                missingIDs.append(id)
                continue
            }

            let displayKey = Self.makeDisplayKey(
                x: SQLiteColumn.doubleOptional(stmt, 5),
                y: SQLiteColumn.doubleOptional(stmt, 6),
                width: SQLiteColumn.doubleOptional(stmt, 7),
                height: SQLiteColumn.doubleOptional(stmt, 8)
            )
            rows.append(
                UnfinalizedFrame(
                    id: id,
                    path: path,
                    width: w,
                    height: h,
                    timestampMs: ts,
                    displayKey: displayKey
                )
            )
        }

        if !missingIDs.isEmpty {
            // Clear dangling image paths so maintenance does not retry missing files forever.
            try clearMissingImagePaths(ids: missingIDs, store: store)
            log.info("Cleared image_path for \(missingIDs.count) frames with missing image files")
        }
        if noDimensions > 0 {
            log.info("skipped before grouping: missingFile=\(missingIDs.count), noDimensions=\(noDimensions)")
        }
        return rows
    }

    /// Rounded display rect key; nil components to nil key (unknown display groups together).
    public static func makeDisplayKey(x: Double?, y: Double?, width: Double?, height: Double?) -> String? {
        guard let x, let y, let width, let height, width > 0, height > 0 else { return nil }
        // Round to whole points to absorb float noise.
        return "\(Int(x.rounded())),\(Int(y.rounded())),\(Int(width.rounded())),\(Int(height.rounded()))"
    }

    private func clearMissingImagePaths(ids: [Int64], store: Store) throws {
        guard !ids.isEmpty else { return }
        try store.db.transaction {
            for id in ids {
                let upd = try store.db.prepare(
                    "UPDATE frame SET image_path = NULL WHERE id = ? AND video IS NULL"
                )
                defer { sqlite3_finalize(upd) }
                SQLiteBind.int64(upd, 1, id)
                _ = sqlite3_step(upd)
            }
        }
    }

    // MARK: - Encode run

    /// Returns count of frames actually committed to a video segment.
    @discardableResult
    private func compactRun(frames: [UnfinalizedFrame], store: Store) throws -> Int {
        guard let first = frames.first else { return 0 }
        let width = first.width
        let height = first.height
        // HEVC / most VT encoders prefer even dimensions.
        let encodeW = width - (width % 2)
        let encodeH = height - (height % 2)
        guard encodeW >= 2, encodeH >= 2 else {
            throw CompactionError.encodeFailed("invalid encode size \(width)x\(height)")
        }

        let outDir = ScreenlogPaths.videosDirectory(root: store.root)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let token = UUID().uuidString.prefix(8)
        let baseName = "v_\(first.id)_\(frames.count)_\(token)"
        let tempURL = outDir.appendingPathComponent("\(baseName).tmp.mp4")
        let finalURL = outDir.appendingPathComponent("\(baseName).mp4")

        // Clean any leftover from a previous crash.
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: finalURL)

        log.info(
            "Processing resolution \(width)x\(height) with \(frames.count) frames -> temp=\(tempURL.lastPathComponent, privacy: .private(mask: .hash))"
        )

        let encoded: [UnfinalizedFrame]
        do {
            encoded = try encodeFrames(
                frames: frames,
                width: encodeW,
                height: encodeH,
                outputURL: tempURL
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        guard !encoded.isEmpty else {
            try? FileManager.default.removeItem(at: tempURL)
            log.info(
                "processedFrameIds empty for \(width)x\(height); removed temp file"
            )
            return 0
        }

        // Promote temp to final only after a successful encode session.
        do {
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw CompactionError.encodeFailed("rename failed: \(error.localizedDescription)")
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?
            .int64Value

        do {
            try store.db.transaction {
                // Encoding deliberately runs outside the mutation lock. Before
                // publishing the video, require every encoded frame to still
                // own the exact still that supplied its pixels. Linking only a
                // surviving subset would leave pixels from a concurrently
                // deleted moment embedded in the shared video file.
                let validate = try store.db.prepare(
                    """
                    SELECT 1
                    FROM frame
                    WHERE id = ? AND video IS NULL AND image_path = ?
                    LIMIT 1
                    """
                )
                defer { sqlite3_finalize(validate) }
                for frame in encoded {
                    sqlite3_reset(validate)
                    sqlite3_clear_bindings(validate)
                    SQLiteBind.int64(validate, 1, frame.id)
                    SQLiteBind.text(validate, 2, frame.path)
                    guard sqlite3_step(validate) == SQLITE_ROW else {
                        throw CompactionCandidateSetChanged()
                    }
                }

                let ins = try store.db.prepare(
                    """
                    INSERT INTO video(height, width, path, num_frames, size_bytes, status)
                    VALUES(?,?,?,?,?,0)
                    """
                )
                defer { sqlite3_finalize(ins) }
                SQLiteBind.int(ins, 1, encodeH)
                SQLiteBind.int(ins, 2, encodeW)
                SQLiteBind.text(ins, 3, finalURL.path)
                SQLiteBind.int(ins, 4, encoded.count)
                SQLiteBind.int64(ins, 5, size)
                if sqlite3_step(ins) != SQLITE_DONE {
                    throw CompactionError.db("INSERT video failed")
                }
                let videoID = store.db.lastInsertRowID()

                // Only frames that were actually encoded get video / video_index and still deletion.
                for (videoIndex, frame) in encoded.enumerated() {
                    let upd = try store.db.prepare(
                        """
                        UPDATE frame
                        SET video = ?, video_index = ?, image_path = NULL
                        WHERE id = ? AND video IS NULL AND image_path IS NOT NULL
                        """
                    )
                    defer { sqlite3_finalize(upd) }
                    SQLiteBind.int64(upd, 1, videoID)
                    SQLiteBind.int(upd, 2, videoIndex)
                    SQLiteBind.int64(upd, 3, frame.id)
                    if sqlite3_step(upd) != SQLITE_DONE {
                        throw CompactionError.db("UPDATE frame \(frame.id) failed")
                    }
                    guard store.db.changes() == 1 else {
                        throw CompactionCandidateSetChanged()
                    }
                }
            }
        } catch is CompactionCandidateSetChanged {
            // A reviewed deletion or retention pass won the race. Discard the
            // entire video because it contains pixels from the old candidate
            // set, even if some rows still exist. A later pass can safely
            // compact the remaining stills.
            try? FileManager.default.removeItem(at: finalURL)
            log.info("compaction candidate set changed during encode; discarded output")
            return 0
        } catch {
            // DB failed after encode: remove video file so we don't orphan pixels without metadata.
            // Stills remain on disk and rows stay unfinalized.
            try? FileManager.default.removeItem(at: finalURL)
            throw error
        }

        // Delete stills only after every encoded row committed its video link.
        for frame in encoded {
            try? FileManager.default.removeItem(atPath: frame.path)
        }

        let skippedInRun = frames.count - encoded.count
        log.info(
            "compacted \(encoded.count) frames -> \(finalURL.lastPathComponent, privacy: .private(mask: .hash)) (decode/encode skipped in run=\(skippedInRun))"
        )
        return encoded.count
    }

    /// Encode stills into `outputURL`. Returns frames that were successfully appended, in order.
    /// Throws if the writer session fails; partial pixel-decode failures skip that frame only.
    private func encodeFrames(
        frames: [UnfinalizedFrame],
        width: Int,
        height: Int,
        outputURL: URL
    ) throws -> [UnfinalizedFrame] {
        let session = try Self.makeWriterSession(
            outputURL: outputURL,
            width: width,
            height: height
        )
        let writer = session.writer
        let input = session.input
        let adaptor = session.adaptor

        guard writer.startWriting() else {
            throw CompactionError.encodeFailed(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        writer.startSession(atSourceTime: .zero)

        var encoded: [UnfinalizedFrame] = []
        var decodeFailed = 0
        var missing = 0
        var appendIndex = 0

        for frame in frames {
            if !FileManager.default.fileExists(atPath: frame.path) {
                missing += 1
                log.warning("missing still during encode, skip frame id=\(frame.id)")
                continue
            }
            guard let pb = Self.pixelBuffer(path: frame.path, width: width, height: height) else {
                decodeFailed += 1
                log.warning("decode failed, skip frame id=\(frame.id) path=\(frame.path, privacy: .private(mask: .hash))")
                continue
            }

            // Wait until the writer can accept more samples (bounded). This
            // parks the calling thread, which is why every entry point runs on
            // a dedicated queue rather than a cooperative pool thread.
            let deadline = Date().addingTimeInterval(readyTimeout)
            while !input.isReadyForMoreMediaData {
                if Date() > deadline {
                    writer.cancelWriting()
                    throw CompactionError.encodeFailed("timeout waiting for writer readiness")
                }
                if writer.status == .failed {
                    writer.cancelWriting()
                    throw CompactionError.encodeFailed(
                        writer.error?.localizedDescription ?? "writer failed while waiting"
                    )
                }
                Thread.sleep(forTimeInterval: 0.005)
            }

            let t = CMTimeMultiply(frameDuration, multiplier: Int32(appendIndex))
            guard adaptor.append(pb, withPresentationTime: t) else {
                // Do not mark this (or any subsequent) frame as encoded.
                let err = writer.error?.localizedDescription ?? "append failed"
                writer.cancelWriting()
                throw CompactionError.encodeFailed(err)
            }
            encoded.append(frame)
            appendIndex += 1
        }

        log.info(
            "Pipe phase done: processed=\(encoded.count), skipped=\(decodeFailed + missing) (missing=\(missing), decodeFailed=\(decodeFailed))"
        )

        if encoded.isEmpty {
            writer.cancelWriting()
            return []
        }

        input.markAsFinished()
        // AVFoundation finishes on its own queue. Waiting here is safe for the
        // same reason as the readiness loop above: this thread is ours.
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        let finishWait = sem.wait(timeout: .now() + 120)
        if finishWait == .timedOut {
            writer.cancelWriting()
            throw CompactionError.encodeFailed("finishWriting timed out (120s)")
        }
        if writer.status != .completed {
            throw CompactionError.encodeFailed(
                writer.error?.localizedDescription ?? "writer status=\(writer.status.rawValue)"
            )
        }
        return encoded
    }

    // MARK: - Writer setup (HEVC to H.264 fallback)

    private struct WriterSession {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let codec: AVVideoCodecType
    }

    private static func makeWriterSession(
        outputURL: URL,
        width: Int,
        height: Int
    ) throws -> WriterSession {
        let codecs: [AVVideoCodecType] = [.hevc, .h264]
        var lastError: Error?

        for codec in codecs {
            do {
                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
                let compressionProperties = Self.compressionProperties(
                    width: width,
                    height: height,
                    codec: codec
                )
                let settings: [String: Any] = [
                    AVVideoCodecKey: codec,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: compressionProperties,
                ]
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                input.expectsMediaDataInRealTime = false

                let attrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                ]
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: attrs
                )

                guard writer.canAdd(input) else {
                    throw CompactionError.encodeFailed("cannot add input for \(codec.rawValue)")
                }
                writer.add(input)

                log.info("encoder session: codec=\(codec.rawValue, privacy: .public) \(width)x\(height)")
                return WriterSession(writer: writer, input: input, adaptor: adaptor, codec: codec)
            } catch {
                lastError = error
                log.warning(
                    "encoder \(codec.rawValue, privacy: .public) unavailable: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        throw CompactionError.encodeFailed(
            lastError?.localizedDescription ?? "no video codec available"
        )
    }

    /// Screen captures need materially more precision than camera footage at
    /// the same dimensions because one-pixel text edges must survive. Scale the
    /// target with pixel count and keep conservative floors for small captures.
    static func targetAverageBitRate(
        width: Int,
        height: Int,
        codec: AVVideoCodecType
    ) -> Int {
        let pixels = max(1, width) * max(1, height)
        let bitsPerPixelPerSecond = codec == .hevc ? 1.2 : 1.6
        let floor = codec == .hevc ? 4_000_000 : 6_000_000
        let scaled = Int((Double(pixels) * bitsPerPixelPerSecond).rounded())
        return min(60_000_000, max(floor, scaled))
    }

    static func compressionProperties(
        width: Int,
        height: Int,
        codec: AVVideoCodecType
    ) -> [String: Any] {
        let profile: String =
            codec == .hevc
            ? (kVTProfileLevel_HEVC_Main_AutoLevel as String)
            : AVVideoProfileLevelH264HighAutoLevel
        return [
            AVVideoAverageBitRateKey: targetAverageBitRate(
                width: width,
                height: height,
                codec: codec
            ),
            AVVideoQualityKey: 0.96,
            AVVideoExpectedSourceFrameRateKey: 2,
            AVVideoMaxKeyFrameIntervalKey: 10,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: profile,
        ]
    }

    // MARK: - Pixel path (HEIC/JPEG/PNG to BGRA CVPixelBuffer)

    private static func pixelBuffer(path: String, width: Int, height: Int) -> CVPixelBuffer? {
        let url = URL(fileURLWithPath: path)
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: true]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary),
            let image = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
        else { return nil }

        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let pb else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(pb),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }
}

private struct CompactionCandidateSetChanged: Error {}

// MARK: - Pass serialization

/// Process-wide "one compaction pass at a time" gate. Skipping is deliberate:
/// a second pass has nothing useful to do while the first one owns the current
/// unfinalized frames, and blocking a caller for the length of an encode would
/// be worse than reporting that there was nothing to compact.
final class CompactionPassGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isRunning = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isRunning { return false }
        isRunning = true
        return true
    }

    func end() {
        lock.lock()
        isRunning = false
        lock.unlock()
    }
}

// MARK: - Errors

public enum CompactionError: Error, LocalizedError, Equatable {
    case encodeFailed(String)
    case db(String)

    public var errorDescription: String? {
        switch self {
        case .encodeFailed(let m): return "encode failed: \(m)"
        case .db(let m): return "compaction db error: \(m)"
        }
    }
}
