import Foundation

public struct ApplicationRow: Sendable, Equatable, Codable {
    public var id: Int64
    public var bundleID: String
    public var version: String
    public var displayName: String?
    public var iconPath: String?
    public var isUserApp: Bool?
    public var dominantColor: Int?

    public init(
        id: Int64,
        bundleID: String,
        version: String = "",
        displayName: String? = nil,
        iconPath: String? = nil,
        isUserApp: Bool? = nil,
        dominantColor: Int? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.version = version
        self.displayName = displayName
        self.iconPath = iconPath
        self.isUserApp = isUserApp
        self.dominantColor = dominantColor
    }
}

public struct DomainRow: Sendable, Equatable, Codable {
    public var id: Int64
    public var normalizedDomain: String
    public var commonName: String?
    public var iconPath: String?
    public var dominantColor: Int?

    public init(
        id: Int64,
        normalizedDomain: String,
        commonName: String? = nil,
        iconPath: String? = nil,
        dominantColor: Int? = nil
    ) {
        self.id = id
        self.normalizedDomain = normalizedDomain
        self.commonName = commonName
        self.iconPath = iconPath
        self.dominantColor = dominantColor
    }
}

public struct SegmentRow: Sendable, Equatable, Codable {
    public var id: Int64
    public var startFrameID: Int64
    public var applicationID: Int64?
    public var domainID: Int64?
    public var url: String?

    public init(id: Int64, startFrameID: Int64, applicationID: Int64? = nil, domainID: Int64? = nil, url: String? = nil) {
        self.id = id
        self.startFrameID = startFrameID
        self.applicationID = applicationID
        self.domainID = domainID
        self.url = url
    }
}

public struct FrameRow: Sendable, Equatable, Codable {
    public var id: Int64
    public var timestampMs: Int64
    public var imagePath: String?
    public var width: Int?
    public var height: Int?
    public var foreground: String?
    public var background: String?
    public var title: String?
    public var segmentID: Int64?
    public var videoID: Int64?
    public var videoIndex: Int?
    public var isInactive: Bool
    /// SHA-256 of content-addressed AX root (`frame.ax_root_hash`).
    public var axRootHash: Data?
    /// Captured display rect in global CG points (`frame.capture_display_*`, REAL).
    public var captureDisplay: CaptureDisplayRect?
    /// Integer convenience aliases of capture display (rounded).
    public var displayX: Int? { captureDisplay.map { Int($0.x.rounded()) } }
    public var displayY: Int? { captureDisplay.map { Int($0.y.rounded()) } }
    public var displayWidth: Int? { captureDisplay.map { Int($0.width.rounded()) } }
    public var displayHeight: Int? { captureDisplay.map { Int($0.height.rounded()) } }

    public init(
        id: Int64,
        timestampMs: Int64,
        imagePath: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        foreground: String? = nil,
        background: String? = nil,
        title: String? = nil,
        segmentID: Int64? = nil,
        videoID: Int64? = nil,
        videoIndex: Int? = nil,
        isInactive: Bool = false,
        axRootHash: Data? = nil,
        captureDisplay: CaptureDisplayRect? = nil
    ) {
        self.id = id
        self.timestampMs = timestampMs
        self.imagePath = imagePath
        self.width = width
        self.height = height
        self.foreground = foreground
        self.background = background
        self.title = title
        self.segmentID = segmentID
        self.videoID = videoID
        self.videoIndex = videoIndex
        self.isInactive = isInactive
        self.axRootHash = axRootHash
        self.captureDisplay = captureDisplay
    }

    public var ocrText: String {
        [foreground, background].compactMap { $0 }.joined()
    }
}

public struct OCRBox: Sendable, Equatable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var textOffset: Int
    public var textLength: Int

    public init(x: Int, y: Int, width: Int, height: Int, textOffset: Int, textLength: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.textOffset = textOffset
        self.textLength = textLength
    }
}

public struct WindowBound: Sendable, Equatable, Codable {
    public var applicationID: Int64?
    public var bundleID: String?
    public var windowTitle: String?
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var windowLayer: Int
    public var zOrder: Int
    public var url: String?

    public init(
        applicationID: Int64? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        windowLayer: Int = 0,
        zOrder: Int = 0,
        url: String? = nil
    ) {
        self.applicationID = applicationID
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.windowLayer = windowLayer
        self.zOrder = zOrder
        self.url = url
    }
}

public struct CaptureDisplayRect: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct CapturePayload: Sendable {
    public var imageData: Data
    public var timestampMs: Int64
    public var width: Int
    public var height: Int
    public var foreground: String
    public var background: String
    public var title: String
    public var bundleID: String?
    public var bundleVersion: String
    public var displayName: String?
    public var url: String?
    public var domain: String?
    public var ocrBoxes: [OCRBox]
    public var windowBounds: [WindowBound]
    public var isInactive: Bool
    public var imageFileExtension: String
    public var captureDisplay: CaptureDisplayRect?

