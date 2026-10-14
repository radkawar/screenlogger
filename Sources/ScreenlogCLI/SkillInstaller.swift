import Foundation
import ScreenlogCore

/// Manages `screenlog-cli-skill` for supported local assistants.
/// This is pure filesystem work and does not require Screenlogger.app.
enum SkillInstaller {
    static let skillFolderName = AssistantIntegrationService.skillFolderName

    enum Operation: String, CaseIterable {
        case install
        case status
        case upgrade
        case remove

        static func parse(_ value: String) -> Operation? {
            switch value {
            case "verify": return .status
            case "uninstall": return .remove
            default: return Operation(rawValue: value)
            }
        }
    }

    enum Target: String, CaseIterable {
        case claude
        case cursor
        case codex
        case grok
        case openclaw
        case all

        var assistantTarget: AssistantIntegrationTarget? {
            guard self != .all else { return nil }
            return AssistantIntegrationTarget(rawValue: rawValue)
        }
    }

    struct Invocation: Equatable {
        var operation: Operation
        var target: Target
        var directoryOverride: String?
        var force: Bool
        var jsonOutput: Bool = false
        var showsHelp: Bool = false
    }

    struct LifecycleResult {
        var changed: [URL] = []
        var inspected: [URL] = []
        var notes: [String] = []
    }

    typealias InstallationState = AssistantIntegrationState

    /// Versioned status contract for assistant and shell automation. Filesystem
    /// locations and associated error strings are intentionally reduced to
    /// stable codes before encoding.
    struct StatusDocument: Encodable, Equatable {
        enum Health: String, Encodable { case ok, degraded }
        enum TargetCode: String, Encodable {
            case claude, cursor, codex, grok, openclaw, all

            init(_ target: Target) {
                switch target {
                case .claude: self = .claude
                case .cursor: self = .cursor
                case .codex: self = .codex
                case .grok: self = .grok
                case .openclaw: self = .openclaw
                case .all: self = .all
                }
            }

            init(_ target: AssistantIntegrationTarget) {
                switch target {
                case .claude: self = .claude
                case .cursor: self = .cursor
                case .codex: self = .codex
                case .grok: self = .grok
                case .openclaw: self = .openclaw
                }
            }
        }
        enum Readiness: String, Encodable {
            case ready
            case notInstalled = "not_installed"
            case updateAvailable = "update_available"
            case setupIncomplete = "setup_incomplete"
            case blocked
            case unavailable

            init(_ readiness: AssistantIntegrationReadiness) {
                switch readiness {
                case .ready: self = .ready
                case .notInstalled: self = .notInstalled
                case .updateAvailable: self = .updateAvailable
                case .setupIncomplete: self = .setupIncomplete
                case .blocked: self = .blocked
                }
            }
        }
        enum State: String, Encodable {
            case missing
            case currentLink = "current_link"
            case currentCopy = "current_copy"
            case staleLink = "stale_link"
            case staleCopy = "stale_copy"
            case brokenLink = "broken_link"
            case conflict
            case unavailable

            init(_ state: AssistantIntegrationState) {
                switch state {
                case .missing: self = .missing
                case .currentLink: self = .currentLink
                case .currentCopy: self = .currentCopy
                case .staleLink: self = .staleLink
                case .staleCopy: self = .staleCopy
                case .brokenLink: self = .brokenLink
                case .conflict: self = .conflict
                }
            }
        }
        enum Registration: String, Encodable {
            case notRequired = "not_required"
            case registered
            case notRegistered = "not_registered"
            case unknown
        }
        enum RemediationAction: String, Encodable {
            case none
            case install
            case upgrade
            case forceInstall = "force_install"
            case reinstallScreenlogger = "reinstall_screenlogger"
            case installOrOpenAssistant = "install_or_open_assistant"
            case selectTarget = "select_target"
            case reviewTargets = "review_targets"
            case reviewConfiguration = "review_configuration"
            case reviewInstallation = "review_installation"
            case retry
        }
        enum Issue: String, Encodable {
            case noTargetsDetected = "no_targets_detected"
            case sourceUnavailable = "source_unavailable"
            case configurationUnavailable = "configuration_unavailable"
            case configurationInvalid = "configuration_invalid"
            case unsafeDestination = "unsafe_destination"
            case inspectionFailed = "inspection_failed"
        }

