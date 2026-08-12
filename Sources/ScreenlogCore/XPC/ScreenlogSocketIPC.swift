import Darwin
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.screenlog", category: "socket-ipc")

// MARK: - Wire protocol (length-prefixed JSON)

/// Request opcodes for CLI  and  app. App owns SQLite; CLI never opens the DB.
public enum IPCCommand: String, Codable, CaseIterable, Hashable, Sendable {
    case ping
    case status
    case startRecording
    case stopRecording
    case captureOnce
    case fts
    case stats
    case topApplications
    case topDomains
    case sessions
    case sample
    case frame
    case frameAt
    case ocrBoxes
    case listApplications
    case listDomains
    case axTree
    case extractImage
    case compact
    case retention
    case permissions
    case unsupported = "__unsupported__"

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = IPCCommand(rawValue: value) ?? .unsupported
    }
}

/// Capabilities available through Screenlogger's local command bridge.
///
/// Read and export operations are available whenever the bridge is enabled.
/// Capture control and Library maintenance require a separate, explicit user
/// opt-in. Keeping this mapping exhaustive makes new IPC commands choose a
/// capability before they can ship.
public enum LocalToolCapability: String, Codable, CaseIterable, Sendable {
    case inspectStatus
    case readLibrary
    case exportSnapshot
    case controlCapture
    case maintainLibrary
    case unsupported

    public var changesScreenloggerState: Bool {
        switch self {
        case .controlCapture, .maintainLibrary: return true
        case .inspectStatus, .readLibrary, .exportSnapshot, .unsupported: return false
        }
    }
}

extension IPCCommand {
    public var requiredLocalToolCapability: LocalToolCapability {
        switch self {
        case .ping, .status, .stats, .permissions:
            return .inspectStatus
        case .fts, .topApplications, .topDomains, .sessions, .sample, .frame,
            .frameAt, .ocrBoxes, .listApplications, .listDomains, .axTree:
            return .readLibrary
        case .extractImage:
            return .exportSnapshot
        case .startRecording, .stopRecording, .captureOnce:
            return .controlCapture
        case .compact, .retention:
            return .maintainLibrary
        case .unsupported:
            return .unsupported
        }
    }
}

/// Stable authorization failure shared by Unix-socket and XPC transports.
public enum LocalToolAccessError: Error, LocalizedError, Equatable, Sendable {
    case mutationAccessRequired

    public var errorDescription: String? {
        switch self {
        case .mutationAccessRequired:
            return
                "Screenlogger local tool access is read-only. In Settings > Integrations, turn on Allow capture control and maintenance, then try again."
        }
    }
}

/// Server-side policy for requests arriving through the local command bridge.
public struct LocalToolAccessPolicy: Sendable {
    public let allowsCaptureControlAndMaintenance: Bool

    public init(allowsCaptureControlAndMaintenance: Bool) {
        self.allowsCaptureControlAndMaintenance = allowsCaptureControlAndMaintenance
    }

    public init(preferences: UserDefaults = ScreenlogProcessPreferences.current) {
        self.init(
            allowsCaptureControlAndMaintenance:
                LocalToolControlAccessPreference
                .isEnabled(in: preferences)
        )
    }

    public func authorize(_ command: IPCCommand) throws {
        guard command.requiredLocalToolCapability.changesScreenloggerState else {
            return
        }
        guard allowsCaptureControlAndMaintenance else {
            throw LocalToolAccessError.mutationAccessRequired
        }
    }
}

/// Versioned contract for the local CLI  and  app wire format.
///
/// Product versions can differ without breaking automation. This version changes only when the
/// request/response envelope or command semantics become incompatible. Peers advertise a range on
/// every request so a rolling app/CLI upgrade either selects a shared version or fails explicitly.
public enum ScreenlogIPCProtocol {
    public static let minimumSupportedVersion = 1
    public static let maximumSupportedVersion = 1

    static func negotiatedVersion(
        peerMinimum: Int, peerMaximum: Int, serverMinimum: Int = minimumSupportedVersion, serverMaximum: Int = maximumSupportedVersion
    ) -> Int? {
        guard peerMinimum > 0, peerMaximum >= peerMinimum, serverMinimum > 0, serverMaximum >= serverMinimum else { return nil }
        let lower = max(serverMinimum, peerMinimum)
        let upper = min(serverMaximum, peerMaximum)
        return lower <= upper ? upper : nil
    }
}

