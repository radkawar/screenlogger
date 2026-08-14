import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import OSLog
import SQLite3
import UniformTypeIdentifiers

private let log = Logger(subsystem: "dev.screenlog", category: "frame-extract")

/// Shared interaction policy for Timeline preview work.
///
/// Pointer drags commonly publish selections faster than ImageIO can decode them. A short
/// latest-selection delay prevents obsolete work while remaining below a perceptible pause.
/// Neighbor prefetch starts only after the selection has settled and uses the same display size,
/// so a cache hit never substitutes a blurry low-resolution image on the stage.
public enum TimelinePreviewPolicy {
    public static let selectionDebounceMilliseconds = 45
    public static let neighborPrefetchDelayMilliseconds = 120
    /// Covers Apple's 6K displays without stretching a low-resolution preview
    /// across the Timeline stage. ImageIO still avoids decoding beyond source size.
    public static let selectedMaxPixelSize = 6_144
    public static let neighborRadius = 1

    /// Indices whose selection would remain current long enough to start expensive work.
    /// This pure model is also used to keep the benchmark workload aligned with UI behavior.
    public static func settledSelectionIndices(
        eventOffsetsMilliseconds: [Int],
        debounceMilliseconds: Int = selectionDebounceMilliseconds
    ) -> [Int] {
        guard debounceMilliseconds >= 0 else { return [] }
        if eventOffsetsMilliseconds.indices.dropFirst().contains(where: { index in
            eventOffsetsMilliseconds[index] < eventOffsetsMilliseconds[index - 1]
        }) {
            return []
        }

        return eventOffsetsMilliseconds.indices.filter { index in
            guard index + 1 < eventOffsetsMilliseconds.count else { return true }
            return eventOffsetsMilliseconds[index + 1] - eventOffsetsMilliseconds[index]
                >= debounceMilliseconds
        }
    }
}

/// Extracts a still `CGImage` from a compacted video at a given `video_index`.
/// Matches the presentation timing used by `VideoCompactionService` (~0.5 fps, 2s/frame).
public enum FrameExtractor {
    /// Default frame duration written by compaction (1/2 second).
    public static let defaultFrameDuration = CMTime(value: 1, timescale: 2)
    /// Avoid visibly compounding loss when a video-backed moment is exported.
    public static let exportedStillQuality: CGFloat = 0.97

    public enum ExtractError: Error, CustomStringConvertible {
        case invalidIndex
        case assetUnreadable
        case noVideoTrack
        case imageGenerationFailed(String)

        public var description: String {
            switch self {
            case .invalidIndex: return "video_index must be >= 0"
            case .assetUnreadable: return "Could not open video asset"
            case .noVideoTrack: return "Video asset has no video track"
            case .imageGenerationFailed(let m): return "Frame extract failed: \(m)"
            }
        }
    }

    /// Presentation time for `videoIndex` given the compaction frame duration.
    public static func presentationTime(
        videoIndex: Int,
        frameDuration: CMTime = defaultFrameDuration
    ) -> CMTime {
        CMTimeMultiply(frameDuration, multiplier: Int32(max(0, videoIndex)))
    }

    /// Extract a `CGImage` for the frame stored at `video_index` inside `videoURL`.
    public static func cgImage(
        videoURL: URL,
        videoIndex: Int,
        frameDuration: CMTime = defaultFrameDuration,
        maximumSize: CGSize? = nil
    ) async throws -> CGImage {
        guard videoIndex >= 0 else { throw ExtractError.invalidIndex }

        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw ExtractError.noVideoTrack }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maximumSize {
            generator.maximumSize = maximumSize
        }