        struct Remediation: Encodable, Equatable {
            let action: RemediationAction
            let requiresConfirmation: Bool

            private init(action: RemediationAction, requiresConfirmation: Bool) {
                self.action = action
                self.requiresConfirmation = requiresConfirmation
            }

            static let none = Remediation(action: .none, requiresConfirmation: false)
            static let reviewTargets = Remediation(
                action: .reviewTargets,
                requiresConfirmation: false
            )

            init(_ readiness: AssistantIntegrationReadiness) {
                switch readiness {
                case .ready:
                    self.init(action: .none, requiresConfirmation: false)
                case .notInstalled:
                    self.init(action: .install, requiresConfirmation: false)
                case .updateAvailable, .setupIncomplete:
                    self.init(action: .upgrade, requiresConfirmation: false)
                case .blocked:
                    self.init(action: .forceInstall, requiresConfirmation: true)
                }
            }

            init(_ issue: Issue) {
                switch issue {
                case .sourceUnavailable:
                    self.init(action: .reinstallScreenlogger, requiresConfirmation: false)
                case .configurationUnavailable:
                    self.init(action: .installOrOpenAssistant, requiresConfirmation: false)
                case .configurationInvalid:
                    self.init(action: .reviewConfiguration, requiresConfirmation: true)
                case .unsafeDestination:
                    self.init(action: .reviewInstallation, requiresConfirmation: true)
                case .noTargetsDetected:
                    self.init(action: .selectTarget, requiresConfirmation: false)
                case .inspectionFailed:
                    self.init(action: .retry, requiresConfirmation: false)
                }
            }
        }

        struct TargetStatus: Encodable, Equatable {
            let target: TargetCode
            let readiness: Readiness
            let state: State
            let registration: Registration
            let remediation: Remediation
            let issues: [Issue]

            init(inspection: AssistantIntegrationInspection) {
                self.target = TargetCode(inspection.target)
                self.readiness = Readiness(inspection.readiness)
                self.state = State(inspection.state)
                self.registration =
                    inspection.isRegistered.map {
                        $0 ? .registered : .notRegistered
                    } ?? .notRequired
                self.remediation = Remediation(inspection.readiness)
                self.issues = []
            }

            init(target: Target, issue: Issue) {
                self.target = TargetCode(target)
                self.readiness = .unavailable
                self.state = .unavailable
                self.registration = .unknown
                self.remediation = Remediation(issue)
                self.issues = [issue]
            }
        }

        let schemaVersion: Int
        let health: Health
        let requestedTarget: TargetCode
        let targets: [TargetStatus]
        let issues: [Issue]
        let remediation: Remediation

        init(requestedTarget: Target, targets: [TargetStatus], issues: [Issue] = []) {
            self.schemaVersion = 1
            self.requestedTarget = TargetCode(requestedTarget)
            self.targets = targets
            self.issues = issues
            let allTargetsReady = targets.allSatisfy { $0.readiness == .ready }
            if let issue = issues.first {
                self.remediation = Remediation(issue)
            } else {
                self.remediation = allTargetsReady ? .none : .reviewTargets
            }
            self.health = issues.isEmpty && allTargetsReady ? .ok : .degraded
        }
    }

    // MARK: - Public entry

