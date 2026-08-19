import SQLite3
import XCTest

@testable import ScreenlogCore

final class StoreQueryTests: XCTestCase {
    var tempRoot: URL!
    var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-query-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = try Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Frame insert + time range

    func testFrameInsertAndTimeRangeQuery() throws {
        let id1 = try store.insertSeedFrame(timestampMs: 1_000, foreground: "early", bundleID: "dev.a")
        let id2 = try store.insertSeedFrame(timestampMs: 2_000, foreground: "mid", bundleID: "dev.a")
        let id3 = try store.insertSeedFrame(timestampMs: 3_000, foreground: "late", bundleID: "dev.b")
        _ = try store.insertSeedFrame(timestampMs: 5_000, foreground: "after", bundleID: "dev.b")

        // [1000, 4000) to id1, id2, id3
        let range = try store.frames(fromTimestampMs: 1_000, toTimestampMs: 4_000)
        XCTAssertEqual(range.map(\.id), [id1, id2, id3])
        XCTAssertEqual(range.map(\.timestampMs), [1_000, 2_000, 3_000])

        // Exclusive upper bound
        let halfOpen = try store.frames(fromTimestampMs: 2_000, toTimestampMs: 3_000)
        XCTAssertEqual(halfOpen.map(\.id), [id2])

        // Empty range
        let empty = try store.frames(fromTimestampMs: 10_000, toTimestampMs: 20_000)
        XCTAssertTrue(empty.isEmpty)

        let stats = try store.stats()
        XCTAssertEqual(stats.totalFrames, 4)
        XCTAssertEqual(stats.minTimestampMs, 1_000)
        XCTAssertEqual(stats.maxTimestampMs, 5_000)
    }

    func testFramesByApplicationAndTime() throws {
        _ = try store.insertSeedFrame(timestampMs: 100, foreground: "a1", bundleID: "com.app.a", displayName: "A")
        _ = try store.insertSeedFrame(timestampMs: 200, foreground: "b1", bundleID: "com.app.b", displayName: "B")
        _ = try store.insertSeedFrame(timestampMs: 300, foreground: "a2", bundleID: "com.app.a", displayName: "A")
        _ = try store.insertSeedFrame(timestampMs: 400, foreground: "a3", bundleID: "com.app.a", displayName: "A")

        let allA = try store.frames(bundleID: "com.app.a")
        XCTAssertEqual(allA.count, 3)
        XCTAssertEqual(allA.map(\.timestampMs), [100, 300, 400])

        let windowed = try store.frames(
            bundleID: "com.app.a",
            fromTimestampMs: 200,
            toTimestampMs: 400
        )
        XCTAssertEqual(windowed.map(\.timestampMs), [300])

        let none = try store.frames(bundleID: "com.missing")
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - Application / domain upsert

    func testApplicationAndDomainUpsertIdempotent() throws {
        let a1 = try store.upsertApplication(bundleID: "dev.upsert", version: "1.0", displayName: "Upsert")
        let a2 = try store.upsertApplication(bundleID: "dev.upsert", version: "1.0", displayName: "Upsert")
        XCTAssertEqual(a1, a2)
        XCTAssertNotNil(a1)

        // Display name only fills when previously NULL - seed with nil then set
        let bare = try store.upsertApplication(bundleID: "dev.bare", version: "", displayName: nil)
        _ = try store.upsertApplication(bundleID: "dev.bare", version: "", displayName: "Bare App")
        let apps = try store.listApplications()
        XCTAssertEqual(apps.first(where: { $0.id == bare })?.displayName, "Bare App")

        let d1 = try store.upsertDomain(normalized: "Example.COM")
        let d2 = try store.upsertDomain(normalized: "example.com")
        XCTAssertEqual(d1, d2)

        let domains = try store.listDomains()
        XCTAssertEqual(domains.filter { $0.normalizedDomain == "example.com" }.count, 1)

        XCTAssertNil(try store.upsertApplication(bundleID: nil, displayName: nil))
        XCTAssertNil(try store.upsertApplication(bundleID: "", displayName: nil))
        XCTAssertNil(try store.upsertDomain(normalized: nil))
        XCTAssertNil(try store.upsertDomain(normalized: ""))
    }

    func testDomainCaseNormalizationOnSeed() throws {
        _ = try store.insertSeedFrame(
            timestampMs: 1,
            foreground: "x",
            domain: "Docs.Example.COM"
        )
        let domains = try store.listDomains()
        XCTAssertTrue(domains.contains(where: { $0.normalizedDomain == "docs.example.com" }))
    }

    // MARK: - OCR boxes + window_bound

    func testOCRBoxesAndWindowBoundsPersist() throws {
        let appID = try store.upsertApplication(bundleID: "dev.win", version: "", displayName: "Win")!
        let payload = CapturePayload(
            imageData: Data([0x00]),
            timestampMs: 77,
            width: 800,
            height: 600,
            foreground: "Hello world text",
            bundleID: "dev.win",
            displayName: "Win",
            ocrBoxes: [
                OCRBox(x: 10, y: 20, width: 100, height: 14, textOffset: 0, textLength: 5),
                OCRBox(x: 10, y: 40, width: 120, height: 14, textOffset: 6, textLength: 5),
            ],
            windowBounds: [
                WindowBound(
                    applicationID: appID,
                    windowTitle: "Editor",
                    x: 0, y: 0, width: 800, height: 600,
                    zOrder: 1,
                    url: "https://example.com/doc"
                )
            ],
            imageFileExtension: "bin"
        )
        let frameID = try store.store(payload: payload)

        let boxes = try store.ocrBoxes(frameID: frameID)
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes[0].x, 10)
        XCTAssertEqual(boxes[0].textOffset, 0)
        XCTAssertEqual(boxes[1].y, 40)

        let bounds = try store.windowBounds(frameID: frameID)
        XCTAssertEqual(bounds.count, 1)
        XCTAssertEqual(bounds[0].windowTitle, "Editor")
        XCTAssertEqual(bounds[0].width, 800)
        XCTAssertEqual(bounds[0].url, "https://example.com/doc")
        XCTAssertEqual(bounds[0].applicationID, appID)
    }

