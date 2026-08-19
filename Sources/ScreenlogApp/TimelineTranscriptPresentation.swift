import Foundation
import ScreenlogCore

/// Readable Timeline-only grouping for finalized transcript segments. Storage
/// remains lossless; passages are rebuilt from the underlying segments so
/// search, export, and deletion continue to operate on canonical rows.
enum TimelineTranscriptPresentation {
    struct Passage: Identifiable, Equatable, Sendable {
        let id: Int64
        let segmentIDs: [Int64]
        let source: TranscriptSource
        let startTimestampMs: Int64
        let endTimestampMs: Int64
        let text: String

        func contains(timestampMs: Int64) -> Bool {
            startTimestampMs <= timestampMs && timestampMs <= endTimestampMs
        }
    }

    // Apple's progressive recognizer may finalize adjacent phrases a couple
    // of seconds apart. Present those canonical rows as one readable passage
    // without changing storage or search granularity.
    static let maximumMergeGapMs: Int64 = 3_000
    static let maximumPassageDurationMs: Int64 = 60_000
    static let maximumPassageCharacters = 600

    static func passages(from frames: [TimelineFrame]) -> [Passage] {
        var seen = Set<Int64>()
        let segments =
            frames
            .flatMap { $0.transcriptSegments ?? [] }
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.startTimestampMs != $1.startTimestampMs {
                    return $0.startTimestampMs < $1.startTimestampMs
                }
                return $0.id < $1.id
            }
        return passages(from: segments)
    }

    static func passages(from segments: [TranscriptSegment]) -> [Passage] {
        var passages: [Passage] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let previous = passages.last,
                previous.source == segment.source,
                segment.startTimestampMs >= previous.startTimestampMs,
                segment.startTimestampMs - previous.endTimestampMs <= maximumMergeGapMs,
                segment.endTimestampMs - previous.startTimestampMs <= maximumPassageDurationMs,
                previous.text.count + 1 + text.count <= maximumPassageCharacters
            {
                passages[passages.count - 1] = Passage(
                    id: previous.id,
                    segmentIDs: previous.segmentIDs + [segment.id],
                    source: previous.source,
                    startTimestampMs: previous.startTimestampMs,
                    endTimestampMs: max(previous.endTimestampMs, segment.endTimestampMs),
                    text: previous.text + " " + text
                )
            } else {
                passages.append(
                    Passage(
                        id: segment.id,
                        segmentIDs: [segment.id],
                        source: segment.source,
                        startTimestampMs: segment.startTimestampMs,
                        endTimestampMs: segment.endTimestampMs,
                        text: text
                    )
                )
            }
        }
        return passages
    }

    static func visiblePassages(
        from passages: [Passage],
        selectedTimestampMs: Int64,
        limit: Int = 3,
        maximumContextDistanceMs: Int64 = 10_000
    ) -> [Passage] {
        guard !passages.isEmpty else { return [] }
        let nearestDistance =
            passages.lazy.map { passage in
                if passage.contains(timestampMs: selectedTimestampMs) { return Int64(0) }
                if selectedTimestampMs < passage.startTimestampMs {
                    return passage.startTimestampMs - selectedTimestampMs
                }
                return selectedTimestampMs - passage.endTimestampMs
            }.min() ?? Int64.max
        guard nearestDistance <= maximumContextDistanceMs else { return [] }
        let visibleLimit = max(1, limit)
        let anchor =
            passages.firstIndex { $0.contains(timestampMs: selectedTimestampMs) }
            ?? passages.lastIndex { $0.startTimestampMs <= selectedTimestampMs }
            ?? 0
        let maximumStart = max(0, passages.count - visibleLimit)
        let start = min(maximumStart, max(0, anchor - 1))
        return Array(passages[start..<min(passages.count, start + visibleLimit)])
    }
}