    /// Canonical syntax is `screenlog skill <operation> [target]`.
    /// `screenlog install-skill ...` calls this with an implicit `install` operation.
    static func run(args: [String]) throws -> LifecycleResult {
        let invocation = try parseInvocation(args)
        if invocation.showsHelp {
            print(helpText)
            return LifecycleResult()
        }

        if invocation.target == .all, invocation.directoryOverride != nil {
            throw CLIError.usage("skill \(invocation.operation.rawValue) all does not take --directory")
        }
        if invocation.target == .openclaw, invocation.directoryOverride != nil {
            throw CLIError.usage("skill \(invocation.operation.rawValue) openclaw does not take --directory")
        }
        if invocation.jsonOutput {
            return try runJSONStatus(invocation)
        }

        // Removal remains available even after the app/CLI skill resources were deleted.
        // Other operations need the source in order to install or verify exact content.
        let source: URL?
        if invocation.operation == .remove {
            source = try? resolveSkillSource()
        } else {
            source = try resolveSkillSource()
        }
        let targets = try selectedTargets(invocation.target)
        var result = LifecycleResult()
        var failures: [String] = []

        for target in targets {
            do {
                let partial = try perform(
                    invocation.operation,
                    target: target,
                    directoryOverride: invocation.directoryOverride,
                    skillSource: source,
                    force: invocation.force
                )
                result.changed.append(contentsOf: partial.changed)
                result.inspected.append(contentsOf: partial.inspected)
                result.notes.append(contentsOf: partial.notes)
            } catch {
                failures.append("\(target.rawValue): \(lifecycleFailureDescription(error))")
            }
        }

        if !failures.isEmpty {
            throw CLIError.message(failures.joined(separator: "\n"))
        }
        return result
    }

    static func parseInvocation(_ args: [String]) throws -> Invocation {
        if args.contains("-h") || args.contains("--help") || args.first == "help" {
            return Invocation(operation: .install, target: .all, directoryOverride: nil, force: false, showsHelp: true)
        }

        var operation: Operation = .install
        var targetFromFlag: String?
        var directory: String?
        var force = false
        var jsonOutput = false
        var positionals: [String] = []
        var index = 0

        if let first = args.first, let parsed = Operation.parse(first) {
            operation = parsed
            index = 1
        }

        while index < args.count {
            let argument = args[index]
            switch argument {
            case "--force":
                guard !force else { throw CLIError.message("Provide --force only once") }
                force = true
            case "--json":
                guard !jsonOutput else { throw CLIError.message("Provide --json only once") }
                jsonOutput = true
            case "--directory", "--target":
                guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else {
                    throw CLIError.message("\(argument) requires a value")
                }
                let value = args[index + 1]
                let maximumBytes = argument == "--directory" ? 4_096 : 32
                guard !value.isEmpty, value.utf8.count <= maximumBytes else {
                    throw CLIError.message("\(argument) is empty or contains more than \(maximumBytes) bytes")
                }
                if argument == "--directory" {
                    guard directory == nil else { throw CLIError.message("Provide --directory only once") }
                    directory = value
                } else {
                    guard targetFromFlag == nil else { throw CLIError.message("Provide --target only once") }
                    targetFromFlag = value
                }
                index += 1
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.message("unknown skill option: \(argument)")
                }
                positionals.append(argument)
            }
            index += 1
        }

        guard positionals.count <= 1 else {
            throw CLIError.usage("skill install|status|upgrade|remove [claude|cursor|codex|grok|openclaw|all]")
        }
        guard targetFromFlag == nil || positionals.isEmpty else {
            throw CLIError.message("choose either --target or a positional target, not both")
        }
        let targetValue = targetFromFlag ?? positionals.first ?? "all"
        guard let target = Target(rawValue: targetValue) else {
            throw CLIError.usage("skill install|status|upgrade|remove [claude|cursor|codex|grok|openclaw|all]")
        }
        if force, operation == .status {
            throw CLIError.usage("skill status does not take --force")
        }
        if jsonOutput, operation != .status {
            throw CLIError.usage("--json is available only for skill status")
        }

