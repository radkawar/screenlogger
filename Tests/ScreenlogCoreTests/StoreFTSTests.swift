import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers
import XCTest

@testable import ScreenlogCore

final class StoreFTSTests: XCTestCase {
    var tempRoot: URL!
    var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = try Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testSchemaCreatesAndStatsEmpty() throws {
        let s = try store.stats()
        XCTAssertEqual(s.totalFrames, 0)
        XCTAssertEqual(s.unfinalizedFrames, 0)
    }

    func testInsertAndFTSMatchRealPath() throws {
        // Alphanumeric token only - FTS5 tokenizer splits on hyphens.
        let phrase = "uniqueftstoken\(String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: ""))"
        let stillPath = tempRoot.appendingPathComponent("still-\(phrase).heic").path
        try Data([0x00, 0x01]).write(to: URL(fileURLWithPath: stillPath))
        let id = try store.insertSeedFrame(
            timestampMs: 1_700_000_000_000,
            foreground: "Invoice total for \(phrase) payable now",
            title: "Mail",
            bundleID: "com.apple.mail",
            displayName: "Mail",
            domain: "mail.example",
            imagePath: stillPath
        )
        XCTAssertGreaterThan(id, 0)

        let hits = try store.ftsSearch(query: phrase, limit: 10)
        XCTAssertFalse(hits.isEmpty, "FTS must return seeded phrase via real Store.ftsSearch")
        XCTAssertEqual(hits.first?.frameID, id)
        XCTAssertEqual(hits.first?.imagePath, stillPath)
        XCTAssertFalse(hits.first?.isCompacted == true)
        XCTAssertTrue(hits.first?.hasStillThumbnail == true)
        XCTAssertTrue(
            (hits.first?.snippet ?? hits.first?.title ?? "").contains(phrase)
                || hits.contains(where: { $0.frameID == id }),
            "result should reference seeded frame"
        )

        let frame = try store.frame(id: id)
        XCTAssertNotNil(frame)
        XCTAssertTrue(frame!.foreground?.contains(phrase) == true)
    }

    func testReusedOCRSkipsSearchIndexRewrite() throws {
        let phrase = "reusedocr\(String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: ""))"
        let indexed = try store.store(
            payload: CapturePayload(
                imageData: Data([0x00, 0x01]),
                timestampMs: 1_700_000_001_000,
                width: 10,
                height: 10,
                foreground: phrase,
                title: "Notes",
                imageFileExtension: "bin",
                indexSearch: true
            )
        )
        let reused = try store.store(
            payload: CapturePayload(
                imageData: Data([0x00, 0x02]),
                timestampMs: 1_700_000_001_500,
                width: 10,
                height: 10,
                foreground: phrase,
                title: "Notes",
                imageFileExtension: "bin",
                indexSearch: false
            )
        )

        let hits = try store.ftsSearch(query: phrase, limit: 10)
        XCTAssertEqual(hits.map(\.frameID), [indexed])
        XCTAssertEqual(try store.frame(id: reused)?.foreground, phrase)

        try store.withSerializedMutation {
            try store.db.exec("DELETE FROM frame WHERE id = \(reused)")
        }
        let hitsAfterDelete = try store.ftsSearch(query: phrase, limit: 10)
        XCTAssertEqual(hitsAfterDelete.map(\.frameID), [indexed])
    }

    func testLibrarySearchAdvertisesOnlyActiveCompactedMedia() throws {
        let activeToken = "activecompact\(UUID().uuidString.prefix(8))"
        let purgedToken = "purgedcompact\(UUID().uuidString.prefix(8))"
        let activeFrame = try store.insertSeedFrame(
            timestampMs: 1_700_000_000_100,
            foreground: activeToken
        )
        let purgedFrame = try store.insertSeedFrame(
            timestampMs: 1_700_000_000_200,
            foreground: purgedToken
        )
        let activeVideo = try store.insertVideo(path: "/tmp/active-preview.mp4", status: 0)
        let purgedVideo = try store.insertVideo(path: "/tmp/purged-preview.mp4", status: 2)
        try store.attachFrame(id: activeFrame, videoID: activeVideo, videoIndex: 0)
        try store.attachFrame(id: purgedFrame, videoID: purgedVideo, videoIndex: 0)
        try store.withSerializedMutation {
            try store.db.exec(
                "UPDATE frame SET image_path = NULL WHERE id IN (\(activeFrame), \(purgedFrame))"
            )
        }

        let activeHit = try XCTUnwrap(
            try store.searchLibrary(query: LibrarySearchQuery(text: activeToken), limit: 1).first
        )
        XCTAssertTrue(activeHit.isCompacted)
        XCTAssertNil(activeHit.imagePath)

        let purgedHit = try XCTUnwrap(
            try store.searchLibrary(query: LibrarySearchQuery(text: purgedToken), limit: 1).first
        )
        XCTAssertFalse(
            purgedHit.isCompacted,
            "Purged video must not be presented as a preview that can still be loaded."
        )
        XCTAssertNil(purgedHit.imagePath)
    }

    func testStructuredSearchMatchesAppLibraryAndAssistantContract() throws {
        let token = "structured" + String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: "")
        let targetID = try store.insertSeedFrame(
            timestampMs: 1_783_000_000_000,
            foreground: "Quarterly invoice \(token)",
            title: "Documentation",
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            domain: "docs.example.com"
        )
        _ = try store.insertSeedFrame(
            timestampMs: 1_784_000_000_000,
            foreground: "Unrelated duplicate \(token)",
            title: "Chat",
            bundleID: "com.example.Chat",
            displayName: "Chat",
            domain: "chat.example.net"
        )

