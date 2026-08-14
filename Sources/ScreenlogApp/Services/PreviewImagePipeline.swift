import CoreGraphics
import Foundation
import ScreenlogCore

enum PreviewImagePriority: Int, Sendable {
    case prefetch = 0
    case card = 1
    case inspector = 2
    case timeline = 3
}

enum PreviewImagePipelineError: Error, Equatable {
    case momentMissing
    case mediaUnavailable
    case mediaUnreadable
}

/// One bounded preview pipeline shared by Library and Timeline.
///
/// Database resolution and cache hits do not consume a decode slot. Actual
/// media decodes are priority ordered, duplicate work is shared, and every
/// result is checked against the Store again before it can be presented.
actor PreviewImagePipeline {
    typealias Decoder = @Sendable (FramePreviewDescriptor, Int) async throws -> CGImage

    struct Snapshot: Equatable, Sendable {
        var activeDecodes: Int
        var maximumObservedDecodes: Int
        var queuedRequests: Int
        var activeRequests: Int
        var sharedDecodes: Int
        var isAcceptingRequests: Bool
    }

    static let maximumConcurrentDecodes = 3

    private final class ImageBox: NSObject, @unchecked Sendable {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private struct Waiter {
        let id: UUID
        let sequence: UInt64
        var priority: PreviewImagePriority
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct DecodeWork {
        let id: UUID
        let baseKey: String
        let maxPixelSize: Int
        var priority: PreviewImagePriority
        var task: Task<Void, Never>?
        var subscribers: [UUID: CheckedContinuation<CGImage, Error>]
    }

    private let maximumConcurrentDecodes: Int
    private let decoder: Decoder
    private let cache: NSCache<NSString, ImageBox> = {
        let cache = NSCache<NSString, ImageBox>()
        cache.countLimit = 192
        cache.totalCostLimit = 128 * 1_024 * 1_024
        return cache
    }()
    private var activeDecodes = 0
    private var maximumObservedDecodes = 0
    private var activeRequests = 0
    private var nextSequence: UInt64 = 0
    private var waiters: [Waiter] = []
    private var inFlight: [String: DecodeWork] = [:]
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []
    private var generation: UInt64 = 0
    private var isAcceptingRequests = true

    init(
        maximumConcurrentDecodes: Int = PreviewImagePipeline.maximumConcurrentDecodes,
        decoder: @escaping Decoder = { descriptor, maxPixelSize in
            try await FrameExtractor.previewCGImage(
                for: descriptor,
                maxPixelSize: maxPixelSize
            )
        }
    ) {
        self.maximumConcurrentDecodes = max(1, maximumConcurrentDecodes)
        self.decoder = decoder
    }

    func image(
        frameID: Int64,
        store: Store,
        maxPixelSize: Int,
        priority: PreviewImagePriority
    ) async throws -> CGImage {
        guard maxPixelSize > 0 else { throw PreviewImagePipelineError.mediaUnreadable }
        try Task.checkCancellation()
        guard isAcceptingRequests else { throw CancellationError() }

        let requestGeneration = generation
        activeRequests += 1
        defer { finishRequest() }

        var resolvedDescriptor = try await descriptor(frameID: frameID, store: store)
        for attempt in 0...1 {
            try verifyRequest(generation: requestGeneration)
            let key = cacheKey(
                descriptor: resolvedDescriptor,
                store: store,
                maxPixelSize: maxPixelSize
            )
            let image: CGImage
            if let cached = cache.object(forKey: key as NSString) {
                image = cached.image
            } else {
                do {
                    image = try await sharedDecode(
                        resolvedDescriptor,
                        store: store,
                        maxPixelSize: maxPixelSize,
                        priority: priority
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let refreshed = try await descriptor(frameID: frameID, store: store)
                    guard attempt == 0, refreshed != resolvedDescriptor else {
                        throw PreviewImagePipelineError.mediaUnreadable
                    }
                    resolvedDescriptor = refreshed
                    continue
                }
            }

            try verifyRequest(generation: requestGeneration)
            let authoritative = try await descriptor(frameID: frameID, store: store)
            try verifyRequest(generation: requestGeneration)
            guard authoritative == resolvedDescriptor else {
                guard attempt == 0 else {
                    throw PreviewImagePipelineError.mediaUnreadable
                }
                resolvedDescriptor = authoritative
                continue
            }

            let cost = min(Int.max, image.bytesPerRow * image.height)
            cache.setObject(ImageBox(image), forKey: key as NSString, cost: cost)
            return image
        }
        throw PreviewImagePipelineError.mediaUnreadable
    }

    /// Invalidates pixels after deletion or retention. New work may begin
    /// immediately against the now-authoritative Store state.
    func removeAll() {
        invalidateWork()
    }

    /// Prevents new Store reads, cancels queued work, and waits until every
    /// request and media decode has left the pipeline. Restore must call this
    /// before closing or replacing SQLite.
    func suspendAndDrain() async {
        isAcceptingRequests = false
        invalidateWork()
        guard activeRequests > 0 || activeDecodes > 0 else { return }
        await withCheckedContinuation { continuation in
            drainContinuations.append(continuation)
        }
    }

    func resume() {
        isAcceptingRequests = true
    }

    func snapshot() -> Snapshot {
        Snapshot(
            activeDecodes: activeDecodes,
            maximumObservedDecodes: maximumObservedDecodes,
            queuedRequests: waiters.count,
            activeRequests: activeRequests,
            sharedDecodes: inFlight.count,
            isAcceptingRequests: isAcceptingRequests
        )
    }

    private func verifyRequest(generation requestGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard isAcceptingRequests, generation == requestGeneration else {
            throw CancellationError()
        }
    }

    private func descriptor(frameID: Int64, store: Store) async throws -> FramePreviewDescriptor {
        guard
            let descriptor = try await store.readAsync({
                try $0.framePreviewDescriptor(id: frameID)
            })
        else {
            throw PreviewImagePipelineError.momentMissing
        }
        guard descriptor.source != .unavailable else {
            throw PreviewImagePipelineError.mediaUnavailable
        }
        return descriptor
    }

    private func sharedDecode(
        _ descriptor: FramePreviewDescriptor,
        store: Store,
        maxPixelSize: Int,
        priority: PreviewImagePriority
    ) async throws -> CGImage {
        let baseKey = mediaKey(descriptor: descriptor, store: store)
        let compatible =
            inFlight
            .filter { $0.value.baseKey == baseKey && $0.value.maxPixelSize >= maxPixelSize }
            .min { $0.value.maxPixelSize < $1.value.maxPixelSize }

        let workKey: String
        let workID: UUID
        if let compatible {
            workKey = compatible.key
            workID = compatible.value.id
            if priority.rawValue > compatible.value.priority.rawValue {
                var promoted = compatible.value
                promoted.priority = priority
                inFlight[workKey] = promoted
                promoteWaiter(id: workID, to: priority)
            }
        } else {
            workKey = "\(baseKey)|\(maxPixelSize)"
            workID = UUID()
            inFlight[workKey] = DecodeWork(
                id: workID,
                baseKey: baseKey,
                maxPixelSize: maxPixelSize,
                priority: priority,
                task: nil,
                subscribers: [:]
            )
            let task = Task { [weak self] in
                guard let self else { return }
                let result: Result<CGImage, Error>
                do {
                    result = .success(
                        try await self.decode(
                            descriptor,
                            maxPixelSize: maxPixelSize,
                            workKey: workKey,
                            workID: workID
                        )
                    )
                } catch {
                    result = .failure(error)
                }
                await self.completeWork(key: workKey, id: workID, result: result)
            }
            inFlight[workKey]?.task = task
        }

        let subscriberID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled,
                    var work = inFlight[workKey], work.id == workID
                else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                work.subscribers[subscriberID] = continuation
                inFlight[workKey] = work
            }
        } onCancel: {
            Task { await self.cancelSubscriber(key: workKey, workID: workID, id: subscriberID) }
        }
    }

    private func decode(
        _ descriptor: FramePreviewDescriptor,
        maxPixelSize: Int,
        workKey: String,
        workID: UUID
    ) async throws -> CGImage {
        let priority =
            inFlight[workKey]?.id == workID
            ? inFlight[workKey]?.priority ?? .prefetch
            : .prefetch
        try await acquire(id: workID, priority: priority)
        defer { release() }
        try Task.checkCancellation()
        let effectivePriority =
            inFlight[workKey]?.id == workID
            ? inFlight[workKey]?.priority ?? priority
            : priority
        let metric: PerformanceMetricID =
            effectivePriority == .timeline || effectivePriority == .prefetch
            ? .timelineFrameExtraction
            : .firstThumbnailDecode
        let image = try await ScreenlogPerformanceSignposts.measure(metric) {
            try await decoder(descriptor, maxPixelSize)
        }
        try Task.checkCancellation()
        return image
    }

    private func completeWork(
        key: String,
        id: UUID,
        result: Result<CGImage, Error>
    ) {
        guard let work = inFlight[key], work.id == id else { return }
        inFlight.removeValue(forKey: key)
        for continuation in work.subscribers.values {
            continuation.resume(with: result)
        }
        signalDrainIfNeeded()
    }

    private func cancelSubscriber(key: String, workID: UUID, id: UUID) {
        guard var work = inFlight[key], work.id == workID,
            let continuation = work.subscribers.removeValue(forKey: id)
        else { return }
        continuation.resume(throwing: CancellationError())
        if work.subscribers.isEmpty {
            inFlight.removeValue(forKey: key)
            work.task?.cancel()
        } else {
            inFlight[key] = work
        }
        signalDrainIfNeeded()
    }

    private func mediaKey(descriptor: FramePreviewDescriptor, store: Store) -> String {
        let source: String
        switch descriptor.source {
        case .still(let path):
            source = "still|\(path)"
        case .video(let path, let index):
            source = "video|\(path)|\(index)"
        case .unavailable:
            source = "unavailable"
        }
        return "\(ObjectIdentifier(store))|\(descriptor.frameID)|\(descriptor.timestampMs)|\(source)"
    }

    private func cacheKey(
        descriptor: FramePreviewDescriptor,
        store: Store,
        maxPixelSize: Int
    ) -> String {
        "\(mediaKey(descriptor: descriptor, store: store))|\(maxPixelSize)"
    }

    private func acquire(id: UUID, priority: PreviewImagePriority) async throws {
        try Task.checkCancellation()
        if activeDecodes < maximumConcurrentDecodes {
            activeDecodes += 1
            maximumObservedDecodes = max(maximumObservedDecodes, activeDecodes)
            return
        }

        let sequence = nextSequence
        nextSequence &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(
                    Waiter(
                        id: id,
                        sequence: sequence,
                        priority: priority,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        signalDrainIfNeeded()
    }

    private func promoteWaiter(id: UUID, to priority: PreviewImagePriority) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        guard priority.rawValue > waiters[index].priority.rawValue else { return }
        waiters[index].priority = priority
    }

    private func release() {
        guard !waiters.isEmpty else {
            activeDecodes = max(0, activeDecodes - 1)
            signalDrainIfNeeded()
            return
        }
        let nextIndex =
            waiters.indices.max { lhs, rhs in
                let left = waiters[lhs]
                let right = waiters[rhs]
                if left.priority.rawValue != right.priority.rawValue {
                    return left.priority.rawValue < right.priority.rawValue
                }
                return left.sequence > right.sequence
            } ?? waiters.startIndex
        let next = waiters.remove(at: nextIndex)
        next.continuation.resume()
    }

    private func finishRequest() {
        activeRequests = max(0, activeRequests - 1)
        signalDrainIfNeeded()
    }

    private func invalidateWork() {
        generation &+= 1
        cache.removeAllObjects()

        let work = inFlight.values
        inFlight.removeAll()
        for item in work {
            item.task?.cancel()
            for continuation in item.subscribers.values {
                continuation.resume(throwing: CancellationError())
            }
        }

        let queued = waiters
        waiters.removeAll()
        for waiter in queued {
            waiter.continuation.resume(throwing: CancellationError())
        }
        signalDrainIfNeeded()
    }

    private func signalDrainIfNeeded() {
        guard !isAcceptingRequests, activeRequests == 0, activeDecodes == 0 else { return }
        let continuations = drainContinuations
        drainContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
