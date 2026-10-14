/// Main-actor ownership of Timeline reads. Explicit navigation supersedes older
/// loads; background refreshes may only publish into an unchanged, settled view.
struct TimelineLoadPublicationState {
    struct BackgroundSnapshot: Equatable {
        fileprivate let loadGeneration: UInt
        fileprivate let selectionRevision: UInt
    }

    private var loadGeneration: UInt = 0
    private var selectionRevision: UInt = 0
    private var isLoading = false

    mutating func beginLoad() -> UInt {
        loadGeneration &+= 1
        isLoading = true
        return loadGeneration
    }

    func allowsLoad(_ generation: UInt) -> Bool {
        generation == loadGeneration
    }

    @discardableResult
    mutating func finishLoad(_ generation: UInt) -> Bool {
        guard allowsLoad(generation) else { return false }
        isLoading = false
        return true
    }

    mutating func invalidate() {
        loadGeneration &+= 1
        isLoading = false
    }

    mutating func selectionDidChange() {
        selectionRevision &+= 1
    }

    var backgroundSnapshot: BackgroundSnapshot? {
        guard !isLoading else { return nil }
        return BackgroundSnapshot(
            loadGeneration: loadGeneration,
            selectionRevision: selectionRevision
        )
    }

    func allowsBackgroundRefresh(_ snapshot: BackgroundSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot == backgroundSnapshot
    }
}
