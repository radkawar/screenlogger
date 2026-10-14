public enum StorageMaintenanceOperation: Equatable, Sendable {
    case compaction
    case retention
}

public enum StorageMaintenanceSuccess: Equatable, Sendable {
    case compacted(imageCount: Int)
    case nothingToCompact
    case retentionApplied(removedMediaCount: Int, freedBytes: Int64)
    case alreadyWithinLimits
}

public enum StorageMaintenanceFailure: Equatable, Sendable {
    case compactionFailed
    case retentionCouldNotRemoveFiles
    case retentionLimitNotSatisfied
    case retentionFailed

    public var userMessage: String {
        switch self {
        case .compactionFailed:
            return "Could not compress older images. Your saved captures remain available. Try again."
        case .retentionCouldNotRemoveFiles:
            return "Screenlogger kept capture images that it could not safely remove. Try again."
        case .retentionLimitNotSatisfied:
            return "Screenlogger removed all eligible images, but other managed data still exceeds the limit."
        case .retentionFailed:
            return "Could not apply storage limits. Screenlogger kept files that it could not safely remove. Try again."
        }
    }

    public var retryOperation: StorageMaintenanceOperation? {
        switch self {
        case .compactionFailed:
            return .compaction
        case .retentionCouldNotRemoveFiles, .retentionFailed:
            return .retention
        case .retentionLimitNotSatisfied:
            return nil
        }
    }
}

public enum StorageMaintenanceOperationState: Equatable, Sendable {
    case idle
    case running(StorageMaintenanceOperation)
    case success(StorageMaintenanceSuccess)
    case failure(StorageMaintenanceFailure)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var retryOperation: StorageMaintenanceOperation? {
        guard case .failure(let failure) = self else { return nil }
        return failure.retryOperation
    }
}
