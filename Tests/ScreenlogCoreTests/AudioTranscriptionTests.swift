import Foundation
import SQLite3
import XCTest

@testable import ScreenlogCore

final class AudioTranscriptionTests: XCTestCase {
    private var tempRoot: URL!
    private var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = try Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testPreferenceDefaultsAreOptInWithBothSourcesReady() {
        let suite = "screenlog-audio-preferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = AudioTranscriptionPreferenceStore.load(from: defaults)
        XCTAssertFalse(initial.isEnabled)
        XCTAssertTrue(initial.computerAudioEnabled)
        XCTAssertTrue(initial.microphoneEnabled)
        XCTAssertTrue(initial.enabledSources.isEmpty)

        let enabled = AudioTranscriptionPreferenceStore.Snapshot(
            isEnabled: true,
            computerAudioEnabled: true,
            microphoneEnabled: false
        )
        AudioTranscriptionPreferenceStore.save(enabled, to: defaults)
        XCTAssertEqual(AudioTranscriptionPreferenceStore.load(from: defaults), enabled)
        XCTAssertEqual(enabled.enabledSources, [.computer])
    }

    func testTranscriptIsSearchableAndHydratesEveryDisplayInMoment() throws {
        let token = "spokenroadmap\(UUID().uuidString.prefix(8))"
            .replacingOccurrences(of: "-", with: "")
        let firstDisplay = try store.insertSeedFrame(
            timestampMs: 10_000,
            foreground: "unrelated screen text",
            title: "Meeting",
            bundleID: "us.zoom.xos",
            displayName: "Zoom"
        )
        let secondDisplay = try store.insertSeedFrame(
            timestampMs: 10_000,
            foreground: "another display",
            title: "Meeting",
            bundleID: "us.zoom.xos",
            displayName: "Zoom"
        )

        let stored = try XCTUnwrap(
            store.storeTranscript(
                TranscriptSegmentDraft(
                    startTimestampMs: 9_800,
                    endTimestampMs: 10_200,
                    source: .microphone,
                    text: "Let's discuss the \(token) next",
                    localeIdentifier: "en-US"
                )
            )
        )
        XCTAssertEqual(stored.frameID, firstDisplay)
        XCTAssertEqual(try store.transcripts(frameID: firstDisplay), [stored])

        let hits = try store.searchLibrary(
            query: LibrarySearchQuery(text: token, appFilter: "Zoom"),
            limit: 10
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].frameID, firstDisplay)
        XCTAssertEqual(hits[0].transcriptSegmentID, stored.id)
        XCTAssertEqual(hits[0].transcriptSource, .microphone)
        XCTAssertTrue(hits[0].snippet?.contains(token) == true)

        let timeline = try store.timeline(
            fromTimestampMs: 9_000,
            toTimestampMs: 11_000,
            limit: 10
        )
        XCTAssertEqual(Set(timeline.map(\.id)), Set([firstDisplay, secondDisplay]))
        XCTAssertTrue(timeline.allSatisfy { $0.transcriptSegments == [stored] })
    }

    func testTranscriptOutsideNearbyMomentIsDiscarded() throws {
        _ = try store.insertSeedFrame(timestampMs: 1_000, foreground: "screen")
        let stored = try store.storeTranscript(
            TranscriptSegmentDraft(
                startTimestampMs: 50_000,
                endTimestampMs: 51_000,
                source: .computer,
                text: "This must not leak across a privacy pause"
            ),
            maximumMomentDistanceMs: 2_000
        )
        XCTAssertNil(stored)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM transcript_segment"), 0)
    }

    func testMixedOCRAndTranscriptMatchReturnsOneMomentAndPrefersTranscriptContext() throws {
        let token = "mixedmatch\(UUID().uuidString.prefix(8))"
            .replacingOccurrences(of: "-", with: "")
        _ = try store.insertSeedFrame(
            timestampMs: 8_000,
            foreground: "The screen also contains \(token)",
            title: "Planning",
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            domain: "example.com"
        )
        let transcript = try XCTUnwrap(
            store.storeTranscript(
                TranscriptSegmentDraft(
                    startTimestampMs: 7_900,
                    endTimestampMs: 8_100,
                    source: .computer,
                    text: "The presenter said \(token) aloud"
                )
            )
        )

        let hits = try store.searchLibrary(
            query: LibrarySearchQuery(
                text: token,
                siteFilter: "example.com",
                fromTimestampMs: 7_500,
                toTimestampMs: 8_500
            ),
            limit: 10
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].transcriptSegmentID, transcript.id)
        XCTAssertEqual(hits[0].transcriptSource, .computer)
    }

    func testTranscriptSearchHonorsExactAppAndSiteFilters() throws {
        _ = try store.insertSeedFrame(
            timestampMs: 20_000,
            foreground: "screen",
            title: "Call",
            bundleID: "us.zoom.xos",
            displayName: "Zoom",
            domain: "meet.example.com"
        )
        _ = try XCTUnwrap(
            store.storeTranscript(
                TranscriptSegmentDraft(
                    startTimestampMs: 19_900,
                    endTimestampMs: 20_100,
                    source: .microphone,
                    text: "quarterly spoken planning"
                )
            )
        )

        XCTAssertEqual(
            try store.searchLibrary(
                query: LibrarySearchQuery(
                    text: "spoken planning",
                    appBundleID: "us.zoom.xos",
                    domain: "meet.example.com"
                )
            ).count,
            1
        )
        XCTAssertTrue(
            try store.searchLibrary(
                query: LibrarySearchQuery(
                    text: "spoken planning",
                    appBundleID: "com.apple.Safari"
                )
            ).isEmpty
        )
        XCTAssertTrue(
            try store.searchLibrary(
                query: LibrarySearchQuery(
                    text: "spoken planning",
                    domain: "other.example.com"
                )
            ).isEmpty
        )
    }

    func testDeletingMomentCascadesTranscriptAndFTS() throws {
        let frameID = try store.insertSeedFrame(timestampMs: 5_000, foreground: "screen")
        _ = try XCTUnwrap(
            store.storeTranscript(
                TranscriptSegmentDraft(
                    startTimestampMs: 4_900,
                    endTimestampMs: 5_100,
                    source: .computer,
                    text: "cascade transcript token"
                )
            )
        )
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM transcript_fts"), 1)

        try store.withSerializedMutation {
            try store.db.exec("DELETE FROM frame WHERE id = \(frameID)")
        }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM transcript_segment"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM transcript_fts"), 0)
    }

    private func scalar(_ sql: String) throws -> Int64 {
        let stmt = try store.db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return SQLiteColumn.int64(stmt, 0)
    }
}
