import Foundation
import SQLite3
import XCTest

@testable import ScreenlogCore

final class SemanticStoreTests: XCTestCase {
    private var root: URL!
    private var store: Store!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("screenlog-semantic-\(UUID().uuidString)")
        store = try Store(root: root)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testDisabledDefaultCreatesNoWorkAndPreferencesRemainPrivate() throws {
        let name = "screenlog-semantic-preferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(SemanticPreferenceStore.load(from: defaults), .init())
        SemanticPreferenceStore.save(.init(enabled: true, mode: .both), to: defaults)
        XCTAssertEqual(SemanticPreferenceStore.load(from: defaults), .init(enabled: true, mode: .both))
        _ = try capture(1_000)
        _ = try store.storeTranscript(.init(startTimestampMs: 900, endTimestampMs: 1_100, source: .microphone, text: "final speech"))
        XCTAssertEqual(try store.semanticStatistics(mode: .both), .init())
        XCTAssertTrue(try store.semanticWork(mode: .both).isEmpty)
        XCTAssertThrowsError(try search())
        XCTAssertEqual(try store.ftsSearch(query: "screen").count, 1)
    }

    func testAdmissionResumeAndFailedWorkDoNotHotRetry() throws {
        let first = try capture(1_000)
        try store.configureSemanticIndex(enabled: true, mode: .both)
        try admitHistory()
        let initial = try store.semanticWork(mode: .both)
        XCTAssertEqual(initial.count, 2)
        XCTAssertEqual(Set(initial.map(\.frameID)), [first])
        XCTAssertEqual(try store.semanticWork(mode: .both).map(\.id), initial.map(\.id), "Interrupted jobs remain pending.")
        let image = try XCTUnwrap(initial.first { $0.kind == .image })
        try store.failSemanticWork(image, message: "Image read failed.")
        XCTAssertFalse(try store.semanticWork(mode: .both).contains { $0.id == image.id })
        XCTAssertEqual(try store.semanticStatistics(mode: .both).failedSources, 1)
        try store.configureSemanticIndex(enabled: false, mode: .both)
        _ = try capture(2_000)
        XCTAssertTrue(try store.semanticWork(mode: .both).isEmpty)
        try store.configureSemanticIndex(enabled: true, mode: .both)
        try admitHistory()
        XCTAssertEqual(try store.semanticStatistics(mode: .both).failedSources, 0)
        XCTAssertEqual(try store.semanticWork(mode: .both).count, 4)
        XCTAssertFalse(try finish(image, hash: "stale-consent"))
        let resumed = try pending(frame: first, kind: .image)
        XCTAssertGreaterThan(resumed.revision, image.revision)
        XCTAssertTrue(try finish(resumed, hash: "resumed"))
    }

    func testChangesWhileDisabledAndPipelineSwitchRejectStaleCommits() throws {
        let frame = try capture(1_000)
        try store.configureSemanticIndex(enabled: true, mode: .text)
        try admitHistory()
        let old = try pending(frame: frame, kind: .screenText)
        XCTAssertTrue(try finish(old, hash: "old-text"))
        try store.configureSemanticIndex(enabled: false, mode: .text)
        try mutate("UPDATE frame SET foreground = 'replacement text' WHERE id = \(frame)")
        XCTAssertEqual(try store.semanticStatistics(mode: .text).indexedSources, 0)
        XCTAssertEqual(try store.semanticStatistics(mode: .text).vectorCount, 0)
        try store.configureSemanticIndex(enabled: true, mode: .text)
        try admitHistory()
        let replacement = try pending(frame: frame, kind: .screenText)
        XCTAssertTrue(replacement.text?.contains("replacement text") == true)
        XCTAssertFalse(try finish(old, hash: "old-text"))
        try store.configureSemanticIndex(enabled: true, mode: .text, pipelineID: "test-pipeline-2")
        try admitHistory()
        XCTAssertFalse(try finish(replacement, hash: "wrong-pipeline"))
        let newPipeline = try pending(frame: frame, kind: .screenText)
        XCTAssertTrue(try finish(newPipeline, hash: "new-pipeline"))
        XCTAssertEqual(try store.semanticStatistics(mode: .text).vectorCount, 1)
        try store.removeSemanticIndex()
        XCTAssertFalse(try finish(newPipeline, hash: "removed"))
        XCTAssertEqual(try store.semanticStatistics(mode: .both), .init())
        try store.configureSemanticIndex(enabled: true, mode: .text)
        try admitHistory()
        XCTAssertEqual(try store.semanticWork(mode: .text).count, 1)
    }

