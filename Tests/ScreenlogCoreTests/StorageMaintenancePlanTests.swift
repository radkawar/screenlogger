import Foundation
import XCTest

@testable import ScreenlogCore

/// Honest tests for StorageManagementMode to auto-compact/retention gating
/// and CapturePreferenceStore UserDefaults round-trip (keys AppModel uses).
final class StorageMaintenancePlanTests: XCTestCase {
    func testCaptureQualityPresetsIncreaseFidelityAndUltraIsNative() {
        XCTAssertEqual(CaptureQualityPreset.standard.maxDimension, 1_920)
        XCTAssertEqual(CaptureQualityPreset.high.maxDimension, 2_880)
        XCTAssertEqual(CaptureQualityPreset.ultra.maxDimension, 0)
        XCTAssertLessThan(
            CaptureQualityPreset.standard.stillCompressionQuality,
            CaptureQualityPreset.high.stillCompressionQuality
        )
        XCTAssertLessThan(
            CaptureQualityPreset.high.stillCompressionQuality,
            CaptureQualityPreset.ultra.stillCompressionQuality
        )
    }

    func testPreReleaseCaptureQualityValuesMigrateWithoutKeepingLowResolutionCaps() {
        XCTAssertEqual(CaptureQualityPreset.migratedMaxDimension(720), 1_920)
        XCTAssertEqual(CaptureQualityPreset.migratedMaxDimension(1_080), 2_880)
        XCTAssertEqual(CaptureQualityPreset.migratedMaxDimension(1_440), 0)
        XCTAssertEqual(CaptureQualityPreset.migratedMaxDimension(3_840), 3_840)

        let suite = "screenlog.capture-quality-migration.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1_440, forKey: CapturePreferenceStore.maxDimension)
        XCTAssertEqual(CapturePreferenceStore.load(from: defaults).maxDimension, 0)
    }

    // MARK: - Off / Compress / Limit gating

    func testOffDisablesBothAutoCompactAndRetention() {
        let plan = StorageManagementMode.off.maintenancePlan(
            retentionDays: 30,
            storageCapMB: 10_000
        )
        XCTAssertFalse(plan.runCompact, "Off must not auto-compact")
        XCTAssertFalse(plan.runRetention, "Off must not auto-purge by age/size")
    }

    func testCompressRunsCompactOnlyNotRetention() {
        let plan = StorageManagementMode.compress.maintenancePlan(
            retentionDays: 14,
            storageCapMB: 5_000
        )
        XCTAssertTrue(plan.runCompact, "Compress must auto-compact stills")
        XCTAssertFalse(plan.runRetention, "Compress must not age/size purge")
        XCTAssertEqual(plan.storageCapMB, 0, "Compress plan zeros cap so retention is inert if mis-invoked")
    }

    func testLimitRunsBothWithConfiguredDaysAndCap() {
        let plan = StorageManagementMode.limit.maintenancePlan(
            retentionDays: 21,
            storageCapMB: 12_345
        )
        XCTAssertTrue(plan.runCompact)
        XCTAssertTrue(plan.runRetention)
        XCTAssertEqual(plan.retentionDays, 21)
        XCTAssertEqual(plan.storageCapMB, 12_345)
    }

    func testOffAndCompressAreNotEquivalentForAutoPath() {
        let off = StorageManagementMode.off.maintenancePlan(retentionDays: 30, storageCapMB: 1000)
        let compress = StorageManagementMode.compress.maintenancePlan(retentionDays: 30, storageCapMB: 1000)
        XCTAssertNotEqual(off, compress, "Off and Compress must produce different auto-maintenance plans")
        XCTAssertFalse(off.runCompact)
        XCTAssertTrue(compress.runCompact)
    }

    @MainActor
    func testEngineApplyStoragePlanSetsFlags() {
        let engine = RecordingEngine()
        // Start from Limit-like defaults, then apply Off.
        engine.applyStoragePlan(
            StorageManagementMode.off.maintenancePlan(retentionDays: 7, storageCapMB: 100)
        )
        XCTAssertFalse(engine.autoCompactEnabled)
        XCTAssertFalse(engine.autoRetentionEnabled)

        engine.applyStoragePlan(
            StorageManagementMode.compress.maintenancePlan(retentionDays: 7, storageCapMB: 100)
        )
        XCTAssertTrue(engine.autoCompactEnabled)
        XCTAssertFalse(engine.autoRetentionEnabled)

        engine.applyStoragePlan(
            StorageManagementMode.limit.maintenancePlan(retentionDays: 9, storageCapMB: 42)
        )
        XCTAssertTrue(engine.autoCompactEnabled)
        XCTAssertTrue(engine.autoRetentionEnabled)
        XCTAssertEqual(engine.retentionDays, 9)
        XCTAssertEqual(engine.storageCapMB, 42)
    }

