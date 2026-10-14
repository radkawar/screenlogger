import Foundation
import ScreenlogCore
import XCTest

@MainActor
final class SemanticSearchControllerTests: XCTestCase {
    private func fixture(
        enabled: Bool = false,
        offline: @escaping @MainActor () -> Bool = { true }
    ) throws -> (SemanticSearchController, Store, UserDefaults, URL, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store(root: root.appendingPathComponent("Library"))
        let suite = "dev.screenlog.semantic-tests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        SemanticPreferenceStore.save(.init(enabled: enabled, mode: .images), to: preferences)
        let controller = SemanticSearchController(
            store: store, preferences: preferences,
            modelDirectory: root.appendingPathComponent("models"), airgap: offline
        )
        return (controller, store, preferences, root, suite)
    }

    func testSavedConsentWithMissingModelsNeverDownloadsAtStartupOrResume() async throws {
        let (controller, store, preferences, root, suite) = try fixture(enabled: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        await controller.start()
        XCTAssertFalse(controller.featureStatus.modelInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("models").path))
        XCTAssertTrue(try store.semanticWork(mode: .images).isEmpty)
        await controller.suspendAndDrain()
        await controller.resume()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("models").path))
        do {
            _ = try await controller.search(.init(query: "blue diagram"))
            XCTFail("Missing model files must not produce fallback results.")
        } catch {}
        await controller.suspendAndDrain()
    }

    func testSuspensionClosesAdmissionAndInvalidateDoesNotReopenIt() async throws {
        let (controller, _, preferences, root, suite) = try fixture()
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        await controller.start()
        await controller.suspendAndDrain()
        await controller.invalidate()
        await controller.start()
        do {
            _ = try await controller.control(.init(action: .removeIndex))
            XCTFail("A suspended controller must reject store mutations.")
        } catch {}
        do {
            _ = try await controller.search(.init(query: "blue diagram"))
            XCTFail("A suspended controller must reject queries.")
        } catch {}
        _ = try await controller.control(.init(action: .disable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("models").path))
        await controller.suspendAndDrain()
    }

    func testOfflineDownloadRequestDoesNotCreateFilesOrSaveEnableConsent() async throws {
        let (controller, _, preferences, root, suite) = try fixture()
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        await controller.start()
        do {
            _ = try await controller.control(.init(action: .downloadModels, mode: .both, enableWhenReady: true))
            XCTFail("Offline mode must reject an explicit model download.")
        } catch {}
        XCTAssertFalse(SemanticPreferenceStore.load(from: preferences).enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("models").path))
        await controller.suspendAndDrain()
    }

    func testIndexNowNeverEnablesOrDownloadsModels() async throws {
        for enabled in [false, true] {
            let (controller, _, preferences, root, suite) = try fixture(enabled: enabled)
            defer {
                preferences.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            await controller.start()
            do {
                _ = try await controller.control(.init(action: .indexNow))
                XCTFail("Index Now requires existing consent and installed models.")
            } catch {
                #if arch(arm64)
                    guard let semantic = error as? SemanticSearchError else {
                        return XCTFail("Expected a semantic setup error, got \(error)")
                    }
                    switch semantic {
                    case .disabled: XCTAssertFalse(enabled)
                    case .modelMissing: XCTAssertTrue(enabled)
                    default: XCTFail("Unexpected setup error: \(error)")
                    }
                #endif
            }
            XCTAssertEqual(SemanticPreferenceStore.load(from: preferences), .init(enabled: enabled, mode: .images))
            XCTAssertEqual(controller.featureStatus.indexingPolicy, .automatic)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("models").path))
            await controller.suspendAndDrain()
        }
    }

    func testManualIndexingOnlyBypassesIdleAndExternalPower() {
        for powerSource in [SystemPowerSourceState.externalPower, .battery, .unknown] {
            for idleSeconds in [TimeInterval(0), 59, 60, 120] {
                let conditions = SemanticIndexingConditions(
                    power: .init(powerSource: powerSource), idleSeconds: idleSeconds)
                XCTAssertNil(conditions.deferral(for: .manual))
                XCTAssertEqual(
                    conditions.deferral(for: .automatic) == nil,
                    powerSource == .externalPower && idleSeconds >= 60)
            }
        }
        for policy in [SemanticIndexingPolicy.automatic, .manual] {
            for thermalState in [ProcessInfo.ThermalState.serious, .critical] {
                XCTAssertNotNil(
                    SemanticIndexingConditions(
                        power: .init(powerSource: .externalPower, thermalState: thermalState), idleSeconds: 120
                    ).deferral(for: policy))
            }
            XCTAssertNotNil(
                SemanticIndexingConditions(
                    power: .init(powerSource: .externalPower, lowPowerModeEnabled: true), idleSeconds: 120
                ).deferral(for: policy))
            XCTAssertNotNil(
                SemanticIndexingConditions(
                    power: .init(powerSource: .externalPower), idleSeconds: 120, memoryPressure: true
                ).deferral(for: policy))
            XCTAssertNil(
                SemanticIndexingConditions(
                    power: .init(powerSource: .externalPower, thermalState: .fair), idleSeconds: 60
                ).deferral(for: policy))
        }
    }

    func testInstalledEmptyLibraryCompletesManualIndexingWithoutWaitingForPower() async throws {
        #if !arch(arm64)
            throw XCTSkip("Semantic indexing requires Apple silicon.")
        #else
            let modelDirectory = SemanticModelManager.defaultDirectory()
            guard try await SemanticModelManager(directory: modelDirectory).isInstalled(for: .text) else {
                throw XCTSkip("Requires the pinned text models; never downloads test models.")
            }
            let (_, store, preferences, root, suite) = try fixture()
            defer {
                preferences.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            SemanticPreferenceStore.save(.init(enabled: true, mode: .text), to: preferences)
            let controller = SemanticSearchController(
                store: store, preferences: preferences, modelDirectory: modelDirectory, airgap: { true },
                indexingConditions: {
                    .init(power: .init(powerSource: .battery, lowPowerModeEnabled: true), idleSeconds: 0, memoryPressure: true)
                })
            await controller.start()
            let accepted = try await controller.control(.init(action: .indexNow))
            XCTAssertEqual(accepted.indexingPolicy, .manual)
            for _ in 0..<100 {
                if controller.featureStatus.phase == .ready && controller.featureStatus.indexingPolicy == .automatic { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(controller.featureStatus.phase, .ready, "An empty Library must not wait for idle time or resources.")
            XCTAssertEqual(controller.featureStatus.indexingPolicy, .automatic)
            XCTAssertEqual(controller.featureStatus.index.pendingSources, 0)
            _ = try await controller.control(.init(action: .indexNow))
            _ = try await controller.control(.init(action: .pause))
            XCTAssertTrue(controller.indexingIsPaused)
            XCTAssertEqual(controller.featureStatus.indexingPolicy, .automatic)
            _ = try await controller.control(.init(action: .indexNow))
            XCTAssertFalse(controller.indexingIsPaused)
            await controller.suspendAndDrain()
            XCTAssertEqual(controller.featureStatus.indexingPolicy, .automatic)
            do {
                _ = try await controller.control(.init(action: .indexNow))
                XCTFail("Drain must close Index Now admission.")
            } catch {}
            await controller.resume()
            _ = try await controller.control(.init(action: .indexNow))
            _ = try await controller.control(.init(action: .disable))
            XCTAssertFalse(controller.featureStatus.enabled)
            XCTAssertEqual(controller.featureStatus.indexingPolicy, .automatic)
            await controller.suspendAndDrain()
        #endif
    }
}