public struct IPCRequest: Codable, Sendable {
    public var id: String
    public var cmd: IPCCommand
    public var protocolMinimumVersion: Int?
    public var protocolMaximumVersion: Int?
    public var clientVersion: String?
    public var query: String?
    public var searchContent: LibrarySearchContent?
    public var limit: Int?
    public var minSegLen: Int?
    public var gapMinutes: Int?
    public var frameID: Int64?
    public var timestampMs: Int64?
    public var outPath: String?
    public var preferBase64: Bool?

    public init(
        id: String = UUID().uuidString, cmd: IPCCommand, protocolMinimumVersion: Int? = ScreenlogIPCProtocol.minimumSupportedVersion,
        protocolMaximumVersion: Int? = ScreenlogIPCProtocol.maximumSupportedVersion, clientVersion: String? = ScreenlogCore.version,
        query: String? = nil,
        searchContent: LibrarySearchContent? = nil,
        limit: Int? = nil, minSegLen: Int? = nil, gapMinutes: Int? = nil, frameID: Int64? = nil, timestampMs: Int64? = nil,
        outPath: String? = nil,
        preferBase64: Bool? = nil
    ) {
        self.id = id
        self.cmd = cmd
        self.protocolMinimumVersion = protocolMinimumVersion
        self.protocolMaximumVersion = protocolMaximumVersion
        self.clientVersion = clientVersion
        self.query = query
        self.searchContent = searchContent
        self.limit = limit
        self.minSegLen = minSegLen
        self.gapMinutes = gapMinutes
        self.frameID = frameID
        self.timestampMs = timestampMs
        self.outPath = outPath
        self.preferBase64 = preferBase64
    }
}

enum IPCRequestLimits {
    static let maximumIdentifierBytes = 128
    static let maximumQueryBytes = 4 * 1024
    static let maximumPathBytes = 4 * 1024
    static let resultLimit = 1...500
    static let minimumSegmentLength = 1...10_000
    static let sessionGapMinutes = 1...10_080
    static let maximumRequestFrameBytes = 1024 * 1024
    static let maximumResponseFrameBytes = 32 * 1024 * 1024
}

enum IPCRequestValidationError: Error, LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return "invalid IPC request: \(message)"
        }
    }
}

extension IPCRequest {
    /// Validate untrusted local socket input before it reaches capture or storage code.
    func validate() throws {
        guard !id.isEmpty, id.utf8.count <= IPCRequestLimits.maximumIdentifierBytes else {
            throw IPCRequestValidationError.invalid("request id is empty or too long")
        }

        if let minimum = protocolMinimumVersion, let maximum = protocolMaximumVersion, minimum < 1 || maximum < minimum {
            throw IPCRequestValidationError.invalid("protocol version range is invalid")
        }
        if let clientVersion, clientVersion.isEmpty || clientVersion.utf8.count > IPCRequestLimits.maximumIdentifierBytes {
            throw IPCRequestValidationError.invalid("client version is empty or too long")
        }

        if let query, query.utf8.count > IPCRequestLimits.maximumQueryBytes {
            throw IPCRequestValidationError.invalid("query exceeds 4096 bytes")
        }
        if let outPath, outPath.utf8.count > IPCRequestLimits.maximumPathBytes {
            throw IPCRequestValidationError.invalid("output path exceeds 4096 bytes")
        }

        switch cmd {
        case .fts, .topApplications, .topDomains, .sample:
            if let limit, !IPCRequestLimits.resultLimit.contains(limit) {
                throw IPCRequestValidationError.invalid("limit must be between 1 and 500")
            }
        default: break
        }

        if cmd == .sample, let minSegLen, !IPCRequestLimits.minimumSegmentLength.contains(minSegLen) {
            throw IPCRequestValidationError.invalid("minimum segment length must be between 1 and 10000")
        }
        if cmd == .sessions, let gapMinutes, !IPCRequestLimits.sessionGapMinutes.contains(gapMinutes) {
            throw IPCRequestValidationError.invalid("session gap must be between 1 and 10080 minutes")
        }

        switch cmd {
        case .frame, .ocrBoxes, .axTree:
            guard let frameID, frameID > 0 else { throw IPCRequestValidationError.invalid("a positive frame id is required") }
        case .extractImage:
            let hasFrameID = (frameID ?? 0) > 0
            guard hasFrameID || timestampMs != nil else {
                throw IPCRequestValidationError.invalid("a positive frame id or timestamp is required")
            }
        default: break
        }
    }
}

