import Combine
import CryptoKit
import Foundation
import ScreenlogCore

/// A snapshot keeps scheduling testable without changing system power or input state.
struct SemanticIndexingConditions {
    var power: CapturePowerConditions
    var idleSeconds: TimeInterval
    var memoryPressure = false

    static func current() -> Self {
        Self(
            power: .current(powerSource: SystemPowerSource.current()),
            idleSeconds: SystemIdleMonitor.secondsSinceLastInput())
    }

    func deferral(for policy: SemanticIndexingPolicy) -> String? {
        if memoryPressure { return "Waiting for available memory." }
        if power.isThermallyPressured { return "Waiting for this Mac to cool down." }
        if power.lowPowerModeEnabled { return "Waiting for Low Power Mode to end." }
        guard policy == .automatic else { return nil }
        if power.powerSource != .externalPower { return "Automatic indexing waits for external power." }
        if idleSeconds < 60 { return "Automatic indexing starts after this Mac is idle for a minute." }
        return nil
    }
}

/// Owns consent, native work, and the lifetime boundary around one Library Store.
@MainActor
final class SemanticSearchController: ObservableObject, SemanticToolService {
    @Published private(set) var featureStatus = SemanticFeatureStatus()
    var indexingIsPaused: Bool { paused }

    private let store: Store
    private let preferences: UserDefaults
    private let airgap: @MainActor () -> Bool
    private let indexingConditions: @MainActor () -> SemanticIndexingConditions
    private let models: SemanticModelManager
    private let worker: SemanticWorkerClient
    private var saved: SemanticPreferenceStore.Snapshot
    private var suspended = false
    private var paused = false
    private var generation: UInt = 0
    private var indexTask: Task<Void, Never>?
    private var changingConfiguration = false
    private var installTask: Task<Void, Never>?
    private var installationID: UUID?
    private var startupTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var queryTasks: [UUID: Task<SemanticSearchResponse, Error>] = [:]
    private var controlTasks: [UUID: Task<SemanticFeatureStatus, Error>] = [:]
    private var controlTail: Task<SemanticFeatureStatus, Error>?
    private var memoryPressure = false
    private var pressureSource: DispatchSourceMemoryPressure?