    public init(
        imageData: Data,
        timestampMs: Int64,
        width: Int,
        height: Int,
        foreground: String = "",
        background: String = "",
        title: String = "",
        bundleID: String? = nil,
        bundleVersion: String = "",
        displayName: String? = nil,
        url: String? = nil,
        domain: String? = nil,
        ocrBoxes: [OCRBox] = [],
        windowBounds: [WindowBound] = [],
        isInactive: Bool = false,
        imageFileExtension: String = "heic",
        captureDisplay: CaptureDisplayRect? = nil
    ) {
        self.imageData = imageData
        self.timestampMs = timestampMs
        self.width = width
        self.height = height
        self.foreground = foreground
        self.background = background
        self.title = title
        self.bundleID = bundleID
        self.bundleVersion = bundleVersion
        self.displayName = displayName
        self.url = url
        self.domain = domain
        self.ocrBoxes = ocrBoxes
        self.windowBounds = windowBounds
        self.isInactive = isInactive
        self.imageFileExtension = imageFileExtension
        self.captureDisplay = captureDisplay
    }
}

public struct FTSResult: Sendable, Equatable, Codable {
    public var frameID: Int64
    public var timestampMs: Int64
    public var title: String?
    public var bundleID: String?
    /// Application display name from segment join (when known).
    public var displayName: String?
    public var domain: String?
    public var snippet: String?
    /// On-disk still path when the frame has not been compacted yet.
    public var imagePath: String?
    /// True when the still was compacted into video (preview needs extract).
    public var isCompacted: Bool
    /// Present when the matching text came from on-device audio transcription.
    public var transcriptSegmentID: Int64?
    public var transcriptSource: TranscriptSource?
    public var transcriptStartTimestampMs: Int64?
    public var transcriptEndTimestampMs: Int64?

    public init(
        frameID: Int64,
        timestampMs: Int64,
        title: String? = nil,
        bundleID: String? = nil,
        displayName: String? = nil,
        domain: String? = nil,
        snippet: String? = nil,
        imagePath: String? = nil,
        isCompacted: Bool = false,
        transcriptSegmentID: Int64? = nil,
        transcriptSource: TranscriptSource? = nil,
        transcriptStartTimestampMs: Int64? = nil,
        transcriptEndTimestampMs: Int64? = nil
    ) {
        self.frameID = frameID
        self.timestampMs = timestampMs
        self.title = title
        self.bundleID = bundleID
        self.displayName = displayName
        self.domain = domain
        self.snippet = snippet
        self.imagePath = imagePath
        self.isCompacted = isCompacted
        self.transcriptSegmentID = transcriptSegmentID
        self.transcriptSource = transcriptSource
        self.transcriptStartTimestampMs = transcriptStartTimestampMs
        self.transcriptEndTimestampMs = transcriptEndTimestampMs
    }

    /// Prefer display name, then last bundle path component, else a generic label.
    public var appLabel: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let bundleID, !bundleID.isEmpty {
            return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
        return "Moment"
    }

    /// True when a still file exists on disk for instant thumbnail paint.
    public var hasStillThumbnail: Bool {
        guard let imagePath, !imagePath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: imagePath)
    }
}

/// Current media backing for a captured moment.
///
/// Search results can remain visible while background compaction replaces a
/// still with a video frame. Preview loaders therefore resolve this descriptor
/// from the Store at decode time instead of trusting an old `imagePath` snapshot.
public enum FramePreviewSource: Sendable, Equatable {
    case still(path: String)
    case video(path: String, index: Int)
    case unavailable
}

public struct FramePreviewDescriptor: Sendable, Equatable {
    public var frameID: Int64
    public var timestampMs: Int64
    public var source: FramePreviewSource

    public init(frameID: Int64, timestampMs: Int64, source: FramePreviewSource) {
        self.frameID = frameID
        self.timestampMs = timestampMs
        self.source = source
    }
}

/// The local audio stream that produced a transcript segment.
public enum TranscriptSource: String, Sendable, Equatable, Codable, CaseIterable {
    case microphone
    case computer

    public var label: String {
        switch self {
        case .microphone: return "You"
        case .computer: return "Computer"
        }
    }
}

/// A finalized, on-device transcript associated with the closest captured moment.
/// Audio samples are never retained by this model or its database table.
public struct TranscriptSegment: Sendable, Equatable, Codable, Identifiable {
    public var id: Int64
    public var frameID: Int64
    public var startTimestampMs: Int64
    public var endTimestampMs: Int64
    public var source: TranscriptSource
    public var text: String
    public var localeIdentifier: String?
    public var confidence: Double?

