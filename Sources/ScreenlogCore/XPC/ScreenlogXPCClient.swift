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

    public func semanticStatus() throws -> SemanticFeatureStatus {
        try socket.semanticStatus()
    }

    public func semanticSearch(_ request: SemanticSearchRequest) throws -> SemanticSearchResponse {
        try socket.semanticSearch(request)
    }

    public func semanticControl(_ request: SemanticControlRequest) throws -> SemanticFeatureStatus {
        try socket.semanticControl(request)
    }

    public func fts(
        query: String,
        limit: Int = 50,
        content: LibrarySearchContent = .all,
        literal: Bool = false
    ) throws -> [FTSResult] {
        let parsed = SearchOperatorParser.parse(query)
        if let issue = parsed.validationIssue { throw SearchQueryValidationError.invalid(issue) }
        let usesStructuredOperators =
            parsed.appFilter != nil || parsed.siteFilter != nil
            || parsed.dayStartMs != nil || parsed.sinceMs != nil || parsed.beforeMs != nil
        return try decode(
            socket.call(
                IPCRequest(
                    cmd: .fts,
                    protocolMinimumVersion: literal || usesStructuredOperators
                        ? ScreenlogIPCProtocol.boundedActivityVersion
                        : ScreenlogIPCProtocol.minimumSupportedVersion,
                    query: query,
                    searchContent: content,
                    literalSearch: literal,
                    limit: limit
                )
            ).data
        )
    }

    public func stats(
        fromTimestampMs: Int64? = nil,
        toTimestampMs: Int64? = nil
    ) throws -> RecordingStats {
        try decode(
            socket.call(
                boundedActivityRequest(
                    cmd: .stats,
                    fromTimestampMs: fromTimestampMs,
                    toTimestampMs: toTimestampMs
                )
            ).data
        )
    }

    public func topApplications(
        limit: Int = 20,
        fromTimestampMs: Int64? = nil,
        toTimestampMs: Int64? = nil
    ) throws -> [UsageTopItem] {
        try decode(
            socket.call(
                boundedActivityRequest(
                    cmd: .topApplications,
                    limit: limit,
                    fromTimestampMs: fromTimestampMs,
                    toTimestampMs: toTimestampMs
                )
            ).data
        )
    }

    public func topDomains(
        limit: Int = 20,
        fromTimestampMs: Int64? = nil,
        toTimestampMs: Int64? = nil
    ) throws -> [UsageTopItem] {
        try decode(
            socket.call(
                boundedActivityRequest(
                    cmd: .topDomains,
                    limit: limit,
                    fromTimestampMs: fromTimestampMs,
                    toTimestampMs: toTimestampMs
                )
            ).data
        )
    }

    public func sessions(
        gapMinutes: Int = 5,
        fromTimestampMs: Int64? = nil,
        toTimestampMs: Int64? = nil
    ) throws -> [SessionRow] {
        try decode(
            socket.call(
                boundedActivityRequest(
                    cmd: .sessions,
                    gapMinutes: gapMinutes,
                    fromTimestampMs: fromTimestampMs,
                    toTimestampMs: toTimestampMs
                )
            ).data
        )
    }

    public func sample(
        limit: Int = 50,
        minSegLen: Int = 1,
        fromTimestampMs: Int64? = nil,
        toTimestampMs: Int64? = nil,
        order: ActivitySortOrder = .oldest
    ) throws -> [FrameRow] {
        try decode(
            socket.call(
                boundedActivityRequest(
                    cmd: .sample,
                    limit: limit,
                    minSegLen: minSegLen,
                    fromTimestampMs: fromTimestampMs,
                    toTimestampMs: toTimestampMs,
                    sortOrder: order
                )
            ).data
        )
    }

    public func recent(limit: Int = 20) throws -> [FrameRow] {
        try decode(
            socket.call(
                IPCRequest(
                    cmd: .recent,
                    protocolMinimumVersion: ScreenlogIPCProtocol.boundedActivityVersion,
                    limit: limit
                )
            ).data
        )
    }

    public func frame(id: Int64) throws -> FrameRow {
        try decode(socket.call(IPCRequest(cmd: .frame, frameID: id)).data)
    }

    public func frames(ids: [Int64]) throws -> [FrameRow] {
        try decode(
            socket.call(
                IPCRequest(
                    cmd: .frames,
                    protocolMinimumVersion: ScreenlogIPCProtocol.boundedActivityVersion,
                    frameIDs: ids
                )
            ).data
        )
    }

    public func context(frameID: Int64, before: Int = 3, after: Int = 3) throws
        -> [FrameRow]
    {
        try decode(
            socket.call(
                IPCRequest(
                    cmd: .context,
                    protocolMinimumVersion: ScreenlogIPCProtocol.boundedActivityVersion,
                    frameID: frameID,
                    contextBeforeCount: before,
                    contextAfterCount: after
                )
            ).data
        )
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
        // The app may have a different working directory. Resolve destinations
        // in the caller process, preserving an explicit directory suffix.
        let destination: String
        if outPath.isEmpty {
            destination = ""
        } else {
            guard !outPath.utf8.contains(0) else {
                throw IPCRequestValidationError.invalid("output path must contain no NUL bytes")
            }
            destination =
                URL(fileURLWithPath: outPath).absoluteURL.path
                + (outPath.hasSuffix("/") ? "/" : "")
        }
        return try decode(
            client.call(
                IPCRequest(
                    cmd: .extractImage,
                    frameID: frameID,
                    timestampMs: timestampMs,
                    outPath: destination,
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

    private func boundedActivityRequest(
        cmd: IPCCommand,
        limit: Int? = nil,
        minSegLen: Int? = nil,
        gapMinutes: Int? = nil,
        fromTimestampMs: Int64? = nil,
        toTimestampMs: Int64? = nil,
        sortOrder: ActivitySortOrder? = nil
    ) -> IPCRequest {
        let usesExtendedContract =
            fromTimestampMs != nil || toTimestampMs != nil || sortOrder != nil
        return IPCRequest(
            cmd: cmd,
            protocolMinimumVersion: usesExtendedContract
                ? ScreenlogIPCProtocol.boundedActivityVersion
                : ScreenlogIPCProtocol.minimumSupportedVersion,
            limit: limit,
            minSegLen: minSegLen,
            gapMinutes: gapMinutes,
            fromTimestampMs: fromTimestampMs,
            toTimestampMs: toTimestampMs,
            sortOrder: sortOrder
        )
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
            return "The CLI could not connect to Screenlogger.app. Open the app first. The CLI uses the app's local connection."
        case .badEndpoint:
            return "Invalid IPC endpoint. Restart Screenlogger.app."
        case .proxyFailed:
            return "The CLI could not create the IPC proxy."
        case .empty:
            return "Screenlogger.app returned an empty response."
        case .timeout:
            return "The IPC request did not complete within its time limit. Check whether Screenlogger.app responds."
        case .incompatibleProtocol:
            return "Screenlogger.app and the screenlog command are incompatible. Update both components."
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