    // MARK: - FTS

    func testFTSTitleAndBackgroundAndEmptyQuery() throws {
        let token = "titletoken\(String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: ""))"
        let id = try store.insertSeedFrame(
            timestampMs: 50,
            foreground: "body",
            background: "sidepanel \(token) note",
            title: "Status \(token)",
            bundleID: "dev.fts",
            displayName: "FTS App"
        )

        let byTitle = try store.ftsSearch(query: token)
        XCTAssertTrue(byTitle.contains(where: { $0.frameID == id }))
        let hit = try XCTUnwrap(byTitle.first(where: { $0.frameID == id }))
        XCTAssertEqual(hit.bundleID, "dev.fts")
        XCTAssertEqual(hit.displayName, "FTS App")
        XCTAssertEqual(hit.appLabel, "FTS App")
        XCTAssertNotNil(hit.snippet)
        XCTAssertTrue(
            (hit.snippet ?? "").localizedCaseInsensitiveContains(token)
                || (hit.title ?? "").localizedCaseInsensitiveContains(token)
        )

        XCTAssertTrue(try store.ftsSearch(query: "").isEmpty)
        XCTAssertTrue(try store.ftsSearch(query: "   ").isEmpty)
        XCTAssertTrue(try store.ftsSearch(query: "zzznotpresentzzz\(UUID().uuidString)").isEmpty)
    }

    func testFTSBackgroundOnlySnippetAndDisplayName() throws {
        let token = "bgtoken\(String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: ""))"
        let id = try store.insertSeedFrame(
            timestampMs: 60,
            foreground: "unrelated front window",
            background: "dock badge \(token) alert",
            title: "Front",
            bundleID: "com.bg.app",
            displayName: "Backgrounder"
        )
        let hits = try store.ftsSearch(query: token)
        let hit = try XCTUnwrap(hits.first(where: { $0.frameID == id }))
        XCTAssertEqual(hit.displayName, "Backgrounder")
        XCTAssertEqual(hit.bundleID, "com.bg.app")
        // Coalesced snippet should still surface the background match.
        XCTAssertTrue(
            (hit.snippet ?? "").localizedCaseInsensitiveContains(token),
            "snippet=\(hit.snippet ?? "nil")"
        )
    }

    // MARK: - Video time ranges + retention helpers