        return Invocation(
            operation: operation,
            target: target,
            directoryOverride: directory,
            force: force,
            jsonOutput: jsonOutput
        )
    }

    // MARK: - Machine-readable status

    private static func runJSONStatus(_ invocation: Invocation) throws -> LifecycleResult {
        let targets = selectedTargetsForJSONStatus(invocation.target)
        guard !targets.isEmpty else {
            let document = StatusDocument(
                requestedTarget: invocation.target,
                targets: [],
                issues: [.noTargetsDetected]
            )
            try printJSON(document)
            throw CLIError.message("skill status found no supported assistants")
        }

        let source: URL
        do {
            source = try resolveSkillSource()
        } catch {
            let document = StatusDocument(
                requestedTarget: invocation.target,
                targets: targets.map { .init(target: $0, issue: .sourceUnavailable) },
                issues: [.sourceUnavailable]
            )
            try printJSON(document)
            throw CLIError.message("Screenlogger integration resources are unavailable. Reinstall Screenlogger.")
        }

        let service = AssistantIntegrationService()
        let statuses = targets.map { target -> StatusDocument.TargetStatus in
            guard let assistantTarget = target.assistantTarget else {
                return .init(target: target, issue: .inspectionFailed)
            }
            do {
                let skillsDirectory = try skillsDirectoryOverride(
                    invocation.directoryOverride,
                    target: target,
                    home: service.homeDirectory
                )
                let inspection = try service.inspect(
                    target: assistantTarget,
                    source: source,
                    skillsDirectoryOverride: skillsDirectory
                )
                return .init(inspection: inspection)
            } catch {
                return .init(target: target, issue: statusIssue(for: error))
            }
        }
        let document = StatusDocument(
            requestedTarget: invocation.target,
            targets: statuses
        )
        try printJSON(document)
        guard document.health == .ok else {
            throw CLIError.message("One or more integrations need action. Review the skill status results.")
        }
        return LifecycleResult(inspected: [])
    }

    static func statusIssue(for error: Error) -> StatusDocument.Issue {
        guard let integrationError = error as? AssistantIntegrationError else {
            return .inspectionFailed
        }
        switch integrationError {
        case .sourceMissing:
            return .sourceUnavailable
        case .configMissing:
            return .configurationUnavailable
        case .malformedConfiguration:
            return .configurationInvalid
        case .unsafeDestination:
            return .unsafeDestination
        case .destinationNeedsUpgrade, .destinationNotOwned, .replacementFailed:
            return .inspectionFailed
        }
    }

    private static func selectedTargetsForJSONStatus(_ requested: Target) -> [Target] {
        guard requested == .all else { return [requested] }
        return detectedTargets()
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    // MARK: - Operations

    private static func perform(
        _ operation: Operation,
        target: Target,
        directoryOverride: String?,
        skillSource: URL?,
        force: Bool
    ) throws -> LifecycleResult {
        guard target != .all else {
            throw CLIError.message("internal: all must be expanded before performing an operation")
        }
        return try performCanonical(
            operation,
            target: target,
            directoryOverride: directoryOverride,
            skillSource: skillSource,
            force: force
        )
    }

    static func performStandard(
        _ operation: Operation,
        target: Target,
        directoryOverride: String?,
        skillSource: URL?,
        force: Bool
    ) throws -> LifecycleResult {
        guard target != .openclaw, target != .all else {
            throw CLIError.message("internal: expected a standard assistant target")
        }
        return try performCanonical(
            operation,
            target: target,
            directoryOverride: directoryOverride,
            skillSource: skillSource,
            force: force
        )
    }

    private static func performCanonical(
        _ operation: Operation,
        target: Target,
        directoryOverride: String?,
        skillSource: URL?,
        force: Bool
    ) throws -> LifecycleResult {
        guard let assistantTarget = target.assistantTarget else {
            throw CLIError.message("internal: all is not an installable assistant")
        }
        let service = AssistantIntegrationService()
        let skillsDirectory = try skillsDirectoryOverride(
            directoryOverride,
            target: target,
            home: service.homeDirectory
        )
        if operation == .remove {
            let destination = try service.destination(
                for: assistantTarget,
                skillsDirectoryOverride: skillsDirectory
            )
            let change = try service.remove(
                target: assistantTarget,
                source: skillSource,
                allowUnowned: force,
                skillsDirectoryOverride: skillsDirectory
            )
            if !change.changed {
                print("\(target.rawValue): already removed - \(destination.path)")
                return LifecycleResult(inspected: [destination])
            }
            print("\(target.rawValue): removed \(destination.path)")
            return LifecycleResult(changed: change.changedURLs)
        }

        guard let skillSource else {
            throw CLIError.message(
                "Screenlogger integration resources are unavailable. Reinstall Screenlogger."
            )
        }
        let inspection = try service.inspect(
            target: assistantTarget,
            source: skillSource,
            skillsDirectoryOverride: skillsDirectory
        )
        let destination = inspection.destination

        switch operation {
        case .status:
            let registration = inspection.isRegistered.map { $0 ? ", registered" : ", not registered" } ?? ""
            print("\(target.rawValue): \(inspection.readiness.statusDescription)\(registration) - \(destination.path)")
            guard inspection.isCurrent else {
                throw CLIError.message(
                    "verification failed; \(statusRemediation(for: inspection.readiness, target: target))"
                )
            }
            return LifecycleResult(
                inspected: assistantTarget == .openclaw
                    ? [destination, service.openClawConfigURL()]
                    : [destination]
            )
        case .remove:
            throw CLIError.message("internal: remove must be handled before source inspection")
        case .install, .upgrade:
            if inspection.isCurrent {
                print("\(target.rawValue): already current - \(destination.path)")
                return LifecycleResult(inspected: [destination] + (assistantTarget == .openclaw ? [service.openClawConfigURL()] : []))
            }
            let mode: AssistantIntegrationInstallMode =
                force
                ? .force
                : (operation == .upgrade ? .upgrade : .install)
            let change = try service.install(
                target: assistantTarget,
                source: skillSource,
                mode: mode,
                skillsDirectoryOverride: skillsDirectory
            )
            let note =
                assistantTarget == .openclaw
                ? "OpenClaw will load the integration on the next agent turn."
                : "Restart \(assistantTarget.label) sessions to load the integration."
            print("\(target.rawValue): installed \(destination.path)")
            print("  \(note)")
            return LifecycleResult(
                changed: change.changedURLs,
                notes: [note]
            )
        }
    }

    /// Gives an operation that can actually resolve the inspected state.
    /// A normal upgrade intentionally cannot replace unauthenticated content,
    /// so blocked states must never recommend a command guaranteed to fail.
    static func statusRemediation(
        for readiness: AssistantIntegrationReadiness,
        target: Target
    ) -> String {
        switch readiness {
        case .ready:
            return "no changes are needed"
        case .notInstalled:
            return "run `screenlog skill install \(target.rawValue)`"
        case .updateAvailable, .setupIncomplete:
            return "run `screenlog skill upgrade \(target.rawValue)`"
        case .blocked:
            return "Review the reported path. Use `screenlog skill install \(target.rawValue) --force` only if you intend to replace it."
        }
    }

    /// CLI lifecycle failures may be consumed by an assistant. Keep arbitrary
    /// NSError descriptions (which often contain account paths) out of output;
    /// destinations are shown separately only when they are useful to resolve a
    /// reviewed conflict.
    static func lifecycleFailureDescription(_ error: Error) -> String {
        guard let integrationError = error as? AssistantIntegrationError else {
            if let cliError = error as? CLIError { return cliError.description }
            return "Screenlogger could not change the integration. It preserved existing files."
        }
        switch integrationError {
        case .sourceMissing:
            return "Screenlogger integration resources are unavailable. Reinstall Screenlogger."
        case .configMissing:
            return "OpenClaw configuration is unavailable. Install or open OpenClaw first."
        case .malformedConfiguration:
            return "OpenClaw configuration is invalid. Screenlogger left it unchanged."
        case .destinationNeedsUpgrade:
            return "the installed Screenlogger integration needs an explicit upgrade"
        case .destinationNotOwned:
            return "the integration location contains an item Screenlogger cannot authenticate"
        case .unsafeDestination:
            return "Screenlogger refused an unsafe integration location"
        case .replacementFailed:
            return "Screenlogger could not replace the integration. It preserved the previous installation."
        }
    }

    // MARK: - Paths and filesystem state

    static func standardDestination(
        target: Target,
        directoryOverride: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard let assistantTarget = target.assistantTarget, assistantTarget != .openclaw else {
            throw CLIError.message("internal: no standard destination for \(target.rawValue)")
        }
        return try AssistantIntegrationService(
            homeDirectory: home,
            environment: environment
        ).destination(
            for: assistantTarget,
            skillsDirectoryOverride: try skillsDirectoryOverride(
                directoryOverride,
                target: target,
                home: home
            )
        )
    }

    private static func skillsDirectoryOverride(
        _ directoryOverride: String?,
        target: Target,
        home: URL
    ) throws -> URL? {
        guard let directoryOverride else { return nil }
        guard let agentRootName = target.assistantTarget?.agentRootName else {
            throw CLIError.message("--directory is unavailable for \(target.rawValue)")
        }
        let expanded = try expandUserPath(directoryOverride, home: home)
        let raw = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        let knownAgentRoots = Set(
            AssistantIntegrationTarget.allCases.compactMap(\.agentRootName)
        )
        if knownAgentRoots.contains(raw.lastPathComponent),
            raw.lastPathComponent != agentRootName
        {
            throw CLIError.message(
                "--directory \(raw.path) belongs to a different assistant than \(target.rawValue)"
            )
        }
        return raw.lastPathComponent == agentRootName
            ? raw.appendingPathComponent("skills", isDirectory: true)
            : raw
    }

    static func expandUserPath(_ path: String, home: URL) throws -> String {
        guard !path.isEmpty, !path.contains("\0") else {
            throw CLIError.message("--directory must be a non-empty filesystem path")
        }
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).path }
        if path.hasPrefix("~") {
            throw CLIError.message("--directory does not support another user's home abbreviation")
        }
        return path
    }

    static func installationState(at destination: URL, source: URL) -> InstallationState {
        AssistantIntegrationService().installationState(
            at: destination,
            source: source
        )
    }

    static func replaceSkill(
        at destination: URL,
        source: URL,
        removeExisting: Bool,
        preferCopy: Bool = false
    ) throws {
        try AssistantIntegrationService().replaceSkill(
            at: destination,
            source: source,
            removeExisting: removeExisting,
            preferCopy: preferCopy
        )
    }

    // MARK: - OpenClaw registration

    private static func openClawConfigURL() -> URL {
        AssistantIntegrationService().openClawConfigURL()
    }

    static func openClawRegistration(configURL: URL, skillHome: URL) throws -> Bool {
        try AssistantIntegrationService().openClawRegistration(
            configURL: configURL,
            skillHome: skillHome
        )
    }

    @discardableResult
    static func updateOpenClawRegistration(
        configURL: URL,
        skillHome: URL,
        shouldRegister: Bool
    ) throws -> Bool {
        try AssistantIntegrationService().updateOpenClawRegistration(
            configURL: configURL,
            skillHome: skillHome,
            shouldRegister: shouldRegister
        )
    }

    // MARK: - Discovery

    private static func selectedTargets(_ requested: Target) throws -> [Target] {
        guard requested == .all else { return [requested] }
        let targets = detectedTargets()
        guard !targets.isEmpty else {
            throw CLIError.message("no supported assistants detected; choose claude, cursor, codex, grok, or openclaw explicitly")
        }
        return targets
    }

    private static func detectedTargets() -> [Target] {
        AssistantHostDiscovery().detectedTargets().compactMap {
            Target(rawValue: $0.rawValue)
        }
    }

    /// Locate the skill directory containing `SKILL.md`.
    static func resolveSkillSource() throws -> URL {
        let fm = FileManager.default
        let service = AssistantIntegrationService()

        if let env = ProcessInfo.processInfo.environment["SCREENLOG_SKILL_DIR"], !env.isEmpty {
            let expanded = try expandUserPath(env, home: fm.homeDirectoryForCurrentUser)
            let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            guard fm.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) else {
                throw CLIError.message("SCREENLOG_SKILL_DIR does not contain SKILL.md")
            }
            do {
                return try service.verifiedSkillSource(url)
            } catch {
                throw CLIError.message("SCREENLOG_SKILL_DIR does not contain a valid Screenlogger skill")
            }
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let executableDirectory = executable.deletingLastPathComponent()
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = [
            executableDirectory.appendingPathComponent("skill/\(skillFolderName)", isDirectory: true),
            executableDirectory.appendingPathComponent("Resources/skill/\(skillFolderName)", isDirectory: true),
            executableDirectory.deletingLastPathComponent().appendingPathComponent(
                "Resources/skill/\(skillFolderName)", isDirectory: true),
            executableDirectory.appendingPathComponent("Screenlogger.app/Contents/Resources/skill/\(skillFolderName)", isDirectory: true),
            executableDirectory.deletingLastPathComponent().appendingPathComponent(
                "Screenlogger.app/Contents/Resources/skill/\(skillFolderName)", isDirectory: true),
            home.appendingPathComponent("Applications/Screenlogger.app/Contents/Resources/skill/\(skillFolderName)", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Screenlogger.app/Contents/Resources/skill/\(skillFolderName)", isDirectory: true),
        ]

        #if DEBUG
            // Packaging verification disables checkout traversal so a missing
            // app resource cannot be hidden by the repository that built it.
            if ProcessInfo.processInfo.environment["SCREENLOG_DISABLE_CHECKOUT_SKILL_FALLBACK"] != "1" {
                let thisFile = URL(fileURLWithPath: #filePath)
                candidates.append(
                    thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                        .appendingPathComponent("Resources/skill/\(skillFolderName)", isDirectory: true)
                )
                candidates.append(
                    thisFile.deletingLastPathComponent().appendingPathComponent(
                        "skill/\(skillFolderName)", isDirectory: true)
                )
                for base in [URL(fileURLWithPath: fm.currentDirectoryPath), executableDirectory] {
                    var directory = base
                    for _ in 0..<8 {
                        candidates.append(directory.appendingPathComponent("Resources/skill/\(skillFolderName)", isDirectory: true))
                        candidates.append(directory.appendingPathComponent("skill/\(skillFolderName)", isDirectory: true))
                        let parent = directory.deletingLastPathComponent()
                        if parent.path == directory.path { break }
                        directory = parent
                    }
                }
            }
        #endif

        #if SWIFT_PACKAGE
            if let resource = Bundle.module.resourceURL?.appendingPathComponent("skill/\(skillFolderName)", isDirectory: true) {
                candidates.append(resource)
            }
        #endif

        for candidate in candidates {
            if fm.fileExists(atPath: candidate.appendingPathComponent("SKILL.md").path) {
                do {
                    return try service.verifiedSkillSource(candidate)
                } catch {
                    throw CLIError.message(
                        "Screenlogger could not verify its integration resources. Reinstall Screenlogger."
                    )
                }
            }
        }
        throw CLIError.message(
            "Screenlogger could not find \(skillFolderName)/SKILL.md. Reinstall Screenlogger or set SCREENLOG_SKILL_DIR."
        )
    }

    static let helpText = """
        screenlog skill - manage the Screenlogger CLI skill for local assistants

        Usage:
          screenlog skill install [claude|cursor|codex|grok|openclaw|all] [--directory PATH] [--force]
          screenlog skill status  [claude|cursor|codex|grok|openclaw|all] [--directory PATH] [--json]
          screenlog skill upgrade [claude|cursor|codex|grok|openclaw|all] [--directory PATH]
          screenlog skill remove  [claude|cursor|codex|grok|openclaw|all] [--directory PATH] [--force]

        Aliases: verify = status, uninstall = remove.
        Compatibility: `screenlog install-skill [target]` is the same as `screenlog skill install [target]`.

        Defaults (global, all projects):
          ~/.claude/skills/screenlog-cli-skill
          ~/.cursor/skills/screenlog-cli-skill
          ~/.agents/skills/screenlog-cli-skill (Codex user skills)
          ~/.grok/skills/screenlog-cli-skill (Grok Build user skills)
          OpenClaw: Application Support + skills.load.extraDirs in ~/.openclaw/openclaw.json

        `all` acts only on detected assistants. It fails if it detects none.
        --directory is a skills directory or an exact agent root such as ~/.claude.
        Install does not change a current installation.
        Upgrade replaces only older content that Screenlogger can authenticate.
        Remove refuses unrelated content and unauthenticated broken links unless you specify --force.
        Status fails unless every selected installation is current and registered.
        JSON status returns exit code 0 when every target is ready.
        It returns code 1 for operational or readiness failures after it emits JSON.
        It returns code 2 for invalid usage.

        These commands do not require Screenlogger.app to be running.
        """
}