public enum IPCResponseErrorCode: String, Codable, Sendable {
    case incompatibleProtocol = "incompatible_protocol"
    case capabilityDenied = "capability_denied"
}

public struct IPCResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var protocolVersion: Int?
    public var protocolMinimumVersion: Int?
    public var protocolMaximumVersion: Int?
    public var serverVersion: String?
    /// Kept as a string so a peer can add error codes without making an older decoder fail.
    public var errorCode: String?
    public var error: String?
    public var string: String?
    public var intValue: Int64?
    public var data: Data?
    public var boolMap: [String: Bool]?

    public static func ok(
        id: String, protocolVersion: Int = ScreenlogIPCProtocol.maximumSupportedVersion, string: String? = nil, intValue: Int64? = nil,
        data: Data? = nil,
        boolMap: [String: Bool]? = nil
    ) -> IPCResponse {
        IPCResponse(
            id: id, ok: true, protocolVersion: protocolVersion, protocolMinimumVersion: ScreenlogIPCProtocol.minimumSupportedVersion,
            protocolMaximumVersion: ScreenlogIPCProtocol.maximumSupportedVersion, serverVersion: ScreenlogCore.version, errorCode: nil,
            error: nil,
            string: string, intValue: intValue, data: data, boolMap: boolMap)
    }

    public static func fail(
        id: String, _ error: String, errorCode: IPCResponseErrorCode? = nil,
        protocolVersion: Int? = ScreenlogIPCProtocol.maximumSupportedVersion
    ) -> IPCResponse {
        IPCResponse(
            id: id, ok: false, protocolVersion: protocolVersion, protocolMinimumVersion: ScreenlogIPCProtocol.minimumSupportedVersion,
            protocolMaximumVersion: ScreenlogIPCProtocol.maximumSupportedVersion, serverVersion: ScreenlogCore.version,
            errorCode: errorCode?.rawValue,
            error: error, string: nil, intValue: nil, data: nil, boolMap: nil)
    }

    func finalized(
        protocolVersion: Int, serverMinimum: Int = ScreenlogIPCProtocol.minimumSupportedVersion,
        serverMaximum: Int = ScreenlogIPCProtocol.maximumSupportedVersion
    ) -> IPCResponse {
        var response = self
        response.protocolVersion = protocolVersion
        response.protocolMinimumVersion = serverMinimum
        response.protocolMaximumVersion = serverMaximum
        response.serverVersion = ScreenlogCore.version
        return response
    }
}

// MARK: - Framing

enum IPCFrame {
    /// 4-byte big-endian length + UTF-8 JSON body.
    static func encode(_ object: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(object)
        var len = UInt32(body.count).bigEndian
        var out = Data(bytes: &len, count: 4)
        out.append(body)
        return out
    }

    static func decodeResponse(from data: Data) throws -> IPCResponse { try JSONDecoder().decode(IPCResponse.self, from: data) }

    static func decodeRequest(from data: Data) throws -> IPCRequest { try JSONDecoder().decode(IPCRequest.self, from: data) }
}

// MARK: - Socket path

public enum ScreenlogSocketPaths {
    public static func socketURL(root: URL) -> URL { root.appendingPathComponent("cli.sock", isDirectory: false) }
}

// MARK: - Host (app-side)

/// App-side IPC server over a Unix domain socket.
/// Used because modern macOS forbids archiving `NSXPCListenerEndpoint` with `NSKeyedArchiver`
/// ("may only be encoded by an NSXPCCoder"). Protocol semantics match XPC daemon methods.
public final class ScreenlogSocketHost: @unchecked Sendable {
    public static let shared = ScreenlogSocketHost()

    private let queue = DispatchQueue(label: "dev.screenlog.socket-host", qos: .userInitiated)
    private let queueSpecificKey = DispatchSpecificKey<Void>()
    private var store: Store?
    private var root: URL?
    private let preferences: UserDefaults
    public private(set) var isRunning = false

