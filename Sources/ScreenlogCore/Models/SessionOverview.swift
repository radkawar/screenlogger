import Foundation

/// Recorded evidence only: no generated summary or inferred work description.
public struct SessionOverview: Sendable, Equatable {
    public struct Activity: Sendable, Equatable, Identifiable {
        public let identifier: String
        public let displayName: String
        public let durationMs: Int64
        public let momentCount: Int64
        public var id: String { identifier }
    }

    /// Lightweight preview/navigation metadata; never loads OCR, AX trees or image bytes.
    public struct Moment: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let timestampMs: Int64
        public let title: String?
        public let bundleID: String?
        public let appLabel: String
        public let domain: String?
        public let imagePath: String?
        public let videoID: Int64?
    }

    public let momentCount: Int64
    public let coveredDurationMs: Int64
    public let applicationCount: Int
    public let domainCount: Int
    public let applications: [Activity]
    public let domains: [Activity]
    public let moments: [Moment]
    public let gapThresholdMs: Int64
}
