import Foundation
import OSLog

private let log = Logger(subsystem: "dev.screenlog", category: "xpc-client")

/// Thin CLI client: all commands go to the running app.
///
/// Transport (in order):
/// 1. **Unix domain socket** at `<data-root>/cli.sock` (default) - required on modern macOS
///    because `NSXPCListenerEndpoint` can no longer be archived with `NSKeyedArchiver`
///    ("may only be encoded by an NSXPCCoder").
/// 2. Optional **mach XPC** when `SCREENLOG_XPC_MACH=1` and a LaunchAgent registers the service.
///
/// The CLI never opens SQLite.
public final class ScreenlogXPCClient: NSObject, ScreenlogClientProtocol {
    private var connection: NSXPCConnection?
    private let root: URL
    private let timeout: TimeInterval
    private let socket: ScreenlogSocketClient

    public init(root: URL = ScreenlogPaths.resolvedRoot(), timeout: TimeInterval = 30) {
        self.root = root
        self.timeout = timeout
        self.socket = ScreenlogSocketClient(root: root, timeout: timeout)
        super.init()
    }

    public func xpcSurfaceEvent(jsonEvent: String) {
        // The event payload can contain OCR and application metadata.
        log.debug("received XPC event")
    }

    // MARK: - Public CLI API (socket-primary)

    public func ping() throws -> String {
        try require(socket.call(IPCRequest(cmd: .ping)).string)
    }

    public func status() throws -> DaemonStatus {
        try decode(socket.call(IPCRequest(cmd: .status)).data)
    }

    public func fts(
        query: String,
        limit: Int = 50,
        content: LibrarySearchContent = .all
    ) throws -> [FTSResult] {
        try decode(
            socket.call(
                IPCRequest(
                    cmd: .fts,
                    query: query,
                    searchContent: content,
                    limit: limit
                )
            ).data
        )
    }

    public func stats() throws -> RecordingStats {
        try decode(socket.call(IPCRequest(cmd: .stats)).data)
    }

    public func topApplications(limit: Int = 20) throws -> [UsageTopItem] {
        try decode(socket.call(IPCRequest(cmd: .topApplications, limit: limit)).data)
    }

    public func topDomains(limit: Int = 20) throws -> [UsageTopItem] {
        try decode(socket.call(IPCRequest(cmd: .topDomains, limit: limit)).data)
    }

    public func sessions(gapMinutes: Int = 5) throws -> [SessionRow] {
        try decode(socket.call(IPCRequest(cmd: .sessions, gapMinutes: gapMinutes)).data)
    }

    public func sample(limit: Int = 50, minSegLen: Int = 1) throws -> [FrameRow] {
        try decode(socket.call(IPCRequest(cmd: .sample, limit: limit, minSegLen: minSegLen)).data)
    }

    public func frame(id: Int64) throws -> FrameRow {
        try decode(socket.call(IPCRequest(cmd: .frame, frameID: id)).data)
    }

    public func frameAt(timestampMs: Int64) throws -> FrameRow {
        try decode(socket.call(IPCRequest(cmd: .frameAt, timestampMs: timestampMs)).data)
    }

    public func extractImage(
        frameID: Int64 = 0,
        timestampMs: Int64 = 0,
        outPath: String = "",
        preferBase64: Bool = false
    ) throws -> ExtractImageResult {
        let client = ScreenlogSocketClient(root: root, timeout: max(timeout, 120))
        return try decode(
            client.call(
                IPCRequest(
                    cmd: .extractImage,
                    frameID: frameID,
                    timestampMs: timestampMs,
                    outPath: outPath,
                    preferBase64: preferBase64
                )
            ).data
        )
    }

    public func ocrBoxes(frameID: Int64) throws -> [OCRBox] {
        try decode(socket.call(IPCRequest(cmd: .ocrBoxes, frameID: frameID)).data)
    }

    public func listApplications() throws -> [ApplicationRow] {
        try decode(socket.call(IPCRequest(cmd: .listApplications)).data)
    }

    public func listDomains() throws -> [DomainRow] {
        try decode(socket.call(IPCRequest(cmd: .listDomains)).data)
    }

    public func axTree(frameID: Int64) throws -> String {
        try require(socket.call(IPCRequest(cmd: .axTree, frameID: frameID)).string)
    }

    public func startRecording() throws {
        _ = try socket.call(IPCRequest(cmd: .startRecording))
    }

    public func stopRecording() throws {
        _ = try socket.call(IPCRequest(cmd: .stopRecording))
    }

    public func captureOnce() throws -> Int64 {
        try require(socket.call(IPCRequest(cmd: .captureOnce)).intValue)
    }

    public func compact() throws -> Int {
        Int(try require(socket.call(IPCRequest(cmd: .compact)).intValue))
    }

    public func retention() throws -> String {
        try require(socket.call(IPCRequest(cmd: .retention)).string)
    }

    public func permissions() throws -> [String: Bool] {
        try require(socket.call(IPCRequest(cmd: .permissions)).boolMap)
    }

    // MARK: - helpers

    private func decode<T: Decodable>(_ data: Data?) throws -> T {
        guard let data else { throw XPCClientError.empty }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw XPCClientError.empty }
        return value
    }
}

public enum XPCClientError: Error, CustomStringConvertible {
    case appNotRunning
    case badEndpoint
    case proxyFailed
    case empty
    case timeout
    case incompatibleProtocol(String)
    case mutationAccessDenied
    case remote(String)

    public var description: String {
        switch self {
        case .appNotRunning:
            return "could not connect to Screenlogger.app - is it running? (CLI is a thin IPC client; launch the app first)"
        case .badEndpoint:
            return "invalid IPC endpoint - restart Screenlogger.app"
        case .proxyFailed:
            return "failed to create IPC proxy"
        case .empty:
            return "empty response from Screenlogger.app"
        case .timeout:
            return "IPC request timed out - is Screenlogger.app responsive?"
        case .incompatibleProtocol:
            return "Screenlogger.app and the screenlog command are incompatible; update them together"
        case .mutationAccessDenied:
            return LocalToolAccessError.mutationAccessRequired.localizedDescription
        case .remote:
            // Remote failures can originate in capture/storage frameworks and
            // may contain Library paths or captured metadata. Keep CLI-facing
            // output stable and privacy-safe; typed command output carries the
            // actionable health state where available.
            return "Screenlogger could not complete the request"
        }
    }
}