    func testVideoAttachAndFramesByVideo() throws {
        let v1 = try store.insertVideo(path: "/tmp/v1.mp4", sizeBytes: 1_000)
        let v2 = try store.insertVideo(path: "/tmp/v2.mp4", sizeBytes: 2_000)

        let f1 = try store.insertSeedFrame(timestampMs: 10_000, foreground: "v1a")
        let f2 = try store.insertSeedFrame(timestampMs: 20_000, foreground: "v1b")
        let f3 = try store.insertSeedFrame(timestampMs: 30_000, foreground: "v2a")
        try store.attachFrame(id: f1, videoID: v1, videoIndex: 0)
        try store.attachFrame(id: f2, videoID: v1, videoIndex: 1)
        try store.attachFrame(id: f3, videoID: v2, videoIndex: 0)

        let v1Frames = try store.frames(videoID: v1)
        XCTAssertEqual(v1Frames.map(\.id), [f1, f2])
        XCTAssertEqual(v1Frames.map(\.videoIndex), [0, 1])

        // videosOlderThan: max timestamp of v1 is 20_000, of v2 is 30_000
        let older = try store.videosOlderThan(newestTimestampMs: 25_000)
        XCTAssertEqual(older.map(\.id), [v1])

        XCTAssertEqual(try store.totalVideoBytes(), 3_000)
        try store.markVideoPurged(id: v1)
        XCTAssertEqual(try store.totalVideoBytes(), 2_000)

        let byOldest = try store.videosByOldestFrame()
        XCTAssertEqual(byOldest.map(\.id), [v2])  // v1 purged (status != 0)
    }

    // MARK: - Timeline / recent

    func testRecentTimelineJoinsAppDomain() throws {
        _ = try store.insertSeedFrame(
            timestampMs: 1,
            foreground: "doc body",
            background: "sidebar notes",
            title: "Doc",
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            domain: "news.ycombinator.com",
            url: "https://news.ycombinator.com/item?id=1",
            width: 3440,
            height: 1440
        )
        let timeline = try store.recentTimeline(limit: 10)
        XCTAssertEqual(timeline.count, 1)
        XCTAssertEqual(timeline[0].bundleID, "com.apple.Safari")
        XCTAssertEqual(timeline[0].displayName, "Safari")
        XCTAssertEqual(timeline[0].domain, "news.ycombinator.com")
        XCTAssertEqual(timeline[0].url, "https://news.ycombinator.com/item?id=1")
        XCTAssertEqual(timeline[0].appLabel, "Safari")
        XCTAssertEqual(timeline[0].foreground, "doc body")
        XCTAssertEqual(timeline[0].background, "sidebar notes")
        XCTAssertEqual(timeline[0].width, 3440)
        XCTAssertEqual(timeline[0].height, 1440)
        XCTAssertEqual(timeline[0].ocrText, "doc bodysidebar notes")
        XCTAssertTrue(timeline[0].ocrPreview.contains("doc body"))
        XCTAssertTrue(timeline[0].ocrPreview.contains("sidebar"))
    }

    func testRecentTimelineLimitCountsMomentsAndKeepsEveryDisplay() throws {
        let main = CaptureDisplayRect(x: 0, y: 0, width: 1_728, height: 1_117)
        let second = CaptureDisplayRect(x: 1_728, y: 0, width: 1_920, height: 1_080)
        _ = try store.insertSeedFrame(
            timestampMs: 1_000,
            foreground: "older",
            captureDisplay: main
        )
        let mainID = try store.insertSeedFrame(
            timestampMs: 2_000,
            foreground: "main",
            width: 3_456,
            height: 2_234,
            captureDisplay: main
        )
        let secondID = try store.insertSeedFrame(
            timestampMs: 2_000,
            foreground: "second",
            width: 3_840,
            height: 2_160,
            captureDisplay: second
        )

        let timeline = try store.recentTimeline(limit: 1)

        XCTAssertEqual(Set(timeline.map(\.id)), Set([mainID, secondID]))
        XCTAssertEqual(timeline.map(\.timestampMs), [2_000, 2_000])
        XCTAssertEqual(
            timeline.compactMap(\.captureDisplay).sorted { $0.x < $1.x },
            [main, second]
        )
    }

