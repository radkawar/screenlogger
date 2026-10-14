import XCTest

@testable import ScreenlogCore

final class StorageMaintenanceOperationStateTests: XCTestCase {
    func testOnlyRunningStateReportsInProgress() {
        XCTAssertFalse(StorageMaintenanceOperationState.idle.isRunning)
        XCTAssertTrue(StorageMaintenanceOperationState.running(.compaction).isRunning)
        XCTAssertFalse(
            StorageMaintenanceOperationState.success(.nothingToCompact).isRunning
        )
        XCTAssertFalse(
            StorageMaintenanceOperationState.failure(.retentionLimitNotSatisfied).isRunning
        )
    }

    func testRetryOperationIsOwnedByRetryableFailure() {
        XCTAssertEqual(
            StorageMaintenanceOperationState.failure(
                .compactionFailed
            ).retryOperation,
            .compaction
        )
        XCTAssertEqual(
            StorageMaintenanceOperationState.failure(
                .retentionCouldNotRemoveFiles
            ).retryOperation,
            .retention
        )
        XCTAssertEqual(
            StorageMaintenanceOperationState.failure(
                .retentionFailed
            ).retryOperation,
            .retention
        )
    }

    func testTerminalLimitFailureCannotOfferRetry() {
        let state = StorageMaintenanceOperationState.failure(.retentionLimitNotSatisfied)

        XCTAssertNil(state.retryOperation)
    }

    func testNonFailureStatesCannotOfferRetry() {
        XCTAssertNil(StorageMaintenanceOperationState.idle.retryOperation)
        XCTAssertNil(StorageMaintenanceOperationState.running(.retention).retryOperation)
        XCTAssertNil(
            StorageMaintenanceOperationState.success(
                .retentionApplied(removedMediaCount: 4, freedBytes: 1_024)
            ).retryOperation
        )
    }
}
