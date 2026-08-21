import CryptoKit
import Foundation

public enum CLIArtifactConflict: Error, LocalizedError, Equatable, Sendable {
    case incomplete(existing: [String], missing: [String])
    case unrecognized(existing: [String])
    case modifiedAuthenticatedInstallation(paths: [String])
    case invalidReceipt(String)

    public var errorDescription: String? {
        switch self {
        case .incomplete(let existing, let missing):
            return
                "The existing command-line installation is incomplete (found: \(existing.joined(separator: ", ")); missing: \(missing.joined(separator: ", "))). Move or remove those files before installing."
        case .unrecognized(let existing):
            return
                "Screenlogger did not create the existing \(existing.joined(separator: ", ")). Move or remove those files before installing."
        case .modifiedAuthenticatedInstallation(let paths):
            return
                "The Screenlogger command-line installation was changed after installation (\(paths.joined(separator: ", "))). Move or remove it before reinstalling."
        case .invalidReceipt(let path):
            return "The Screenlogger command-line receipt at \(path) is invalid. Move or remove it before installing."
        }
    }

    public var paths: [String] {
        switch self {
        case .incomplete(let existing, let missing): return existing + missing
        case .unrecognized(let existing): return existing
        case .modifiedAuthenticatedInstallation(let paths): return paths
        case .invalidReceipt(let path): return [path]
        }
    }
}

public enum CLIArtifactInstallationState: Equatable, Sendable {
    case notInstalled
    /// Receipt-backed files exactly match the supplied app-bundled artifacts.
    case current
    /// Receipt-backed files are intact, but are either older than the supplied
    /// artifacts or could not be compared because no source was supplied.
    case managed
    case conflict(CLIArtifactConflict)

    /// Automatic maintenance may replace only an intact receipt-backed
    /// installation. Missing, modified, and unrelated files always require an
    /// explicit user decision.
    public var needsAutomaticUpgrade: Bool {
        if case .managed = self { return true }
        return false
    }
}

/// A transaction directory retained because Screenlogger could not restore
/// every authenticated command artifact automatically. These directories are
/// deliberately discoverable across app launches until the user resolves or
/// removes them.
public enum CLIArtifactRecovery: Equatable, Sendable {
    case installation(directory: String)
    case removal(directory: String)

    public var directory: String {
        switch self {
        case .installation(let directory), .removal(let directory):
            return directory
        }
    }
}

public enum CLIArtifactInstallationError: Error, LocalizedError, Equatable {
    case conflict(CLIArtifactConflict)
    case sourceArtifactsInvalid
    case stagedVerificationFailed(String)
    case installationFailed(String)
    case removalFailed(String)
    case installationRecoveryRequired(String)
    case removalRecoveryRequired(String)

    public var errorDescription: String? {
        switch self {
        case .conflict(let conflict): return conflict.localizedDescription
        case .sourceArtifactsInvalid:
            return "Screenlogger's bundled command files could not be verified. Reinstall the app and try again."
        case .stagedVerificationFailed(let reason):
            return "The staged screenlog command failed its launch check: \(reason)"
        case .installationFailed(let reason): return reason
        case .removalFailed(let reason): return reason
        case .installationRecoveryRequired(let path):
            return
                "Screenlogger couldn't roll back every command file automatically. Recovery files were preserved at \(path)."
        case .removalRecoveryRequired(let path):
            return
                "Screenlogger couldn't restore every command file automatically. Recovery files were preserved at \(path)."
        }
    }
}

/// Owns the safe, transactional installation of the CLI, its paired framework,
/// and the assistant skill required by the CLI's integration commands.
/// Unknown destination nodes are never executed, removed, or overwritten.
public struct CLIArtifactInstallationService {
    public static let executableName = "screenlog"
    public static let frameworkName = "ScreenlogCore.framework"
    public static let skillDirectoryName = "skill"
    public static let skillName = "screenlog-cli-skill"
    public static let receiptName = ".screenlog-cli-install.json"