    func testTimelineAroundUsesMomentBoundsAndKeepsCenterDisplays() throws {
        var centerID: Int64 = 0
        for timestamp in 1...12 {
            let id = try store.insertSeedFrame(
                timestampMs: Int64(timestamp * 1_000),
                foreground: "moment \(timestamp)"
            )
            if timestamp == 6 {
                centerID = id
                _ = try store.insertSeedFrame(
                    timestampMs: Int64(timestamp * 1_000),
                    foreground: "moment \(timestamp) second display"
                )
            }
        }

        let timeline = try store.timelineAround(frameID: centerID, before: 2, after: 3)

        XCTAssertEqual(Set(timeline.map(\.timestampMs)), Set([4_000, 5_000, 6_000, 7_000, 8_000, 9_000]))
        XCTAssertEqual(timeline.filter { $0.timestampMs == 6_000 }.count, 2)
    }

    func testTimelineSessionAndExpand() throws {
        // Session A: 0...2000, then gap, Session B: 1_000_000...
        let a1 = try store.insertSeedFrame(timestampMs: 0, foreground: "a1", background: "bg-a1")
        let a2 = try store.insertSeedFrame(timestampMs: 1_000, foreground: "a2")
        let a3 = try store.insertSeedFrame(timestampMs: 2_000, foreground: "a3")
        let b1 = try store.insertSeedFrame(timestampMs: 1_000_000, foreground: "b1")
        let b2 = try store.insertSeedFrame(timestampMs: 1_001_000, foreground: "b2")

        let sessions = try store.sessions(gapMs: 60_000)
        XCTAssertEqual(sessions.count, 2)

        // sessions are ordered by start DESC to B first, then A
        let sessionB = sessions[0]
        let sessionA = sessions[1]
        XCTAssertEqual(sessionA.startMs, 0)
        XCTAssertEqual(sessionA.endMs, 2_000)
        XCTAssertEqual(sessionB.startMs, 1_000_000)
        XCTAssertEqual(sessionA.pinKey, "0-2000")
        XCTAssertEqual(SessionPinStore.pinID(for: sessionA), sessionA.pinKey)

        let aFrames = try store.timeline(session: sessionA)
        XCTAssertEqual(aFrames.map(\.id), [a1, a2, a3])
        XCTAssertEqual(aFrames.first?.background, "bg-a1")

        let bFrames = try store.timeline(session: sessionB)
        XCTAssertEqual(bFrames.map(\.id), [b1, b2])

        // Expand around a2: radius 1500 ms to [0, 2500] to a1,a2,a3 (not session B)
        let expanded = try store.timelineExpand(aroundTimestampMs: 1_000, radiusMs: 1_500, limit: 50)
        XCTAssertEqual(expanded.map(\.id), [a1, a2, a3])

        // Range query inclusive
        let range = try store.timeline(fromTimestampMs: 1_000, toTimestampMs: 2_000)
        XCTAssertEqual(range.map(\.id), [a2, a3])

        // Near-zero center clamps without crash
        let nearZero = try store.timelineExpand(aroundTimestampMs: 100, radiusMs: 5_000, limit: 50)
        XCTAssertTrue(nearZero.map(\.id).contains(a1))
        XCTAssertFalse(nearZero.map(\.id).contains(b1))
    }

    func testLongSessionWindowCanReachBeginningMiddleAndEndWithoutTruncation() throws {
        for moment in 0..<1_200 {
            _ = try store.insertSeedFrame(
                timestampMs: Int64(moment) * 1_000,
                foreground: "moment \(moment)"
            )
        }
        let session = try XCTUnwrap(store.sessions(gapMs: 60_000).first)

        let beginning = try store.timeline(
            session: session,
            aroundTimestampMs: session.startMs,
            before: 0,
            after: 499
        )
        let middle = try store.timeline(
            session: session,
            aroundTimestampMs: 600_000,
            before: 249,
            after: 250
        )
        let end = try store.timeline(
            session: session,
            aroundTimestampMs: session.endMs,
            before: 499,
            after: 0
        )

        XCTAssertEqual(beginning.count, 500)
        XCTAssertEqual(beginning.first?.timestampMs, session.startMs)
        XCTAssertEqual(middle.count, 500)
        XCTAssertEqual(middle.first?.timestampMs, 351_000)
        XCTAssertEqual(middle.last?.timestampMs, 850_000)
        XCTAssertEqual(end.count, 500)
        XCTAssertEqual(end.last?.timestampMs, session.endMs)
    }