    init(
        store: Store, preferences: UserDefaults,
        modelDirectory: URL = SemanticModelManager.defaultDirectory(),
        airgap: @escaping @MainActor () -> Bool,
        indexingConditions: @escaping @MainActor () -> SemanticIndexingConditions = { .current() }
    ) {
        self.store = store
        self.preferences = preferences
        self.airgap = airgap
        self.indexingConditions = indexingConditions
        saved = SemanticPreferenceStore.load(from: preferences)
        let models = SemanticModelManager(directory: modelDirectory)
        self.models = models
        worker = SemanticWorkerClient(modelDirectory: models.directory)
        featureStatus = SemanticFeatureStatus(enabled: saved.enabled, mode: saved.mode)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.pressureSource else { return }
                self.memoryPressure = !source.data.contains(.normal)
            }
        }
        source.resume()
        pressureSource = source
    }

    deinit { pressureSource?.cancel() }

    func modelsAreInstalled(for mode: SemanticSearchMode) async throws -> Bool {
        try await models.isInstalled(for: mode)
    }

    func status() async -> SemanticFeatureStatus {
        guard !suspended, !changingConfiguration, installTask == nil else { return featureStatus }
        if let statusTask {
            await statusTask.value
            return featureStatus
        }
        let epoch = generation
        let task = Task { [weak self] in
            guard let self else { return }
            do { try await self.refreshStatistics(epoch: epoch) } catch is CancellationError {} catch {
                self.recordFailure(error, epoch: epoch)
            }
        }
        statusTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == epoch { statusTask = nil }
        return featureStatus
    }

    func start() async {
        guard !suspended, !Task.isCancelled else { return }
        if let startupTask {
            await startupTask.value
            return
        }
        let epoch = generation
        _ = await controlTail?.result
        guard !suspended, !Task.isCancelled, generation == epoch else { return }
        if let startupTask {
            await startupTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do { try await self.configure(epoch: epoch) } catch is CancellationError {} catch { self.recordFailure(error, epoch: epoch) }
        }
        startupTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == epoch { startupTask = nil }
    }

    /// Admission closes before cancellation or any other suspension point.
    func suspendAndDrain() async {
        suspended = true
        generation &+= 1
        startupTask?.cancel()
        let startup = startupTask
        startupTask = nil
        let controls = Array(controlTasks.values)
        controls.forEach { $0.cancel() }
        await stopWork()
        await startup?.value
        for task in controls { _ = await task.result }
        controlTasks.removeAll()
        controlTail = nil
        featureStatus.phase = saved.enabled ? .paused : .disabled
        featureStatus.message = saved.enabled ? "Indexing is paused while the Library is busy." : nil
    }

    func resume() async {
        guard !Task.isCancelled else { return }
        suspended = false
        await start()
    }

    func invalidate() async {
        let wasSuspended = suspended
        await suspendAndDrain()
        if !wasSuspended { await resume() }
    }

    func networkPolicyDidChange() async {
        guard airgap(), let task = installTask else { return }
        let epoch = generation
        task.cancel()
        await task.value
        guard !suspended, generation == epoch, !Task.isCancelled else { return }
        installTask = nil
        await start()
        guard !suspended, generation == epoch, !Task.isCancelled else { return }
        featureStatus.message = "Offline mode stopped the model download. Local search remains available."
    }

    func control(_ request: SemanticControlRequest) async throws -> SemanticFeatureStatus {
        guard !suspended else {
            if request.action == .disable && !saved.enabled { return featureStatus }
            throw SemanticSearchError.unavailable("The Library is busy. Try again after the current operation.")
        }
        let id = UUID()
        let previous = controlTail
        let epoch = generation
        let task = Task { [weak self] () throws -> SemanticFeatureStatus in
            _ = await previous?.result
            guard let self else { throw CancellationError() }
            await self.startupTask?.value
            try self.check(epoch)
            return try await self.apply(request, epoch: epoch)
        }
        controlTasks[id] = task
        controlTail = task
        defer {
            controlTasks[id] = nil
            if controlTasks.isEmpty { controlTail = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func search(_ request: SemanticSearchRequest) async throws -> SemanticSearchResponse {
        guard !suspended else { throw SemanticSearchError.unavailable("The Library is busy. Try again after the current operation.") }
        guard !changingConfiguration, installTask == nil else {
            throw SemanticSearchError.unavailable("Semantic Search setup is in progress.")
        }
        guard featureStatus.phase != .unsupported else {
            throw SemanticSearchError.unavailable("Related search requires an Apple silicon Mac.")
        }
        guard saved.enabled else { throw SemanticSearchError.disabled }
        guard featureStatus.modelInstalled else { throw SemanticSearchError.modelMissing }
        let mode = try SemanticSearchPresentation.queryMode(request.mode, enabled: saved.mode)
        guard (1...500).contains(request.limit) else { throw SemanticSearchError.invalidRequest("Use a result limit from 1 to 500.") }
        let parsed = SearchOperatorParser.parse(request.query)
        if let issue = parsed.validationIssue { throw SemanticSearchError.invalidRequest(issue) }
        guard !parsed.ftsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SemanticSearchError.invalidRequest("Enter a description for Related search.")
        }
        let epoch = generation
        let id = UUID()
        let task = Task { [weak self] () throws -> SemanticSearchResponse in
            guard let self else { throw CancellationError() }
            try self.check(epoch)
            let coverage = try await self.store.readAsync { try $0.semanticStatistics(mode: mode) }
            try self.check(epoch)
            guard coverage.indexedSources > 0 else { throw SemanticSearchError.indexEmpty }
            let vector = try await self.worker.queryVector(parsed.ftsText)
            try self.check(epoch)
            let bounds = SearchOperatorParser.sqlTimeBounds(from: parsed)
            let query = LibrarySearchQuery(
                text: "", appFilter: parsed.appFilter, siteFilter: parsed.siteFilter,
                appBundleID: request.appBundleID, domain: request.domain,
                fromTimestampMs: SemanticSearchPresentation.lowerBound(bounds.fromTimestampMs, request.fromTimestampMs),
                toTimestampMs: SemanticSearchPresentation.upperBound(bounds.toTimestampMs, request.toTimestampMs),
                content: request.content
            )
            // Explicit fuzzy filters are separate from operators. Resolve both
            // before ranking; never filter a limited result page afterward.
            let hits = try await self.store.readAsync { store in
                try store.semanticSearch(
                    vector: vector, query: query, mode: mode, limit: request.limit,
                    appFilter: request.appFilter, siteFilter: request.siteFilter)
            }
            try self.check(epoch)
            try await self.refreshStatistics(epoch: epoch)
            if hits.isEmpty && self.featureStatus.index.indexedSources == 0 {
                throw SemanticSearchError.indexEmpty
            }
            return SemanticSearchResponse(hits: hits, status: self.featureStatus)
        }
        queryTasks[id] = task
        defer { queryTasks[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func apply(_ request: SemanticControlRequest, epoch: UInt) async throws -> SemanticFeatureStatus {
        #if !arch(arm64)
            if request.action == .downloadModels || request.action == .enable || request.action == .resume
                || request.action == .indexNow
            {
                featureStatus.phase = .unsupported
                throw SemanticSearchError.unavailable("Related search requires an Apple silicon Mac.")
            }
        #endif
        if installTask != nil && request.action != .disable && request.action != .removeModels
            && request.action != .removeIndex && request.action != .downloadModels
        {
            throw SemanticSearchError.unavailable("Wait for the model download or cancel it first.")
        }
        changingConfiguration = request.action != .pause && request.action != .indexNow
        let previousPhase = featureStatus.phase
        if changingConfiguration { featureStatus.phase = .verifying }
        defer {
            changingConfiguration = false
            if featureStatus.phase == .verifying && installTask == nil {
                featureStatus.phase = previousPhase
            }
        }
        switch request.action {
        case .downloadModels:
            guard !airgap() else { throw SemanticSearchError.unavailable("Turn off Keep Screenlogger Offline before you download models.") }
            guard installTask == nil else { throw SemanticSearchError.unavailable("A model download is already in progress.") }
            let mode = request.mode ?? saved.mode
            await stopWork()
            try check(epoch)
            featureStatus.mode = mode
            featureStatus.downloadBytes = SemanticModelManager.downloadBytes(for: mode)
            featureStatus.downloadedBytes = 0
            featureStatus.phase = .downloading
            featureStatus.message = nil
            let installationID = UUID()
            self.installationID = installationID
            installTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.installationID == installationID {
                        self.installTask = nil
                        self.installationID = nil
                    }
                }
                do {
                    try self.check(epoch)
                    try await self.models.install(mode: mode) { [weak self] received, total, verifying in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.generation == epoch, !self.suspended,
                                self.installationID == installationID
                            else { return }
                            self.featureStatus.downloadedBytes = received
                            self.featureStatus.downloadBytes = total
                            self.featureStatus.phase = verifying ? .verifying : .downloading
                        }
                    }
                    try self.check(epoch)
                    if request.enableWhenReady {
                        self.saved = .init(enabled: true, mode: mode)
                        self.save()
                    } else if !self.saved.enabled {
                        self.saved = .init(enabled: false, mode: mode)
                        self.save()
                    }
                    try await self.configure(epoch: epoch)
                } catch is CancellationError {
                } catch {
                    self.recordFailure(error, epoch: epoch)
                }
            }
        case .enable:
            let mode = request.mode ?? saved.mode
            guard try await models.isInstalled(for: mode) else { throw SemanticSearchError.modelMissing }
            try check(epoch)
            await stopWork()
            try check(epoch)
            saved = .init(enabled: true, mode: mode)
            paused = false
            save()
            try await configure(epoch: epoch)
        case .disable:
            await stopWork()
            try check(epoch)
            saved = .init(enabled: false, mode: saved.mode)
            save()
            try await configure(epoch: epoch)
        case .pause:
            paused = true
            await stopIndex()
            try check(epoch)
            featureStatus.phase = saved.enabled ? .paused : .disabled
            featureStatus.message = saved.enabled ? "Indexing is paused. Your existing index is still searchable." : nil
        case .resume:
            guard saved.enabled else { throw SemanticSearchError.disabled }
            paused = false
            try await configure(epoch: epoch)
        case .indexNow:
            guard saved.enabled else { throw SemanticSearchError.disabled }
            guard request.mode == nil, !request.enableWhenReady else {
                throw SemanticSearchError.invalidRequest("Index Now uses the enabled sources and installed models.")
            }
            guard try await models.isInstalled(for: saved.mode) else { throw SemanticSearchError.modelMissing }
            try check(epoch)
            paused = false
            featureStatus.indexingPolicy = .manual
            featureStatus.phase = .indexing
            featureStatus.message = "Indexing now."
            beginIndexing(epoch: epoch)
        case .removeIndex:
            await stopWork()
            try check(epoch)
            saved = .init(enabled: false, mode: saved.mode)
            save()
            try await store.readAsync { try $0.removeSemanticIndex() }
            try await configure(epoch: epoch)
        case .removeModels:
            await stopWork()
            try check(epoch)
            saved = .init(enabled: false, mode: saved.mode)
            save()
            let mode = saved.mode
            try await store.readAsync { try $0.configureSemanticIndex(enabled: false, mode: mode) }
            try await models.removeModels()
            try await configure(epoch: epoch)
        }
        return featureStatus
    }

    private func configure(epoch: UInt) async throws {
        try check(epoch)
        featureStatus.indexingPolicy = .automatic
        #if !arch(arm64)
            let mode = saved.mode
            try await store.readAsync { try $0.configureSemanticIndex(enabled: false, mode: mode) }
            try check(epoch)
            try await refreshStatistics(epoch: epoch)
            featureStatus.phase = .unsupported
            featureStatus.message = "Related search requires an Apple silicon Mac. Exact search remains available."
            return
        #else
            let mode = saved.mode
            let installed = try await models.isInstalled(for: mode)
            try check(epoch)
            let enabled = saved.enabled && installed
            try await store.readAsync { try $0.configureSemanticIndex(enabled: enabled, mode: mode) }
            try check(epoch)
            featureStatus.enabled = saved.enabled
            featureStatus.mode = mode
            featureStatus.modelInstalled = installed
            featureStatus.downloadBytes = SemanticModelManager.downloadBytes(for: mode)
            featureStatus.phase = !installed ? .modelMissing : (saved.enabled ? (paused ? .paused : .ready) : .disabled)
            featureStatus.message = enabled && paused ? "Indexing is paused. Your existing index is still searchable." : nil
            try await refreshStatistics(epoch: epoch)
            if enabled && !paused { beginIndexing(epoch: epoch) }
        #endif
    }

    private func beginIndexing(epoch: UInt) {
        guard indexTask == nil else { return }
        indexTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == epoch { self.indexTask = nil }
            }
            var historyComplete = false
            while !Task.isCancelled {
                do {
                    try self.check(epoch)
                    if !self.queryTasks.isEmpty {
                        try await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    if !historyComplete {
                        historyComplete = try await self.store.readAsync { try $0.admitSemanticHistory() }
                        try self.check(epoch)
                    }
                    let mode = self.saved.mode
                    let work = try await self.store.readAsync { try $0.semanticWork(mode: mode, limit: 1) }
                    try self.check(epoch)
                    guard let item = work.first else {
                        if !historyComplete {
                            await Task.yield()
                            continue
                        }
                        self.featureStatus.phase = .ready
                        self.featureStatus.indexingPolicy = .automatic
                        try await self.refreshStatistics(epoch: epoch)
                        self.featureStatus.message =
                            self.featureStatus.index.failedSources > 0
                            ? "Indexing finished. Some items could not be indexed."
                            : (self.featureStatus.index.indexedSources == 0 ? "No captures to index yet." : "Index is up to date.")
                        try await Task.sleep(for: .seconds(5))
                        continue
                    }
                    try await self.refreshStatistics(epoch: epoch)
                    do { try await self.index(item, epoch: epoch) } catch is CancellationError { throw CancellationError() } catch {
                        try self.check(epoch)
                        let message = error.localizedDescription
                        try await self.store.readAsync { try $0.failSemanticWork(item, message: message) }
                        self.featureStatus.message = message
                    }
                    try await self.refreshStatistics(epoch: epoch)
                    await Task.yield()
                } catch is CancellationError { break } catch {
                    self.recordFailure(error, epoch: epoch)
                    break
                }
            }
        }
    }

    private func index(_ item: SemanticWorkItem, epoch: UInt) async throws {
        try await awaitBackgroundSlot(epoch: epoch)
        if item.kind == .image {
            guard let preview = item.preview else { throw SemanticSearchError.unavailable("The captured image is not available.") }
            let prepared = try await worker.prepareImage(preview)
            do {
                try check(epoch)
                let reused = try await store.readAsync { try $0.reuseSemanticWork(item, contentHash: prepared.hash) }
                if !reused {
                    try await awaitBackgroundSlot(epoch: epoch)
                    let chunk: SemanticVectorChunk
                    if let cached = try await store.readAsync({ try $0.semanticVectorChunk(hash: prepared.hash) }) {
                        chunk = cached
                    } else {
                        chunk = try await worker.encodeImage(prepared)
                    }
                    try check(epoch)
                    _ = try await store.readAsync { try $0.completeSemanticWork(item, contentHash: prepared.hash, chunks: [chunk]) }
                }
                await worker.discardImage(prepared)
            } catch {
                await worker.discardImage(prepared)
                throw error
            }
        } else {
            let text = item.text ?? ""
            guard text.utf8.count <= SemanticWorkerLimits.maximumTextBytes,
                (item.title?.utf8.count ?? 0) <= SemanticWorkerLimits.maximumTextBytes
            else {
                throw SemanticSearchError.unavailable("This text exceeds the local model input limit.")
            }
            let hash = SemanticSearchPresentation.textIdentity(title: item.title, text: text)
            if try await store.readAsync({ try $0.reuseSemanticWork(item, contentHash: hash) }) { return }
            try await awaitBackgroundSlot(epoch: epoch)
            let prepared = try await worker.prepareText(title: item.title, text: text)
            var chunks: [SemanticVectorChunk] = []
            chunks.reserveCapacity(prepared.count)
            for part in prepared {
                try await awaitBackgroundSlot(epoch: epoch)
                if let cached = try await store.readAsync({ try $0.semanticVectorChunk(hash: part.hash) }) {
                    chunks.append(cached)
                } else {
                    chunks.append(try await worker.encodeTextChunk(part))
                }
                await Task.yield()
            }
            try check(epoch)
            let completed = chunks
            _ = try await store.readAsync { try $0.completeSemanticWork(item, contentHash: hash, chunks: completed) }
        }
    }

    private func awaitBackgroundSlot(epoch: UInt) async throws {
        while true {
            try check(epoch)
            let reason = backgroundDeferral
            if queryTasks.isEmpty && reason == nil {
                featureStatus.phase = .indexing
                featureStatus.message = featureStatus.indexingPolicy == .manual ? "Indexing now." : nil
                return
            }
            if let reason {
                featureStatus.phase = .paused
                featureStatus.message = reason
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private var backgroundDeferral: String? {
        var conditions = indexingConditions()
        conditions.memoryPressure = conditions.memoryPressure || memoryPressure
        return conditions.deferral(for: featureStatus.indexingPolicy)
    }

    private func refreshStatistics(epoch: UInt) async throws {
        let mode = saved.mode
        let statistics = try await store.readAsync { try $0.semanticStatistics(mode: mode) }
        try check(epoch)
        featureStatus.index = statistics
    }

    private func stopIndex() async {
        featureStatus.indexingPolicy = .automatic
        let task = indexTask
        indexTask = nil
        task?.cancel()
        await worker.stop()
        await task?.value
    }

    private func stopWork() async {
        featureStatus.indexingPolicy = .automatic
        let statistics = statusTask
        statusTask = nil
        statistics?.cancel()
        let installation = installTask
        installTask = nil
        installationID = nil
        installation?.cancel()
        let indexing = indexTask
        indexTask = nil
        indexing?.cancel()
        let queries = Array(queryTasks.values)
        queries.forEach { $0.cancel() }
        await worker.stop()
        await installation?.value
        await indexing?.value
        await statistics?.value
        for query in queries { _ = await query.result }
    }

    private func check(_ epoch: UInt) throws {
        try Task.checkCancellation()
        guard !suspended, generation == epoch else { throw CancellationError() }
    }

    private func save() {
        SemanticPreferenceStore.save(saved, to: preferences)
        featureStatus.enabled = saved.enabled
        featureStatus.mode = saved.mode
    }

    private func recordFailure(_ error: Error, epoch: UInt) {
        guard generation == epoch, !suspended else { return }
        featureStatus.phase = .failed
        featureStatus.message = error.localizedDescription
    }
}