    private static let receiptProduct = "dev.screenlog.cli"
    private static let receiptSchemaVersion = 2
    private static let frameworkBundleIdentifier = "dev.screenlog.core"
    private static let frameworkDependency = "@rpath/ScreenlogCore.framework/Versions/A/ScreenlogCore"
    private static let maximumIdentityFileSize: Int64 = 512 * 1_024 * 1_024
    private static let maximumSkillManifestSize = 256 * 1_024
    private static let recoveryMarkerName = ".screenlog-recovery"
    private static let recoveryMarkerContents = Data("screenlogger-cli-recovery-v1\n".utf8)

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Validates the app-side artifact set before Settings uses it for version
    /// comparison or publication. Destination files are never executed by
    /// this check.
    public func sourceArtifactsAreValid(executable: URL, framework: URL) -> Bool {
        isRecognizedArtifactPair(executable: executable, framework: framework)
            && sourceSkill(for: executable) != nil
    }

    /// Finds the newest preserved recovery transaction without following
    /// symlinks or searching outside the exact installation directory.
    public func pendingRecovery(in destinationDirectory: URL) -> CLIArtifactRecovery? {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: destinationDirectory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ],
                options: []
            )
        else { return nil }

        let candidates = entries.compactMap { entry -> (CLIArtifactRecovery, Date)? in
            guard
                let values = try? entry.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ]),
                values.isDirectory == true,
                values.isSymbolicLink != true
            else { return nil }

            let recovery: CLIArtifactRecovery
            let identifier: Substring
            if entry.lastPathComponent.hasPrefix(".screenlog-backup-") {
                identifier = entry.lastPathComponent.dropFirst(".screenlog-backup-".count)
                recovery = .installation(directory: entry.path)
            } else if entry.lastPathComponent.hasPrefix(".screenlog-remove-") {
                identifier = entry.lastPathComponent.dropFirst(".screenlog-remove-".count)
                recovery = .removal(directory: entry.path)
            } else {
                return nil
            }
            let marker = entry.appendingPathComponent(Self.recoveryMarkerName)
            guard UUID(uuidString: String(identifier)) != nil,
                isRegularNode(marker),
                (try? Data(contentsOf: marker)) == Self.recoveryMarkerContents
            else { return nil }
            return (recovery, values.contentModificationDate ?? .distantPast)
        }
        return candidates.max { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.directory < rhs.0.directory
            }
            return lhs.1 < rhs.1
        }?.0
    }

    public func inspect(
        in destinationDirectory: URL,
        sourceExecutable: URL? = nil,
        sourceFramework: URL? = nil
    ) -> CLIArtifactInstallationState {
        let paths = installationPaths(in: destinationDirectory)
        if nodeExists(paths.skillContainer), !isDirectoryNode(paths.skillContainer) {
            return .conflict(.unrecognized(existing: [paths.skillContainer.path]))
        }
        let executableExists = nodeExists(paths.executable)
        let frameworkExists = nodeExists(paths.framework)
        let skillExists = nodeExists(paths.skill)
        let receiptExists = nodeExists(paths.receipt)

        guard executableExists || frameworkExists || skillExists || receiptExists else {
            return .notInstalled
        }

        if receiptExists {
            let receipt: Receipt
            do {
                guard isRegularNode(paths.receipt) else {
                    return .conflict(.invalidReceipt(paths.receipt.path))
                }
                receipt = try decodeReceipt(at: paths.receipt)
            } catch {
                return .conflict(.invalidReceipt(paths.receipt.path))
            }
            guard
                receipt.schemaVersion == Self.receiptSchemaVersion,
                receipt.productIdentifier == Self.receiptProduct,
                receipt.skillSHA256 != nil
            else {
                return .conflict(.invalidReceipt(paths.receipt.path))
            }
            guard executableExists, frameworkExists, skillExists else {
                return .conflict(
                    .incomplete(
                        existing: existingNames(paths),
                        missing: missingArtifactNames(paths, includeSkill: true)
                    ))
            }
            do {
                let executableDigest = try digest(of: paths.executable)
                let frameworkDigest = try digest(of: paths.framework)
                let skillDigest = try digest(of: paths.skill)
                var modifiedPaths: [String] = []
                if executableDigest != receipt.executableSHA256 {
                    modifiedPaths.append(paths.executable.path)
                }
                if frameworkDigest != receipt.frameworkSHA256 {
                    modifiedPaths.append(paths.framework.path)
                }
                if skillDigest != receipt.skillSHA256 {
                    modifiedPaths.append(paths.skill.path)
                }
                guard modifiedPaths.isEmpty else {
                    return .conflict(
                        .modifiedAuthenticatedInstallation(paths: modifiedPaths)
                    )
                }
                if let sourceExecutable, let sourceFramework,
                    let sourceSkill = sourceSkill(for: sourceExecutable),
                    executableDigest == (try? digest(of: sourceExecutable)),
                    frameworkDigest == (try? digest(of: sourceFramework)),
                    skillDigest == (try? digest(of: sourceSkill))
                {
                    return .current
                }
                return .managed
            } catch {
                return .conflict(
                    .modifiedAuthenticatedInstallation(
                        paths: [paths.executable.path, paths.framework.path, paths.skill.path]
                    ))
            }
        }

        guard executableExists, frameworkExists else {
            return .conflict(
                .incomplete(
                    existing: existingNames(paths),
                    missing: missingArtifactNames(paths, includeSkill: false)
                ))
        }
        // Product-shaped bytes do not establish ownership. Before the first
        // production release there is no supported pre-receipt generation, so
        // every complete receiptless destination is an ordinary conflict.
        return .conflict(.unrecognized(existing: existingNames(paths)))
    }

    /// Publishes a verified artifact set and receipt as one recoverable transaction.
    /// `verifyStagedExecutable` must only execute the trusted staged source.
    @discardableResult
    public func install(
        executable sourceExecutable: URL,
        framework sourceFramework: URL,
        into destinationDirectory: URL,
        verifyStagedExecutable: (URL) throws -> Void
    ) throws -> URL {
        // Never publish or authenticate a symlinked, structurally unrelated,
        // or incomplete source pair. The app bundle is the trust boundary;
        // destination receipts only prove what Screenlogger published later.
        guard
            isRecognizedArtifactPair(
                executable: sourceExecutable,
                framework: sourceFramework
            ),
            let sourceSkill = sourceSkill(for: sourceExecutable)
        else {
            throw CLIArtifactInstallationError.sourceArtifactsInvalid
        }

        if case .conflict(let conflict) = inspect(
            in: destinationDirectory,
            sourceExecutable: sourceExecutable,
            sourceFramework: sourceFramework
        ) {
            throw CLIArtifactInstallationError.conflict(conflict)
        }

        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            return try publish(
                executable: sourceExecutable,
                framework: sourceFramework,
                skill: sourceSkill,
                into: destinationDirectory,
                verifyStagedExecutable: verifyStagedExecutable
            )
        } catch let error as CLIArtifactInstallationError {
            throw error
        } catch {
            throw CLIArtifactInstallationError.installationFailed(error.localizedDescription)
        }
    }

    /// Removes only a complete installation Screenlogger can authenticate.
    /// Unknown, partial, modified, and invalid-receipt nodes are preserved as
    /// typed conflicts. Known artifacts first move out of their live names so
    /// the command is never left visible without its paired runtime.
    @discardableResult
    public func remove(from destinationDirectory: URL) throws -> Bool {
        let destination = installationPaths(in: destinationDirectory)
        switch inspect(in: destinationDirectory) {
        case .notInstalled:
            return false
        case .conflict(let conflict):
            throw CLIArtifactInstallationError.conflict(conflict)
        case .current, .managed:
            break
        }

        // Defense in depth: every removable state must retain the current
        // ownership receipt.
        guard nodeExists(destination.receipt) else {
            throw CLIArtifactInstallationError.conflict(
                .unrecognized(
                    existing: [destination.executable.path, destination.framework.path]
                ))
        }
        let quarantine = destinationDirectory.appendingPathComponent(
            ".screenlog-remove-\(UUID().uuidString)",
            isDirectory: true
        )
        let quarantined = installationPaths(in: quarantine)
        do {
            try fileManager.createDirectory(
                at: quarantine,
                withIntermediateDirectories: false
            )
            try fileManager.createDirectory(
                at: quarantined.skillContainer,
                withIntermediateDirectories: false
            )
        } catch {
            try? fileManager.removeItem(at: quarantine)
            throw CLIArtifactInstallationError.removalFailed(
                "The screenlog command couldn't be removed. Its existing files were preserved."
            )
        }

        var moved: [ArtifactPath] = []
        do {
            for artifact in ArtifactPath.allCases where nodeExists(destination[artifact]) {
                try fileManager.moveItem(
                    at: destination[artifact],
                    to: quarantined[artifact]
                )
                moved.append(artifact)
            }
        } catch {
            let restored = restoreArtifacts(
                moved,
                from: quarantined,
                to: destination
            )
            if restored {
                try? fileManager.removeItem(at: quarantine)
            } else {
                markRecovery(in: quarantine)
                throw CLIArtifactInstallationError.removalRecoveryRequired(
                    quarantine.path
                )
            }
            throw CLIArtifactInstallationError.removalFailed(
                "The screenlog command couldn't be removed. Its existing files were preserved."
            )
        }

        // The live installation is now absent as one logical operation. A
        // cleanup failure can leave only a uniquely named hidden quarantine;
        // it can never shadow or impersonate the screenlog command.
        try? fileManager.removeItem(at: quarantine)
        removeDirectoryIfEmpty(destination.skillContainer)
        return true
    }

    private func publish(
        executable sourceExecutable: URL,
        framework sourceFramework: URL,
        skill sourceSkill: URL,
        into destinationDirectory: URL,
        verifyStagedExecutable: (URL) throws -> Void
    ) throws -> URL {
        let transactionID = UUID().uuidString
        let staging =
            destinationDirectory
            .appendingPathComponent(".screenlog-install-\(transactionID)", isDirectory: true)
        let backup =
            destinationDirectory
            .appendingPathComponent(".screenlog-backup-\(transactionID)", isDirectory: true)
        let staged = installationPaths(in: staging)
        let destination = installationPaths(in: destinationDirectory)
        let backedUp = installationPaths(in: backup)
        var preserveBackup = false

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer {
            try? fileManager.removeItem(at: staging)
            if !preserveBackup {
                try? fileManager.removeItem(at: backup)
            }
        }
        try fileManager.createDirectory(
            at: staged.skillContainer,
            withIntermediateDirectories: false
        )
        try fileManager.copyItem(at: sourceExecutable, to: staged.executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.executable.path)
        try fileManager.copyItem(at: sourceFramework, to: staged.framework)
        try fileManager.copyItem(at: sourceSkill, to: staged.skill)
        // Validate the fixed staged bytes again before executing them. This
        // closes the source-check/copy gap if the app bundle changes while an
        // installation is in progress.
        guard
            isRecognizedArtifactPair(
                executable: staged.executable,
                framework: staged.framework
            ),
            isRecognizedSkill(staged.skill)
        else {
            throw CLIArtifactInstallationError.sourceArtifactsInvalid
        }
        let receipt = Receipt(
            schemaVersion: Self.receiptSchemaVersion,
            productIdentifier: Self.receiptProduct,
            executableSHA256: try digest(of: staged.executable),
            frameworkSHA256: try digest(of: staged.framework),
            skillSHA256: try digest(of: staged.skill)
        )
        try JSONEncoder.screenloggerReceipt.encode(receipt).write(to: staged.receipt, options: .atomic)

        do {
            try verifyStagedExecutable(staged.executable)
        } catch {
            throw CLIArtifactInstallationError.stagedVerificationFailed(error.localizedDescription)
        }

        try fileManager.createDirectory(at: backup, withIntermediateDirectories: false)
        try fileManager.createDirectory(
            at: backedUp.skillContainer,
            withIntermediateDirectories: false
        )
        let createdDestinationSkillContainer = !nodeExists(destination.skillContainer)
        if createdDestinationSkillContainer {
            try fileManager.createDirectory(
                at: destination.skillContainer,
                withIntermediateDirectories: false
            )
        } else if !isDirectoryNode(destination.skillContainer) {
            throw CLIArtifactInstallationError.conflict(
                .unrecognized(existing: [destination.skillContainer.path])
            )
        }
        var movedToBackup: [ArtifactPath] = []
        var published: [ArtifactPath] = []
        do {
            for artifact in ArtifactPath.allCases where nodeExists(destination[artifact]) {
                try fileManager.moveItem(at: destination[artifact], to: backedUp[artifact])
                movedToBackup.append(artifact)
            }
            // Publish dependencies before the executable so the command is
            // never visible without its runtime and integration resource. The
            // ownership receipt is committed last.
            for artifact in [ArtifactPath.framework, .skill, .executable, .receipt] {
                try fileManager.moveItem(at: staged[artifact], to: destination[artifact])
                published.append(artifact)
            }
        } catch {
            let removedPublished = removeArtifacts(published, from: destination)
            let restoredPrevious = restoreArtifacts(
                movedToBackup,
                from: backedUp,
                to: destination
            )
            if createdDestinationSkillContainer {
                removeDirectoryIfEmpty(destination.skillContainer)
            }
            guard removedPublished, restoredPrevious else {
                preserveBackup = true
                markRecovery(in: backup)
                throw CLIArtifactInstallationError.installationRecoveryRequired(
                    backup.path
                )
            }
            throw error
        }
        return destination.executable
    }

    private func isRecognizedArtifactPair(executable: URL, framework: URL) -> Bool {
        guard isRegularNode(executable),
            isDirectoryNode(framework),
            fileManager.isExecutableFile(atPath: executable.path),
            isMachOFile(executable),
            fileContains(executable, utf8: Self.frameworkDependency),
            let info = NSDictionary(
                contentsOf:
                    framework
                    .appendingPathComponent("Versions/A/Resources/Info.plist"))
                ?? NSDictionary(contentsOf: framework.appendingPathComponent("Resources/Info.plist")),
            info["CFBundleIdentifier"] as? String == Self.frameworkBundleIdentifier,
            info["CFBundlePackageType"] as? String == "FMWK",
            let frameworkExecutableName = info["CFBundleExecutable"] as? String,
            frameworkExecutableName == "ScreenlogCore"
        else {
            return false
        }
        let frameworkExecutable = framework.appendingPathComponent(frameworkExecutableName)
        return isMachOFile(frameworkExecutable)
    }

    /// Finds only resources distributed as part of the executable's own
    /// product layout. It intentionally never searches installed apps,
    /// developer checkouts, or user-controlled environment overrides.
    private func sourceSkill(for executable: URL) -> URL? {
        let executableDirectory = executable.deletingLastPathComponent()
        let candidates = [
            executableDirectory
                .appendingPathComponent(Self.skillDirectoryName, isDirectory: true)
                .appendingPathComponent(Self.skillName, isDirectory: true),
            executableDirectory.deletingLastPathComponent()
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(Self.skillDirectoryName, isDirectory: true)
                .appendingPathComponent(Self.skillName, isDirectory: true),
        ]
        for candidate in candidates where nodeExists(candidate) {
            return isRecognizedSkill(candidate) ? candidate : nil
        }
        return nil
    }

    private func isRecognizedSkill(_ skill: URL) -> Bool {
        guard isDirectoryNode(skill),
            let entries = try? fileManager.contentsOfDirectory(
                at: skill,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            ),
            entries.map(\.lastPathComponent).sorted() == ["SKILL.md"]
        else { return false }
        let manifest = skill.appendingPathComponent("SKILL.md")
        guard isRegularNode(manifest),
            let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > 0,
            size <= Self.maximumSkillManifestSize,
            let data = try? Data(contentsOf: manifest, options: .mappedIfSafe),
            let text = String(data: data, encoding: .utf8),
            (try? digest(of: skill)) != nil
        else { return false }
        let header = text.split(whereSeparator: \.isNewline).prefix(12)
        return header.first?.trimmingCharacters(in: .whitespaces) == "---"
            && header.dropFirst().contains {
                $0.trimmingCharacters(in: .whitespaces) == "name: \(Self.skillName)"
            }
    }

    private func isMachOFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        return Set<[UInt8]>([
            [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
        ]).contains(Array(magic))
    }

    private func fileContains(_ url: URL, utf8 needle: String) -> Bool {
        guard !currentTaskIsCancelled,
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            Int64(size) <= Self.maximumIdentityFileSize,
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return false }
        guard !currentTaskIsCancelled else { return false }
        return data.range(of: Data(needle.utf8)) != nil
    }

    private func digest(of url: URL) throws -> String {
        guard !currentTaskIsCancelled else { throw CancellationError() }
        var hasher = SHA256()
        var remainingBytes = Self.maximumIdentityFileSize
        let rootValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if rootValues.isSymbolicLink == true {
            hasher.update(data: Data("link\0".utf8))
            hasher.update(data: Data(try fileManager.destinationOfSymbolicLink(atPath: url.path).utf8))
            return hasher.finalize().hexString
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if !isDirectory.boolValue {
            hasher.update(data: Data("file\0".utf8))
            try update(&hasher, withFileAt: url, remainingBytes: &remainingBytes)
            return hasher.finalize().hexString
        }

        hasher.update(data: Data("directory\0".utf8))
        var enumerationError: Error?
        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            )
        else { throw CocoaError(.fileReadUnknown) }
        let entries = enumerator.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
        if let enumerationError { throw enumerationError }
        for entry in entries {
            guard !currentTaskIsCancelled else { throw CancellationError() }
            let relative = String(entry.path.dropFirst(url.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                hasher.update(data: Data("link\0".utf8))
                let target = try fileManager.destinationOfSymbolicLink(atPath: entry.path)
                hasher.update(data: Data(target.utf8))
            } else if values.isRegularFile == true {
                hasher.update(data: Data("file\0".utf8))
                try update(&hasher, withFileAt: entry, remainingBytes: &remainingBytes)
            } else if values.isDirectory == true {
                hasher.update(data: Data("directory\0".utf8))
            } else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().hexString
    }

    private func decodeReceipt(at url: URL) throws -> Receipt {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 65_536 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
    }

    private func update(
        _ hasher: inout SHA256,
        withFileAt url: URL,
        remainingBytes: inout Int64
    ) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= 0, Int64(size) <= remainingBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        remainingBytes -= Int64(size)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            guard !currentTaskIsCancelled else { throw CancellationError() }
            hasher.update(data: chunk)
        }
    }

    private var currentTaskIsCancelled: Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }

    private func markRecovery(in directory: URL) {
        try? Self.recoveryMarkerContents.write(
            to: directory.appendingPathComponent(Self.recoveryMarkerName),
            options: .atomic
        )
    }

    private func nodeExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func isRegularNode(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func isDirectoryNode(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func removeDirectoryIfEmpty(_ directory: URL) {
        guard isDirectoryNode(directory),
            let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
            contents.isEmpty
        else { return }
        try? fileManager.removeItem(at: directory)
    }

    private func removeArtifacts(
        _ artifacts: [ArtifactPath],
        from paths: InstallationPaths
    ) -> Bool {
        var removedAll = true
        for artifact in artifacts.reversed() where nodeExists(paths[artifact]) {
            do {
                try fileManager.removeItem(at: paths[artifact])
            } catch {
                removedAll = false
            }
        }
        return removedAll && artifacts.allSatisfy { !nodeExists(paths[$0]) }
    }

    private func restoreArtifacts(
        _ artifacts: [ArtifactPath],
        from source: InstallationPaths,
        to destination: InstallationPaths
    ) -> Bool {
        var restoredAll = true
        for artifact in artifacts.reversed() where nodeExists(source[artifact]) {
            guard !nodeExists(destination[artifact]) else {
                restoredAll = false
                continue
            }
            do {
                try fileManager.moveItem(
                    at: source[artifact],
                    to: destination[artifact]
                )
            } catch {
                restoredAll = false
            }
        }
        return restoredAll
            && artifacts.allSatisfy {
                !nodeExists(source[$0]) && nodeExists(destination[$0])
            }
    }

    private func existingNames(_ paths: InstallationPaths) -> [String] {
        ArtifactPath.allCases.compactMap { nodeExists(paths[$0]) ? paths[$0].path : nil }
    }

    private func missingArtifactNames(
        _ paths: InstallationPaths,
        includeSkill: Bool
    ) -> [String] {
        let required: [ArtifactPath] =
            includeSkill
            ? [.executable, .framework, .skill]
            : [.executable, .framework]
        return required.compactMap { nodeExists(paths[$0]) ? nil : paths[$0].path }
    }

    private func installationPaths(in directory: URL) -> InstallationPaths {
        let skillContainer = directory.appendingPathComponent(
            Self.skillDirectoryName,
            isDirectory: true
        )
        return InstallationPaths(
            executable: directory.appendingPathComponent(Self.executableName),
            framework: directory.appendingPathComponent(Self.frameworkName, isDirectory: true),
            skillContainer: skillContainer,
            skill: skillContainer.appendingPathComponent(Self.skillName, isDirectory: true),
            receipt: directory.appendingPathComponent(Self.receiptName)
        )
    }
}

private enum ArtifactPath: CaseIterable {
    case executable
    case framework
    case skill
    case receipt
}

private struct InstallationPaths {
    let executable: URL
    let framework: URL
    let skillContainer: URL
    let skill: URL
    let receipt: URL

    subscript(_ artifact: ArtifactPath) -> URL {
        switch artifact {
        case .executable: return executable
        case .framework: return framework
        case .skill: return skill
        case .receipt: return receipt
        }
    }
}

private struct Receipt: Codable {
    let schemaVersion: Int
    let productIdentifier: String
    let executableSHA256: String
    let frameworkSHA256: String
    let skillSHA256: String?
}

extension JSONEncoder {
    fileprivate static var screenloggerReceipt: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension SHA256.Digest {
    fileprivate var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