    public init(
        id: Int64,
        frameID: Int64,
        startTimestampMs: Int64,
        endTimestampMs: Int64,
        source: TranscriptSource,
        text: String,
        localeIdentifier: String? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.frameID = frameID
        self.startTimestampMs = startTimestampMs
        self.endTimestampMs = endTimestampMs
        self.source = source
        self.text = text
        self.localeIdentifier = localeIdentifier
        self.confidence = confidence
    }
}

/// A transcript ready to persist after on-device recognition finalizes it.
public struct TranscriptSegmentDraft: Sendable, Equatable {
    public var startTimestampMs: Int64
    public var endTimestampMs: Int64
    public var source: TranscriptSource
    public var text: String
    public var localeIdentifier: String?
    public var confidence: Double?

    public init(
        startTimestampMs: Int64,
        endTimestampMs: Int64,
        source: TranscriptSource,
        text: String,
        localeIdentifier: String? = nil,
        confidence: Double? = nil
    ) {
        self.startTimestampMs = startTimestampMs
        self.endTimestampMs = endTimestampMs
        self.source = source
        self.text = text
        self.localeIdentifier = localeIdentifier
        self.confidence = confidence
    }
}

public struct UsageTopItem: Sendable, Equatable, Codable {
    public var identifier: String
    public var displayName: String?
    public var frameCount: Int64

    public init(identifier: String, displayName: String? = nil, frameCount: Int64) {
        self.identifier = identifier
        self.displayName = displayName
        self.frameCount = frameCount
    }
}

public struct SessionRow: Sendable, Equatable, Codable, Identifiable {
    public var startMs: Int64
    public var endMs: Int64
    public var frameCount: Int64
    /// Bundle id of the earliest frame in the session (when segment/app join is available).
    public var primaryBundleID: String?
    /// Display name for `primaryBundleID` when known.
    public var primaryDisplayName: String?
    /// First on-disk still in the session (optional preview thumb).
    public var previewImagePath: String?

    public init(
        startMs: Int64,
        endMs: Int64,
        frameCount: Int64,
        primaryBundleID: String? = nil,
        primaryDisplayName: String? = nil,
        previewImagePath: String? = nil
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.frameCount = frameCount
        self.primaryBundleID = primaryBundleID
        self.primaryDisplayName = primaryDisplayName
        self.previewImagePath = previewImagePath
    }

    /// Stable list identity. Unlike `endMs`, a session's start does not change
    /// while new moments are appended.
    public var id: String { "session-\(startMs)" }

    /// Backward-compatible persisted pin key. Pin matching uses `startMs` so
    /// historic keys remain valid while a live session grows.
    public var pinKey: String { SessionPinning.pinKey(startMs: startMs, endMs: endMs) }

    public var durationMs: Int64 { max(0, endMs - startMs) }

    public var appLabel: String {
        if let primaryDisplayName, !primaryDisplayName.isEmpty { return primaryDisplayName }
        if let primaryBundleID, !primaryBundleID.isEmpty {
            return primaryBundleID.split(separator: ".").last.map(String.init) ?? primaryBundleID
        }
        return "Session"
    }
}

public struct RecordingStats: Sendable, Equatable, Codable {
    public var totalFrames: Int64
    public var minTimestampMs: Int64?
    public var maxTimestampMs: Int64?
    public var unfinalizedFrames: Int64
    /// Synchronized capture intervals. Older hosts omit these fields, so
    /// clients fall back to physical frame counts during a rolling update.
    public var totalMoments: Int64?
    public var unfinalizedMoments: Int64?

    public init(
        totalFrames: Int64,
        minTimestampMs: Int64?,
        maxTimestampMs: Int64?,
        unfinalizedFrames: Int64,
        totalMoments: Int64? = nil,
        unfinalizedMoments: Int64? = nil
    ) {
        self.totalFrames = totalFrames
        self.minTimestampMs = minTimestampMs
        self.maxTimestampMs = maxTimestampMs
        self.unfinalizedFrames = unfinalizedFrames
        self.totalMoments = totalMoments
        self.unfinalizedMoments = unfinalizedMoments
    }

    public var momentCount: Int64 { totalMoments ?? totalFrames }
    public var unfinalizedMomentCount: Int64 { unfinalizedMoments ?? unfinalizedFrames }
}

/// Host status snapshot returned by `xpcGetStatus` (JSON over XPC).
public struct DaemonStatus: Sendable, Equatable, Codable {
    public var version: String
    public var recording: Bool
    /// Expected reason a running engine is not currently saving frames.
    public var pauseReason: CapturePauseReason?
    public var connections: Int
    public var totalFrames: Int64?
    public var unfinalizedFrames: Int64?
    public var minTimestampMs: Int64?
    public var maxTimestampMs: Int64?
    public var screenRecording: Bool?
    public var accessibility: Bool?
    public var dataRoot: String?