    func testFullInputAndChunkReusePruneOnlyOrphanVectors() throws {
        let first = try capture(1_000)
        let second = try capture(2_000)
        let third = try capture(3_000)
        try store.configureSemanticIndex(enabled: true, mode: .text)
        try admitHistory()
        let work = try pending(frame: first, kind: .screenText)
        let chunks = [SemanticVectorChunk(hash: "shared-a", values: basis(0)), .init(hash: "shared-b", values: basis(1))]
        XCTAssertTrue(try store.completeSemanticWork(work, contentHash: "full-text", chunks: chunks))
        XCTAssertTrue(try store.reuseSemanticWork(pending(frame: second, kind: .screenText), contentHash: "full-text"))
        XCTAssertEqual(try store.semanticVectorChunk(hash: "shared-a")?.values, basis(0))
        XCTAssertTrue(
            try store.completeSemanticWork(pending(frame: third, kind: .screenText), contentHash: "partly-shared", chunks: [chunks[0]]))
        XCTAssertEqual(try store.semanticStatistics(mode: .text).vectorCount, 2)
        XCTAssertEqual(try store.semanticStatistics(mode: .text).vectorBytes, 2 * 768 * 4)
        try mutate("DELETE FROM frame WHERE id IN (\(first), \(second))")
        XCTAssertEqual(try store.semanticStatistics(mode: .text).vectorCount, 1)
        XCTAssertNil(try store.semanticVectorChunk(hash: "shared-b"))
        try mutate("DELETE FROM frame WHERE id = \(third)")
        XCTAssertEqual(try store.semanticStatistics(mode: .both), .init())
        XCTAssertTrue(try store.db.foreignKeyViolations().isEmpty)
    }

    func testVectorValidationRejectsInvalidDimensionsNormAndValuesAtomically() throws {
        let frame = try capture(1_000)
        try store.configureSemanticIndex(enabled: true, mode: .images)
        try admitHistory()
        let work = try pending(frame: frame, kind: .image)
        var nonfinite = basis(0)
        nonfinite[0] = .nan
        var infinity = basis(0)
        infinity[0] = .infinity
        for invalid in [
            [Float](repeating: 0, count: 768), [Float](repeating: 1, count: 768), [Float](repeating: 1, count: 256), nonfinite, infinity,
        ] {
            XCTAssertThrowsError(
                try store.completeSemanticWork(work, contentHash: "invalid", chunks: [.init(hash: "invalid", values: invalid)]))
        }
        XCTAssertThrowsError(try store.completeSemanticWork(work, contentHash: "empty", chunks: []))
        XCTAssertThrowsError(try store.completeSemanticWork(work, contentHash: "", chunks: [.init(hash: "valid", values: basis(0))]))
        XCTAssertEqual(try store.semanticStatistics(mode: .images).vectorCount, 0)
        XCTAssertEqual(try store.semanticStatistics(mode: .images).pendingSources, 1)
        XCTAssertTrue(try finish(work, hash: "valid"))
        XCTAssertEqual(try scalar("SELECT hex(substr(value, 1, 4)) = '0000803F' FROM semantic_vector"), 1)
        let another = try capture(2_000)
        XCTAssertThrowsError(
            try store.completeSemanticWork(
                pending(frame: another, kind: .image), contentHash: "collision", chunks: [.init(hash: "valid", values: basis(1))]))
        XCTAssertEqual(try store.semanticStatistics(mode: .images).vectorCount, 1)
        XCTAssertEqual(try store.semanticStatistics(mode: .images).pendingSources, 1)
    }

    func testAppSiteTimeAndContentFiltersApplyBeforeLimitAndBestChunkWins() throws {
        let excluded = try capture(1_000, app: "com.example.other", domain: "other.example")
        let target = try capture(2_000, app: "com.example.browser", domain: "docs.example.com")
        let later = try capture(3_000, app: "com.example.browser", domain: "docs.example.com")
        try store.configureSemanticIndex(enabled: true, mode: .text)
        try admitHistory()
        XCTAssertTrue(try finish(pending(frame: excluded, kind: .screenText), hash: "excluded", vector: basis(0)))
        var weaker = [Float](repeating: 0, count: 768)
        weaker[0] = 0.6
        weaker[1] = 0.8
        XCTAssertTrue(
            try store.completeSemanticWork(
                pending(frame: target, kind: .screenText), contentHash: "target",
                chunks: [.init(hash: "weak", values: basis(1)), .init(hash: "best", values: weaker)]))
        XCTAssertTrue(try finish(pending(frame: later, kind: .screenText), hash: "later"))
        let query = LibrarySearchQuery(
            appFilter: "browser", siteFilter: "example.com", appBundleID: "com.example.browser", domain: "docs.example.com",
            fromTimestampMs: 1_500, toTimestampMs: 2_500, content: .screenText)
        let hits = try store.semanticSearch(vector: basis(0), query: query, mode: .text, limit: 1)
        XCTAssertEqual(hits.map(\.result.frameID), [target])
        XCTAssertEqual(try XCTUnwrap(hits.first).score, 0.6, accuracy: 0.0001)
        XCTAssertTrue(try store.semanticSearch(vector: basis(0), query: query, mode: .text, limit: 1, appFilter: "other").isEmpty)
        XCTAssertTrue(try store.semanticSearch(vector: basis(0), query: query, mode: .text, limit: 1, siteFilter: "other.example").isEmpty)
        XCTAssertTrue(try search(query: .init(content: .transcripts), mode: .text).isEmpty)
    }