    func testOCRTextAndBoxSlices() throws {
        let fg = "Hello"
        let bg = "World"
        // FG starts at 0 and BG at utf16(fg); this fixture inserts one foreground box.
        let id = try store.insertSeedFrame(
            timestampMs: 99,
            foreground: fg,
            background: bg
        )

        XCTAssertEqual(try store.ocrText(frameID: id), fg + bg)
        XCTAssertNil(try store.ocrText(frameID: 999_999))

        // Replace OCR boxes with explicit FG + BG slices into concatenated text.
        try store.db.exec("DELETE FROM ocr WHERE frame = \(id)")
        let boxes = [
            OCRBox(x: 0, y: 0, width: 40, height: 12, textOffset: 0, textLength: fg.utf16.count),
            OCRBox(
                x: 0, y: 20, width: 40, height: 12,
                textOffset: fg.utf16.count,
                textLength: bg.utf16.count
            ),
        ]
        for box in boxes {
            let stmt = try store.db.prepare(
                """
                INSERT INTO ocr(frame, x, y, width, height, text_offset, text_length)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.int64(stmt, 1, id)
            SQLiteBind.int(stmt, 2, box.x)
            SQLiteBind.int(stmt, 3, box.y)
            SQLiteBind.int(stmt, 4, box.width)
            SQLiteBind.int(stmt, 5, box.height)
            SQLiteBind.int(stmt, 6, box.textOffset)
            SQLiteBind.int(stmt, 7, box.textLength)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        }

        let slices = try store.ocrBoxTexts(frameID: id)
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].text, "Hello")
        XCTAssertEqual(slices[1].text, "World")
        XCTAssertEqual(slices[0].box.textOffset, 0)
        XCTAssertEqual(slices[1].box.textOffset, fg.utf16.count)

        XCTAssertTrue(try store.ocrBoxTexts(frameID: 999_999).isEmpty)

        // Timeline around / near also carry background
        let around = try store.timelineAround(frameID: id, before: 5, after: 5)
        XCTAssertEqual(around.first?.background, bg)
        let near = try store.timelineNear(timestampMs: 99, limit: 5)
        XCTAssertEqual(near.first(where: { $0.id == id })?.ocrText, fg + bg)
    }

    func testTopDomains() throws {
        _ = try store.insertSeedFrame(timestampMs: 1, foreground: "a", domain: "a.com")
        _ = try store.insertSeedFrame(timestampMs: 2, foreground: "a", domain: "a.com")
        _ = try store.insertSeedFrame(timestampMs: 3, foreground: "b", domain: "b.com")
        let tops = try store.topDomains(limit: 5)
        XCTAssertEqual(tops.first?.identifier, "a.com")
        XCTAssertEqual(tops.first?.frameCount, 2)
    }

    func testUsageAndSessionsCountSynchronizedDisplaysAsOneMoment() throws {
        _ = try store.insertSeedFrame(
            timestampMs: 1_000,
            foreground: "main",
            bundleID: "dev.multidisplay",
            displayName: "Multi Display"
        )
        _ = try store.insertSeedFrame(
            timestampMs: 1_000,
            foreground: "secondary",
            bundleID: "dev.multidisplay",
            displayName: "Multi Display"
        )

        XCTAssertEqual(try store.topApplications(limit: 1).first?.frameCount, 1)
        XCTAssertEqual(try store.sessions().first?.frameCount, 1)
        XCTAssertEqual(try store.stats().totalFrames, 2)
        XCTAssertEqual(try store.stats().momentCount, 1)
        XCTAssertEqual(try store.stats().unfinalizedMomentCount, 1)
    }

    func testSampleFramesMinSegmentLength() throws {
        // same app/domain/url to one segment with 2 frames
        _ = try store.insertSeedFrame(timestampMs: 1, foreground: "s", bundleID: "dev.s", url: "u")
        _ = try store.insertSeedFrame(timestampMs: 2, foreground: "s", bundleID: "dev.s", url: "u")
        // different to second segment with 1 frame
        _ = try store.insertSeedFrame(timestampMs: 3, foreground: "t", bundleID: "dev.t", url: "v")

        let min2 = try store.sampleFrames(limit: 50, minSegLen: 2)
        XCTAssertEqual(min2.count, 1)

        let min1 = try store.sampleFrames(limit: 50, minSegLen: 1)
        XCTAssertEqual(min1.count, 2)
    }
}