    init(preferences: UserDefaults = ScreenlogProcessPreferences.current) {
        self.preferences = preferences
        queue.setSpecific(key: queueSpecificKey, value: ())
    }

    public func start(store: Store, root: URL) throws {
        stop()
        self.store = store
        self.root = root
        try ScreenlogPaths.ensureDirectories(root: root)

        let sockURL = ScreenlogSocketPaths.socketURL(root: root)
        try? FileManager.default.removeItem(at: sockURL)
        try startBSD(store: store, socketPath: sockURL.path)
    }

    public func stop() {
        isRunning = false
        if let root { try? FileManager.default.removeItem(at: ScreenlogSocketPaths.socketURL(root: root)) }
        bsdStop()
        // `acceptOne` performs each accepted request on this serial queue. A
        // synchronous barrier makes the ordinary restart path release the old
        // Store before `start` publishes a replacement one.
        let releaseStore = {
            self.store = nil
            self.root = nil
        }
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            releaseStore()
        } else {
            queue.sync(execute: releaseStore)
        }
    }

    /// Stop accepting clients, finish every request already serialized on the
    /// host queue, and release Store before its SQLite connection is closed.
    public func stopAndDrain() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.isRunning = false
                if let root = self.root {
                    try? FileManager.default.removeItem(at: ScreenlogSocketPaths.socketURL(root: root))
                }
                self.bsdStop()
                self.store = nil
                self.root = nil
                continuation.resume()
            }
        }
    }

    // MARK: BSD AF_UNIX (reliable for local CLI)

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    private func startBSD(store: Store, socketPath: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socketCreate }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw IPCError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { cptr in for (i, b) in pathBytes.enumerated() { cptr[i] = b }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in bind(fd, sockPtr, addrLen) }
        }
        guard bindResult == 0 else {
            close(fd)
            throw IPCError.bind(errno)
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw IPCError.listen(errno)
        }

        // Restrict local activity history access to the current user.
        do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socketPath) } catch {
            close(fd)
            try? FileManager.default.removeItem(atPath: socketPath)
            throw error
        }

        serverFD = fd
        isRunning = true
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()
        log.info("socket IPC listening at \(socketPath, privacy: .private(mask: .hash))")
    }

    private func bsdStop() {
        if let acceptSource { acceptSource.cancel() } else if serverFD >= 0 { close(serverFD) }
        acceptSource = nil
        serverFD = -1
    }

    private func acceptOne() {
        let client = accept(serverFD, nil, nil)
        guard client >= 0 else { return }
        // The DispatchSource invokes this method on `queue`; keep request work
        // in that same block. Enqueuing a second block here would let a drain
        // barrier overtake a just-accepted request.
        defer { close(client) }
        do {
            var noSigPipe: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var clientTimeout = timeval(tv_sec: 10, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &clientTimeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &clientTimeout, socklen_t(MemoryLayout<timeval>.size))
            let reqData = try Self.readFrame(fd: client, maximumBytes: IPCRequestLimits.maximumRequestFrameBytes)
            let req = try IPCFrame.decodeRequest(from: reqData)
            let resp = handle(req)
            let out = try IPCFrame.encode(resp)
            try Self.writeAll(fd: client, data: out)
        } catch { log.error("socket client error: \(error.localizedDescription)") }
    }

    static func readFrame(fd: Int32, maximumBytes: Int) throws -> Data {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        try readExact(fd: fd, buffer: &lenBuf)
        let len = Int(UInt32(bigEndian: lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard len > 0, len <= maximumBytes else { throw IPCError.badFrame }
        var body = [UInt8](repeating: 0, count: len)
        try readExact(fd: fd, buffer: &body)
        return Data(body)
    }

    private static func readExact(fd: Int32, buffer: inout [UInt8]) throws {
        var offset = 0
        let total = buffer.count
        while offset < total {
            let n: Int = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return read(fd, base.advanced(by: offset), total - offset)
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { throw XPCClientError.timeout }
            if n <= 0 { throw IPCError.read }
            offset += n
        }
    }

    static func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        let total = data.count
        while offset < total {
            let n: Int = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base.advanced(by: offset), total - offset)
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { throw XPCClientError.timeout }
            if n <= 0 { throw IPCError.write }
            offset += n
        }
    }

    // MARK: - Dispatch

    private func handle(_ req: IPCRequest) -> IPCResponse {
        guard let peerMinimum = req.protocolMinimumVersion, let peerMaximum = req.protocolMaximumVersion else {
            return .fail(
                id: req.id, "incompatible IPC protocol: client did not declare a supported protocol range; update the Screenlogger CLI",
                errorCode: .incompatibleProtocol, protocolVersion: nil)
        }
        guard let negotiatedVersion = ScreenlogIPCProtocol.negotiatedVersion(peerMinimum: peerMinimum, peerMaximum: peerMaximum) else {
            return .fail(
                id: req.id,
                "incompatible IPC protocol: client supports \(peerMinimum)...\(peerMaximum); Screenlogger supports \(ScreenlogIPCProtocol.minimumSupportedVersion)...\(ScreenlogIPCProtocol.maximumSupportedVersion)",
                errorCode: .incompatibleProtocol, protocolVersion: nil)
        }

        do {
            try req.validate()
            do {
                try LocalToolAccessPolicy(preferences: preferences).authorize(req.cmd)
            } catch let error as LocalToolAccessError {
                return .fail(
                    id: req.id,
                    error.localizedDescription,
                    errorCode: .capabilityDenied
                ).finalized(protocolVersion: negotiatedVersion)
            }
            let response: IPCResponse = try { () throws -> IPCResponse in
                switch req.cmd {
                case .ping: return .ok(id: req.id, protocolVersion: negotiatedVersion, string: "pong \(ScreenlogCore.version)")
                case .status:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    let sem = DispatchSemaphore(value: 0)
                    var engineState: (recording: Bool, pauseReason: CapturePauseReason?)?
                    Task { @MainActor in
                        engineState = (
                            RecordingEngine.shared.isRecording,
                            RecordingEngine.shared.pauseReason
                        )
                        sem.signal()
                    }
                    guard sem.wait(timeout: .now() + 2) == .success, let engineState else {
                        return .fail(id: req.id, "recording status timed out")
                    }
                    let permissions = try awaitSync { await PermissionsSnapshot.current() }
                    let stats = try store.stats()
                    let status = DaemonStatus(
                        version: ScreenlogCore.version,
                        recording: engineState.recording,
                        pauseReason: engineState.pauseReason,
                        connections: 1,
                        totalFrames: stats.totalFrames,
                        unfinalizedFrames: stats.unfinalizedFrames,
                        minTimestampMs: stats.minTimestampMs,
                        maxTimestampMs: stats.maxTimestampMs,
                        screenRecording: permissions.screenRecording,
                        accessibility: permissions.accessibility,
                        dataRoot: root?.path ?? store.root.path
                    )
                    return .ok(id: req.id, data: try JSONEncoder().encode(status))
                case .startRecording:
                    let sem = DispatchSemaphore(value: 0)
                    var outcome: (recording: Bool, error: String?)?
                    Task { @MainActor in
                        RecordingEngine.shared.start()
                        outcome = (RecordingEngine.shared.isRecording, RecordingEngine.shared.lastError)
                        sem.signal()
                    }
                    guard sem.wait(timeout: .now() + 5) == .success, let outcome else {
                        return .fail(id: req.id, "start recording timed out")
                    }
                    guard outcome.recording else { return .fail(id: req.id, outcome.error ?? "recording did not start") }
                    TimedCapturePausePreference.clear(from: ScreenlogProcessPreferences.current)
                    CaptureIntentPreference.save(true, to: ScreenlogProcessPreferences.current)
                    return .ok(id: req.id, string: "started")
                case .stopRecording:
                    let sem = DispatchSemaphore(value: 0)
                    var stopped = false
                    Task { @MainActor in
                        RecordingEngine.shared.stop()
                        stopped = !RecordingEngine.shared.isRecording
                        sem.signal()
                    }
                    guard sem.wait(timeout: .now() + 5) == .success, stopped else { return .fail(id: req.id, "stop recording timed out") }
                    TimedCapturePausePreference.clear(from: ScreenlogProcessPreferences.current)
                    CaptureIntentPreference.save(false, to: ScreenlogProcessPreferences.current)
                    return .ok(id: req.id, string: "stopped")
                case .captureOnce:
                    let id: Int64 = try awaitSync { try await RecordingEngine.shared.captureOneNow() }
                    return .ok(id: req.id, intValue: id)
                case .fts:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    let data = try JSONEncoder().encode(
                        try store.searchLibrary(
                            query: LibrarySearchQuery(
                                text: req.query ?? "",
                                content: req.searchContent ?? .all
                            ),
                            limit: req.limit ?? 50
                        )
                    )
                    return .ok(id: req.id, data: data)
                case .stats:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    return .ok(id: req.id, data: try JSONEncoder().encode(try store.stats()))
                case .topApplications:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    return .ok(id: req.id, data: try JSONEncoder().encode(try store.topApplications(limit: req.limit ?? 20)))
                case .topDomains:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    return .ok(id: req.id, data: try JSONEncoder().encode(try store.topDomains(limit: req.limit ?? 20)))
                case .sessions:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    let gap = Int64(max(1, req.gapMinutes ?? 5)) * 60_000
                    return .ok(id: req.id, data: try JSONEncoder().encode(try store.sessions(gapMs: gap)))
                case .sample:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    return .ok(
                        id: req.id,
                        data: try JSONEncoder().encode(try store.sampleFrames(limit: req.limit ?? 50, minSegLen: req.minSegLen ?? 1)))
                case .frame:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    guard let fid = req.frameID, let f = try store.frame(id: fid) else { return .fail(id: req.id, "not found") }
                    return .ok(id: req.id, data: try JSONEncoder().encode(f))
                case .frameAt:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    guard let ts = req.timestampMs, let f = try store.frameNearest(timestampMs: ts) else {
                        return .fail(id: req.id, "not found")
                    }
                    return .ok(id: req.id, data: try JSONEncoder().encode(f))
                case .ocrBoxes:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    guard let fid = req.frameID else { return .fail(id: req.id, "frameID required") }
                    return .ok(id: req.id, data: try JSONEncoder().encode(try store.ocrBoxes(frameID: fid)))
                case .listApplications:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    return .ok(id: req.id, data: try JSONEncoder().encode(try store.listApplications()))
                case .listDomains:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    return .ok(id: req.id, data: try JSONEncoder().encode(try store.listDomains()))
                case .axTree:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    guard let fid = req.frameID else { return .fail(id: req.id, "frameID required") }
                    let xml = try store.axTreeXML(frameID: fid) ?? ""
                    return .ok(id: req.id, string: xml)
                case .extractImage:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    let frame: FrameRow
                    if let fid = req.frameID, fid > 0 {
                        guard let f = try store.frame(id: fid) else { return .fail(id: req.id, "not found") }
                        frame = f
                    } else if let ts = req.timestampMs {
                        guard let f = try store.frameNearest(timestampMs: ts) else { return .fail(id: req.id, "not found") }
                        frame = f
                    } else {
                        return .fail(id: req.id, "frameID or timestampMs required")
                    }
                    let still = try awaitSync { try await FrameExtractor.stillData(forFrame: frame, store: store) }
                    var path: String?
                    let out = req.outPath ?? ""
                    if !out.isEmpty {
                        let dest = URL(fileURLWithPath: out)
                        let url = try awaitSync { try await FrameExtractor.writeStill(forFrame: frame, store: store, to: dest) }
                        path = url.path
                    } else if still.source == "still", let existing = frame.imagePath, FileManager.default.fileExists(atPath: existing) {
                        path = existing
                    } else {
                        let dir = (root ?? store.root).appendingPathComponent("exports", isDirectory: true)
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let url = dir.appendingPathComponent("frame_\(frame.id).\(still.fileExtension)")
                        try still.data.write(to: url, options: .atomic)
                        path = url.path
                    }
                    let result = ExtractImageResult(
                        frameID: frame.id, timestampMs: frame.timestampMs, path: path,
                        base64: (req.preferBase64 == true) ? still.data.base64EncodedString() : nil, fileExtension: still.fileExtension,
                        byteCount: still.data.count, source: still.source)
                    return .ok(id: req.id, data: try JSONEncoder().encode(result))
                case .compact:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    let n = try VideoCompactionService().compactIfNeeded(store: store)
                    return .ok(id: req.id, intValue: Int64(n))
                case .retention:
                    guard let store else { return .fail(id: req.id, "store unavailable") }
                    let report = try RetentionService().run(store: store)
                    return .ok(id: req.id, string: report)
                case .permissions:
                    let p = try awaitSync { await PermissionsSnapshot.current() }
                    return .ok(id: req.id, boolMap: ["screen_recording": p.screenRecording, "accessibility": p.accessibility])
                case .unsupported: return .fail(id: req.id, "unsupported IPC command")
                }
            }()
            return response.finalized(protocolVersion: negotiatedVersion)
        } catch { return .fail(id: req.id, error.localizedDescription).finalized(protocolVersion: negotiatedVersion) }
    }
}

