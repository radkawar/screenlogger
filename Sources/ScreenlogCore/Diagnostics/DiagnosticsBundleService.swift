import Foundation

public struct DiagnosticsLogEntry: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable {
        case bootstrap
        case localStore
        case socketBridge
        case capture
        case dataRefresh
        case diagnosticsExport
    }

    public enum Outcome: String, Codable, Sendable {
        case started
        case succeeded
        case failed
        case stopped
        case retrying
    }

    public let timestamp: Date
    public let event: Event
    public let outcome: Outcome

    public init(timestamp: Date = Date(), event: Event, outcome: Outcome) {
        self.timestamp = timestamp
        self.event = event
        self.outcome = outcome
    }
}

/// A small, allowlisted JSON-lines log. Entries cannot carry free-form text,
/// paths, URLs, OCR, screenshot data, or user-entered values.
public final class StructuredDiagnosticsLog: @unchecked Sendable {
    public static let directoryName = "Diagnostics"
    public static let currentName = "events.jsonl"
    public static let previousName = "events.previous.jsonl"

    private let fileManager: FileManager
    private let directory: URL
    private let maximumBytes: Int
    private let lock = NSLock()

    public init(
        root: URL,
        maximumBytes: Int = 256 * 1_024,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        self.maximumBytes = max(1_024, maximumBytes)
        self.directory = root.appendingPathComponent(Self.directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func record(_ entry: DiagnosticsLogEntry) {
        lock.lock()
        defer { lock.unlock() }
        do {
            var data = try Self.encoder.encode(entry)
            data.append(0x0A)
            let current = directory.appendingPathComponent(Self.currentName)
            let size = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size + data.count > maximumBytes {
                let previous = directory.appendingPathComponent(Self.previousName)
                if fileManager.fileExists(atPath: previous.path) {
                    try fileManager.removeItem(at: previous)
                }
                if fileManager.fileExists(atPath: current.path) {
                    try fileManager.moveItem(at: current, to: previous)
                }
            }
            if !fileManager.fileExists(atPath: current.path) {
                try data.write(to: current, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: current)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
        } catch {
            // Diagnostics must never interrupt capture or application startup.
        }
    }

    public func entries(limit: Int = 2_000) -> [DiagnosticsLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let urls = [Self.previousName, Self.currentName].map {
            directory.appendingPathComponent($0)
        }
        var result: [DiagnosticsLogEntry] = []
        for url in urls where fileManager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), data.count <= maximumBytes else { continue }
            for line in data.split(separator: 0x0A) {
                guard line.count <= 4_096,
                    let entry = try? Self.decoder.decode(DiagnosticsLogEntry.self, from: Data(line))
                else { continue }
                result.append(entry)
            }
        }
        return Array(result.suffix(max(0, limit)))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public struct DiagnosticsSnapshot: Codable, Equatable, Sendable {
    public enum Health: String, Codable, Sendable { case healthy, attention, unavailable, unknown }
    public enum CaptureState: String, Codable, Sendable { case capturing, paused, off, unavailable }
    public enum NewestCaptureAge: String, Codable, Sendable {
        case none, withinHour, withinDay, withinWeek, older
    }

    public struct App: Codable, Equatable, Sendable {
        public let version: String
        public let build: String
        public let coreVersion: String

        public init(version: String, build: String, coreVersion: String) {
            self.version = version
            self.build = build
            self.coreVersion = coreVersion
        }
    }

    public struct System: Codable, Equatable, Sendable {
        public let operatingSystemVersion: String
        public let architecture: String

        public init(operatingSystemVersion: String, architecture: String) {
            self.operatingSystemVersion = operatingSystemVersion
            self.architecture = architecture
        }
    }

    public struct Library: Codable, Equatable, Sendable {
        public let health: Health
        public let frameCount: Int64
        public let unfinalizedFrameCount: Int64
        public let managedBytes: Int64
        public let newestCaptureAge: NewestCaptureAge

        public init(
            health: Health,
            frameCount: Int64,
            unfinalizedFrameCount: Int64,
            managedBytes: Int64,
            newestCaptureAge: NewestCaptureAge
        ) {
            self.health = health
            self.frameCount = max(0, frameCount)
            self.unfinalizedFrameCount = max(0, unfinalizedFrameCount)
            self.managedBytes = max(0, managedBytes)
            self.newestCaptureAge = newestCaptureAge
        }
    }

    public struct Capture: Codable, Equatable, Sendable {
        public let state: CaptureState
        public let pauseReason: String?
        public let screenRecordingPermission: Bool
        public let accessibilityPermission: Bool

        public init(
            state: CaptureState,
            pauseReason: String?,
            screenRecordingPermission: Bool,
            accessibilityPermission: Bool
        ) {
            self.state = state
            self.pauseReason = DiagnosticsSnapshot.safeToken(pauseReason)
            self.screenRecordingPermission = screenRecordingPermission
            self.accessibilityPermission = accessibilityPermission
        }
    }

    public let app: App
    public let system: System
    public let library: Library
    public let capture: Capture

    public init(app: App, system: System, library: Library, capture: Capture) {
        self.app = App(
            version: Self.safeToken(app.version) ?? "unknown",
            build: Self.safeToken(app.build) ?? "unknown",
            coreVersion: Self.safeToken(app.coreVersion) ?? "unknown"
        )
        self.system = System(
            operatingSystemVersion: Self.safeToken(system.operatingSystemVersion) ?? "unknown",
            architecture: Self.safeToken(system.architecture) ?? "unknown"
        )
        self.library = library
        self.capture = capture
    }

    private static func safeToken(_ value: String?) -> String? {
        guard let value, (1...64).contains(value.utf8.count) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+()-")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }
}

public struct DiagnosticsManifest: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let productIdentifier: String
    public let createdAt: Date
    public let app: DiagnosticsSnapshot.App
    public let system: DiagnosticsSnapshot.System
    public let library: DiagnosticsSnapshot.Library
    public let capture: DiagnosticsSnapshot.Capture
    public let structuredEventCount: Int
}

public struct DiagnosticsBundleResult: Equatable, Sendable {
    public let destination: URL
    public let manifest: DiagnosticsManifest
}

public enum DiagnosticsBundleError: Error, LocalizedError, Equatable, Sendable {
    case unsafeDestination
    case destinationExists
    case creationFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeDestination:
            return "Choose a location outside the live Screenlogger Library."
        case .destinationExists:
            return "A file or folder already exists there. Choose another name."
        case .creationFailed:
            return "Screenlogger could not create the diagnostics bundle. Try another location."
        }
    }
}

public enum DiagnosticsExportState: Equatable, Sendable {
    case idle
    case exporting
    case completed(URL)
    case failed(DiagnosticsBundleError)

