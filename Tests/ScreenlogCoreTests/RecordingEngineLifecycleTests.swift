import Foundation
import XCTest

@testable import ScreenlogCore

final class RecordingEngineLifecycleTests: XCTestCase {
    @MainActor
    func testStopThenReplacementWaitsForCaptureAndMaintenance() async throws {
        let (engine, root) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: root) }
        let captureEntered = Signal()
        let releaseCapture = Signal()
        let captureExited = Signal()
        let maintenanceEntered = Signal()
        let releaseMaintenance = Signal()
        var maintenanceFinished = false
        engine.start(
            captureLoop: {
                captureEntered.signal()
                await releaseCapture.wait()
                captureExited.signal()
            },
            maintenanceLoop: {
                maintenanceEntered.signal()
                await releaseMaintenance.wait()
                maintenanceFinished = true
            }
        )
        await captureEntered.wait()
        await maintenanceEntered.wait()
        XCTAssertTrue(engine.stop())
        XCTAssertTrue(engine.stop())

        let drainEntered = Signal()
        var drainFinished = false
        let drain = Task { @MainActor in
            drainEntered.signal()
            await engine.quiesceForLibraryReplacement()
            XCTAssertTrue(maintenanceFinished)
            drainFinished = true
        }
        await drainEntered.wait()
        XCTAssertFalse(drainFinished)
        XCTAssertFalse(engine.start(), "Replacement must close admission before awaiting old work")
        do {
            _ = try await engine.captureOneNow(operation: { 99 })
            XCTFail("Capture Now must not obtain the Store during replacement")
        } catch CaptureError.notAuthorized {
            // Expected: replacement has detached the old Store.
        }
        releaseCapture.signal()
        await captureExited.wait()
        XCTAssertFalse(drainFinished, "A canceled queue pass still owns the Store")
        releaseMaintenance.signal()
        await drain.value
        XCTAssertTrue(drainFinished)
    }

    @MainActor
    func testRestartCannotHideAnOlderCanceledLoopFromReplacement() async throws {
        let (engine, root) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldEntered = Signal()
        let releaseOld = Signal()
        var oldFinished = false
        var replacementLoopStarted = false
        engine.start(
            captureLoop: {
                oldEntered.signal()
                await releaseOld.wait()
                oldFinished = true
            },
            maintenanceLoop: {}
        )
        await oldEntered.wait()
        engine.stop()
        engine.start(
            captureLoop: { replacementLoopStarted = true },
            maintenanceLoop: {}
        )

        let drainEntered = Signal()
        var drainFinished = false
        let drain = Task { @MainActor in
            drainEntered.signal()
            await engine.quiesceForLibraryReplacement()
            XCTAssertTrue(oldFinished)
            drainFinished = true
        }
        await drainEntered.wait()
        XCTAssertFalse(drainFinished)
        XCTAssertFalse(replacementLoopStarted)
        releaseOld.signal()
        await drain.value
        XCTAssertTrue(drainFinished)
        XCTAssertFalse(replacementLoopStarted, "Canceled successor must not begin capture")
    }

    @MainActor
    func testRestartBeginsOnlyAfterPreviousLoopFinishes() async throws {
        let (engine, root) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldEntered = Signal()
        let releaseOld = Signal()
        let newEntered = Signal()
        var oldFinished = false
        engine.start(
            captureLoop: {
                oldEntered.signal()
                await releaseOld.wait()
                oldFinished = true
            },
            maintenanceLoop: {}
        )
        await oldEntered.wait()
        engine.stop()
        engine.start(
            captureLoop: {
                XCTAssertTrue(oldFinished)
                newEntered.signal()
            },
            maintenanceLoop: {}
        )
        releaseOld.signal()
        await newEntered.wait()
        engine.stop()
        await engine.quiesceForLibraryReplacement()
    }

    @MainActor
    func testStopThenReplacementDrainsManualCaptureWhileRecordingIsOff() async throws {
        let (engine, root) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = Signal()
        let release = Signal()
        var operationFinished = false
        let manual = Task { @MainActor in
            try await engine.captureOneNow {
                entered.signal()
                await release.wait()
                operationFinished = true
                return 42
            }
        }
        await entered.wait()
        XCTAssertFalse(engine.isRecording)
        XCTAssertTrue(engine.stop())
        let drainEntered = Signal()
        var drainFinished = false
        let drain = Task { @MainActor in
            drainEntered.signal()
            await engine.quiesceForLibraryReplacement()
            XCTAssertTrue(operationFinished)
            drainFinished = true
        }
        await drainEntered.wait()
        XCTAssertFalse(drainFinished)
        release.signal()
        await drain.value
        do {
            _ = try await manual.value
            XCTFail("Replacement must cancel the owned manual capture")
        } catch is CancellationError {
            // Cancellation is a lifecycle result, not a late successful capture.
        }
        XCTAssertTrue(drainFinished)
    }

    @MainActor
    func testManualCallerCancellationPropagatesToOwnedOperation() async throws {
        let (engine, root) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = Signal()
        let release = Signal()
        var operationWasCanceled = false
        let manual = Task { @MainActor in
            try await engine.captureOneNow {
                entered.signal()
                await release.wait()
                operationWasCanceled = Task.isCancelled
                return 42
            }
        }
        await entered.wait()
        manual.cancel()
        release.signal()
        do {
            _ = try await manual.value
            XCTFail("Caller cancellation must propagate through the owned task")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(operationWasCanceled)
        await engine.quiesceForLibraryReplacement()
    }

    @MainActor
    func testAudioStopWaitsForAlreadyDetachedTranscriptFinalizers() async {
        let coordinator = AudioTranscriptionCoordinator()
        let firstEntered = Signal()
        let releaseFirst = Signal()
        let secondQueued = Signal()
        let secondEntered = Signal()
        let releaseSecond = Signal()
        var firstFinished = false
        var secondFinished = false
        let first = Task { @MainActor in
            await coordinator.finishResources {
                firstEntered.signal()
                await releaseFirst.wait()
                firstFinished = true
            }
        }
        await firstEntered.wait()
        let second = Task { @MainActor in
            secondQueued.signal()
            await coordinator.finishResources {
                XCTAssertTrue(firstFinished)
                secondEntered.signal()
                await releaseSecond.wait()
                secondFinished = true
            }
        }
        await secondQueued.wait()
        let stopEntered = Signal()
        var stopFinished = false
        let stop = Task { @MainActor in
            stopEntered.signal()
            await coordinator.stop()
            XCTAssertTrue(firstFinished)
            XCTAssertTrue(secondFinished)
            stopFinished = true
        }
        await stopEntered.wait()
        XCTAssertFalse(stopFinished)
        releaseFirst.signal()
        await secondEntered.wait()
        XCTAssertFalse(stopFinished)
        releaseSecond.signal()
        await first.value
        await second.value
        await stop.value
        XCTAssertTrue(stopFinished)
    }

    @MainActor
    private func makeEngine() throws -> (RecordingEngine, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-recording-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let store = try Store(root: root)
        let engine = RecordingEngine()
        engine.configure(store: store)
        return (engine, root)
    }

    /// The signal's sender stays on MainActor until its next suspension. A
    /// waiter therefore observes the exact pending-work boundary without sleeps.
    @MainActor
    private final class Signal {
        private var signaled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            signaled = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }

        func wait() async {
            guard !signaled else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
