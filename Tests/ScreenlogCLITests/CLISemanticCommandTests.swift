import Foundation
@testable import ScreenlogCLI
import ScreenlogCore
import XCTest

final class CLISemanticCommandTests: XCTestCase {
    func testReadOnlyQueryPreservesOperatorsAndNarrowsMode() throws {
        let query = "a blue chart app:Safari site:example.com since:2026-10-01 before:2026-10-14"
        let parsed = try CLISemanticQuery.parse([query, "--mode", "images", "--limit", "500", "--json"])
        XCTAssertEqual(parsed.request.query, query)
        XCTAssertEqual(parsed.request.mode, .images)
        XCTAssertEqual(parsed.request.limit, 500)
        XCTAssertTrue(parsed.json)
    }

    func testControlsRequireExactApprovalAndModes() throws {
        for (command, action) in [("download", SemanticControlAction.downloadModels), ("enable", .enable)] {
            for mode in SemanticSearchMode.allCases {
                guard case .control(let request) = try CLISemanticOperation.parse([command, "--mode", mode.rawValue, "--yes"]) else {
                    return XCTFail("Expected explicit control")
                }
                XCTAssertEqual(request.action, action)
                XCTAssertEqual(request.mode, mode)
                XCTAssertFalse(request.enableWhenReady)
            }
            XCTAssertThrowsError(try CLISemanticOperation.parse([command, "--mode", "images"]))
            XCTAssertThrowsError(try CLISemanticOperation.parse([command, "--yes"]))
        }
        for command in ["disable", "pause", "resume", "index-now", "remove-index", "remove-models"] {
            XCTAssertNoThrow(try CLISemanticOperation.parse([command, "--yes"]))
            XCTAssertThrowsError(try CLISemanticOperation.parse([command]))
            XCTAssertThrowsError(try CLISemanticOperation.parse([command, "--yes", "--mode", "both"]))
            XCTAssertThrowsError(try CLISemanticOperation.parse([command, "--yes", "--yes"]))
            XCTAssertThrowsError(try CLISemanticOperation.parse([command, "--yes", "--dry-run"]))
            XCTAssertThrowsError(try CLISemanticOperation.parse([command, "--yes", "unexpected"]))
        }
        guard case .status(let json) = try CLISemanticOperation.parse(["status", "--json"]) else {
            return XCTFail("Expected read-only status")
        }
        XCTAssertTrue(json)
        XCTAssertThrowsError(try CLISemanticOperation.parse(["status", "--yes"]))
        XCTAssertThrowsError(try CLISemanticOperation.parse(["status", "--json", "--json"]))
    }

    func testIndexNowDoesNotChangeSourcesOrGrantSetupConsent() throws {
        guard case .control(let request) = try CLISemanticOperation.parse(["index-now", "--yes"]) else {
            return XCTFail("Expected explicit Index Now control")
        }
        XCTAssertEqual(request.action, .indexNow)
        XCTAssertNil(request.mode)
        XCTAssertFalse(request.enableWhenReady)
    }

    func testQueryRejectsAmbiguousUnknownDuplicateAndOutOfBoundsArguments() {
        let invalid = [
            [], [""], ["app:Safari"], ["one", "two"], ["chart", "--query", "graph"],
            ["--query", "chart", "--query", "graph"], ["chart", "--mode", "image"],
            ["chart", "--mode", "images", "--mode", "text"], ["chart", "--mode"],
            ["chart", "--limit", "0"], ["chart", "--limit", "501"], ["chart", "--limit", "1.5"],
            ["chart", "--limit", "1", "--limit", "2"], ["chart", "--json", "--json"],
            ["chart", "--yes"], ["chart", "--download"], ["chart", "--content", "all"],
            [String(repeating: "x", count: 4097)], ["chart\u{0}"],
            ["chart date:2026-02-30"], ["chart since:2026-10-20 before:2026-10-10"],
            ["chart app:Safari app:Mail"], ["chart site:"],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try CLISemanticQuery.parse(arguments), "Accepted invalid arguments: \(arguments)")
        }
        XCTAssertNoThrow(try CLISemanticQuery.parse(["chart", "--limit", "1"]))
        XCTAssertNoThrow(try CLISemanticQuery.parse([String(repeating: "x", count: 4096)]))
    }

    func testInvalidControlFailsBeforeAttemptingConnection() async {
        do {
            try await ScreenlogCLIMain.run(args: [
                "--data-dir", "/tmp/screenlog-no-semantic-app-\(UUID().uuidString)", "semantic", "remove-models",
            ])
            XCTFail("Missing approval must fail")
        } catch is CLIError {
            // An IPC attempt would throw XPCClientError.appNotRunning instead.
        } catch { XCTFail("Unexpected connection attempt: \(error)") }
    }

    func testSemanticHelpDoesNotRequireAppOrMutateState() async throws {
        let root = "/tmp/screenlog-no-semantic-app-\(UUID().uuidString)"
        try await ScreenlogCLIMain.run(args: ["--data-dir", root, "semantic", "remove-models", "--help"])
        try await ScreenlogCLIMain.run(args: ["--data-dir", root, "query", "semantic", "--help"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root))
    }

    func testSemanticJSONWhitelistsEvidenceAndCoverageWithoutPrivatePaths() throws {
        let privatePath = "/Users/private/secret.heic"
        let status = SemanticFeatureStatus(
            enabled: true, mode: .both, phase: .indexing, indexingPolicy: .manual, modelInstalled: true,
            index: SemanticIndexStatistics(pendingSources: 3, indexedSources: 2, failedSources: 1), message: privatePath)
        let response = SemanticSearchResponse(
            hits: [
                SemanticSearchHit(
                    result: FTSResult(
                        frameID: 7, timestampMs: 1000, title: "Editor", bundleID: "dev.editor", imagePath: privatePath, isCompacted: true),
                    kind: .image, score: 0.4, occurrenceCount: 3)
            ], status: status)
        let document = CLISemanticSearchDocument(response)
        let json = try CLIOutputFormat.json(document)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hits = try XCTUnwrap(object["hits"] as? [[String: Any]])
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit["score"] as? Double, 0.4)
        XCTAssertEqual(hit["occurrenceCount"] as? Int, 3)
        XCTAssertEqual(hit["kind"] as? String, "image")
        XCTAssertEqual(object["scoreType"] as? String, "cosine_similarity")
        let result = try XCTUnwrap(hit["result"] as? [String: Any])
        XCTAssertEqual(result["frameID"] as? Int, 7)
        let exportedStatus = try XCTUnwrap(object["status"] as? [String: Any])
        XCTAssertEqual(exportedStatus["indexingPolicy"] as? String, "manual")
        let index = try XCTUnwrap(exportedStatus["index"] as? [String: Any])
        XCTAssertEqual(index["pendingSources"] as? Int, 3)
        XCTAssertEqual(index["failedSources"] as? Int, 1)
        for forbidden in [privatePath, "imagePath", "isCompacted", "confidence"] { XCTAssertFalse(json.contains(forbidden)) }
        let errorJSON = try CLIOutputFormat.json(
            CLISemanticErrorDocument(error: SemanticSearchError.unavailable(privatePath), status: status))
        XCTAssertFalse(errorJSON.contains(privatePath))
        XCTAssertTrue(errorJSON.contains("semantic_unavailable"))
    }
}