    func testDistinctDisplaysAndDuplicateImagesRetainFilteredOccurrenceLocations() throws {
        let left = CaptureDisplayRect(x: 0, y: 0, width: 100, height: 100)
        let right = CaptureDisplayRect(x: 100, y: 0, width: 100, height: 100)
        let first = try capture(1_000, display: left)
        let secondDisplay = try capture(1_000, display: right)
        let reused = try capture(2_000, app: "com.example.return", domain: "return.example", indexSearch: false, display: left)
        try store.configureSemanticIndex(enabled: true, mode: .images)
        try admitHistory()
        XCTAssertEqual(try store.semanticWork(mode: .images).count, 2, "Do not encode every reused capture or merge distinct displays.")
        XCTAssertTrue(try finish(pending(frame: first, kind: .image), hash: "left-pixels"))
        XCTAssertTrue(try finish(pending(frame: secondDisplay, kind: .image), hash: "right-pixels", vector: basis(1)))
        let hits = try search(mode: .images)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.result.frameID, reused)
        XCTAssertEqual(hits.first?.occurrenceCount, 2)
        let filtered = try search(query: .init(appBundleID: "com.example.return", fromTimestampMs: 1_500), mode: .images)
        XCTAssertEqual(filtered.map(\.result.frameID), [reused])
        XCTAssertEqual(filtered.first?.occurrenceCount, 1)
        XCTAssertEqual(try search(query: .init(toTimestampMs: 1_500), mode: .images).first?.result.frameID, first)
        let returning = try capture(3_000, display: left)
        XCTAssertTrue(try store.reuseSemanticWork(pending(frame: returning, kind: .image), contentHash: "left-pixels"))
        XCTAssertEqual(try search(mode: .images).first?.occurrenceCount, 3)
        XCTAssertEqual(try search(mode: .images).first?.result.frameID, returning)
        XCTAssertEqual(try store.semanticStatistics(mode: .images).vectorCount, 2)
    }

    func testBestSourcePerFrameDoesNotCollapseDifferentDisplaysAtSameMoment() throws {
        let left = try capture(1_000, display: .init(x: 0, y: 0, width: 100, height: 100))
        let right = try capture(1_000, display: .init(x: 100, y: 0, width: 100, height: 100))
        try store.configureSemanticIndex(enabled: true, mode: .both)
        try admitHistory()
        for frame in [left, right] {
            XCTAssertTrue(try finish(pending(frame: frame, kind: .image), hash: "image-\(frame)", vector: basis(1)))
            XCTAssertTrue(try finish(pending(frame: frame, kind: .screenText), hash: "text-\(frame)", vector: basis(0)))
        }
        let hits = try search()
        XCTAssertEqual(Set(hits.map(\.result.frameID)), [left, right])
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.kind == .screenText })
    }

    func testScreensFilterIncludesImagesAndScreenTextButNotTranscripts() throws {
        let imageFrame = try capture(1_000)
        let textFrame = try capture(3_000)
        let transcriptFrame = try capture(5_000)
        try store.configureSemanticIndex(enabled: true, mode: .both)
        try admitHistory()
        XCTAssertTrue(try finish(pending(frame: imageFrame, kind: .image), hash: "screen-image"))
        XCTAssertTrue(try finish(pending(frame: textFrame, kind: .screenText), hash: "screen-text"))
        _ = try XCTUnwrap(
            store.storeTranscript(
                .init(startTimestampMs: 4_800, endTimestampMs: 5_200, source: .computer, text: "spoken words")))
        XCTAssertTrue(try finish(pending(frame: transcriptFrame, kind: .transcript), hash: "spoken"))

        let screens = LibrarySearchQuery(content: .screenText)
        XCTAssertEqual(Set(try search(query: screens).map(\.result.frameID)), [imageFrame, textFrame])
        XCTAssertEqual(try search(query: screens, mode: .images).map(\.result.frameID), [imageFrame])
        XCTAssertEqual(try search(query: screens, mode: .text).map(\.result.frameID), [textFrame])
        XCTAssertEqual(try search(query: .init(content: .transcripts)).map(\.result.frameID), [transcriptFrame])
    }

    func testDelayedTranscriptAdmissionAndReplacementAreIndependent() throws {
        let frame = try capture(1_000)
        try store.configureSemanticIndex(enabled: true, mode: .text)
        try admitHistory()
        XCTAssertTrue(try finish(pending(frame: frame, kind: .screenText), hash: "screen"))
        let transcript = try XCTUnwrap(
            store.storeTranscript(.init(startTimestampMs: 800, endTimestampMs: 1_200, source: .computer, text: "final spoken words")))
        let work = try pending(frame: frame, kind: .transcript)
        XCTAssertEqual(work.transcriptID, transcript.id)
        XCTAssertEqual(work.text, "final spoken words")
        XCTAssertTrue(try finish(work, hash: "transcript"))
        let hits = try search(query: .init(content: .transcripts), mode: .text)
        XCTAssertEqual(hits.first?.result.transcriptStartTimestampMs, 800)
        XCTAssertEqual(hits.first?.result.transcriptEndTimestampMs, 1_200)
        XCTAssertEqual(hits.first?.result.transcriptSource, .computer)
        try store.configureSemanticIndex(enabled: false, mode: .text)
        try mutate("UPDATE transcript_segment SET text = 'corrected spoken words' WHERE id = \(transcript.id)")
        XCTAssertEqual(try store.semanticStatistics(mode: .text).indexedSources, 1)
        try store.configureSemanticIndex(enabled: true, mode: .text)
        try admitHistory()
        XCTAssertFalse(try finish(work, hash: "stale-transcript"))
        XCTAssertEqual(try pending(frame: frame, kind: .transcript).text, "corrected spoken words")
        try mutate("DELETE FROM transcript_segment WHERE id = \(transcript.id)")
        XCTAssertEqual(try store.semanticStatistics(mode: .text).transcriptSources, 0)
        XCTAssertEqual(try store.semanticStatistics(mode: .text).textSources, 1)
    }

    func testMediaRetentionCompactionReactivationAndHistoryDeletion() throws {
        let frame = try capture(1_000)
        try store.configureSemanticIndex(enabled: true, mode: .both)
        try admitHistory()
        let image = try pending(frame: frame, kind: .image)
        let text = try pending(frame: frame, kind: .screenText)
        XCTAssertTrue(try finish(image, hash: "pixels"))
        XCTAssertTrue(try finish(text, hash: "retained-text"))
        let path = try XCTUnwrap(store.frame(id: frame)?.imagePath)
        let videoPath = root.appendingPathComponent("test-video.mp4").path
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: videoPath))
        let video = try store.insertVideo(path: videoPath, numFrames: 1, sizeBytes: 3)
        try store.attachFrame(id: frame, videoID: video, videoIndex: 0)
        try store.markFrameImagePurged(id: frame, expectedPath: path)
        XCTAssertEqual(try store.semanticStatistics(mode: .both).indexedSources, 2, "Compaction must preserve image vectors.")
        XCTAssertTrue(try search(mode: .images).first?.result.isCompacted == true)
        try store.markVideoPurged(id: video)
        XCTAssertEqual(try store.semanticStatistics(mode: .images).imageSources, 0)
        XCTAssertEqual(try store.semanticStatistics(mode: .text).indexedSources, 1)
        XCTAssertFalse(try finish(image, hash: "cannot-revive-media"))
        try store.restoreVideoForRetentionRetry(id: video, path: videoPath, sizeBytes: 3)
        let restored = try pending(frame: frame, kind: .image)
        XCTAssertNotEqual(restored.id, image.id)
        XCTAssertTrue(try finish(restored, hash: "restored-pixels"))
        try mutate("DELETE FROM frame WHERE id = \(frame)")
        XCTAssertFalse(try finish(restored, hash: "cannot-revive-frame"))
        XCTAssertEqual(try store.semanticStatistics(mode: .both), .init())
        XCTAssertTrue(try store.db.foreignKeyViolations().isEmpty)
    }

    func testRemovingRepresentativePreservesOtherOccurrencesWithoutStaleWork() throws {
        let original = try capture(1_000)
        let duplicate = try capture(2_000, indexSearch: false)
        try store.configureSemanticIndex(enabled: true, mode: .both)
        try admitHistory()
        let originalImage = try pending(frame: original, kind: .image)
        XCTAssertTrue(try finish(pending(frame: original, kind: .screenText), hash: "shared-text"))
        let path = try XCTUnwrap(store.frame(id: original)?.imagePath)
        try store.markFrameImagePurged(id: original, expectedPath: path)
        XCTAssertFalse(try finish(originalImage, hash: "stale-anchor"))
        let remaining = try pending(frame: duplicate, kind: .image)
        XCTAssertEqual(remaining.id, originalImage.id)
        XCTAssertTrue(try finish(remaining, hash: "remaining-pixels"))
        XCTAssertEqual(try search(mode: .images).map(\.result.frameID), [duplicate])
        try mutate("DELETE FROM frame WHERE id = \(original)")
        XCTAssertEqual(try search(mode: .text).map(\.result.frameID), [duplicate])
        XCTAssertEqual(try store.semanticStatistics(mode: .both).vectorCount, 2)
        try mutate("DELETE FROM frame WHERE id = \(duplicate)")
        XCTAssertEqual(try store.semanticStatistics(mode: .both).vectorCount, 0)
    }

    func testStillReactivationWhileDisabledAndTextAliasesRemainCorrect() throws {
        let original = try capture(1_000)
        let duplicate = try capture(2_000, indexSearch: false)
        try store.configureSemanticIndex(enabled: true, mode: .both)
        try admitHistory()
        XCTAssertTrue(try finish(pending(frame: original, kind: .screenText), hash: "old-shared"))
        try store.configureSemanticIndex(enabled: false, mode: .both)
        try mutate("UPDATE frame SET foreground = 'changed original' WHERE id = \(original)")
        let path = try XCTUnwrap(store.frame(id: original)?.imagePath)
        try store.markFrameImagePurged(id: original, expectedPath: path)
        try store.restoreFrameImageForRetentionRetry(id: original, path: path)
        try store.configureSemanticIndex(enabled: true, mode: .both)
        try admitHistory()
        XCTAssertEqual(try search(mode: .text).map(\.result.frameID), [duplicate])
        XCTAssertTrue(try pending(frame: original, kind: .screenText).text?.contains("changed original") == true)
        XCTAssertNotNil(try pending(frame: original, kind: .image).preview)
    }

    func testPreviewTransitionRequeuesPendingAndFailedStillWork() throws {
        try store.configureSemanticIndex(enabled: true, mode: .images)
        for failBeforeCompaction in [false, true] {
            let frame = try capture(failBeforeCompaction ? 2_000 : 1_000)
            let still = try pending(frame: frame, kind: .image)
            let path = try XCTUnwrap(store.frame(id: frame)?.imagePath)
            let videoPath = root.appendingPathComponent("preview-\(frame).mp4").path
            let video = try store.insertVideo(path: videoPath, numFrames: 1, sizeBytes: 3)
            try store.attachFrame(id: frame, videoID: video, videoIndex: 0)
            let attached = try pending(frame: frame, kind: .image)
            XCTAssertEqual(attached.revision, still.revision, "The same still remains the effective preview.")
            XCTAssertEqual(attached.preview?.source, .still(path: path))
            if failBeforeCompaction {
                try store.failSemanticWork(still, message: "The still is not available.")
            }
            try store.markFrameImagePurged(id: frame, expectedPath: path)
            let replacement = try pending(frame: frame, kind: .image)
            XCTAssertEqual(replacement.id, still.id)
            XCTAssertGreaterThan(replacement.revision, still.revision)
            XCTAssertEqual(replacement.preview?.source, .video(path: videoPath, index: 0))
            try store.failSemanticWork(still, message: "Stale still failure.")
            XCTAssertEqual(try store.semanticStatistics(mode: .images).failedSources, 0)
            XCTAssertFalse(try finish(still, hash: "stale-preview-\(frame)"))
            XCTAssertTrue(try finish(replacement, hash: "video-preview-\(frame)"))
        }
    }

    func testFailedRepresentativeRequeuesWhenAnAliasBecomesThePreview() throws {
        let original = try capture(1_000)
        let duplicate = try capture(2_000, indexSearch: false)
        try store.configureSemanticIndex(enabled: true, mode: .images)
        XCTAssertFalse(try store.admitSemanticHistory(limit: 1))
        XCTAssertTrue(try store.admitSemanticHistory(limit: 1))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_occurrence"), 2)
        let failed = try pending(frame: original, kind: .image)
        try store.failSemanticWork(failed, message: "The original preview failed.")
        let path = try XCTUnwrap(store.frame(id: original)?.imagePath)
        try store.markFrameImagePurged(id: original, expectedPath: path)
        let replacement = try pending(frame: duplicate, kind: .image)
        XCTAssertEqual(replacement.id, failed.id)
        XCTAssertGreaterThan(replacement.revision, failed.revision)
        try store.failSemanticWork(failed, message: "Stale original failure.")
        XCTAssertEqual(try store.semanticStatistics(mode: .images).failedSources, 0)
        XCTAssertTrue(try finish(replacement, hash: "alias-preview"))
    }

    func testHistoryAdmissionBoundsCoverageAndResumeAcrossReopen() throws {
        for timestamp in [Int64(1_000), 2_000, 3_000] {
            _ = try capture(timestamp)
            _ = try store.storeTranscript(
                .init(
                    startTimestampMs: timestamp, endTimestampMs: timestamp + 100,
                    source: .microphone, text: "speech \(timestamp)"))
        }
        try store.configureSemanticIndex(enabled: true, mode: .both)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source"), 0)
        XCTAssertTrue(try store.semanticWork(mode: .both).isEmpty)
        XCTAssertEqual(
            try store.semanticStatistics(mode: .both),
            .init(imageSources: 3, textSources: 3, transcriptSources: 3, pendingSources: 9))
        XCTAssertFalse(try store.admitSemanticHistory(limit: 2))
        let initial = try store.semanticWork(mode: .both)
        XCTAssertEqual(initial.count, 2)
        for work in initial {
            XCTAssertTrue(try finish(work, hash: "resumed-\(work.id)"))
        }
        XCTAssertEqual(try store.semanticStatistics(mode: .both).pendingSources, 7)
        store = nil
        store = try Store(root: root)
        XCTAssertEqual(try scalar("SELECT images_watermark FROM semantic_config"), 2)
        var complete = false
        for expectedCount in [4, 6, 8, 9] {
            let previousWatermarks = try scalar("SELECT images_watermark + text_watermark + transcripts_watermark FROM semantic_config")
            let previousSources = try scalar("SELECT COUNT(*) FROM semantic_source")
            complete = try store.admitSemanticHistory(limit: 2)
            let watermarks = try scalar("SELECT images_watermark + text_watermark + transcripts_watermark FROM semantic_config")
            let sources = try scalar("SELECT COUNT(*) FROM semantic_source")
            XCTAssertLessThanOrEqual(watermarks - previousWatermarks, 2)
            XCTAssertLessThanOrEqual(sources - previousSources, 2)
            XCTAssertEqual(sources, Int64(expectedCount))
            XCTAssertEqual(complete, expectedCount == 9)
            if expectedCount == 8 {
                store = nil
                store = try Store(root: root)
                XCTAssertEqual(try scalar("SELECT transcripts_watermark FROM semantic_config"), 2)
                XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source"), 8)
            }
        }
        XCTAssertTrue(complete)
        XCTAssertEqual(
            try store.semanticStatistics(mode: .both),
            .init(
                imageSources: 3, textSources: 3, transcriptSources: 3,
                pendingSources: 7, indexedSources: 2, vectorCount: 2, vectorBytes: 2 * 768 * 4))
        XCTAssertTrue(try store.admitSemanticHistory(limit: 2))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source"), 9)
        XCTAssertEqual(try scalar("SELECT MAX(revision) FROM semantic_source"), 1)
    }

    func testHistoryAdmissionClampsLimitsAndCountsIneligibleCandidates() throws {
        try mutate(
            """
            WITH RECURSIVE candidates(id) AS (
                SELECT 1 UNION ALL SELECT id + 1 FROM candidates WHERE id < 600
            )
            INSERT INTO frame(timestamp, image_path, foreground)
            SELECT id, 'historical.bin', 'history' FROM candidates
            """)
        try store.configureSemanticIndex(enabled: true, mode: .both)
        XCTAssertThrowsError(try store.admitSemanticHistory(limit: 0))
        XCTAssertThrowsError(try store.admitSemanticHistory(limit: -1))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source"), 0)
        XCTAssertFalse(try store.admitSemanticHistory(limit: Int.max))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source"), 512)
        XCTAssertEqual(try scalar("SELECT images_watermark + text_watermark FROM semantic_config"), 512)
        XCTAssertFalse(try store.admitSemanticHistory())
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source"), 768)
        XCTAssertEqual(try scalar("SELECT images_watermark + text_watermark FROM semantic_config"), 768)
        XCTAssertTrue(try store.admitSemanticHistory(limit: 512))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source"), 1_200)

        try store.removeSemanticIndex()
        try mutate("UPDATE frame SET image_path = NULL, foreground = NULL")
        try store.configureSemanticIndex(enabled: true, mode: .both)
        XCTAssertEqual(try store.semanticStatistics(mode: .both), .init())
        XCTAssertFalse(try store.admitSemanticHistory(limit: 1))
        XCTAssertEqual(try scalar("SELECT images_watermark + text_watermark FROM semantic_config"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source"), 0)
    }

    func testHistoryAdmissionPreservesBacklogAcrossCaptureConsentModeAndPipelineChanges() throws {
        for timestamp in [Int64(1_000), 2_000, 3_000] {
            _ = try capture(timestamp)
            _ = try store.storeTranscript(
                .init(
                    startTimestampMs: timestamp, endTimestampMs: timestamp + 100,
                    source: .microphone, text: "speech \(timestamp)"))
        }
        try store.configureSemanticIndex(enabled: true, mode: .both)
        XCTAssertFalse(try store.admitSemanticHistory(limit: 1))
        let stale = try XCTUnwrap(store.semanticWork(mode: .both).first)
        let inserted = try capture(4_000)
        _ = try store.storeTranscript(
            .init(
                startTimestampMs: 4_000, endTimestampMs: 4_100,
                source: .microphone, text: "concurrent speech"))
        XCTAssertEqual(try scalar("SELECT images_watermark FROM semantic_config"), 1)
        XCTAssertEqual(try scalar("SELECT text_watermark + transcripts_watermark FROM semantic_config"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source WHERE frame_id = \(inserted)"), 3)
        try store.configureSemanticIndex(enabled: false, mode: .both)
        _ = try capture(5_000)
        _ = try store.storeTranscript(
            .init(
                startTimestampMs: 5_000, endTimestampMs: 5_100,
                source: .microphone, text: "disabled speech"))
        let disabledCount = try scalar("SELECT COUNT(*) FROM semantic_source")
        XCTAssertTrue(try store.admitSemanticHistory(limit: 1))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source"), disabledCount)
        XCTAssertEqual(try scalar("SELECT images_watermark + text_watermark + transcripts_watermark FROM semantic_config"), 1)

        try store.configureSemanticIndex(enabled: true, mode: .text)
        while try store.admitSemanticHistory(limit: 2) == false {}
        XCTAssertEqual(try scalar("SELECT images_watermark FROM semantic_config"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source WHERE kind != 'image'"), 10)
        XCTAssertTrue(try store.semanticWork(mode: .images).isEmpty)
        XCTAssertFalse(try finish(stale, hash: "stale-consent"))
        try store.configureSemanticIndex(enabled: true, mode: .images)
        while try store.admitSemanticHistory(limit: 2) == false {}
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source"), 15)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_occurrence"), 10)
        XCTAssertEqual(
            try scalar("SELECT MIN(revision) FROM semantic_source WHERE frame_id = \(inserted)"),
            try scalar("SELECT MAX(revision) FROM semantic_source WHERE frame_id = \(inserted)"))

        try store.configureSemanticIndex(enabled: true, mode: .both, pipelineID: "bounded-pipeline")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source"), 0)
        XCTAssertEqual(try store.semanticStatistics(mode: .both).pendingSources, 15)
        XCTAssertFalse(try store.admitSemanticHistory(limit: 1))
        XCTAssertFalse(try finish(stale, hash: "stale-pipeline"))
        while try store.admitSemanticHistory(limit: 2) == false {}
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source"), 15)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_source WHERE pipeline_id = 'bounded-pipeline'"), 15)
        XCTAssertTrue(try store.db.foreignKeyViolations().isEmpty)
    }

    func testVersionEightMigrationReplacesAdmissionAndPreviewTriggers() throws {
        try mutate(
            """
            DROP TRIGGER semantic_frame_ai;
            CREATE TRIGGER semantic_frame_ai AFTER INSERT ON frame
            WHEN (SELECT enabled AND mode IN ('text', 'both') FROM semantic_config WHERE id = 1)
            BEGIN
                \(SemanticSchema.admitFrame(frame: "NEW.id", kind: "screenText"))
                UPDATE semantic_config SET text_watermark = MAX(text_watermark, NEW.id) WHERE id = 1;
            END;
            DROP TRIGGER semantic_frame_media_au;
            CREATE TRIGGER semantic_frame_media_au AFTER UPDATE OF image_path, video, video_index ON frame
            BEGIN
                \(SemanticSchema.detach(frame: "NEW.id", kind: "image", condition: "NOT (\(SemanticSchema.mediaAvailable("NEW")))"))
                \(SemanticSchema.admitFrame(frame: "NEW.id", kind: "image"))
                UPDATE semantic_config SET images_watermark = MAX(images_watermark, NEW.id)
                    WHERE id = 1 AND enabled = 1 AND mode IN ('images', 'both');
            END;
            DELETE FROM schema_migrations;
            INSERT INTO schema_migrations VALUES(8);
            """)
        store = nil
        store = try Store(root: root)
        XCTAssertEqual(try scalar("SELECT MAX(version) FROM schema_migrations"), Int64(Schema.currentVersion))
        try store.configureSemanticIndex(enabled: true, mode: .both)
        let frame = try capture(1_000)
        XCTAssertEqual(try scalar("SELECT images_watermark + text_watermark FROM semantic_config"), 0)
        let still = try pending(frame: frame, kind: .image)
        let path = try XCTUnwrap(store.frame(id: frame)?.imagePath)
        let video = try store.insertVideo(path: root.appendingPathComponent("migration.mp4").path, numFrames: 1, sizeBytes: 3)
        try store.attachFrame(id: frame, videoID: video, videoIndex: 0)
        try store.markFrameImagePurged(id: frame, expectedPath: path)
        try store.failSemanticWork(still, message: "Stale version-eight preview.")
        XCTAssertGreaterThan(try pending(frame: frame, kind: .image).revision, still.revision)
        XCTAssertEqual(try store.semanticStatistics(mode: .both).failedSources, 0)
    }

    func testVersionSevenMigrationAndPendingIndexForeignKeys() throws {
        let db = try SQLiteDatabase(path: root.appendingPathComponent("migration.sqlite").path)
        for sql in Schema.createStatements.dropLast(SemanticSchema.statements.count) { try db.exec(sql) }
        try db.exec("CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY NOT NULL)")
        try db.exec("INSERT INTO schema_migrations VALUES(7)")
        try Schema.migrate(db)
        try Schema.validate(db)
        XCTAssertTrue(try db.foreignKeyViolations().isEmpty)
        XCTAssertThrowsError(try db.exec("INSERT INTO semantic_source(frame_id, kind, pipeline_id) VALUES(999, 'image', 'test')"))
        let plan = try db.prepare(
            "EXPLAIN QUERY PLAN SELECT id FROM semantic_source WHERE state = 'pending' AND kind = 'image' ORDER BY id LIMIT 8")
        defer { sqlite3_finalize(plan) }
        var details = ""
        while sqlite3_step(plan) == SQLITE_ROW { details += SQLiteColumn.text(plan, 3) ?? "" }
        XCTAssertTrue(details.contains("idx_semantic_pending"), details)
    }

    @discardableResult
    private func capture(
        _ timestamp: Int64, app: String = "com.example.app", domain: String = "example.com",
        indexSearch: Bool = true, display: CaptureDisplayRect? = nil
    ) throws -> Int64 {
        try store.store(
            payload: CapturePayload(
                imageData: Data([1, 2, 3]), timestampMs: timestamp,
                width: 100, height: 100, foreground: "screen words", title: "Document", bundleID: app,
                displayName: app, domain: domain, imageFileExtension: "bin", captureDisplay: display, indexSearch: indexSearch))
    }

    private func admitHistory() throws {
        while try store.admitSemanticHistory() == false {}
    }

    private func basis(_ index: Int) -> [Float] {
        var values = [Float](repeating: 0, count: SemanticPipeline.dimensions)
        values[index] = 1
        return values
    }

    private func pending(frame: Int64, kind: SemanticSourceKind) throws -> SemanticWorkItem {
        try XCTUnwrap(store.semanticWork(mode: .both, limit: 64).first { $0.frameID == frame && $0.kind == kind })
    }

    private func finish(_ work: SemanticWorkItem, hash: String, vector: [Float]? = nil) throws -> Bool {
        try store.completeSemanticWork(work, contentHash: hash, chunks: [.init(hash: hash, values: vector ?? basis(0))])
    }

    private func search(query: LibrarySearchQuery = .init(), mode: SemanticSearchMode = .both) throws -> [SemanticSearchHit] {
        try store.semanticSearch(vector: basis(0), query: query, mode: mode, limit: 50)
    }

    private func mutate(_ sql: String) throws {
        try store.withSerializedMutation { try store.db.exec(sql) }
    }

    private func scalar(_ sql: String) throws -> Int64 {
        let stmt = try store.db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return SQLiteColumn.int64(stmt, 0)
    }
}