    @MainActor
    func testEngineStartWithoutConfiguredStoreReportsFailureAndRemainsStopped() {
        let engine = RecordingEngine()

        XCTAssertFalse(engine.start())
        XCTAssertFalse(engine.isRecording)
        XCTAssertEqual(engine.lastError, "Store not configured")
    }

    @MainActor
    func testEngineStopIsIdempotentAndReportsAuthoritativeState() {
        let engine = RecordingEngine()

        XCTAssertTrue(engine.stop())
        XCTAssertFalse(engine.isRecording)
        XCTAssertFalse(engine.pausedForDisk)
        XCTAssertFalse(engine.pausedForInactivity)
    }

    func testCaptureFailureBackoffIsExponentialAndCapped() {
        let backoff = RecordingCaptureBackoff(baseDelay: 2, maximumDelay: 60)

        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 0), 0)
        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 1), 2)
        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 2), 4)
        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 5), 32)
        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 6), 60)
        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 20), 60)
    }

    func testCaptureFailureBackoffNormalizesUnsafeBounds() {
        let backoff = RecordingCaptureBackoff(baseDelay: 0, maximumDelay: 0)

        XCTAssertEqual(backoff.baseDelay, 0.5)
        XCTAssertEqual(backoff.maximumDelay, 0.5)
        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 1), 0.5)
    }

    // MARK: - CapturePreferenceStore round-trip

    func testCaptureIntentIsUnsetUntilUserExplicitlyChooses() {
        let suite = "screenlog.capture-intent.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(CaptureIntentPreference.value(from: defaults))
        CaptureIntentPreference.save(true, to: defaults)
        XCTAssertEqual(CaptureIntentPreference.value(from: defaults), true)
        CaptureIntentPreference.save(false, to: defaults)
        XCTAssertEqual(CaptureIntentPreference.value(from: defaults), false)
    }

    func testCapturePreferenceStoreRoundTripIntervalRetentionMode() {
        let suite = "screenlog.prefs.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var snap = CapturePreferenceStore.Snapshot(
            intervalSeconds: 3.5,
            maxDimension: 2_880,
            retentionDays: 45,
            storageCapMB: 8_000,
            storageMode: .compress,
            stillEncoding: .jpeg,
            ocrLanguagesCSV: "en-US,fr-FR",
            differentialOCR: false,
            displayMode: .all
        )
        CapturePreferenceStore.save(snap, to: defaults)

        let loaded = CapturePreferenceStore.load(from: defaults)
        XCTAssertEqual(loaded.intervalSeconds, 3.5, accuracy: 0.001)
        XCTAssertEqual(loaded.maxDimension, 2_880)
        XCTAssertEqual(loaded.retentionDays, 45)
        XCTAssertEqual(loaded.storageCapMB, 8_000)
        XCTAssertEqual(loaded.storageMode, .compress)
        XCTAssertEqual(loaded.stillEncoding, .jpeg)
        XCTAssertEqual(loaded.ocrLanguagesCSV, "en-US,fr-FR")
        XCTAssertEqual(loaded.ocrLanguages, ["en-US", "fr-FR"])
        XCTAssertFalse(loaded.differentialOCR)
        XCTAssertEqual(loaded.displayMode, .all)

        // Keys match the product constants AppModel uses.
        XCTAssertEqual(defaults.double(forKey: CapturePreferenceStore.intervalSeconds), 3.5, accuracy: 0.001)
        XCTAssertEqual(defaults.integer(forKey: CapturePreferenceStore.retentionDays), 45)
        XCTAssertEqual(defaults.string(forKey: ProductPreferenceKey.storageMode), "compress")
        XCTAssertEqual(defaults.string(forKey: CapturePreferenceStore.displayMode), "all")

        // Round-trip storage mode to maintenance plan from loaded snapshot.
        let plan = loaded.maintenancePlan
        XCTAssertTrue(plan.runCompact)
        XCTAssertFalse(plan.runRetention)

        // Flip to Off via store and prove plan would skip compact.
        snap.storageMode = .off
        CapturePreferenceStore.save(snap, to: defaults)
        let offLoaded = CapturePreferenceStore.load(from: defaults)
        XCTAssertFalse(offLoaded.maintenancePlan.runCompact)
        XCTAssertFalse(offLoaded.maintenancePlan.runRetention)
    }

    func testLimitClampDaysAndCapInPlan() {
        let plan = StorageManagementMode.limit.maintenancePlan(
            retentionDays: 0,  // clamp to 1
            storageCapMB: -5  // clamp to 0
        )
        XCTAssertEqual(plan.retentionDays, 1)
        XCTAssertEqual(plan.storageCapMB, 0)
        XCTAssertTrue(plan.runRetention)
    }

    func testStoreSerializesFilesystemMaintenance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-maintenance-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        let probe = MaintenanceConcurrencyProbe()

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            store.withExclusiveMaintenance {
                probe.enter()
                Thread.sleep(forTimeInterval: 0.01)
                probe.leave()
            }
        }

        XCTAssertEqual(probe.maximumConcurrentOperations, 1)
    }

    func testLiveCaptureMutationWaitsForMaintenanceExecutor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-capture-maintenance-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        let maintenanceEntered = DispatchSemaphore(value: 0)
        let releaseMaintenance = DispatchSemaphore(value: 0)
        let captureStarted = DispatchSemaphore(value: 0)
        let captureFinished = DispatchSemaphore(value: 0)
        let captureResult = ConcurrentMutationResult()

        DispatchQueue.global(qos: .userInitiated).async {
            store.withExclusiveMaintenance {
                maintenanceEntered.signal()
                _ = releaseMaintenance.wait(timeout: .now() + 2)
            }
        }
        XCTAssertEqual(maintenanceEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            captureStarted.signal()
            captureResult.run {
                _ = try store.insertSeedFrame(
                    timestampMs: 1_700_000_000_000,
                    foreground: "serialized capture"
                )
            }
            captureFinished.signal()
        }
        XCTAssertEqual(captureStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            captureFinished.wait(timeout: .now() + 0.05),
            .timedOut,
            "Capture must not mutate SQLite or managed files during maintenance"
        )

        releaseMaintenance.signal()
        XCTAssertEqual(captureFinished.wait(timeout: .now() + 2), .success)
        XCTAssertNil(captureResult.error)
        XCTAssertEqual(try store.stats().totalFrames, 1)
    }

    func testThrownMutationRollsBackAndReleasesExecutor() throws {
        enum SimulatedInterruption: Error { case stop }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-mutation-interruption-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)

        XCTAssertThrowsError(
            try store.withSerializedMutation {
                try store.db.transaction {
                    try store.setMeta(key: "interrupted", value: "must roll back")
                    throw SimulatedInterruption.stop
                }
            }
        )
        XCTAssertNil(try store.getMeta(key: "interrupted"))

        // A failed operation must not strand the recursive executor or connection
        // in a transaction; the next independent mutation must complete normally.
        try store.setMeta(key: "next", value: "committed")
        XCTAssertEqual(try store.getMeta(key: "next"), "committed")
    }

    func testCaptureRollbackRemovesImageWrittenBeforeDatabaseFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-capture-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        try store.db.exec(
            """
            CREATE TRIGGER reject_capture_ocr
            BEFORE INSERT ON ocr
            BEGIN
                SELECT RAISE(ABORT, 'simulated capture interruption');
            END;
            """
        )

        XCTAssertThrowsError(
            try store.insertSeedFrame(
                timestampMs: 1_700_000_000_000,
                foreground: "must roll back"
            )
        )
        XCTAssertEqual(try store.stats().totalFrames, 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: store.framesDirectory,
                includingPropertiesForKeys: nil
            ),
            [],
            "A rolled-back capture must not leave an orphaned still"
        )
    }
}

private final class MaintenanceConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    var maximumConcurrentOperations: Int {
        lock.withLock { maximum }
    }

    func enter() {
        lock.withLock {
            active += 1
            maximum = max(maximum, active)
        }
    }

    func leave() {
        lock.withLock { active -= 1 }
    }
}

private final class ConcurrentMutationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.withLock { storedError }
    }

    func run(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            lock.withLock { storedError = error }
        }
    }
}