        let time = presentationTime(videoIndex: videoIndex, frameDuration: frameDuration)
        do {
            let (image, actual) = try await generator.image(at: time)
            log.debug(
                "extracted frame index=\(videoIndex) requested=\(String(describing: time)) actual=\(String(describing: actual))"
            )
            return image
        } catch {
            throw ExtractError.imageGenerationFailed(error.localizedDescription)
        }
    }

    /// Extract and encode a still (HEIC preferred, JPEG fallback) for storage or preview.
    public static func stillData(
        videoURL: URL,
        videoIndex: Int,
        frameDuration: CMTime = defaultFrameDuration,
        quality: CGFloat = exportedStillQuality
    ) async throws -> (data: Data, fileExtension: String) {
        let image = try await cgImage(
            videoURL: videoURL,
            videoIndex: videoIndex,
            frameDuration: frameDuration
        )
        if let heic = try? encode(image, type: .heic, quality: quality), !heic.isEmpty {
            return (heic, "heic")
        }
        let jpeg = try encode(image, type: .jpeg, quality: quality)
        return (jpeg, "jpg")
    }

    /// Resolve video path + index from a `FrameRow` via the store and extract the image.
    public static func cgImage(forFrame frame: FrameRow, store: Store) async throws -> CGImage {
        if let path = frame.imagePath,
            FileManager.default.fileExists(atPath: path),
            let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        {
            return image
        }
        guard let videoID = frame.videoID, let index = frame.videoIndex else {
            throw ExtractError.imageGenerationFailed("frame has no video or image_path")
        }
        let path = try videoPath(videoID: videoID, store: store)
        return try await cgImage(videoURL: URL(fileURLWithPath: path), videoIndex: index)
    }

    /// Decode a still directly at preview resolution instead of materializing the full-size image.
    public static func previewCGImage(atPath path: String, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
            FileManager.default.fileExists(atPath: path),
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Resolve a frame to a bounded-size image suitable for timeline presentation.
    public static func previewCGImage(
        forFrame frame: FrameRow,
        store: Store,
        maxPixelSize: Int
    ) async throws -> CGImage {
        try await ScreenlogPerformanceSignposts.measure(.timelineFrameExtraction) {
            guard maxPixelSize > 0 else {
                throw ExtractError.imageGenerationFailed("maxPixelSize must be greater than zero")
            }
            if let path = frame.imagePath,
                let image = previewCGImage(atPath: path, maxPixelSize: maxPixelSize)
            {
                return image
            }
            guard let videoID = frame.videoID, let index = frame.videoIndex else {
                throw ExtractError.imageGenerationFailed("frame has no video or readable image_path")
            }
            let path = try videoPath(videoID: videoID, store: store)
            let edge = CGFloat(maxPixelSize)
            return try await cgImage(
                videoURL: URL(fileURLWithPath: path),
                videoIndex: index,
                maximumSize: CGSize(width: edge, height: edge)
            )
        }
    }

    /// Decode an authoritative Store descriptor at a bounded preview size.
    public static func previewCGImage(
        for descriptor: FramePreviewDescriptor,
        maxPixelSize: Int
    ) async throws -> CGImage {
        guard maxPixelSize > 0 else {
            throw ExtractError.imageGenerationFailed("maxPixelSize must be greater than zero")
        }
        switch descriptor.source {
        case .still(let path):
            guard let image = previewCGImage(atPath: path, maxPixelSize: maxPixelSize) else {
                throw ExtractError.imageGenerationFailed("still preview is unavailable")
            }
            return image
        case .video(let path, let index):
            guard FileManager.default.fileExists(atPath: path) else {
                throw ExtractError.imageGenerationFailed("video preview is unavailable")
            }
            let edge = CGFloat(maxPixelSize)
            return try await cgImage(
                videoURL: URL(fileURLWithPath: path),
                videoIndex: index,
                maximumSize: CGSize(width: edge, height: edge)
            )
        case .unavailable:
            throw ExtractError.imageGenerationFailed("frame has no retained preview media")
        }
    }

    /// Still bytes for a frame: prefer existing `image_path`, else extract from compacted video.
    public static func stillData(
        forFrame frame: FrameRow,
        store: Store,
        quality: CGFloat = exportedStillQuality
    ) async throws -> (data: Data, fileExtension: String, source: String) {
        if let path = frame.imagePath,
            FileManager.default.fileExists(atPath: path)
        {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard !data.isEmpty else {
                throw ExtractError.imageGenerationFailed("image_path is empty: \(path)")
            }
            let ext = (path as NSString).pathExtension
            return (data, ext.isEmpty ? "bin" : ext.lowercased(), "still")
        }
        guard let videoID = frame.videoID, let index = frame.videoIndex else {
            throw ExtractError.imageGenerationFailed("frame has no video or image_path")
        }
        let path = try videoPath(videoID: videoID, store: store)
        let still = try await stillData(
            videoURL: URL(fileURLWithPath: path),
            videoIndex: index,
            quality: quality
        )
        return (still.data, still.fileExtension, "video")
    }

    /// Write a still for `frame` to `destination` (parent dirs created). Returns final URL.
    @discardableResult
    public static func writeStill(
        forFrame frame: FrameRow,
        store: Store,
        to destination: URL,
        quality: CGFloat = exportedStillQuality
    ) async throws -> URL {
        let still = try await stillData(forFrame: frame, store: store, quality: quality)
        let url: URL
        if destination.hasDirectoryPath
            || destination.pathExtension.isEmpty
        {
            let name = String(format: "frame-%lld-%lld.%@", frame.id, frame.timestampMs, still.fileExtension)
            url = destination.appendingPathComponent(name)
        } else {
            url = destination
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try still.data.write(to: url, options: .atomic)
        return url
    }

    private static func videoPath(videoID: Int64, store: Store) throws -> String {
        let stmt = try store.db.prepare(
            "SELECT path FROM video WHERE id = ? AND status = 0 LIMIT 1"
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, videoID)
        guard sqlite3_step(stmt) == SQLITE_ROW, let path = SQLiteColumn.text(stmt, 0) else {
            throw ExtractError.imageGenerationFailed("active video row \(videoID) not found")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw ExtractError.imageGenerationFailed("active video file \(videoID) not found")
        }
        return path
    }

    private static func encode(_ image: CGImage, type: UTType, quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                data as CFMutableData,
                type.identifier as CFString,
                1,
                nil
            )
        else {
            throw ExtractError.imageGenerationFailed("destination create failed")
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExtractError.imageGenerationFailed("destination finalize failed")
        }
        return data as Data
    }
}