        let refined = try store.searchLibrary(
            query: "\(token) app:Safari site:example.com since:2026-01-01 before:2027-01-01",
            limit: 10
        )
        XCTAssertEqual(refined.map(\.frameID), [targetID])

        let operatorOnly = try store.searchLibrary(
            query: "app:Safari site:docs.example.com since:2026-01-01",
            limit: 10
        )
        XCTAssertEqual(operatorOnly.map(\.frameID), [targetID])
    }

    func testConstrainedSearchFiltersBeforeLimit() throws {
        let token = "constrained\(String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: ""))"
        let targetID = try store.insertSeedFrame(
            timestampMs: 1_500_000_000_000,
            foreground: "archived \(token) invoice",
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            domain: "docs.example.com"
        )

        for index in 0..<90 {
            _ = try store.insertSeedFrame(
                timestampMs: 2_000_000_000_000 + Int64(index),
                foreground: "newer global \(token) result \(index)",
                bundleID: "com.example.Chat",
                displayName: "Chat",
                domain: "chat.example.net"
            )
        }

        let global = try store.ftsSearch(query: token, limit: 80)
        XCTAssertEqual(global.count, 80)
        XCTAssertFalse(global.contains(where: { $0.frameID == targetID }))

        let constrained = try store.searchLibrary(
            query: LibrarySearchQuery(
                text: token,
                appFilter: "com.apple.Safari",
                siteFilter: "example.com"
            ),
            limit: 10
        )
        XCTAssertEqual(constrained.map(\.frameID), [targetID])

        let operatorQuery = try store.searchLibrary(
            query: "\(token) app:Safari site:example.com",
            limit: 10
        )
        XCTAssertEqual(operatorQuery.map(\.frameID), [targetID])
    }

    func testPagedSearchUsesPrivateSentinelWithoutExpandingPublicLimit() throws {
        let token = "paged\(String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: ""))"
        for index in 0..<502 {
            _ = try store.insertSeedFrame(
                timestampMs: 2_100_000_000_000 + Int64(index),
                foreground: "\(token) result \(index)"
            )
        }

        let page = try store.searchLibraryPage(
            query: LibrarySearchQuery(text: token),
            visibleLimit: 500
        )
        XCTAssertEqual(page.results.count, 500)
        XCTAssertTrue(page.isTruncated)

        let ordinarySearch = try store.searchLibrary(
            query: LibrarySearchQuery(text: token),
            limit: 501
        )
        XCTAssertEqual(ordinarySearch.count, 500)
    }

    func testKeysetPagesAreStableAcrossNewCaptures() throws {
        let token = "cursor\(String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: ""))"
        for index in 0..<205 {
            _ = try store.insertSeedFrame(
                timestampMs: 2_200_000_000_000 + Int64(index),
                foreground: "\(token) result \(index)"
            )
        }

        let first = try store.searchLibraryPage(
            query: LibrarySearchQuery(text: token),
            visibleLimit: 80
        )
        XCTAssertEqual(first.results.count, 80)
        XCTAssertTrue(first.isTruncated)
        let firstCursor = try XCTUnwrap(first.nextCursor)
        XCTAssertEqual(firstCursor.frameID, first.results.last?.frameID)

        // A newer capture arriving between page requests must not shift the
        // cursor window or cause any previously visible result to repeat.
        let insertedAfterFirstPage = try store.insertSeedFrame(
            timestampMs: 2_300_000_000_000,
            foreground: "\(token) captured later"
        )
        let second = try store.searchLibraryPage(
            query: LibrarySearchQuery(text: token),
            visibleLimit: 80,
            after: firstCursor
        )
        let secondCursor = try XCTUnwrap(second.nextCursor)
        let third = try store.searchLibraryPage(
            query: LibrarySearchQuery(text: token),
            visibleLimit: 80,
            after: secondCursor
        )

        XCTAssertEqual(second.results.count, 80)
        XCTAssertEqual(third.results.count, 45)
        XCTAssertFalse(third.isTruncated)
        XCTAssertNil(third.nextCursor)

        let pagedIDs =
            first.results.map(\.frameID)
            + second.results.map(\.frameID)
            + third.results.map(\.frameID)
        XCTAssertEqual(pagedIDs.count, 205)
        XCTAssertEqual(Set(pagedIDs).count, 205)
        XCTAssertFalse(pagedIDs.contains(insertedAfterFirstPage))
        XCTAssertTrue(
            zip(pagedIDs, pagedIDs.dropFirst()).allSatisfy { newerID, olderID in
                let newer = try? store.frame(id: newerID)
                let older = try? store.frame(id: olderID)
                guard let newer, let older else { return false }
                return newer.timestampMs > older.timestampMs
                    || (newer.timestampMs == older.timestampMs && newerID > olderID)
            }
        )
    }

    func testSearchReturnsOneExactDisplayPerMomentAndPaginatesByMoment() throws {
        let token = "multisearch\(String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: ""))"
        _ = try store.insertSeedFrame(
            timestampMs: 3_000,
            foreground: "\(token) main display"
        )
        let selectedDisplayID = try store.insertSeedFrame(
            timestampMs: 3_000,
            foreground: "\(token) secondary display"
        )
        let olderID = try store.insertSeedFrame(
            timestampMs: 2_000,
            foreground: "\(token) older moment"
        )

        let first = try store.searchLibraryPage(
            query: LibrarySearchQuery(text: token),
            visibleLimit: 1
        )
        XCTAssertEqual(first.results.map(\.frameID), [selectedDisplayID])
        XCTAssertTrue(first.isTruncated)

        let second = try store.searchLibraryPage(
            query: LibrarySearchQuery(text: token),
            visibleLimit: 1,
            after: try XCTUnwrap(first.nextCursor)
        )
        XCTAssertEqual(second.results.map(\.frameID), [olderID])
        XCTAssertFalse(second.isTruncated)
    }

    func testCancelledQueuedReadDoesNotRunBeforeTheNewestRequest() async throws {
        let firstReadStarted = expectation(description: "first read started")
        let releaseFirstRead = DispatchSemaphore(value: 0)
        let cancelledBodyRan = DispatchSemaphore(value: 0)

        let firstRead = Task {
            try await store.readAsync { _ in
                firstReadStarted.fulfill()
                releaseFirstRead.wait()
                return 1
            }
        }
        await fulfillment(of: [firstReadStarted], timeout: 2)

        let supersededRead = Task {
            try await store.readAsync { _ in
                cancelledBodyRan.signal()
                return 2
            }
        }
        supersededRead.cancel()
        releaseFirstRead.signal()

        let firstReadValue = try await firstRead.value
        XCTAssertEqual(firstReadValue, 1)
        do {
            _ = try await supersededRead.value
            XCTFail("A canceled queued Store read should throw CancellationError")
        } catch is CancellationError {
            // Expected: the queued body never reaches SQLite.
        }
        XCTAssertEqual(cancelledBodyRan.wait(timeout: .now() + 0.05), .timedOut)
    }

    func testAsyncStoreReadNeverExecutesOnTheMainThread() async throws {
        let executedOnMainThread = try await store.readAsync { _ in
            Thread.isMainThread
        }
        XCTAssertFalse(executedOnMainThread)
    }

    func testConstrainedSearchSupportsTimeOnlyQueriesSafely() throws {
        _ = try store.insertSeedFrame(timestampMs: 1_000, foreground: "before window")
        let inWindowID = try store.insertSeedFrame(timestampMs: 2_000, foreground: "inside window")
        _ = try store.insertSeedFrame(timestampMs: 3_000, foreground: "after window")

        let timeOnly = try store.searchLibrary(
            query: LibrarySearchQuery(fromTimestampMs: 1_500, toTimestampMs: 2_500),
            limit: 10
        )
        XCTAssertEqual(timeOnly.map(\.frameID), [inWindowID])
        XCTAssertTrue(try store.searchLibrary(query: LibrarySearchQuery()).isEmpty)
        XCTAssertTrue(
            try store.searchLibrary(
                query: LibrarySearchQuery(text: "-", appFilter: "Safari")
            ).isEmpty
        )
        XCTAssertTrue(
            try store.searchLibrary(
                query: LibrarySearchQuery(fromTimestampMs: 3_000, toTimestampMs: 2_000)
            ).isEmpty
        )
    }

    func testConstrainedSearchSupportsAppAndSiteOnlyQueries() throws {
        let safariDocsID = try store.insertSeedFrame(
            timestampMs: 1_000,
            foreground: "Safari documentation",
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            domain: "docs.example.com"
        )
        let safariOtherID = try store.insertSeedFrame(
            timestampMs: 2_000,
            foreground: "Safari elsewhere",
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            domain: "other.test"
        )
        let mailDocsID = try store.insertSeedFrame(
            timestampMs: 3_000,
            foreground: "Mail documentation",
            bundleID: "com.apple.mail",
            displayName: "Mail",
            domain: "mail.example.com"
        )

        let appOnly = try store.searchLibrary(
            query: LibrarySearchQuery(appFilter: "COM.APPLE.SAFARI"),
            limit: 10
        )
        XCTAssertEqual(appOnly.map(\.frameID), [safariOtherID, safariDocsID])

        let siteOnly = try store.searchLibrary(
            query: LibrarySearchQuery(siteFilter: "https://www.example.com/path"),
            limit: 10
        )
        XCTAssertEqual(siteOnly.map(\.frameID), [mailDocsID, safariDocsID])

        let combined = try store.searchLibrary(
            query: LibrarySearchQuery(
                appFilter: "Safari",
                siteFilter: "example.com"
            ),
            limit: 10
        )
        XCTAssertEqual(combined.map(\.frameID), [safariDocsID])
    }

    func testExactChipConstraintsIntersectFuzzyOperators() throws {
        let targetID = try store.insertSeedFrame(
            timestampMs: 1_000,
            foreground: "intersected result",
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            domain: "example.com"
        )
        _ = try store.insertSeedFrame(
            timestampMs: 2_000,
            foreground: "wrong app",
            bundleID: "com.apple.SafariTechnologyPreview",
            displayName: "Safari Technology Preview",
            domain: "example.com"
        )
        _ = try store.insertSeedFrame(
            timestampMs: 3_000,
            foreground: "wrong domain",
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            domain: "docs.example.com"
        )

        let results = try store.searchLibrary(
            query: LibrarySearchQuery(
                appFilter: "Safari",
                siteFilter: "example.com",
                appBundleID: "COM.APPLE.SAFARI",
                domain: "https://www.example.com/path"
            )
        )
        XCTAssertEqual(results.map(\.frameID), [targetID])
    }

    func testExactAppChipDoesNotMatchBundleVariants() throws {
        let exactID = try store.insertSeedFrame(
            timestampMs: 1_000,
            foreground: "exact editor",
            bundleID: "com.example.Editor",
            displayName: "Editor"
        )
        _ = try store.insertSeedFrame(
            timestampMs: 2_000,
            foreground: "editor helper",
            bundleID: "com.example.Editor.Helper",
            displayName: "Editor Helper"
        )

        let results = try store.searchLibrary(
            query: LibrarySearchQuery(appBundleID: "COM.EXAMPLE.EDITOR")
        )
        XCTAssertEqual(results.map(\.frameID), [exactID])
    }

    func testExactDomainChipDoesNotMatchSubdomains() throws {
        let exactID = try store.insertSeedFrame(
            timestampMs: 1_000,
            foreground: "parent site",
            domain: "example.com"
        )
        _ = try store.insertSeedFrame(
            timestampMs: 2_000,
            foreground: "child site",
            domain: "docs.example.com"
        )

        let results = try store.searchLibrary(
            query: LibrarySearchQuery(domain: "https://www.example.com/path")
        )
        XCTAssertEqual(results.map(\.frameID), [exactID])
    }

    /// `date:` / `since:` / `before:` must filter in SQL. Without bounds, LIMIT returns only
    /// the newest hits - an older matching frame is invisible even when it matches the query.
    func testFTSSearchSQLTimeBoundsFindOlderHits() throws {
        let token = "timetoken\(String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: ""))"
        // 100 recent frames all contain the token (newest first in FTS default order).
        let recentBase: Int64 = 2_000_000_000_000
        for i in 0..<100 {
            _ = try store.insertSeedFrame(
                timestampMs: recentBase + Int64(i),
                foreground: "recent \(token) hit \(i)",
                title: "Recent"
            )
        }
        // One older frame that also matches - would be outside LIMIT 80 of newest-only results.
        let oldMs: Int64 = 1_500_000_000_000
        let oldID = try store.insertSeedFrame(
            timestampMs: oldMs,
            foreground: "old invoice \(token) from yesterday",
            title: "Old"
        )

        // Prove unbounded LIMIT 80 misses the old row (ORDER BY timestamp DESC).
        let newest = try store.ftsSearch(query: token, limit: 80)
        XCTAssertEqual(newest.count, 80)
        XCTAssertFalse(
            newest.contains(where: { $0.frameID == oldID }),
            "unbounded LIMIT should only return the newest 80 - old hit must be outside the set"
        )

        // SQL time window around the old frame surfaces it even with a small LIMIT.
        let windowed = try store.ftsSearch(
            query: token,
            limit: 10,
            fromTimestampMs: oldMs - 1_000,
            toTimestampMs: oldMs + 1_000
        )
        XCTAssertEqual(windowed.map(\.frameID), [oldID])
        XCTAssertEqual(windowed.first?.timestampMs, oldMs)

        // since: / before: style half-open style bounds (inclusive in SQL).
        let sinceOnly = try store.ftsSearch(
            query: token,
            limit: 5,
            fromTimestampMs: oldMs,
            toTimestampMs: oldMs
        )
        XCTAssertEqual(sinceOnly.map(\.frameID), [oldID])

        // Upper bound alone excludes recent cluster.
        let beforeRecent = try store.ftsSearch(
            query: token,
            limit: 20,
            fromTimestampMs: nil,
            toTimestampMs: recentBase - 1
        )
        XCTAssertTrue(beforeRecent.contains(where: { $0.frameID == oldID }))
        XCTAssertTrue(beforeRecent.allSatisfy { $0.timestampMs <= recentBase - 1 })
    }

    /// End-to-end: parse `token since:... before:...` to sqlTimeBounds to ftsSearch finds old hit.
    func testParseOperatorsToFTSTimeBoundsIntegration() throws {
        let token = "invtoken\(String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: ""))"
        let recentBase: Int64 = 1_800_000_000_000
        for i in 0..<90 {
            _ = try store.insertSeedFrame(
                timestampMs: recentBase + Int64(i * 1000),
                foreground: "\(token) today body \(i)"
            )
        }
        // Fixed day: 2020-06-15 12:00 UTC ~ use absolute ms for seed.
        // Use parser with fixed calendar so since/before map to known ms.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let oldDay = cal.date(from: DateComponents(year: 2020, month: 6, day: 15, hour: 12))!
        let oldMs = Int64(oldDay.timeIntervalSince1970 * 1000)
        let oldID = try store.insertSeedFrame(
            timestampMs: oldMs,
            foreground: "\(token) archived invoice"
        )

        let raw = "\(token) since:2020-06-01 before:2020-06-30"
        let parsed = SearchOperatorParser.parse(raw, calendar: cal, timeZone: cal.timeZone)
        XCTAssertEqual(parsed.ftsText, token)
        let bounds = SearchOperatorParser.sqlTimeBounds(from: parsed)
        XCTAssertNotNil(bounds.fromTimestampMs)
        XCTAssertNotNil(bounds.toTimestampMs)
        XCTAssertLessThan(bounds.fromTimestampMs!, oldMs)
        XCTAssertGreaterThan(bounds.toTimestampMs!, oldMs)

        let hits = try store.ftsSearch(
            query: parsed.ftsText,
            limit: 50,
            fromTimestampMs: bounds.fromTimestampMs,
            toTimestampMs: bounds.toTimestampMs
        )
        XCTAssertTrue(
            hits.contains(where: { $0.frameID == oldID }),
            "SQL bounds from since:/before: must return the archived frame, not only recent LIMIT set"
        )
        XCTAssertTrue(
            hits.allSatisfy {
                SearchOperatorParser.matchesTimeBounds($0, parsed: parsed)
            })
    }

    func testSessionsTimelineNeighborhood() throws {
        let a = try store.insertSeedFrame(timestampMs: 1_000, foreground: "sess alpha one")
        _ = try store.insertSeedFrame(timestampMs: 2_000, foreground: "sess alpha two")
        let b = try store.insertSeedFrame(timestampMs: 1_000_000, foreground: "sess beta")
        let sessions = try store.sessions(gapMs: 60_000)
        XCTAssertEqual(sessions.count, 2)
        let early = sessions.first(where: { $0.startMs <= 2_000 })!
        let frames = try store.timeline(session: early, limit: 50)
        XCTAssertGreaterThanOrEqual(frames.count, 2)
        XCTAssertTrue(frames.contains(where: { $0.id == a }))
        let around = try store.timelineAround(frameID: b, before: 5, after: 5)
        XCTAssertFalse(around.isEmpty)
        XCTAssertTrue(around.contains(where: { $0.id == b }))
    }

    func testSegmentsAndTopApps() throws {
        _ = try store.insertSeedFrame(
            timestampMs: 1000,
            foreground: "alpha",
            bundleID: "dev.a",
            displayName: "A"
        )
        _ = try store.insertSeedFrame(
            timestampMs: 2000,
            foreground: "beta",
            bundleID: "dev.a",
            displayName: "A"
        )
        _ = try store.insertSeedFrame(
            timestampMs: 3000,
            foreground: "gamma",
            bundleID: "dev.b",
            displayName: "B"
        )
        let tops = try store.topApplications(limit: 5)
        XCTAssertFalse(tops.isEmpty)
        XCTAssertEqual(tops.first?.identifier, "dev.a")
        XCTAssertEqual(tops.first?.frameCount, 2)
    }

    func testSessionsGap() throws {
        _ = try store.insertSeedFrame(timestampMs: 0, foreground: "s1")
        _ = try store.insertSeedFrame(timestampMs: 1_000, foreground: "s1b")
        _ = try store.insertSeedFrame(timestampMs: 1_000_000, foreground: "s2")
        let sessions = try store.sessions(gapMs: 60_000)
        XCTAssertEqual(sessions.count, 2)
    }

    func testSessionsPrimaryAppEnrichment() throws {
        _ = try store.insertSeedFrame(
            timestampMs: 10_000,
            foreground: "hello",
            bundleID: "com.example.editor",
            displayName: "Editor"
        )
        _ = try store.insertSeedFrame(
            timestampMs: 11_000,
            foreground: "world",
            bundleID: "com.example.other",
            displayName: "Other"
        )
        let sessions = try store.sessions(gapMs: 60_000)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].primaryBundleID, "com.example.editor")
        XCTAssertEqual(sessions[0].primaryDisplayName, "Editor")
        XCTAssertEqual(sessions[0].appLabel, "Editor")
        XCTAssertEqual(sessions[0].frameCount, 2)
    }

    func testFrameNearestAndAtOrBefore() throws {
        let a = try store.insertSeedFrame(timestampMs: 1_000, foreground: "near-a")
        let b = try store.insertSeedFrame(timestampMs: 5_000, foreground: "near-b")
        let c = try store.insertSeedFrame(timestampMs: 9_000, foreground: "near-c")

        let nearest = try store.frameNearest(timestampMs: 5_200)
        XCTAssertEqual(nearest?.id, b)
        XCTAssertEqual(try store.frameNearest(timestampMs: 3_000)?.id, a)

        let before = try store.frameAtOrBefore(timestampMs: 4_999)
        XCTAssertEqual(before?.id, a)

        let exact = try store.frameNearest(timestampMs: 9_000)
        XCTAssertEqual(exact?.id, c)

        let lowerTie = try store.insertSeedFrame(timestampMs: 7_000, foreground: "tie-a")
        _ = try store.insertSeedFrame(timestampMs: 7_000, foreground: "tie-b")
        XCTAssertEqual(try store.frameNearest(timestampMs: 7_000)?.id, lowerTie)
        XCTAssertEqual(try store.frameNearest(timestampMs: 7_001)?.id, lowerTie)

        let emptyRoot = tempRoot.appendingPathComponent("empty-db", isDirectory: true)
        let empty = try Store(root: emptyRoot)
        XCTAssertNil(try empty.frameNearest(timestampMs: 1))
    }

    func testFrameExtractorStillFromImagePath() async throws {
        // Minimal 1x1 PNG
        let pngBase64 =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let png = Data(base64Encoded: pngBase64)!
        let imgURL = tempRoot.appendingPathComponent("tiny.png")
        try png.write(to: imgURL)

        let id = try store.insertSeedFrame(
            timestampMs: 42,
            foreground: "img",
            imagePath: imgURL.path
        )
        let frame = try XCTUnwrap(try store.frame(id: id))
        let still = try await FrameExtractor.stillData(forFrame: frame, store: store)
        XCTAssertEqual(still.source, "still")
        XCTAssertEqual(still.fileExtension, "png")
        XCTAssertFalse(still.data.isEmpty)

        let out = tempRoot.appendingPathComponent("export-out.png")
        let written = try await FrameExtractor.writeStill(forFrame: frame, store: store, to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
    }

    func testFrameExtractorPreviewDownsamplesWithoutChangingAspectRatio() throws {
        let png = try Self.makeSolidPNG(width: 640, height: 320, gray: 96)
        let imageURL = tempRoot.appendingPathComponent("preview-source.png")
        try png.write(to: imageURL)

        let preview = try XCTUnwrap(
            FrameExtractor.previewCGImage(atPath: imageURL.path, maxPixelSize: 160)
        )
        XCTAssertEqual(preview.width, 160)
        XCTAssertEqual(preview.height, 80)
        XCTAssertNil(
            FrameExtractor.previewCGImage(
                atPath: tempRoot.appendingPathComponent("missing.png").path,
                maxPixelSize: 160
            )
        )
    }

    /// After compaction clears image_path, FrameExtractor must pull from video (`source == "video"`).
    func testFrameExtractorAfterCompactSourceIsVideo() async throws {
        let w = 64
        let h = 64
        let base = Int64(1_710_000_000_000)
        var ids: [Int64] = []
        for i in 0..<3 {
            let png = try Self.makeSolidPNG(width: w, height: h, gray: UInt8(50 + i * 50))
            let path = tempRoot.appendingPathComponent("extract-still-\(i).png").path
            try png.write(to: URL(fileURLWithPath: path))
            let id = try store.insertSeedFrame(
                timestampMs: base + Int64(i) * 2_000,
                foreground: "extract-\(i)",
                imagePath: path,
                width: w,
                height: h
            )
            ids.append(id)
        }

        let service = VideoCompactionService()
        service.minBatchSize = 2
        service.minRunSize = 2
        let n = try service.compactIfNeeded(store: store)
        XCTAssertEqual(n, 3)

        let frame = try XCTUnwrap(try store.frame(id: ids[1]))
        XCTAssertNil(frame.imagePath, "compact clears still path")
        XCTAssertNotNil(frame.videoID)
        XCTAssertEqual(frame.videoIndex, 1)

        let still = try await FrameExtractor.stillData(forFrame: frame, store: store)
        XCTAssertEqual(still.source, "video", "must extract from compacted video, not still path")
        XCTAssertFalse(still.data.isEmpty)
        XCTAssertTrue(["heic", "jpg", "jpeg"].contains(still.fileExtension.lowercased()))
    }

    func testListApplicationsAndDomains() throws {
        _ = try store.insertSeedFrame(
            timestampMs: 1,
            foreground: "x",
            bundleID: "dev.screenlog.test",
            domain: "docs.example.com"
        )
        let apps = try store.listApplications()
        let domains = try store.listDomains()
        XCTAssertTrue(apps.contains(where: { $0.bundleID == "dev.screenlog.test" }))
        XCTAssertTrue(domains.contains(where: { $0.normalizedDomain == "docs.example.com" }))
    }

    func testFrameworkImportsLinkRequiredSystemStack() {
        // Structural: core module exposes capture/OCR/XPC symbols (compile-time linkage).
        _ = ScreenCaptureService.self
        _ = OCRService.self
        _ = ScreenlogXPCHost.self
        _ = ScreenlogXPCClient.self
        _ = ScreenlogDaemonProtocol.self
        _ = VideoCompactionService.self
        _ = RecordingEngine.self
        _ = ExclusionStore.self
        _ = FrameExtractor.self
        _ = DiskSpaceMonitor.self
        _ = DifferentialOCRService.self
        _ = AXTreeExtractor.self
        _ = BrowserURLService.self
        _ = RetentionService.self
        _ = ScreenlogCore.version
        XCTAssertFalse(ScreenlogCore.version.isEmpty)
    }

    func testAXSnapshotRoundTrip() throws {
        let id = try store.insertSeedFrame(timestampMs: 42, foreground: "ax-test-frame")
        let snap = AXTreeSnapshot(
            xml: "<AccessibilityTree><Node role=\"AXApplication\" /></AccessibilityTree>",
            nodeCount: 1,
            bundleID: "dev.test",
            applicationName: "Test",
            pid: 1,
            isPartial: false,
            extractionMode: "xml_full"
        )
        try store.storeAXSnapshot(frameID: id, snapshot: snap)
        let xml = try store.axTreeXML(frameID: id)
        XCTAssertEqual(xml, snap.xml)
        let frame = try store.frame(id: id)
        XCTAssertNotNil(frame)
        XCTAssertNotNil(frame?.axRootHash)
        XCTAssertEqual(frame?.axRootHash?.count, 32)  // SHA-256
    }

    func testAppVersionUniquenessAndCaptureDisplay() throws {
        let rect = CaptureDisplayRect(x: 10.5, y: 20.25, width: 1920, height: 1080)
        let payload = CapturePayload(
            imageData: Data([0x00]),
            timestampMs: 99,
            width: 100,
            height: 100,
            foreground: "disp",
            bundleID: "dev.versioned",
            bundleVersion: "1.2.3",
            displayName: "Versioned",
            imageFileExtension: "bin",
            captureDisplay: rect
        )
        let id = try store.store(payload: payload)
        let frame = try store.frame(id: id)
        XCTAssertEqual(frame?.captureDisplay?.x, 10.5)
        XCTAssertEqual(frame?.captureDisplay?.width, 1920)

        let apps = try store.listApplications()
        XCTAssertTrue(apps.contains(where: { $0.bundleID == "dev.versioned" && $0.version == "1.2.3" }))

        // Same bundle, different version to second row
        _ = try store.upsertApplication(bundleID: "dev.versioned", version: "2.0.0", displayName: "Versioned")
        let again = try store.listApplications().filter { $0.bundleID == "dev.versioned" }
        XCTAssertEqual(again.count, 2)
    }

    func testOnceTasksAndMetadata() throws {
        XCTAssertFalse(try store.isOnceTaskCompleted("normalize_cyrillic_ocr_v1"))
        try store.markOnceTask("normalize_cyrillic_ocr_v1")
        XCTAssertTrue(try store.isOnceTaskCompleted("normalize_cyrillic_ocr_v1"))
        try store.setMeta(key: "schema_note", value: "screenlogger-v5")
        XCTAssertEqual(try store.getMeta(key: "schema_note"), "screenlogger-v5")
        try store.recordTimezone("America/Los_Angeles")
        try store.recordAppVersion("0.1.0")
    }

    // MARK: - Compaction integrity

    func testBuildResolutionRunsSplitsOnResolutionDisplayAndGap() {
        typealias F = VideoCompactionService.UnfinalizedFrame
        let frames: [F] = [
            F(id: 1, path: "a", width: 100, height: 100, timestampMs: 0, displayKey: "d1"),
            F(id: 2, path: "b", width: 100, height: 100, timestampMs: 2_000, displayKey: "d1"),
            // resolution change to new run
            F(id: 3, path: "c", width: 200, height: 100, timestampMs: 4_000, displayKey: "d1"),
            F(id: 4, path: "d", width: 200, height: 100, timestampMs: 6_000, displayKey: "d1"),
            // display change to new run
            F(id: 5, path: "e", width: 200, height: 100, timestampMs: 8_000, displayKey: "d2"),
            // large gap to new run (same res + display)
            F(id: 6, path: "f", width: 200, height: 100, timestampMs: 8_000 + 120_000, displayKey: "d2"),
            // back to 100x100 contiguous pair
            F(id: 7, path: "g", width: 100, height: 100, timestampMs: 8_000 + 122_000, displayKey: "d1"),
            F(id: 8, path: "h", width: 100, height: 100, timestampMs: 8_000 + 124_000, displayKey: "d1"),
        ]
        let runs = VideoCompactionService.buildResolutionRuns(frames: frames, maxGapMs: 60_000)
        XCTAssertEqual(runs.count, 5)
        XCTAssertEqual(runs[0].map(\.id), [1, 2])
        XCTAssertEqual(runs[1].map(\.id), [3, 4])
        XCTAssertEqual(runs[2].map(\.id), [5])
        XCTAssertEqual(runs[3].map(\.id), [6])
        XCTAssertEqual(runs[4].map(\.id), [7, 8])
    }

    func testBuildResolutionRunsCompactsInterleavedDisplayStreams() {
        typealias F = VideoCompactionService.UnfinalizedFrame
        let frames: [F] = [
            F(id: 1, path: "a1", width: 100, height: 100, timestampMs: 0, displayKey: "left"),
            F(id: 2, path: "b1", width: 200, height: 100, timestampMs: 0, displayKey: "right"),
            F(id: 3, path: "a2", width: 100, height: 100, timestampMs: 2_000, displayKey: "left"),
            F(id: 4, path: "b2", width: 200, height: 100, timestampMs: 2_000, displayKey: "right"),
            F(id: 5, path: "a3", width: 100, height: 100, timestampMs: 4_000, displayKey: "left"),
            F(id: 6, path: "b3", width: 200, height: 100, timestampMs: 4_000, displayKey: "right"),
        ]

        let runs = VideoCompactionService.buildResolutionRuns(frames: frames, maxGapMs: 60_000)

        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].map(\.id), [1, 3, 5])
        XCTAssertEqual(runs[1].map(\.id), [2, 4, 6])
    }

    func testMakeDisplayKeyRoundsAndNilSafe() {
        XCTAssertNil(VideoCompactionService.makeDisplayKey(x: nil, y: 0, width: 1, height: 1))
        XCTAssertEqual(
            VideoCompactionService.makeDisplayKey(x: 10.4, y: 20.6, width: 1920.2, height: 1080.8),
            "10,21,1920,1081"
        )
    }

    func testCompactionBitRateScalesForScreenDetailAndCodecEfficiency() {
        let smallHEVC = VideoCompactionService.targetAverageBitRate(
            width: 1_920,
            height: 1_080,
            codec: .hevc
        )
        let retinaHEVC = VideoCompactionService.targetAverageBitRate(
            width: 3_456,
            height: 2_234,
            codec: .hevc
        )
        let retinaH264 = VideoCompactionService.targetAverageBitRate(
            width: 3_456,
            height: 2_234,
            codec: .h264
        )

        XCTAssertGreaterThanOrEqual(smallHEVC, 4_000_000)
        XCTAssertGreaterThan(retinaHEVC, smallHEVC)
        XCTAssertGreaterThan(retinaH264, retinaHEVC)
        XCTAssertLessThanOrEqual(retinaH264, 60_000_000)
    }

    func testCompactOnlyDeletesSuccessfullyEncodedFrames() throws {
        let w = 64
        let h = 64
        let base = Int64(1_700_000_000_000)
        var ids: [Int64] = []
        var paths: [String] = []

        // 4 good stills + 1 missing path that must remain unfinalized (not deleted from DB as video).
        for i in 0..<4 {
            let png = try Self.makeSolidPNG(width: w, height: h, gray: UInt8(40 + i * 40))
            let path = tempRoot.appendingPathComponent("still-\(i).png").path
            try png.write(to: URL(fileURLWithPath: path))
            let id = try store.insertSeedFrame(
                timestampMs: base + Int64(i) * 2_000,
                foreground: "compact-\(i)",
                imagePath: path,
                width: w,
                height: h
            )
            ids.append(id)
            paths.append(path)
        }

        // Frame with non-existent still: loadUnfinalized will clear image_path and skip it.
        let ghostPath = tempRoot.appendingPathComponent("missing-ghost.png").path
        let ghostID = try store.insertSeedFrame(
            timestampMs: base + 20_000,
            foreground: "ghost",
            imagePath: ghostPath,
            width: w,
            height: h
        )

        let service = VideoCompactionService()
        service.minBatchSize = 2
        service.minRunSize = 2
        service.maxGapMs = 60_000

        let n = try service.compactIfNeeded(store: store)
        XCTAssertEqual(n, 4, "all decodable contiguous frames should compact")

        for id in ids {
            let frame = try store.frame(id: id)
            XCTAssertNotNil(frame?.videoID, "frame \(id) should point at video")
            XCTAssertNotNil(frame?.videoIndex)
            XCTAssertNil(frame?.imagePath, "image_path cleared after compact")
            // still file removed
            let idx = ids.firstIndex(of: id)!
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths[idx]))
        }

        let ghost = try store.frame(id: ghostID)
        // Missing file path cleared; must NOT be linked to a video as if encoded.
        XCTAssertNil(ghost?.videoID)
        XCTAssertNil(ghost?.imagePath)

        // video row exists with num_frames matching encoded count
        let stmt = try store.db.prepare("SELECT num_frames, path FROM video WHERE status = 0")
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(SQLiteColumn.int64(stmt, 0), 4)
        let vpath = SQLiteColumn.text(stmt, 0 + 1)
        XCTAssertNotNil(vpath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vpath!))
    }

    func testCompactDoesNotStitchNonContiguousSameResolution() throws {
        let w = 64
        let h = 64
        let base = Int64(1_800_000_000_000)

        // Run A: two frames
        for i in 0..<2 {
            let png = try Self.makeSolidPNG(width: w, height: h, gray: 80)
            let path = tempRoot.appendingPathComponent("a-\(i).png").path
            try png.write(to: URL(fileURLWithPath: path))
            _ = try store.insertSeedFrame(
                timestampMs: base + Int64(i) * 2_000,
                foreground: "a\(i)",
                imagePath: path,
                width: w,
                height: h
            )
        }
        // Different resolution interrupting middle (would have been stitched by old bucket-by-WxH bug)
        do {
            let png = try Self.makeSolidPNG(width: 80, height: 64, gray: 120)
            let path = tempRoot.appendingPathComponent("mid.png").path
            try png.write(to: URL(fileURLWithPath: path))
            _ = try store.insertSeedFrame(
                timestampMs: base + 10_000,
                foreground: "mid",
                imagePath: path,
                width: 80,
                height: 64
            )
        }
        // Run B: two more 64x64 - must be a *separate* video, not stitched with A
        for i in 0..<2 {
            let png = try Self.makeSolidPNG(width: w, height: h, gray: 200)
            let path = tempRoot.appendingPathComponent("b-\(i).png").path
            try png.write(to: URL(fileURLWithPath: path))
            _ = try store.insertSeedFrame(
                timestampMs: base + 20_000 + Int64(i) * 2_000,
                foreground: "b\(i)",
                imagePath: path,
                width: w,
                height: h
            )
        }

        let service = VideoCompactionService()
        service.minBatchSize = 2
        service.minRunSize = 2
        let n = try service.compactIfNeeded(store: store)
        // 2 + 2 from 64x64 runs; mid 80x64 alone (< minRunSize) stays unfinalized
        XCTAssertEqual(n, 4)

        let countStmt = try store.db.prepare("SELECT COUNT(*) FROM video WHERE status = 0")
        defer { sqlite3_finalize(countStmt) }
        XCTAssertEqual(sqlite3_step(countStmt), SQLITE_ROW)
        XCTAssertEqual(SQLiteColumn.int64(countStmt, 0), 2, "two separate videos for non-contiguous same-res runs")

        let midFrames = try store.db.prepare(
            "SELECT COUNT(*) FROM frame WHERE image_path IS NOT NULL AND width = 80"
        )
        defer { sqlite3_finalize(midFrames) }
        XCTAssertEqual(sqlite3_step(midFrames), SQLITE_ROW)
        XCTAssertEqual(SQLiteColumn.int64(midFrames, 0), 1, "interrupted resolution run left as still")
    }

    private static func makeSolidPNG(width: Int, height: Int, gray: UInt8) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        for i in stride(from: 0, to: data.count, by: 4) {
            data[i] = gray
            data[i + 1] = gray
            data[i + 2] = gray
            data[i + 3] = 255
        }
        guard
            let ctx = CGContext(
                data: &data,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = ctx.makeImage()
        else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "CGContext failed"])
        }
        let out = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                out as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "dest failed"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "test", code: 3, userInfo: [NSLocalizedDescriptionKey: "finalize failed"])
        }
        return out as Data
    }
}