// MARK: - Client (CLI-side)

public final class ScreenlogSocketClient: @unchecked Sendable {
    private let root: URL
    private let timeout: TimeInterval

    public init(root: URL = ScreenlogPaths.resolvedRoot(), timeout: TimeInterval = 30) {
        self.root = root
        self.timeout = timeout.isFinite && timeout > 0 ? min(max(timeout, 1), 300) : 30
    }

    public func call(_ req: IPCRequest) throws -> IPCResponse {
        try req.validate()
        let path = ScreenlogSocketPaths.socketURL(root: root).path
        guard FileManager.default.fileExists(atPath: path) else { throw XPCClientError.appNotRunning }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socketCreate }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw IPCError.pathTooLong }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { cptr in for (i, b) in pathBytes.enumerated() { cptr[i] = b }
            }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { throw XPCClientError.appNotRunning }

        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Optional timeout via SO_RCVTIMEO
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let out = try IPCFrame.encode(req)
        try ScreenlogSocketHost.writeAll(fd: fd, data: out)
        let body = try ScreenlogSocketHost.readFrame(fd: fd, maximumBytes: IPCRequestLimits.maximumResponseFrameBytes)
        let resp = try IPCFrame.decodeResponse(from: body)
        guard resp.id == req.id else { throw XPCClientError.remote("IPC response id did not match request") }
        try validateCompatibility(response: resp, request: req)
        if resp.errorCode == IPCResponseErrorCode.capabilityDenied.rawValue {
            throw XPCClientError.mutationAccessDenied
        }
        if !resp.ok { throw XPCClientError.remote(resp.error ?? "unknown error") }
        return resp
    }

    func validateCompatibility(response: IPCResponse, request: IPCRequest) throws {
        guard let serverMinimum = response.protocolMinimumVersion, let serverMaximum = response.protocolMaximumVersion, serverMinimum > 0,
            serverMaximum >= serverMinimum
        else {
            throw XPCClientError.incompatibleProtocol(
                "Screenlogger.app did not declare a valid IPC protocol range; update the app and CLI together")
        }

        if response.errorCode == IPCResponseErrorCode.incompatibleProtocol.rawValue {
            throw XPCClientError.incompatibleProtocol(response.error ?? "the app and CLI do not share a compatible IPC protocol version")
        }

        guard let clientMinimum = request.protocolMinimumVersion, let clientMaximum = request.protocolMaximumVersion, clientMinimum > 0,
            clientMaximum >= clientMinimum, let selected = response.protocolVersion, (clientMinimum...clientMaximum).contains(selected),
            (serverMinimum...serverMaximum).contains(selected)
        else { throw XPCClientError.incompatibleProtocol("invalid IPC negotiation response from Screenlogger.app") }
    }
}

// MARK: - Helpers

public enum IPCError: Error, LocalizedError {
    case socketCreate
    case pathTooLong
    case bind(Int32)
    case listen(Int32)
    case read
    case write
    case badFrame

    public var errorDescription: String? {
        switch self {
        case .socketCreate: return "socket create failed"
        case .pathTooLong: return "socket path too long"
        case .bind(let e): return "socket bind failed errno=\(e)"
        case .listen(let e): return "socket listen failed errno=\(e)"
        case .read: return "socket read failed"
        case .write: return "socket write failed"
        case .badFrame: return "invalid IPC frame"
        }
    }
}

private func awaitSync<T>(_ body: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try result.get()
}