    public var isExporting: Bool { self == .exporting }
}

/// Creates a bounded directory bundle from typed health data and allowlisted
/// structured events. Unified logs and bootstrap.log are deliberately excluded.
public final class DiagnosticsBundleService: @unchecked Sendable {
    public static let preferredExtension = "screenloggerdiagnostics"
    public static let manifestName = "manifest.json"
    public static let eventsName = "events.jsonl"
    public static let formatVersion = 1
    public static let productIdentifier = "dev.screenlog.diagnostics"
    public static let maximumEvents = 2_000

    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init() {
        fileManager = .default
        now = { Date() }
    }

    init(fileManager: FileManager = .default, now: @escaping @Sendable () -> Date) {
        self.fileManager = fileManager
        self.now = now
    }

    public func export(
        snapshot: DiagnosticsSnapshot,
        events: [DiagnosticsLogEntry],
        dataRoot: URL,
        to requestedDestination: URL
    ) throws -> DiagnosticsBundleResult {
        let destination = try validatedDestination(requestedDestination, dataRoot: dataRoot)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).exporting-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            let boundedEvents = Array(events.suffix(Self.maximumEvents))
            let manifest = DiagnosticsManifest(
                formatVersion: Self.formatVersion,
                productIdentifier: Self.productIdentifier,
                createdAt: now(),
                app: snapshot.app,
                system: snapshot.system,
                library: snapshot.library,
                capture: snapshot.capture,
                structuredEventCount: boundedEvents.count
            )
            try Self.prettyEncoder.encode(manifest).write(
                to: staging.appendingPathComponent(Self.manifestName),
                options: .atomic
            )
            let eventData = try boundedEvents.reduce(into: Data()) { output, entry in
                output.append(try Self.lineEncoder.encode(entry))
                output.append(0x0A)
            }
            try eventData.write(to: staging.appendingPathComponent(Self.eventsName), options: .atomic)
            try Self.readme.write(
                to: staging.appendingPathComponent("README.txt"),
                atomically: true,
                encoding: .utf8
            )
            try fileManager.moveItem(at: staging, to: destination)
            return DiagnosticsBundleResult(destination: destination, manifest: manifest)
        } catch let error as DiagnosticsBundleError {
            throw error
        } catch {
            throw DiagnosticsBundleError.creationFailed
        }
    }

    private func validatedDestination(_ requested: URL, dataRoot: URL) throws -> URL {
        guard !requested.lastPathComponent.isEmpty, requested.lastPathComponent != "." else {
            throw DiagnosticsBundleError.unsafeDestination
        }
        let parent = requested.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw DiagnosticsBundleError.unsafeDestination
        }
        let destination = parent.resolvingSymlinksInPath()
            .appendingPathComponent(requested.lastPathComponent, isDirectory: true)
            .standardizedFileURL
        let protectedRoot = dataRoot.resolvingSymlinksInPath().standardizedFileURL
        guard !Self.isSameOrDescendant(destination, of: protectedRoot) else {
            throw DiagnosticsBundleError.unsafeDestination
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw DiagnosticsBundleError.destinationExists
        }
        return destination
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static let readme = """
        Screenlogger Diagnostics

        This bundle contains app, macOS, Library, permission, and capture-health metadata plus a bounded allowlisted event log.
        It does not contain screenshots, recognized text, searches, URLs, website domains, window titles, secrets, usernames, or Library paths.
        """

    private static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
