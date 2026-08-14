import CoreGraphics
import Foundation
import ImageIO
import ScreenlogCore
import UniformTypeIdentifiers
import XCTest

final class PreviewImagePipelineTests: XCTestCase {
    private actor DecoderProbe {
        private let image: CGImage
        private let blockedFrameIDs: Set<Int64>
        private var blockers: [Int64: CheckedContinuation<Void, Never>] = [:]
        private(set) var started: [Int64] = []
        private(set) var active = 0
        private(set) var maximumActive = 0

        init(blockedFrameID: Int64? = nil) {
            blockedFrameIDs = blockedFrameID.map { [$0] } ?? []
            let context = CGContext(
                data: nil,
                width: 8,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 8 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            image = context.makeImage()!
        }

        init(blockedFrameIDs: Set<Int64>) {
            self.blockedFrameIDs = blockedFrameIDs
            let context = CGContext(
                data: nil,
                width: 8,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 8 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            image = context.makeImage()!
        }

        func decode(_ descriptor: FramePreviewDescriptor, _: Int) async throws -> CGImage {
            started.append(descriptor.frameID)
            active += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }

            if blockedFrameIDs.contains(descriptor.frameID) {
                await withCheckedContinuation { blockers[descriptor.frameID] = $0 }
            } else {
                try await Task.sleep(for: .milliseconds(15))
            }
            return image
        }

        func releaseBlocker() {
            let current = Array(blockers.values)
            blockers.removeAll()
            current.forEach { $0.resume() }
        }
    }

    func testDecodeConcurrencyStaysBounded() async throws {
        let fixture = try makeFixture(frameCount: 8)
        defer { cleanup(fixture) }
        let probe = DecoderProbe()
        let pipeline = PreviewImagePipeline(
            maximumConcurrentDecodes: 2,
            decoder: { descriptor, maxPixelSize in
                try await probe.decode(descriptor, maxPixelSize)
            }
        )

        let tasks = fixture.frameIDs.map { frameID in
            Task {
                try await pipeline.image(
                    frameID: frameID,
                    store: fixture.store,
                    maxPixelSize: 320,
                    priority: .card
                )
            }
        }
        for task in tasks {
            _ = try await task.value
        }

        let snapshot = await pipeline.snapshot()
        let maximumActive = await probe.maximumActive
        XCTAssertEqual(snapshot.maximumObservedDecodes, 2)
        XCTAssertEqual(maximumActive, 2)
    }

    func testInspectorJumpsAheadOfQueuedCards() async throws {
        let fixture = try makeFixture(frameCount: 4)
        defer { cleanup(fixture) }
        let firstID = try XCTUnwrap(fixture.frameIDs.first)
        let probe = DecoderProbe(blockedFrameID: firstID)
        let pipeline = PreviewImagePipeline(
            maximumConcurrentDecodes: 1,
            decoder: { descriptor, maxPixelSize in
                try await probe.decode(descriptor, maxPixelSize)
            }
        )

        let blocker = request(
            fixture.frameIDs[0],
            priority: .card,
            pipeline: pipeline,
            store: fixture.store
        )
        try await waitForStartedCount(1, probe: probe)
        let cardA = request(
            fixture.frameIDs[1],
            priority: .card,
            pipeline: pipeline,
            store: fixture.store
        )
        let cardB = request(
            fixture.frameIDs[2],
            priority: .card,
            pipeline: pipeline,
            store: fixture.store
        )
        try await waitForQueuedCount(2, pipeline: pipeline)
        let inspector = request(
            fixture.frameIDs[3],
            priority: .inspector,
            pipeline: pipeline,
            store: fixture.store
        )
        try await waitForQueuedCount(3, pipeline: pipeline)

        await probe.releaseBlocker()
        _ = try await blocker.value
        _ = try await inspector.value
        _ = try await cardA.value
        _ = try await cardB.value

        let started = await probe.started
        XCTAssertEqual(Array(started.prefix(2)), [fixture.frameIDs[0], fixture.frameIDs[3]])
        XCTAssertEqual(Set(started.dropFirst(2)), Set([fixture.frameIDs[1], fixture.frameIDs[2]]))
    }

    func testCompactedSearchResultRendersThroughSharedPipeline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-compaction-\(UUID().uuidString)", isDirectory: true)
        let store = try Store(root: root)
        defer { cleanup((root: root, store: store, frameIDs: [])) }
        var frameIDs: [Int64] = []
        for index in 0..<3 {
            let path = root.appendingPathComponent("source-\(index).png")
            try makePNG(gray: UInt8(50 + index * 60)).write(to: path)
            frameIDs.append(
                try store.insertSeedFrame(
                    timestampMs: 20_000 + Int64(index * 2_000),
                    foreground: "compacted preview \(index)",
                    imagePath: path.path,
                    width: 64,
                    height: 64
                )
            )
        }
        let compactor = VideoCompactionService()
        compactor.minBatchSize = 2
        compactor.minRunSize = 2
        XCTAssertEqual(try compactor.compactIfNeeded(store: store), 3)

        let hit = try XCTUnwrap(
            try store.searchLibrary(
                query: LibrarySearchQuery(text: "compacted preview"),
                limit: 1
            ).first
        )
        XCTAssertTrue(hit.isCompacted)
        let image = try await PreviewImagePipeline().image(
            frameID: hit.frameID,
            store: store,
            maxPixelSize: 320,
            priority: .card
        )

        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 64)
    }

    func testCancelledQueuedCardDoesNotDecode() async throws {
        let fixture = try makeFixture(frameCount: 3)
        defer { cleanup(fixture) }
        let firstID = fixture.frameIDs[0]
        let probe = DecoderProbe(blockedFrameID: firstID)
        let pipeline = PreviewImagePipeline(
            maximumConcurrentDecodes: 1,
            decoder: { descriptor, maxPixelSize in
                try await probe.decode(descriptor, maxPixelSize)
            }
        )
        let blocker = request(
            firstID,
            priority: .card,
            pipeline: pipeline,
            store: fixture.store
        )
        try await waitForStartedCount(1, probe: probe)
        let cancelled = request(
            fixture.frameIDs[1],
            priority: .card,
            pipeline: pipeline,
            store: fixture.store
        )
        let survivor = request(
            fixture.frameIDs[2],
            priority: .inspector,
            pipeline: pipeline,
            store: fixture.store
        )
        try await waitForQueuedCount(2, pipeline: pipeline)
        cancelled.cancel()
        let cancelledPromptly = expectation(description: "queued cancellation returned")
        Task {
            do {
                _ = try await cancelled.value
            } catch is CancellationError {
                cancelledPromptly.fulfill()
            } catch {
                XCTFail("Expected cancellation, received \(error)")
            }
        }
        await fulfillment(of: [cancelledPromptly], timeout: 0.5)
        await probe.releaseBlocker()

        _ = try await blocker.value
        _ = try await survivor.value
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled off-screen request must not decode")
        } catch is CancellationError {
            // Expected.
        }
        let started = await probe.started
        XCTAssertFalse(started.contains(fixture.frameIDs[1]))
    }

    func testDuplicateRequestsShareOneDecode() async throws {
        let fixture = try makeFixture(frameCount: 1)
        defer { cleanup(fixture) }
        let frameID = fixture.frameIDs[0]
        let probe = DecoderProbe(blockedFrameID: frameID)
        let pipeline = PreviewImagePipeline(
            maximumConcurrentDecodes: 2,
            decoder: { descriptor, maxPixelSize in
                try await probe.decode(descriptor, maxPixelSize)
            }
        )

        let card = request(frameID, priority: .card, pipeline: pipeline, store: fixture.store)
        try await waitForStartedCount(1, probe: probe)
        let inspector = request(
            frameID,
            priority: .inspector,
            pipeline: pipeline,
            store: fixture.store
        )
        try await waitForActiveRequestCount(2, pipeline: pipeline)

        let sharedDecodes = await pipeline.snapshot().sharedDecodes
        XCTAssertEqual(sharedDecodes, 1)
        await probe.releaseBlocker()
        _ = try await card.value
        _ = try await inspector.value
        let duplicateStarts = await probe.started.filter { $0 == frameID }.count
        XCTAssertEqual(duplicateStarts, 1)
    }

    func testInspectorPromotesItsAlreadyQueuedCardDecode() async throws {
        let fixture = try makeFixture(frameCount: 3)
        defer { cleanup(fixture) }
        let firstID = fixture.frameIDs[0]
        let promotedID = fixture.frameIDs[2]
        let probe = DecoderProbe(blockedFrameID: firstID)
        let pipeline = PreviewImagePipeline(
            maximumConcurrentDecodes: 1,
            decoder: { descriptor, maxPixelSize in
                try await probe.decode(descriptor, maxPixelSize)
            }
        )

        let blocker = request(firstID, priority: .card, pipeline: pipeline, store: fixture.store)
        try await waitForStartedCount(1, probe: probe)
        let earlierCard = request(
            fixture.frameIDs[1],
            priority: .card,
            pipeline: pipeline,
            store: fixture.store
        )
        let selectedCard = request(
            promotedID,
            priority: .card,
            pipeline: pipeline,
            store: fixture.store
        )
        try await waitForQueuedCount(2, pipeline: pipeline)
        let inspector = request(
            promotedID,
            priority: .inspector,
            pipeline: pipeline,
            store: fixture.store
        )
        try await waitForActiveRequestCount(4, pipeline: pipeline)

        await probe.releaseBlocker()
        _ = try await blocker.value
        _ = try await inspector.value
        _ = try await selectedCard.value
        _ = try await earlierCard.value

        let started = await probe.started
        XCTAssertEqual(started, [firstID, promotedID, fixture.frameIDs[1]])
    }

    func testCachedInspectorBypassesThreeColdDecodes() async throws {
        let fixture = try makeFixture(frameCount: 4)
        defer { cleanup(fixture) }
        let coldIDs = Set(fixture.frameIDs.dropFirst())
        let probe = DecoderProbe(blockedFrameIDs: coldIDs)
        let pipeline = PreviewImagePipeline(
            maximumConcurrentDecodes: 3,
            decoder: { descriptor, maxPixelSize in
                try await probe.decode(descriptor, maxPixelSize)
            }
        )

        _ = try await pipeline.image(
            frameID: fixture.frameIDs[0],
            store: fixture.store,
            maxPixelSize: 320,
            priority: .card
        )
        let cold = fixture.frameIDs.dropFirst().map {
            request($0, priority: .card, pipeline: pipeline, store: fixture.store)
        }
        try await waitForStartedCount(4, probe: probe)

        let cacheHit = expectation(description: "cached inspector returned")
        Task {
            do {
                _ = try await pipeline.image(
                    frameID: fixture.frameIDs[0],
                    store: fixture.store,
                    maxPixelSize: 320,
                    priority: .inspector
                )
                cacheHit.fulfill()
            } catch {
                XCTFail("Cached inspector failed: \(error)")
            }
        }
        await fulfillment(of: [cacheHit], timeout: 0.5)

        await probe.releaseBlocker()
        for task in cold { _ = try await task.value }
        let cachedFrameStarts = await probe.started.filter { $0 == fixture.frameIDs[0] }.count
        XCTAssertEqual(cachedFrameStarts, 1)
    }

    func testSuspendRejectsNewWorkAndDrainsActiveAndQueuedRequests() async throws {
        let fixture = try makeFixture(frameCount: 2)
        defer { cleanup(fixture) }
        let firstID = fixture.frameIDs[0]
        let probe = DecoderProbe(blockedFrameID: firstID)
        let pipeline = PreviewImagePipeline(
            maximumConcurrentDecodes: 1,
            decoder: { descriptor, maxPixelSize in
                try await probe.decode(descriptor, maxPixelSize)
            }
        )
        let active = request(firstID, priority: .card, pipeline: pipeline, store: fixture.store)
        try await waitForStartedCount(1, probe: probe)
        let queued = request(
            fixture.frameIDs[1],
            priority: .card,
            pipeline: pipeline,
            store: fixture.store
        )
        try await waitForQueuedCount(1, pipeline: pipeline)

        let suspension = Task { await pipeline.suspendAndDrain() }
        try await waitForSuspended(pipeline)
        let activeDecodes = await pipeline.snapshot().activeDecodes
        XCTAssertEqual(activeDecodes, 1)
        do {
            _ = try await pipeline.image(
                frameID: fixture.frameIDs[1],
                store: fixture.store,
                maxPixelSize: 320,
                priority: .inspector
            )
            XCTFail("A suspended pipeline accepted new Store work")
        } catch is CancellationError {
            // Expected.
        }

        await probe.releaseBlocker()
        await suspension.value
        for task in [active, queued] {
            do {
                _ = try await task.value
                XCTFail("Suspension must cancel old-generation preview work")
            } catch is CancellationError {
                // Expected.
            }
        }
        let snapshot = await pipeline.snapshot()
        XCTAssertEqual(snapshot.activeRequests, 0)
        XCTAssertEqual(snapshot.activeDecodes, 0)
        await pipeline.resume()
        let resumed = await pipeline.snapshot().isAcceptingRequests
        XCTAssertTrue(resumed)
    }

    func testRetentionDuringDecodeCannotPublishPurgedPixels() async throws {
        let fixture = try makeFixture(frameCount: 1)
        defer { cleanup(fixture) }
        let frameID = fixture.frameIDs[0]
        let probe = DecoderProbe(blockedFrameID: frameID)
        let pipeline = PreviewImagePipeline(
            decoder: { descriptor, maxPixelSize in
                try await probe.decode(descriptor, maxPixelSize)
            }
        )
        let request = request(frameID, priority: .card, pipeline: pipeline, store: fixture.store)
        try await waitForStartedCount(1, probe: probe)

        let report = try RetentionService(
            policy: RetentionPolicy(retentionDays: 0, storageCapMB: 0)
        ).runDetailed(store: fixture.store)
        XCTAssertEqual(report.purgedStillCount, 1)
        await probe.releaseBlocker()

        do {
            _ = try await request.value
            XCTFail("Pixels removed by retention must not be published")
        } catch let error as PreviewImagePipelineError {
            XCTAssertEqual(error, .mediaUnavailable)
        }
    }

    private func request(
        _ frameID: Int64,
        priority: PreviewImagePriority,
        pipeline: PreviewImagePipeline,
        store: Store
    ) -> Task<CGImage, Error> {
        Task {
            try await pipeline.image(
                frameID: frameID,
                store: store,
                maxPixelSize: 320,
                priority: priority
            )
        }
    }

    private func waitForStartedCount(_ count: Int, probe: DecoderProbe) async throws {
        for _ in 0..<100 {
            if await probe.started.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for decoder work to start")
    }

    private func waitForQueuedCount(
        _ count: Int,
        pipeline: PreviewImagePipeline
    ) async throws {
        for _ in 0..<100 {
            if await pipeline.snapshot().queuedRequests >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for queued preview work")
    }

    private func waitForActiveRequestCount(
        _ count: Int,
        pipeline: PreviewImagePipeline
    ) async throws {
        for _ in 0..<100 {
            if await pipeline.snapshot().activeRequests >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for active preview requests")
    }

    private func waitForSuspended(_ pipeline: PreviewImagePipeline) async throws {
        for _ in 0..<100 {
            if await !pipeline.snapshot().isAcceptingRequests { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for preview suspension")
    }

    private func makeFixture(frameCount: Int) throws -> (root: URL, store: Store, frameIDs: [Int64]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-pipeline-\(UUID().uuidString)", isDirectory: true)
        let store = try Store(root: root)
        let frameIDs = try (0..<frameCount).map { index in
            try store.insertSeedFrame(
                timestampMs: 10_000 + Int64(index),
                foreground: "preview \(index)"
            )
        }
        return (root, store, frameIDs)
    }

    private func cleanup(_ fixture: (root: URL, store: Store, frameIDs: [Int64])) {
        try? fixture.store.withSerializedMutation {
            try fixture.store.db.close()
        }
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func makePNG(gray: UInt8) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 64,
                height: 64,
                bitsPerComponent: 8,
                bytesPerRow: 64 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let component = CGFloat(gray) / 255
        context.setFillColor(red: component, green: component, blue: component, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
