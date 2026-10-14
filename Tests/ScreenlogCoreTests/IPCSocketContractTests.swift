import Darwin
import Foundation
import XCTest

@testable import ScreenlogCore

final class IPCSocketContractTests: XCTestCase {
    private var root: URL!
    private var preferences: UserDefaults!
    private var preferenceSuiteName: String!
    private var host: ScreenlogSocketHost!
    private var store: Store!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: "/tmp/screenlog-ipc-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        preferenceSuiteName = "screenlog.ipc.preferences.\(UUID().uuidString)"
        preferences = try XCTUnwrap(UserDefaults(suiteName: preferenceSuiteName))
        preferences.removePersistentDomain(forName: preferenceSuiteName)
        host = ScreenlogSocketHost(preferences: preferences)
        store = try Store(root: root)
        try host.start(store: store, root: root)
    }

    override func tearDownWithError() throws {
        host.stop()
        try? FileManager.default.removeItem(at: root)
        preferences.removePersistentDomain(forName: preferenceSuiteName)
        host = nil
        store = nil
        root = nil
        preferences = nil
        preferenceSuiteName = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testHeldSemanticSearchesLeavePingExactStatusAndControlResponsive() async throws {
        let frameID = try store.insertSeedFrame(timestampMs: 1_000, foreground: "socketExactIdentifier")
        let entered = expectation(description: "bounded semantic searches entered")
        entered.expectedFulfillmentCount = ScreenlogSocketHost.maximumSemanticSearches
        let service = HeldSocketSemanticService(entered: entered)
        defer { service.release() }
        LocalToolControlAccessPreference.save(true, to: preferences)
        try host.start(store: store, root: root, semanticService: service)
        let client = ScreenlogSocketClient(root: root, timeout: 10)
        let searches = (0..<ScreenlogSocketHost.maximumSemanticSearches).map { _ in
            Task {
                try await withCheckedThrowingContinuation { continuation in
                    // Socket reads block. Keep them off Swift's cooperative pool,
                    // which can have fewer threads than the admitted searches.
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(
                            with: Result { try client.semanticSearch(SemanticSearchRequest(query: "held diagram")) })
                    }
                }
            }
        }
        await fulfillment(of: [entered], timeout: 2)

        let independent = ScreenlogSocketClient(root: root, timeout: 1)
        try await Task.detached {
            XCTAssertTrue(try independent.call(IPCRequest(cmd: .ping)).ok)
            let exact = try independent.call(IPCRequest(cmd: .fts, query: "socketExactIdentifier"))
            let hits = try JSONDecoder().decode([FTSResult].self, from: XCTUnwrap(exact.data))
            XCTAssertEqual(hits.map(\.frameID), [frameID])
            XCTAssertTrue(try independent.call(IPCRequest(cmd: .status)).ok)
            XCTAssertEqual(try independent.semanticStatus().phase, .ready)
            XCTAssertEqual(try independent.semanticControl(SemanticControlRequest(action: .pause)).phase, .paused)
            XCTAssertThrowsError(try independent.semanticSearch(SemanticSearchRequest(query: "over capacity"))) { error in
                guard case SemanticSearchError.unavailable = error else {
                    return XCTFail("Expected bounded search admission, got \(error)")
                }
            }
        }.value
        XCTAssertEqual(service.searchCount, ScreenlogSocketHost.maximumSemanticSearches)
        XCTAssertEqual(service.controlCount, 1)
        XCTAssertEqual(service.completedSearchCount, 0)
        service.release()
        for search in searches { _ = try await search.value }
        await host.stopAndDrain()
    }

    @MainActor
    func testStopOnMainActorStopsAdmissionWithoutWaitingAndDrainWaitsForSearch() async throws {
        let entered = expectation(description: "semantic search entered MainActor")
        let service = HeldSocketSemanticService(entered: entered)
        defer { service.release() }
        try host.start(store: store, root: root, semanticService: service)
        let client = ScreenlogSocketClient(root: root, timeout: 10)
        let search = Task.detached { try client.semanticSearch(SemanticSearchRequest(query: "held chart")) }
        await fulfillment(of: [entered], timeout: 2)

        // The service cannot finish until this MainActor releases it. stop()
        // must not synchronously join the worker that is waiting for that actor.
        host.stop()
        XCTAssertFalse(host.isRunning)
        XCTAssertThrowsError(try client.call(IPCRequest(cmd: .ping)))
        let earlyDrain = expectation(description: "drain must wait for the admitted search")
        earlyDrain.isInverted = true
        let socketHost = try XCTUnwrap(host)
        let drain = Task { @MainActor in
            await socketHost.stopAndDrain()
            if !service.isReleased { earlyDrain.fulfill() }
            XCTAssertEqual(service.completedSearchCount, 1)
        }
        await fulfillment(of: [earlyDrain], timeout: 0.1)
        service.release()
        _ = try await search.value
        await drain.value
        XCTAssertThrowsError(try client.call(IPCRequest(cmd: .ping)))
    }

    @MainActor
    func testPartialRequestsKeepTheirStoreRootAndServiceAcrossRestartAndDrain() async throws {
        let frameID = try store.insertSeedFrame(timestampMs: 1_000, foreground: "oldSocketGeneration")
        let oldService = HeldSocketSemanticService()
        try host.start(store: store, root: root, semanticService: oldService)
        let exactFD = try connectRawClient(root: root)
        defer { close(exactFD) }
        let statusFD = try connectRawClient(root: root)
        defer { close(statusFD) }
        let daemonFD = try connectRawClient(root: root)
        defer { close(daemonFD) }
        let exactFrame = try IPCFrame.encode(IPCRequest(cmd: .fts, query: "oldSocketGeneration"))
        let statusFrame = try IPCFrame.encode(IPCRequest(cmd: .semanticStatus, protocolMinimumVersion: 3))
        let daemonFrame = try IPCFrame.encode(IPCRequest(cmd: .status))
        try ScreenlogSocketHost.writeAll(fd: exactFD, data: Data(exactFrame.prefix(4)))
        try ScreenlogSocketHost.writeAll(fd: statusFD, data: Data(statusFrame.prefix(4)))
        try ScreenlogSocketHost.writeAll(fd: daemonFD, data: Data(daemonFrame.prefix(4)))
        // These connections precede ping in the listener backlog. A reply
        // proves their admission without requiring their request bodies to arrive.
        let oldClient = ScreenlogSocketClient(root: root, timeout: 1)
        let oldPing = try await Task.detached { try oldClient.call(IPCRequest(cmd: .ping)) }.value
        XCTAssertTrue(oldPing.ok)

        let replacementRoot = root.appendingPathComponent("replacement", isDirectory: true)
        let replacementStore = try Store(root: replacementRoot)
        _ = try replacementStore.insertSeedFrame(timestampMs: 2_000, foreground: "newSocketGeneration")
        try host.start(store: replacementStore, root: replacementRoot)
        let replacementClient = ScreenlogSocketClient(root: replacementRoot, timeout: 1)
        let replacement = try await Task.detached {
            try replacementClient.call(IPCRequest(cmd: .fts, query: "oldSocketGeneration"))
        }.value
        XCTAssertEqual(try JSONDecoder().decode([FTSResult].self, from: XCTUnwrap(replacement.data)).count, 0)

        host.stop()
        let earlyDrain = expectation(description: "retired partial requests must drain")
        earlyDrain.isInverted = true
        let progress = SocketDrainProgress()
        let socketHost = try XCTUnwrap(host)
        let drain = Task { @MainActor in
            await socketHost.stopAndDrain()
            if !progress.bodiesSent { earlyDrain.fulfill() }
        }
        await fulfillment(of: [earlyDrain], timeout: 0.1)
        progress.bodiesSent = true
        try ScreenlogSocketHost.writeAll(fd: exactFD, data: Data(exactFrame.dropFirst(4)))
        try ScreenlogSocketHost.writeAll(fd: statusFD, data: Data(statusFrame.dropFirst(4)))
        try ScreenlogSocketHost.writeAll(fd: daemonFD, data: Data(daemonFrame.dropFirst(4)))
        let responses = try await Task.detached {
            let exact = try IPCFrame.decodeResponse(
                from: ScreenlogSocketHost.readFrame(
                    fd: exactFD, maximumBytes: IPCRequestLimits.maximumResponseFrameBytes))
            let status = try IPCFrame.decodeResponse(
                from: ScreenlogSocketHost.readFrame(
                    fd: statusFD, maximumBytes: IPCRequestLimits.maximumResponseFrameBytes))
            let daemon = try IPCFrame.decodeResponse(
                from: ScreenlogSocketHost.readFrame(
                    fd: daemonFD, maximumBytes: IPCRequestLimits.maximumResponseFrameBytes))
            return (exact, status, daemon)
        }.value
        XCTAssertEqual(
            try JSONDecoder().decode([FTSResult].self, from: XCTUnwrap(responses.0.data)).map(\.frameID), [frameID])
        XCTAssertEqual(
            try JSONDecoder().decode(SemanticFeatureStatus.self, from: XCTUnwrap(responses.1.data)).phase, .ready)
        XCTAssertEqual(
            try JSONDecoder().decode(DaemonStatus.self, from: XCTUnwrap(responses.2.data)).dataRoot, root.path)
        await drain.value
        XCTAssertFalse(host.isRunning)
    }

    @MainActor
    func testDrainDoesNotStopOrWaitForALaterListenerGeneration() async throws {
        let oldEntered = expectation(description: "old search entered")
        let oldService = HeldSocketSemanticService(entered: oldEntered)
        defer { oldService.release() }
        try host.start(store: store, root: root, semanticService: oldService)
        let client = ScreenlogSocketClient(root: root, timeout: 10)
        let oldSearch = Task.detached { try client.semanticSearch(SemanticSearchRequest(query: "old search")) }
        await fulfillment(of: [oldEntered], timeout: 2)
        host.stop()
        let earlyDrain = expectation(description: "old generation remains held")
        earlyDrain.isInverted = true
        let drained = expectation(description: "old generation drained")
        let socketHost = try XCTUnwrap(host)
        let drain = Task { @MainActor in
            await socketHost.stopAndDrain()
            if !oldService.isReleased { earlyDrain.fulfill() }
            drained.fulfill()
        }
        await fulfillment(of: [earlyDrain], timeout: 0.1)

        let newEntered = expectation(description: "new search entered")
        let newService = HeldSocketSemanticService(entered: newEntered)
        defer { newService.release() }
        try host.start(store: store, root: root, semanticService: newService)
        let newSearch = Task.detached { try client.semanticSearch(SemanticSearchRequest(query: "new search")) }
        await fulfillment(of: [newEntered], timeout: 2)
        oldService.release()
        _ = try await oldSearch.value
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertTrue(host.isRunning)
        XCTAssertEqual(newService.completedSearchCount, 0)
        let ping = try await Task.detached { try client.call(IPCRequest(cmd: .ping)) }.value
        XCTAssertTrue(ping.ok)
        newService.release()
        _ = try await newSearch.value
        await drain.value
        await host.stopAndDrain()
    }

    func testWritingToADisconnectedSocketReturnsAnError() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        guard descriptors[0] >= 0, descriptors[1] >= 0 else { return }
        defer { close(descriptors[0]) }
        close(descriptors[1])
        // No process-wide SIGPIPE handler is installed. The shared host/client
        // write boundary must make this a normal error on this socket.
        XCTAssertThrowsError(try ScreenlogSocketHost.writeAll(fd: descriptors[0], data: Data([1])))
    }

    @MainActor
    func testDisconnectedSearchClientCannotTerminateHostDuringResponse() async throws {
        let entered = expectation(description: "search entered before disconnect")
        let service = HeldSocketSemanticService(entered: entered)
        defer { service.release() }
        try host.start(store: store, root: root, semanticService: service)
        let fd = try connectRawClient(root: root)
        let request = IPCRequest(
            cmd: .semanticSearch, protocolMinimumVersion: 3,
            semanticSearch: SemanticSearchRequest(query: "disconnect before reply"))
        do {
            try ScreenlogSocketHost.writeAll(fd: fd, data: IPCFrame.encode(request))
        } catch {
            close(fd)
            throw error
        }
        await fulfillment(of: [entered], timeout: 2)
        shutdown(fd, SHUT_RDWR)
        close(fd)
        service.release()
        await host.stopAndDrain()
        XCTAssertEqual(service.completedSearchCount, 1)
        try host.start(store: store, root: root)
        let client = ScreenlogSocketClient(root: root, timeout: 1)
        let ping = try await Task.detached { try client.call(IPCRequest(cmd: .ping)) }.value
        XCTAssertTrue(ping.ok)
        await host.stopAndDrain()
    }

    private func connectRawClient(root: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socketCreate }
        do {
            try ScreenlogSocketHost.setTimeout(fd: fd, seconds: 2)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = ScreenlogSocketPaths.socketURL(root: root).path.utf8CString
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw IPCError.pathTooLong }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: path.count) { bytes in
                    for (index, byte) in path.enumerated() { bytes[index] = byte }
                }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw XPCClientError.appNotRunning }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    func testSemanticDiscoveryDoesNotRequireMaintenanceOrChangeLibrary() throws {
        let frameID = try store.insertSeedFrame(timestampMs: 1_000, foreground: "exact identifier XYZ123")
        let client = ScreenlogXPCClient(root: root)
        let status = try client.semanticStatus()
        XCTAssertEqual(status.phase, .unsupported)
        XCTAssertFalse(status.enabled)
        XCTAssertFalse(status.modelInstalled)
        XCTAssertThrowsError(try client.semanticSearch(SemanticSearchRequest(query: "a diagram"))) { error in
            guard case SemanticSearchError.unavailable = error else {
                return XCTFail("Expected a typed unavailable error, got \(error)")
            }
        }
        XCTAssertEqual(try client.fts(query: "XYZ123").map(\.frameID), [frameID])
        XCTAssertEqual(try client.stats().totalFrames, 1)
    }

    func testEverySemanticControlRequiresMaintenanceBeforeServiceDispatch() throws {
        let client = ScreenlogXPCClient(root: root)
        for action in [SemanticControlAction.downloadModels, .enable, .disable, .pause, .resume, .indexNow, .removeIndex, .removeModels] {
            let mode: SemanticSearchMode? = action == .downloadModels || action == .enable ? .images : nil
            XCTAssertThrowsError(try client.semanticControl(SemanticControlRequest(action: action, mode: mode))) { error in
                guard case XPCClientError.mutationAccessDenied = error else {
                    return XCTFail("Expected maintenance denial for \(action), got \(error)")
                }
            }
        }
        LocalToolControlAccessPreference.save(true, to: preferences)
        for action in [SemanticControlAction.disable, .indexNow] {
            XCTAssertThrowsError(try client.semanticControl(SemanticControlRequest(action: action))) { error in
                guard case SemanticSearchError.unavailable = error else {
                    return XCTFail("Expected service dispatch after grant, got \(error)")
                }
            }
        }
    }

    func testSemanticCommandsCannotNegotiateOlderAppOrMasqueradeAsLegacyReads() throws {
        let client = ScreenlogSocketClient(root: root)
        let request = IPCRequest(cmd: .semanticStatus, protocolMinimumVersion: 3)
        let oldResponse = IPCResponse.ok(id: request.id).finalized(protocolVersion: 2, serverMaximum: 2)
        XCTAssertThrowsError(try client.validateCompatibility(response: oldResponse, request: request)) { error in
            guard case XPCClientError.incompatibleProtocol = error else { return XCTFail("Expected compatibility failure") }
        }
        XCTAssertNil(ScreenlogIPCProtocol.negotiatedVersion(peerMinimum: 3, peerMaximum: 3, serverMaximum: 2))
        for version in [1, 2] {
            let response = try client.call(IPCRequest(cmd: .stats, protocolMinimumVersion: version, protocolMaximumVersion: version))
            XCTAssertEqual(response.protocolVersion, version)
            XCTAssertThrowsError(try IPCRequest(cmd: .semanticStatus, protocolMinimumVersion: version).validate())
        }
        XCTAssertThrowsError(try IPCRequest(cmd: .status, semanticControl: SemanticControlRequest(action: .removeModels)).validate())
        XCTAssertThrowsError(try IPCRequest(cmd: .semanticStatus, protocolMinimumVersion: 3, query: "ignored").validate())
    }

    func testSemanticRequestBoundariesAndPayloadConflicts() throws {
        func validate(_ request: SemanticSearchRequest) throws {
            try IPCRequest(cmd: .semanticSearch, protocolMinimumVersion: 3, semanticSearch: request).validate()
        }
        for limit in [1, 500] {
            XCTAssertNoThrow(
                try validate(
                    SemanticSearchRequest(query: "chart app:Safari site:example.com since:2026-10-01", mode: .images, limit: limit)))
        }
        for limit in [0, 501] {
            XCTAssertThrowsError(try validate(SemanticSearchRequest(query: "chart", limit: limit)))
        }
        for query in [
            "", "   ", "app:Safari", String(repeating: "x", count: 4097), "chart\u{0}",
            "chart since:7d", "chart date:2026-02-30", "chart since:2030-01-01 before:2020-01-01",
        ] {
            XCTAssertThrowsError(try validate(SemanticSearchRequest(query: query)))
        }
        XCTAssertNoThrow(try validate(SemanticSearchRequest(query: String(repeating: "x", count: 4096))))
        XCTAssertThrowsError(try validate(SemanticSearchRequest(query: "chart", fromTimestampMs: 10, toTimestampMs: 10)))
        XCTAssertThrowsError(
            try IPCRequest(
                cmd: .semanticSearch, protocolMinimumVersion: 3,
                semanticSearch: SemanticSearchRequest(query: "chart"),
                semanticControl: SemanticControlRequest(action: .disable)
            ).validate())
        XCTAssertThrowsError(
            try IPCRequest(
                cmd: .semanticControl, protocolMinimumVersion: 3,
                semanticControl: SemanticControlRequest(action: .enable)
            ).validate())
        XCTAssertThrowsError(
            try IPCRequest(
                cmd: .semanticControl, protocolMinimumVersion: 3,
                semanticControl: SemanticControlRequest(action: .removeIndex, mode: .text)
            ).validate())
        XCTAssertThrowsError(
            try IPCRequest(
                cmd: .semanticControl, protocolMinimumVersion: 3,
                semanticControl: SemanticControlRequest(action: .resume, enableWhenReady: true)
            ).validate())
        XCTAssertNoThrow(
            try IPCRequest(
                cmd: .semanticControl, protocolMinimumVersion: 3,
                semanticControl: SemanticControlRequest(action: .indexNow)
            ).validate())
        XCTAssertThrowsError(
            try IPCRequest(
                cmd: .semanticControl, protocolMinimumVersion: 3,
                semanticControl: SemanticControlRequest(action: .indexNow, mode: .both)
            ).validate())
        XCTAssertThrowsError(
            try IPCRequest(
                cmd: .semanticControl, protocolMinimumVersion: 3,
                semanticControl: SemanticControlRequest(action: .indexNow, enableWhenReady: true)
            ).validate())
    }

    func testSemanticStatusRoundTripsIndexingPolicy() throws {
        XCTAssertEqual(SemanticFeatureStatus().indexingPolicy, .automatic)
        for policy in [SemanticIndexingPolicy.automatic, .manual] {
            let status = SemanticFeatureStatus(enabled: true, phase: .indexing, indexingPolicy: policy, modelInstalled: true)
            let data = try JSONEncoder().encode(status)
            XCTAssertEqual(try JSONDecoder().decode(SemanticFeatureStatus.self, from: data), status)
        }
    }

    func testRealHostAndClientNegotiateBeforeReturningPayload() throws {
        let client = ScreenlogSocketClient(root: root, timeout: 2)
        let response = try client.call(IPCRequest(id: "contract-success", cmd: .stats, clientVersion: "99.0.0"))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.protocolVersion, ScreenlogIPCProtocol.maximumSupportedVersion)
        XCTAssertEqual(response.protocolMinimumVersion, ScreenlogIPCProtocol.minimumSupportedVersion)
        XCTAssertEqual(response.protocolMaximumVersion, ScreenlogIPCProtocol.maximumSupportedVersion)
        XCTAssertEqual(response.serverVersion, ScreenlogCore.version)

        let payload = try XCTUnwrap(response.data)
        let stats = try JSONDecoder().decode(RecordingStats.self, from: payload)
        XCTAssertEqual(stats.totalFrames, 0)
    }

    func testProtocolTwoActivityBatchAndContextCommandsRoundTrip() throws {
        let first = try store.insertSeedFrame(
            timestampMs: 1_000,
            foreground: "release 0.1.13",
            bundleID: "dev.first"
        )
        let second = try store.insertSeedFrame(
            timestampMs: 2_000,
            foreground: "middle",
            bundleID: "dev.middle"
        )
        let third = try store.insertSeedFrame(
            timestampMs: 3_000,
            foreground: "last",
            bundleID: "dev.last"
        )
        let client = ScreenlogXPCClient(root: root)

        XCTAssertEqual(
            try client.stats(fromTimestampMs: 1_500, toTimestampMs: 3_000).momentCount,
            1
        )
        XCTAssertEqual(try client.frames(ids: [third, first]).map(\.id), [third, first])
        XCTAssertEqual(
            try client.context(frameID: second, before: 1, after: 1).map(\.id),
            [first, second, third]
        )
        XCTAssertEqual(
            try client.fts(query: "0.1.13", literal: true).map(\.frameID),
            [first]
        )
        XCTAssertEqual(try client.recent(limit: 2).map(\.id), [third, second])
    }

    func testImageClientResolvesRelativeDestinationsAndPreservesDirectoryIntent() throws {
        let source = root.appendingPathComponent("source.heic")
        let bytes = Data("synthetic retained still bytes".utf8)
        try bytes.write(to: source)
        let frameID = try store.insertSeedFrame(
            timestampMs: 1_000, foreground: "export fixture", imagePath: source.path
        )
        let client = ScreenlogXPCClient(root: root)
        // Reach the isolated root from the caller's working directory without
        // changing process-wide CWD (other tests may be running concurrently).
        let depth = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .pathComponents.filter { $0 != "/" }.count
        let relativeRoot =
            String(repeating: "../", count: depth)
            + root.path.dropFirst() + "/"
        for suffix in ["export.heic", "export.directory/"] {
            let result = try client.extractImage(
                frameID: frameID, outPath: relativeRoot + suffix
            )
            let destination = URL(fileURLWithPath: try XCTUnwrap(result.path))
                .standardizedFileURL
            let expected =
                suffix.hasSuffix("/")
                ? root.appendingPathComponent("export.directory/frame-\(frameID)-1000.heic")
                : root.appendingPathComponent("export.heic")
            XCTAssertEqual(destination.path, expected.standardizedFileURL.path)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
        }
    }

    func testNewerCLIThanAppFailsWithExplicitCompatibilityError() throws {
        let client = ScreenlogSocketClient(root: root, timeout: 2)
        let futureVersion = ScreenlogIPCProtocol.maximumSupportedVersion + 1

        XCTAssertThrowsError(
            try client.call(
                IPCRequest(
                    id: "future-client", cmd: .stats, protocolMinimumVersion: futureVersion, protocolMaximumVersion: futureVersion,
                    clientVersion: "99.0.0"))
        ) { error in
            guard case XPCClientError.incompatibleProtocol(let message) = error else {
                return XCTFail("expected compatibility error, got \(error)")
            }
            XCTAssertTrue(message.contains("client supports \(futureVersion)...\(futureVersion)"))
            XCTAssertTrue(message.contains("Screenlogger supports"))
        }
    }

    func testLegacyCLIWithoutProtocolDeclarationFailsClearly() throws {
        let client = ScreenlogSocketClient(root: root, timeout: 2)

        XCTAssertThrowsError(
            try client.call(
                IPCRequest(id: "legacy-client", cmd: .stats, protocolMinimumVersion: nil, protocolMaximumVersion: nil, clientVersion: nil))
        ) { error in
            guard case XPCClientError.incompatibleProtocol(let message) = error else {
                return XCTFail("expected compatibility error, got \(error)")
            }
            XCTAssertTrue(message.contains("did not declare a supported protocol range"))
        }
    }

    func testWireJSONUsesStableKeyOrdering() throws {
        let response = IPCResponse.ok(id: "stable-json", boolMap: ["screen_recording": true, "accessibility": false])
        let first = try IPCFrame.encode(response)
        let second = try IPCFrame.encode(response)

        XCTAssertEqual(first, second)
        let body = first.dropFirst(4)
        let json = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertLessThan(
            try XCTUnwrap(json.range(of: "accessibility")?.lowerBound), try XCTUnwrap(json.range(of: "screen_recording")?.lowerBound))
    }

    func testTranscriptSearchScopeRoundTripsOnTheWire() throws {
        let request = IPCRequest(
            id: "transcript-scope",
            cmd: .fts,
            query: "roadmap",
            searchContent: .transcripts,
            limit: 12
        )

        let encoded = try IPCFrame.encode(request)
        let decoded = try IPCFrame.decodeRequest(from: Data(encoded.dropFirst(4)))

        XCTAssertEqual(decoded.searchContent, .transcripts)
        XCTAssertEqual(decoded.query, "roadmap")
        XCTAssertEqual(decoded.limit, 12)
    }

    func testLegacyAppEnvelopeFailsBeforePayloadDecoding() throws {
        let legacyJSON = Data(#"{"id":"legacy-app","ok":true,"data":"bm90LXRoZS1leHBlY3RlZC1wYXlsb2Fk"}"#.utf8)
        let response = try JSONDecoder().decode(IPCResponse.self, from: legacyJSON)
        let client = ScreenlogSocketClient(root: root, timeout: 2)

        XCTAssertThrowsError(try client.validateCompatibility(response: response, request: IPCRequest(id: "legacy-app", cmd: .stats))) {
            error in
            guard case XPCClientError.incompatibleProtocol(let message) = error else {
                return XCTFail("expected compatibility error, got \(error)")
            }
            XCTAssertTrue(message.contains("did not declare a valid IPC protocol range"))
        }
    }

    func testNegotiationStampsLowerSelectedVersionOnNonPingResponse() throws {
        let selected = try XCTUnwrap(
            ScreenlogIPCProtocol.negotiatedVersion(peerMinimum: 1, peerMaximum: 1, serverMinimum: 1, serverMaximum: 2))
        let payload = try JSONEncoder().encode(
            RecordingStats(totalFrames: 0, minTimestampMs: nil, maxTimestampMs: nil, unfinalizedFrames: 0))
        let response = IPCResponse.ok(id: "stats-v1", data: payload).finalized(
            protocolVersion: selected, serverMinimum: 1, serverMaximum: 2)

        XCTAssertEqual(selected, 1)
        XCTAssertEqual(response.protocolVersion, 1)
        XCTAssertEqual(response.protocolMinimumVersion, 1)
        XCTAssertEqual(response.protocolMaximumVersion, 2)
        XCTAssertNotNil(response.data)
    }

    func testCapabilityClassificationIsExhaustiveAndMutationsAreExplicit() {
        let mutations: Set<IPCCommand> = [
            .startRecording,
            .stopRecording,
            .captureOnce,
            .compact,
            .retention,
            .semanticControl,
        ]

        XCTAssertEqual(
            Set(
                IPCCommand.allCases.filter {
                    $0.requiredLocalToolCapability.changesScreenloggerState
                }
            ),
            mutations
        )
        XCTAssertEqual(IPCCommand.extractImage.requiredLocalToolCapability, .exportSnapshot)

        let readOnlyPolicy = LocalToolAccessPolicy(
            allowsCaptureControlAndMaintenance: false
        )
        for command in IPCCommand.allCases
        where !command.requiredLocalToolCapability.changesScreenloggerState {
            XCTAssertNoThrow(try readOnlyPolicy.authorize(command))
        }
    }

    func testMutationAccessPreferenceDefaultsOffAndRoundTrips() {
        XCTAssertFalse(LocalToolControlAccessPreference.isEnabled(in: preferences))

        LocalToolControlAccessPreference.save(true, to: preferences)
        XCTAssertTrue(LocalToolControlAccessPreference.isEnabled(in: preferences))

        LocalToolControlAccessPreference.save(false, to: preferences)
        XCTAssertFalse(LocalToolControlAccessPreference.isEnabled(in: preferences))
    }

    func testSocketHostDeniesEveryMutationByDefaultWithTypedActionableError() throws {
        let client = ScreenlogSocketClient(root: root, timeout: 2)

        for command in IPCCommand.allCases where command.requiredLocalToolCapability.changesScreenloggerState {
            XCTAssertThrowsError(
                try client.call(
                    command == .semanticControl
                        ? IPCRequest(
                            id: "denied-semantic", cmd: .semanticControl, protocolMinimumVersion: 3,
                            semanticControl: SemanticControlRequest(action: .disable))
                        : IPCRequest(id: "denied-\(command.rawValue)", cmd: command)
                ),
                "expected \(command.rawValue) to require explicit mutation access"
            ) { error in
                guard case XPCClientError.mutationAccessDenied = error else {
                    return XCTFail("expected typed mutation denial for \(command.rawValue), got \(error)")
                }
                XCTAssertTrue(String(describing: error).contains("read-only"))
                XCTAssertTrue(
                    String(describing: error).contains(
                        "Allow capture control and maintenance"
                    )
                )
            }
        }
    }

    func testSocketHostReReadsOptInAndAllowsMaintenanceWithoutRestart() throws {
        let client = ScreenlogSocketClient(root: root, timeout: 2)
        XCTAssertThrowsError(try client.call(IPCRequest(cmd: .compact)))

        LocalToolControlAccessPreference.save(true, to: preferences)

        let response = try client.call(IPCRequest(cmd: .compact))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.intValue, 0)
    }

    func testLegacyXPCHostEnforcesSameReadOnlyBoundaryBeforeDispatch() throws {
        let xpcHost = ScreenlogXPCHost(preferences: preferences)
        let expected = try XCTUnwrap(LocalToolAccessError.mutationAccessRequired.errorDescription)

        let start = expectation(description: "start denied")
        xpcHost.xpcStartRecording { succeeded, error in
            XCTAssertFalse(succeeded)
            XCTAssertEqual(error, expected)
            start.fulfill()
        }

        let stop = expectation(description: "stop denied")
        xpcHost.xpcStopRecording { succeeded, error in
            XCTAssertFalse(succeeded)
            XCTAssertEqual(error, expected)
            stop.fulfill()
        }

        let capture = expectation(description: "capture once denied")
        xpcHost.xpcCaptureOnce { frameID, error in
            XCTAssertEqual(frameID, -1)
            XCTAssertEqual(error, expected)
            capture.fulfill()
        }

        let compact = expectation(description: "compact denied")
        xpcHost.xpcCompact { count, error in
            XCTAssertEqual(count, 0)
            XCTAssertEqual(error, expected)
            compact.fulfill()
        }

        let retention = expectation(description: "retention denied")
        xpcHost.xpcRunRetention { report, error in
            XCTAssertNil(report)
            XCTAssertEqual(error, expected)
            retention.fulfill()
        }

        wait(for: [start, stop, capture, compact, retention], timeout: 1)
    }
}

@MainActor
private final class SocketDrainProgress {
    var bodiesSent = false
}

@MainActor
private final class HeldSocketSemanticService: SemanticToolService {
    private let entered: XCTestExpectation?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isReleased = false
    private(set) var searchCount = 0
    private(set) var completedSearchCount = 0
    private(set) var controlCount = 0

    init(entered: XCTestExpectation? = nil) {
        self.entered = entered
    }

    func status() async -> SemanticFeatureStatus {
        SemanticFeatureStatus(enabled: true, phase: .ready, modelInstalled: true)
    }

    func search(_ request: SemanticSearchRequest) async throws -> SemanticSearchResponse {
        searchCount += 1
        entered?.fulfill()
        if !isReleased {
            await withCheckedContinuation { waiters.append($0) }
        }
        completedSearchCount += 1
        return SemanticSearchResponse(hits: [], status: await status())
    }

    func control(_ request: SemanticControlRequest) async throws -> SemanticFeatureStatus {
        controlCount += 1
        return SemanticFeatureStatus(enabled: true, phase: .paused, modelInstalled: true)
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
