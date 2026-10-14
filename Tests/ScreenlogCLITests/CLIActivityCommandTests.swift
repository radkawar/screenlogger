import Foundation
@testable import ScreenlogCLI
import ScreenlogCore
import XCTest

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
        XCTAssertThrowsError(
            try ScreenlogCLIMain.parseActivityBound(
                "now",
                now: Date(timeIntervalSince1970: .infinity)
            )
        )
        XCTAssertNoThrow(try ScreenlogCLIMain.parseTimestampMs(String(Int64.min)))
        XCTAssertThrowsError(
            try ScreenlogCLIMain.commaSeparatedIDs("1,0,3")
        )
        XCTAssertEqual(
            try ScreenlogCLIMain.commaSeparatedIDs("3,1,3,2"),
            [3, 1, 2]
        )
    }

    func testSampleCursorIsOverflowSafeAndRespectsRequestedBounds() throws {
        XCTAssertThrowsError(
            try ScreenlogCLIMain.sampleActivityBounds(
                ["--cursor", String(Int64.max)],
                order: .oldest
            )
        )

        let oldest = try ScreenlogCLIMain.sampleActivityBounds(
            ["--since", "1000", "--before", "2000", "--cursor", "1500"],
            order: .oldest
        )
        XCTAssertEqual(oldest.sinceMs, 1_500_001)
        XCTAssertEqual(oldest.beforeMs, 2_000_000)

        XCTAssertThrowsError(
            try ScreenlogCLIMain.sampleActivityBounds(
                ["--since", "1000", "--before", "2000", "--cursor", "2000"],
                order: .oldest
            )
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
        try await ScreenlogCLIMain.run(args: ["skill", "remove", "--help"])
    }

    func testMutationCommandsRejectExtraArgumentsBeforeConnecting() async throws {
        let root = "/tmp/screenlog-cli-invalid-\(UUID().uuidString)"
        for arguments in [
            ["compact", "--dry-run"],
            ["retention", "--dry-run"],
            ["compact", "unexpected"],
            ["retention", "unexpected"],
            ["record", "start", "--dry-run"],
            ["record", "stop", "--dry-run"],
            ["record", "once", "unexpected"],
        ] {
            do {
                try await ScreenlogCLIMain.run(args: ["--data-dir", root] + arguments)
                XCTFail("Expected usage error for \(arguments)")
            } catch let error as CLIError {
                guard case .usage = error else {
                    return XCTFail("Expected usage error, got \(error)")
                }
                XCTAssertEqual(error.exitCode, 2)
            } catch {
                XCTFail("Malformed mutation reached the bridge: \(error)")
            }
        }
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

    func testHumanReadableSampleOutputIncludesBoundedOCRWhenRequested() {
        let frame = FrameRow(
            id: 7,
            timestampMs: 1_000,
            foreground: "abcdefghij",
            title: "Editor",
            segmentID: 3
        )

        XCTAssertEqual(
            ScreenlogCLIMain.humanReadableSampleLines(
                frame: frame,
                maximumOCRCharacters: 4
            ).last,
            "  OCR (truncated): abcd"
        )
        XCTAssertEqual(
            ScreenlogCLIMain.humanReadableSampleLines(
                frame: frame,
                maximumOCRCharacters: 0
            ).count,
            1
        )
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
