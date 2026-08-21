import Foundation
import ScreenlogCore
import XCTest

@testable import ScreenlogCLI

final class CLIActivityCommandTests: XCTestCase {
    func testRelativeAndAbsoluteActivityBoundsAreHalfOpenAndDeterministic() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let bounds = try ScreenlogCLIMain.activityBounds(
            ["--since", "2d", "--before", "1d"],
            now: now
        )

        XCTAssertEqual(bounds.sinceMs, 1_827_200_000)
        XCTAssertEqual(bounds.beforeMs, 1_913_600_000)
        XCTAssertThrowsError(
            try ScreenlogCLIMain.activityBounds(
                ["--since", "1d", "--before", "2d"],
                now: now
            )
        )
    }

    func testNonFiniteRelativeDateAndInvalidBatchIdentifiersAreRejected() throws {
        XCTAssertThrowsError(try ScreenlogCLIMain.parseActivityBound("1e309d"))
        XCTAssertNoThrow(try ScreenlogCLIMain.parseTimestampMs(String(Int64.min)))
        XCTAssertThrowsError(
            try ScreenlogCLIMain.commaSeparatedIDs("1,0,3")
        )
        XCTAssertEqual(
            try ScreenlogCLIMain.commaSeparatedIDs("3,1,3,2"),
            [3, 1, 2]
        )
    }

    func testActivityRangeCountsEveryCalendarDayTouchedByASession() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day: Int64 = 24 * 60 * 60 * 1_000
        let range = CLIActivityRangeDocument(
            bounds: .init(),
            stats: RecordingStats(
                totalFrames: 2,
                minTimestampMs: day - 1_000,
                maxTimestampMs: day + 1_000,
                unfinalizedFrames: 0,
                totalMoments: 2
            ),
            sessions: [
                SessionRow(
                    startMs: day - 1_000,
                    endMs: day + 1_000,
                    frameCount: 2
                )
            ],
            calendar: calendar
        )

        XCTAssertEqual(range.activeDays, 2)
        XCTAssertEqual(range.sessionBreakCount, 0)
    }

    func testHelpForReadAndMutationCommandsReturnsBeforeConnecting() async throws {
        try await ScreenlogCLIMain.run(args: ["stats", "--help"])
        try await ScreenlogCLIMain.run(args: ["compact", "--help"])
        try await ScreenlogCLIMain.run(args: ["retention", "--help"])
        try await ScreenlogCLIMain.run(args: ["recent", "--help"])
        try await ScreenlogCLIMain.run(args: ["usage", "sessions", "--help"])
        try await ScreenlogCLIMain.run(args: ["query", "sample", "--help"])
    }

    func testFrameDocumentBoundsOCRAndNeverSerializesMediaPaths() throws {
        let privatePath = "/Users/private/secret.heic"
        let document = CLIFrameDocument(
            frame: FrameRow(
                id: 7,
                timestampMs: 1_000,
                imagePath: privatePath,
                foreground: "abcdefghij",
                title: "Editor",
                bundleID: "dev.editor",
                displayName: "Editor",
                domain: "example.com"
            ),
            maximumOCRCharacters: 4
        )
        let json = try CLIOutputFormat.json(document)

        XCTAssertEqual(document.ocr, "abcd")
        XCTAssertTrue(document.ocrTruncated)
        XCTAssertEqual(document.bundleID, "dev.editor")
        XCTAssertEqual(document.displayName, "Editor")
        XCTAssertEqual(document.domain, "example.com")
        XCTAssertFalse(json.contains(privatePath))
    }

    func testSearchDocumentNeverSerializesMediaPathsOrCompactionDetails() throws {
        let privatePath = "/Users/private/secret.heic"
        let document = CLISearchResultDocument(
            FTSResult(
                frameID: 7,
                timestampMs: 1_000,
                title: "Editor",
                bundleID: "dev.editor",
                imagePath: privatePath,
                isCompacted: true
            )
        )
        let json = try CLIOutputFormat.json(document)

        XCTAssertFalse(json.contains(privatePath))
        XCTAssertFalse(json.contains("imagePath"))
        XCTAssertFalse(json.contains("isCompacted"))
    }
}
