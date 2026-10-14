import Foundation
import XCTest

@testable import ScreenlogCore

final class DiagnosticsBundleServiceTests: XCTestCase {
    private var temporaryRoot: URL!
    private var dataRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlogger-diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
        dataRoot = temporaryRoot.appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
    }

    func testExportContainsOnlySanitizedTypedDiagnostics() throws {
        let secret = "quarterly OCR https://secret.example user@example.com"
        let snapshot = makeSnapshot(version: secret)
        let destination = temporaryRoot.appendingPathComponent("Support.screenloggerdiagnostics")
        let result = try DiagnosticsBundleService(
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        ).export(
            snapshot: snapshot,
            events: [.init(timestamp: Date(timeIntervalSince1970: 1), event: .capture, outcome: .failed)],
            dataRoot: dataRoot,
            to: destination
        )

        XCTAssertEqual(result.manifest.app.version, "unknown")
        let exportedText = try ["manifest.json", "events.jsonl", "README.txt"]
            .map { try String(contentsOf: destination.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(exportedText.contains(secret))
        XCTAssertFalse(exportedText.contains("secret.example"))
        XCTAssertFalse(exportedText.contains(dataRoot.path))
        XCTAssertFalse(exportedText.localizedCaseInsensitiveContains("screenshot data"))
    }

    func testExportRefusesDestinationInsideLiveDataRoot() throws {
        let destination = dataRoot.appendingPathComponent("Unsafe.screenloggerdiagnostics")
        XCTAssertThrowsError(
            try DiagnosticsBundleService().export(
                snapshot: makeSnapshot(), events: [], dataRoot: dataRoot, to: destination
            )
        ) { error in
            XCTAssertEqual(error as? DiagnosticsBundleError, .unsafeDestination)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExportRefusesOverwriteWithoutChangingExistingDestination() throws {
        let destination = temporaryRoot.appendingPathComponent("Existing.screenloggerdiagnostics")
        let sentinel = Data("do not replace".utf8)
        try sentinel.write(to: destination)

        XCTAssertThrowsError(
            try DiagnosticsBundleService().export(
                snapshot: makeSnapshot(), events: [], dataRoot: dataRoot, to: destination
            )
        ) { error in
            XCTAssertEqual(error as? DiagnosticsBundleError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
    }

    func testStructuredLogDropsMalformedFreeFormEntries() throws {
        let log = try StructuredDiagnosticsLog(root: dataRoot, maximumBytes: 1_024)
        log.record(.init(event: .bootstrap, outcome: .started))
        let current =
            dataRoot
            .appendingPathComponent(StructuredDiagnosticsLog.directoryName)
            .appendingPathComponent(StructuredDiagnosticsLog.currentName)
        let handle = try FileHandle(forWritingTo: current)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"secret\":\"recognized text\"}\n".utf8))
        try handle.close()

        XCTAssertEqual(log.entries().map(\.event), [.bootstrap])
    }

    private func makeSnapshot(version: String = "1.2.3") -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            app: .init(version: version, build: "42", coreVersion: "1.2.3"),
            system: .init(operatingSystemVersion: "14.6.1", architecture: "arm64"),
            library: .init(
                health: .healthy,
                frameCount: 24,
                unfinalizedFrameCount: 1,
                managedBytes: 4_096,
                newestCaptureAge: .withinHour
            ),
            capture: .init(
                state: .capturing,
                pauseReason: nil,
                screenRecordingPermission: true,
                accessibilityPermission: false
            )
        )
    }
}