    public init(
        version: String,
        recording: Bool,
        pauseReason: CapturePauseReason? = nil,
        connections: Int,
        totalFrames: Int64? = nil,
        unfinalizedFrames: Int64? = nil,
        minTimestampMs: Int64? = nil,
        maxTimestampMs: Int64? = nil,
        screenRecording: Bool? = nil,
        accessibility: Bool? = nil,
        dataRoot: String? = nil
    ) {
        self.version = version
        self.recording = recording
        self.pauseReason = pauseReason
        self.connections = connections
        self.totalFrames = totalFrames
        self.unfinalizedFrames = unfinalizedFrames
        self.minTimestampMs = minTimestampMs
        self.maxTimestampMs = maxTimestampMs
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.dataRoot = dataRoot
    }
}

/// Result of host-side frame image extract (still path and/or base64).
public struct ExtractImageResult: Sendable, Equatable, Codable {
    public var frameID: Int64
    public var timestampMs: Int64
    public var path: String?
    public var base64: String?
    public var fileExtension: String
    public var byteCount: Int
    public var source: String

    public init(
        frameID: Int64,
        timestampMs: Int64,
        path: String? = nil,
        base64: String? = nil,
        fileExtension: String,
        byteCount: Int,
        source: String
    ) {
        self.frameID = frameID
        self.timestampMs = timestampMs
        self.path = path
        self.base64 = base64
        self.fileExtension = fileExtension
        self.byteCount = byteCount
        self.source = source
    }
}

/// Recent frame with segment metadata for History / Timeline UI.
public struct TimelineFrame: Sendable, Equatable, Codable, Identifiable {
    public var id: Int64
    public var timestampMs: Int64
    public var imagePath: String?
    /// Stored media pixel dimensions. Preview images may be downsampled further.
    public var width: Int?
    public var height: Int?
    public var title: String?
    /// Focused-app OCR layer (`frame.foreground`).
    public var foreground: String?
    /// Other-window OCR layer (`frame.background`); OCR box offsets address `foreground||background`.
    public var background: String?
    public var bundleID: String?
    public var displayName: String?
    public var domain: String?
    public var url: String?
    /// Activity segment used for navigation and timeline band coloring.
    public var segmentID: Int64?
    /// Compacted video row id when still was deleted after encode.
    public var videoID: Int64?
    /// Index within the compacted video (for on-select extract).
    public var videoIndex: Int?
    /// Global display geometry for this view of a synchronized moment.
    public var captureDisplay: CaptureDisplayRect?
    /// Finalized captions associated with this moment. Optional for rolling XPC compatibility.
    public var transcriptSegments: [TranscriptSegment]?

    public init(
        id: Int64,
        timestampMs: Int64,
        imagePath: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        title: String? = nil,
        foreground: String? = nil,
        background: String? = nil,
        bundleID: String? = nil,
        displayName: String? = nil,
        domain: String? = nil,
        url: String? = nil,
        segmentID: Int64? = nil,
        videoID: Int64? = nil,
        videoIndex: Int? = nil,
        captureDisplay: CaptureDisplayRect? = nil,
        transcriptSegments: [TranscriptSegment]? = nil
    ) {
        self.id = id
        self.timestampMs = timestampMs
        self.imagePath = imagePath
        self.width = width
        self.height = height
        self.title = title
        self.foreground = foreground
        self.background = background
        self.bundleID = bundleID
        self.displayName = displayName
        self.domain = domain
        self.url = url
        self.segmentID = segmentID
        self.videoID = videoID
        self.videoIndex = videoIndex
        self.captureDisplay = captureDisplay
        self.transcriptSegments = transcriptSegments
    }

    /// Still file gone but frame lives in a compacted video - show list placeholder, extract on select.
    public var isCompacted: Bool {
        let hasStill = imagePath.map { !$0.isEmpty } ?? false
        return !hasStill && videoID != nil && videoIndex != nil
    }

    /// Concatenated OCR text used by box offsets (`foreground || background`).
    public var ocrText: String {
        [foreground, background].compactMap { $0 }.joined()
    }

    public var ocrPreview: String {
        let text = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        if text.count <= 160 { return text }
        return String(text.prefix(160)) + "..."
    }

    public var appLabel: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let bundleID, !bundleID.isEmpty { return bundleID }
        return "Unknown app"
    }

    /// Stable capture order that remains correct after backup restoration,
    /// where database identifiers may no longer increase with timestamps.
    public static func chronologicalAscending(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs < rhs.timestampMs }
        return lhs.id < rhs.id
    }
}
