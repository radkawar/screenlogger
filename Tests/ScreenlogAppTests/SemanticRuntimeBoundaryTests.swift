import Foundation
import ScreenlogCore
import XCTest

final class SemanticRuntimeBoundaryTests: XCTestCase {
    func testPinnedProfileDownloadSizes() {
        XCTAssertEqual(SemanticModelManager.downloadBytes(for: .text), 320_311_585)
        XCTAssertEqual(SemanticModelManager.downloadBytes(for: .images), 513_421_847)
        XCTAssertEqual(SemanticModelManager.downloadBytes(for: .both), 513_421_847)
    }

    func testMissingModelReadinessDoesNotCreateDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("semantic-model-test-" + UUID().uuidString)
        let manager = SemanticModelManager(directory: root)
        let installed = try await manager.isInstalled(for: .both)
        XCTAssertFalse(installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testProfileDirectoryAndUnverifiedMarkerAreNotReadiness() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("semantic-model-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("text-q8"), withIntermediateDirectories: true)
        try Data("ready".utf8).write(to: root.appendingPathComponent("text-q8/manifest.json"))
        let manager = SemanticModelManager(directory: root)
        let installed = try await manager.isInstalled(for: .text)
        XCTAssertFalse(installed)
    }

    func testOversizeRequestFailsWithoutLaunchingWorker() async {
        let worker = SemanticWorkerClient(
            modelDirectory: URL(fileURLWithPath: "/unavailable-model-directory"),
            executableURL: URL(fileURLWithPath: "/unavailable-semantic-worker"))
        do {
            _ = try await worker.queryVector(String(repeating: "a", count: SemanticWorkerLimits.maximumTextBytes + 1))
            XCTFail("Oversized semantic requests must fail.")
        } catch let error as SemanticSearchError {
            #if arch(arm64)
                guard case .invalidRequest = error else { return XCTFail("Expected a bounded-input error, got \(error)") }
            #else
                guard case .unavailable = error else { return XCTFail("Expected unsupported architecture.") }
            #endif
        } catch { XCTFail("Unexpected error: \(error)") }
        await worker.stop()
    }

    func testExitedNativeProcessFailsAndDrains() async {
        #if arch(arm64)
            let worker = SemanticWorkerClient(
                modelDirectory: URL(fileURLWithPath: "/unavailable-model-directory"),
                executableURL: URL(fileURLWithPath: "/usr/bin/false"))
            do {
                _ = try await worker.queryVector("A blue window")
                XCTFail("An exited helper must not return a vector.")
            } catch {}
            await worker.stop()
        #endif
    }
}
