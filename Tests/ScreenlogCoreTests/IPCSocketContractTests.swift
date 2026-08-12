import Foundation
import XCTest

@testable import ScreenlogCore

final class IPCSocketContractTests: XCTestCase {
    private var root: URL!
    private var preferences: UserDefaults!
    private var preferenceSuiteName: String!
    private var host: ScreenlogSocketHost!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: "/tmp/screenlog-ipc-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        preferenceSuiteName = "screenlog.ipc.preferences.\(UUID().uuidString)"
        preferences = try XCTUnwrap(UserDefaults(suiteName: preferenceSuiteName))
        preferences.removePersistentDomain(forName: preferenceSuiteName)
        host = ScreenlogSocketHost(preferences: preferences)
        try host.start(store: Store(root: root), root: root)
    }

    override func tearDownWithError() throws {
        host.stop()
        try? FileManager.default.removeItem(at: root)
        preferences.removePersistentDomain(forName: preferenceSuiteName)
        host = nil
        root = nil
        preferences = nil
        preferenceSuiteName = nil
        try super.tearDownWithError()
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
                try client.call(IPCRequest(id: "denied-\(command.rawValue)", cmd: command)),
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
