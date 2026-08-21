import AppKit
import Foundation
import ScreenlogCore

/// Coordinates local command access and assistant integrations.
@MainActor
extension AppModel {
    func applyCLIEnabled() {
        guard cliEnabled else {
            ScreenlogSocketHost.shared.stop()
            cliBridgeState = .disabled
            clearAssistantLiveVerification()
            writeBootstrapLog("socket IPC stopped (cliEnabled=false)")
            recordDiagnostic(.socketBridge, .stopped)
            return
        }
        guard let store else {
            cliBridgeState = .unavailable(.libraryUnavailable)
            return
        }
        cliBridgeState = .starting
        do {
            if !ScreenlogSocketHost.shared.isRunning {
                try ScreenlogSocketHost.shared.start(store: store, root: root)
            }
            synchronizeCLIBridgeStateFromHost()
            recordDiagnostic(.socketBridge, .succeeded)
            writeBootstrapLog(
                "socket IPC ok running=\(cliBridgeState.isAvailable) path=\(ScreenlogSocketPaths.socketURL(root: root).path)"
            )
        } catch {
            // Keep the underlying system error in the local bootstrap log. The
            // Settings pane gets stable, actionable copy without filesystem or
            // account details from NSError descriptions.
            cliBridgeState = .unavailable(.startFailed)
            clearAssistantLiveVerification()
            recordDiagnostic(.socketBridge, .failed)
            writeBootstrapLog("socket IPC FAILED: \(error)")
        }
    }

    func synchronizeCLIBridgeStateFromHost() {
        guard cliEnabled else {
            cliBridgeState = .disabled
            return
        }
        cliBridgeState =
            ScreenlogSocketHost.shared.isRunning
            ? .available(socketPath: ScreenlogSocketPaths.socketURL(root: root).path)
            : .unavailable(.notListening)
        if cliBridgeState.isAvailable {
            verifyAssistantAccessIfPossible()
        } else {
            clearAssistantLiveVerification()
        }
    }

    func retryCLIBridge() {
        guard cliEnabled else { return }
        clearAssistantLiveVerification()
        cliBridgeState = .starting
        ScreenlogSocketHost.shared.stop()
        applyCLIEnabled()
    }

    /// Open Settings, optionally routing directly to the pane named by the
    /// invoking control. A nil destination preserves the user's last pane.
    // MARK: - Agent skills

    typealias AgentSkillTarget = AssistantIntegrationTarget

    /// Install a matched CLI/framework pair into ~/.local/bin.
    ///
    /// The CLI links ScreenlogCore through `@executable_path`, so installing only
    /// the executable creates a command that immediately fails at dyld launch.
    func installCLIToLocalBin(announce: Bool = true) {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".local/bin",
            isDirectory: true
        )
        guard cliInstallTask == nil else { return }

        guard let artifacts = Self.cliSourceArtifacts() else {
            cliInstallState = .failed(.artifactsUnavailable)
            return
        }

        let priorInstallInspection = cancelCLIInstallInspection()
        cliInstallState = .installing
        let priorPathInspection = clearCLICommandAvailability()
        cliInstallTask = Task.detached(priority: .userInitiated) { [weak self] in
            await priorInstallInspection?.value
            await priorPathInspection?.value
            guard !Task.isCancelled else { return }
            guard let model = self else { return }
            do {
                let destination = try CLIArtifactInstallationService().install(
                    executable: artifacts.executable,
                    framework: artifacts.framework,
                    into: bin,
                    verifyStagedExecutable: Self.verifyStagedCLI
                )
                await MainActor.run {
                    model.cliInstallTask = nil
                    model.cliInstallState = .ready(path: destination.path)
                    model.prepareCLICommandAvailability(forceReset: true)
                    model.clearAssistantLiveVerification()
                    model.continueAssistantAccessVerification()
                    if announce {
                        model.statusMessage = "Terminal command installed"
                    }
                }
            } catch CLIArtifactInstallationError.conflict(let conflict) {
                await MainActor.run {
                    model.cliInstallTask = nil
                    model.cliInstallState = .conflict(conflict)
                }
            } catch CLIArtifactInstallationError.sourceArtifactsInvalid {
                await MainActor.run {
                    model.cliInstallTask = nil
                    model.cliInstallState = .failed(.artifactsInvalid)
                }
            } catch CLIArtifactInstallationError.installationRecoveryRequired(let path) {
                await MainActor.run {
                    model.cliInstallTask = nil
                    model.cliInstallState = .failed(
                        .installationRecoveryRequired(path)
                    )
                }
            } catch {
                await MainActor.run {
                    model.writeBootstrapLog("CLI artifact installation failed: \(error)")
                    model.cliInstallTask = nil
                    model.cliInstallState = .failed(.installationFailed)
                }
            }
        }
    }

    func removeCLIFromLocalBin() {
        let bin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        guard cliInstallTask == nil else { return }

        let priorInstallInspection = cancelCLIInstallInspection()
        cliInstallState = .removing
        let priorPathInspection = clearCLICommandAvailability()
        cliInstallTask = Task.detached(priority: .userInitiated) { [weak self] in
            await priorInstallInspection?.value
            await priorPathInspection?.value
            guard !Task.isCancelled else { return }
            guard let model = self else { return }
            do {
                try CLIArtifactInstallationService().remove(from: bin)
                await MainActor.run {
                    model.cliInstallTask = nil
                    model.cliInstallState = .notInstalled
                    model.clearCLICommandAvailability()
                    model.clearAssistantLiveVerification()
                    model.statusMessage = "Terminal command removed"
                }
            } catch CLIArtifactInstallationError.conflict(let conflict) {
                await MainActor.run {
                    model.cliInstallTask = nil
                    model.cliInstallState = .conflict(conflict)
                }
            } catch CLIArtifactInstallationError.removalRecoveryRequired(let path) {
                await MainActor.run {
                    model.cliInstallTask = nil
                    model.cliInstallState = .failed(
                        .removalRecoveryRequired(path)
                    )
                }
            } catch {
                await MainActor.run {
                    model.writeBootstrapLog("CLI artifact removal failed: \(error)")
                    model.cliInstallTask = nil
                    model.cliInstallState = .failed(.removalFailed)
                }
            }
        }
    }

    func refreshCLIInstallState(automaticallyUpgradeManaged: Bool = false) {
        guard !cliInstallState.isBusy else { return }
        let bin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        let executable = bin.appendingPathComponent("screenlog")
        let priorInspection = cancelCLIInstallInspection()
        let requestID = UUID()
        cliInstallInspectionRequestID = requestID
        cliInstallInspectionTask = Task.detached(priority: .utility) { [weak self] in
            await priorInspection?.value
            guard !Task.isCancelled else { return }
            let service = CLIArtifactInstallationService()
            let recovery = service.pendingRecovery(in: bin)
            let artifacts = Self.cliSourceArtifacts()
            let inspection = service.inspect(
                in: bin,
                sourceExecutable: artifacts?.executable,
                sourceFramework: artifacts?.framework
            )
            guard !Task.isCancelled, let model = self else { return }
            await MainActor.run {
                guard model.cliInstallInspectionRequestID == requestID else { return }
                model.cliInstallInspectionTask = nil
                model.cliInstallInspectionRequestID = nil
                guard !model.cliInstallState.isBusy else { return }
                if let recovery {
                    model.cliInstallState = .failed(CLIInstallFailure(recovery: recovery))
                } else {
                    model.cliInstallState = CLIInstallState(
                        inspection: inspection,
                        commandPath: executable.path,
                        bundledArtifactsAvailable: artifacts != nil
                    )
                }
                model.prepareCLICommandAvailability()
                model.continueAssistantAccessVerification()
                if automaticallyUpgradeManaged,
                    inspection.needsAutomaticUpgrade,
                    artifacts != nil
                {
                    model.installCLIToLocalBin(announce: false)
                }
            }
        }
    }

    func prepareCLICommandAvailability(forceReset: Bool = false) {
        guard cliInstallState.isReady, let commandPath = cliInstallState.commandPath else {
            clearCLICommandAvailability()
            return
        }
        guard
            cliCommandAvailability.needsPreparation(
                expectedPath: commandPath,
                forceReset: forceReset
            )
        else {
            return
        }
        clearCLICommandAvailability()
        cliCommandAvailability = CLICommandAvailabilityService.notChecked(
            expectedExecutable: URL(fileURLWithPath: commandPath)
        )
    }

    func checkCLICommandAvailability() {
        guard cliInstallState.isReady, let commandPath = cliInstallState.commandPath else {
            clearCLICommandAvailability()
            return
        }
        guard cliPathInspectionTask == nil else { return }

        let expectedExecutable = URL(fileURLWithPath: commandPath)
        cliCommandAvailability = .checking
        cliPathInspectionTask = Task.detached(priority: .utility) { [weak self] in
            let availability = CLICommandAvailabilityService.inspect(
                expectedExecutable: expectedExecutable
            )
            guard !Task.isCancelled, let model = self else { return }
            await MainActor.run {
                guard
                    model.cliInstallState.commandPath == expectedExecutable.path
                else { return }
                model.cliPathInspectionTask = nil
                model.cliCommandAvailability = availability
                model.clearAssistantLiveVerification()
                model.verifyAssistantAccessIfPossible()
            }
        }
    }

    @discardableResult
    func clearCLICommandAvailability() -> Task<Void, Never>? {
        let task = cliPathInspectionTask
        task?.cancel()
        cliPathInspectionTask = nil
        cliCommandAvailability = .unknown
        clearAssistantLiveVerification()
        return task
    }

    func checkAssistantLiveVerification() {
        guard assistantLiveVerificationTask == nil,
            case .ready(let commandPath) = cliInstallState,
            cliCommandAvailability.isAvailable,
            cliBridgeState.isAvailable
        else { return }

        clearAssistantTestSearch()
        assistantLiveVerificationState = .notRun
        assistantLiveVerificationIsRunning = true
        let executable = URL(fileURLWithPath: commandPath)
        let requestID = UUID()
        assistantLiveVerificationRequestID = requestID
        assistantLiveVerificationTask = Task.detached(priority: .utility) { [weak self] in
            let state = AssistantLiveVerificationService.verify(executable: executable)
            guard !Task.isCancelled, let model = self else { return }
            await MainActor.run {
                guard model.assistantLiveVerificationRequestID == requestID else { return }
                guard model.cliInstallState.commandPath == commandPath,
                    model.cliCommandAvailability.isAvailable,
                    model.cliBridgeState.isAvailable
                else {
                    model.assistantLiveVerificationTask = nil
                    model.assistantLiveVerificationRequestID = nil
                    model.assistantLiveVerificationIsRunning = false
                    model.assistantLiveVerificationState = .notRun
                    return
                }
                model.assistantLiveVerificationTask = nil
                model.assistantLiveVerificationRequestID = nil
                model.assistantLiveVerificationIsRunning = false
                model.assistantLiveVerificationState = state
            }
        }
    }

    @discardableResult
    func clearAssistantLiveVerification() -> Task<Void, Never>? {
        let task = assistantLiveVerificationTask
        task?.cancel()
        assistantLiveVerificationTask = nil
        assistantLiveVerificationRequestID = nil
        assistantLiveVerificationIsRunning = false
        assistantLiveVerificationState = .notRun
        clearAssistantTestSearch()
        return task
    }

    func runAssistantTestSearch() {
        guard assistantTestSearchTask == nil,
            case .ready(let commandPath) = cliInstallState,
            cliCommandAvailability.isAvailable,
            cliBridgeState.isAvailable,
            assistantLiveVerificationState == .succeeded
        else { return }

        assistantTestSearchOutcome = nil
        assistantTestSearchIsRunning = true
        let executable = URL(fileURLWithPath: commandPath)
        let requestID = UUID()
        assistantTestSearchRequestID = requestID
        assistantTestSearchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = AssistantTestSearchService.test(executable: executable)
            guard !Task.isCancelled, let model = self else { return }
            await MainActor.run {
                guard model.assistantTestSearchRequestID == requestID else { return }
                guard model.cliInstallState.commandPath == commandPath,
                    model.cliCommandAvailability.isAvailable,
                    model.cliBridgeState.isAvailable,
                    model.assistantLiveVerificationState == .succeeded
                else {
                    model.assistantTestSearchTask = nil
                    model.assistantTestSearchRequestID = nil
                    model.assistantTestSearchIsRunning = false
                    model.assistantTestSearchOutcome = nil
                    return
                }
                model.assistantTestSearchTask = nil
                model.assistantTestSearchRequestID = nil
                model.assistantTestSearchIsRunning = false
                model.assistantTestSearchOutcome = outcome
            }
        }
    }

    @discardableResult
    func clearAssistantTestSearch() -> Task<Void, Never>? {
        let task = assistantTestSearchTask
        task?.cancel()
        assistantTestSearchTask = nil
        assistantTestSearchRequestID = nil
        assistantTestSearchIsRunning = false
        assistantTestSearchOutcome = nil
        return task
    }

    func assistantOperationalReadiness(
        for target: AgentSkillTarget
    ) -> AssistantIntegrationOperationalReadiness {
        let snapshot = agentSkillSnapshotState(target).snapshot
        let host: AssistantIntegrationHostState =
            snapshot?.presence.isPresent == true ? .usable : .notDetected
        let integrationFiles = snapshot?.inspection?.readiness ?? .notInstalled
        return AssistantIntegrationOperationalReadinessEvaluator().evaluate(
            AssistantIntegrationOperationalInputs(
                host: host,
                integrationFiles: integrationFiles,
                managedCLI: cliInstallState,
                shellCommand: assistantShellCommandResolution,
                bridge: cliBridgeState,
                liveVerification: assistantLiveVerificationState
            )
        )
    }

    private func verifyAssistantAccessIfPossible() {
        guard assistantLiveVerificationState == .notRun else { return }
        checkAssistantLiveVerification()
    }

    private func continueAssistantAccessVerification() {
        switch cliCommandAvailability.automaticAssistantAccessVerificationAction {
        case .checkCommandAvailability:
            checkCLICommandAvailability()
        case .verifyLiveAccess:
            verifyAssistantAccessIfPossible()
        case .noAction:
            break
        }
    }

    private var assistantShellCommandResolution: AssistantIntegrationShellCommandResolution {
        switch cliCommandAvailability {
        case .available(let path):
            return .resolved(path: path)
        case .shadowed(_, let resolvedPath, _):
            return .resolved(path: resolvedPath)
        case .unavailable:
            return .missing
        case .checkFailed:
            return .checkFailed
        case .unknown, .notChecked, .checking:
            return .notChecked
        }
    }

    @discardableResult
    private func cancelCLIInstallInspection() -> Task<Void, Never>? {
        let task = cliInstallInspectionTask
        task?.cancel()
        cliInstallInspectionTask = nil
        cliInstallInspectionRequestID = nil
        return task
    }

    nonisolated private static func cliSourceArtifacts() -> CLIInstallationArtifacts? {
        let fm = FileManager.default
        let service = CLIArtifactInstallationService()
        // Release builds trust only the command embedded in Screenlogger.app.
        // Developer builds retain local-product and PATH discovery for iteration.
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL {
            candidates.append(
                executable.deletingLastPathComponent().appendingPathComponent("screenlog")
            )
        }

        #if DEBUG
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Sources/ScreenlogApp
                .deletingLastPathComponent()  // Sources
                .deletingLastPathComponent()  // repository
            candidates.append(
                repositoryRoot.appendingPathComponent(
                    "build/DerivedData/Build/Products/Release/screenlog"
                ))
            candidates.append(
                repositoryRoot.appendingPathComponent(
                    "build/DerivedData/Build/Products/Debug/screenlog"
                ))
            if let path = ProcessInfo.processInfo.environment["PATH"] {
                for component in path.split(separator: ":") {
                    candidates.append(
                        URL(fileURLWithPath: String(component)).appendingPathComponent("screenlog")
                    )
                }
            }
        #endif

        let bundledFramework = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("ScreenlogCore.framework", isDirectory: true)
        return candidates.lazy.compactMap { executable -> CLIInstallationArtifacts? in
            guard fm.isExecutableFile(atPath: executable.path) else { return nil }
            let productDirectory = executable.deletingLastPathComponent()
            let frameworks = [
                productDirectory.appendingPathComponent(
                    "ScreenlogCore.framework",
                    isDirectory: true
                ),
                productDirectory.appendingPathComponent(
                    "Frameworks/ScreenlogCore.framework",
                    isDirectory: true
                ),
                bundledFramework,
            ].compactMap { $0 }
            guard
                let framework = frameworks.first(where: {
                    service.sourceArtifactsAreValid(
                        executable: executable,
                        framework: $0
                    )
                })
            else { return nil }
            return CLIInstallationArtifacts(executable: executable, framework: framework)
        }.first
    }

    func revealCLIInstallConflict() {
        guard let conflict = cliInstallState.conflict else { return }
        let existing = conflict.paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            NSWorkspace.shared.open(
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin", isDirectory: true)
            )
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }

    func revealCLIRecoveryDirectory() {
        guard let path = cliInstallState.recoveryDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: path, isDirectory: true)
        ])
    }

    nonisolated private static func verifyStagedCLI(_ executable: URL) throws {
        let verification = Process()
        verification.executableURL = executable
        verification.arguments = ["--version"]
        verification.standardOutput = FileHandle.nullDevice
        verification.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        verification.terminationHandler = { _ in completed.signal() }
        try verification.run()
        guard completed.wait(timeout: .now() + 10) == .success else {
            verification.terminate()
            throw NSError(
                domain: "dev.screenlog.cli-install",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The launch check timed out."]
            )
        }
        guard verification.terminationReason == .exit, verification.terminationStatus == 0 else {
            throw NSError(
                domain: "dev.screenlog.cli-install",
                code: Int(verification.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "The staged screenlog command failed its launch check."]
            )
        }
    }

    func agentSkillSnapshotState(
        _ target: AgentSkillTarget
    ) -> AgentSkillSnapshotLoadState {
        agentSkillSnapshotStates[target] ?? .idle
    }

    func assistantIntegrationWork(
        for target: AgentSkillTarget
    ) -> AssistantIntegrationWorkKind? {
        assistantIntegrationWorkRegistry.work(for: target)
    }

    func assistantIntegrationActionNotice(
        for target: AgentSkillTarget
    ) -> AssistantIntegrationActionNotice? {
        assistantIntegrationActionNotices[target]
    }

    var integrationRefreshIsActive: Bool {
        cliInstallState.isBusy || cliInstallInspectionTask != nil
            || cliCommandAvailability.isChecking
            || assistantLiveVerificationIsRunning
            || assistantTestSearchIsRunning
            || AgentSkillTarget.allCases.contains {
                assistantIntegrationWork(for: $0) != nil
            }
    }

    /// Rechecks the complete Integrations page. A short automatic-refresh
    /// coalescing window prevents pane appearance and app activation from
    /// launching the same discovery work twice.
    func refreshIntegrationSettings(automatic: Bool) {
        #if DEBUG
            if AppUITestFixture.installIsolatedAssistantStateIfRequested(on: self) {
                return
            }
        #endif
        if automatic, let lastAutomaticIntegrationRefreshAt,
            Date().timeIntervalSince(lastAutomaticIntegrationRefreshAt) < 1
        {
            return
        }
        if automatic { lastAutomaticIntegrationRefreshAt = Date() }
        if !automatic { clearAssistantLiveVerification() }
        refreshCLIInstallState(automaticallyUpgradeManaged: true)
        for target in AgentSkillTarget.allCases {
            assistantIntegrationActionNotices[target] = nil
            startAgentSkillInspection(target, feedback: .automaticMaintenance)
        }
    }

    /// Retained for entry points that only need the initial cached discovery.
    func loadAssistantIntegrationsIfNeeded() {
        for target in AgentSkillTarget.allCases
        where agentSkillSnapshotState(target) == .idle {
            startAgentSkillInspection(target, feedback: .silent)
        }
    }

    func reinspectUnavailableAgentSkill(_ target: AgentSkillTarget) {
        assistantIntegrationActionNotices[target] = nil
        startAgentSkillInspection(target, feedback: .availability)
    }

    func reinspectAgentSkill(_ target: AgentSkillTarget) {
        assistantIntegrationActionNotices[target] = nil
        startAgentSkillInspection(target, feedback: .inspectionStatus)
    }

    /// Short subtitle for Agents pane.
    func agentPresenceDetail(_ target: AgentSkillTarget) -> String {
        let state = agentSkillSnapshotState(target)
        guard let snapshot = state.snapshot else { return "Checking this Mac..." }
        let d = snapshot.presence
        let inspection = snapshot.inspection
        guard let inspection else {
            if let issue = snapshot.inspectionIssue {
                return assistantIntegrationInspectionIssueDetail(issue)
            }
            return d.isPresent
                ? "Detected, but integration status is unavailable"
                : "Not detected; integration status is unavailable"
        }
        if !d.isPresent {
            return inspection.isOwned
                ? "Not detected, but integration files are present"
                : "Not on this Mac"
        }
        var bits: [String] = []
        if d.appURL != nil { bits.append("App") }
        if d.cliURL != nil { bits.append("CLI") }
        switch inspection.readiness {
        case .ready:
            bits.append("integration installed")
        case .setupIncomplete:
            bits.append("registration needed")
        case .updateAvailable:
            bits.append("update available")
        case .blocked(let state):
            if case .brokenLink = state {
                bits.append("integration link is broken")
            } else {
                bits.append("integration path is in use")
            }
        case .notInstalled:
            break
        }
        return bits.isEmpty ? "Detected" : bits.joined(separator: ", ")
    }

    func installAgentSkill(
        _ target: AgentSkillTarget,
        reinstall: Bool = false,
        announce: Bool = true
    ) {
        if announce {
            assistantIntegrationActionNotices[target] = nil
        }
        guard
            let token = beginAssistantIntegrationWork(
                .installation,
                target: target
            )
        else { return }

        agentSkillTasks[target] = Task { [weak self] in
            do {
                let result = try await AgentSkillInstaller.install(
                    target: target,
                    reinstall: reinstall
                )
                guard !Task.isCancelled else { return }
                self?.completeAgentSkillInstall(
                    result,
                    target: target,
                    token: token,
                    announce: announce
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.completeAssistantIntegrationFailure(
                    error,
                    kind: .installation,
                    target: target,
                    token: token,
                    announce: announce
                )
            }
        }
    }

    func removeAgentSkill(_ target: AgentSkillTarget) {
        assistantIntegrationActionNotices[target] = nil
        guard
            let token = beginAssistantIntegrationWork(
                .removal,
                target: target
            )
        else { return }

        agentSkillTasks[target] = Task { [weak self] in
            do {
                let result = try await AgentSkillInstaller.remove(target: target)
                guard !Task.isCancelled else { return }
                self?.completeAgentSkillRemoval(result, target: target, token: token)
            } catch {
                guard !Task.isCancelled else { return }
                self?.completeAssistantIntegrationFailure(
                    error,
                    kind: .removal,
                    target: target,
                    token: token
                )
            }
        }
    }

    private func startAgentSkillInspection(
        _ target: AgentSkillTarget,
        feedback: AgentSkillInspectionFeedback
    ) {
        guard
            let token = beginAssistantIntegrationWork(
                .inspection,
                target: target
            )
        else { return }

        let previous = agentSkillSnapshotState(target).snapshot
        agentSkillSnapshotStates[target] = .loading(previous: previous)
        agentSkillTasks[target] = Task { [weak self] in
            let snapshot = await AgentSkillInstaller.snapshot(target: target)
            guard !Task.isCancelled else { return }
            self?.completeAgentSkillInspection(
                snapshot,
                target: target,
                token: token,
                feedback: feedback
            )
        }
    }

    private func completeAgentSkillInspection(
        _ snapshot: AgentSkillSnapshot,
        target: AgentSkillTarget,
        token: UUID,
        feedback: AgentSkillInspectionFeedback
    ) {
        guard finishAssistantIntegrationWork(.inspection, target: target, token: token) else {
            return
        }
        agentSkillSnapshotStates[target] = .loaded(snapshot)
        switch feedback {
        case .silent:
            break
        case .automaticMaintenance:
            guard snapshot.inspection?.needsAutomaticMaintenance == true else { return }
            installAgentSkill(target, announce: false)
        case .availability:
            if let issue = snapshot.inspectionIssue {
                publishAssistantIntegrationNotice(
                    .failed(AssistantIntegrationActionFailure(issue)),
                    for: target
                )
            } else {
                publishAssistantIntegrationNotice(
                    snapshot.inspection == nil
                        ? .inspectionUnavailable(target)
                        : .inspectionAvailableAgain(target),
                    for: target
                )
            }
        case .inspectionStatus:
            guard let inspection = snapshot.inspection else {
                let notice =
                    snapshot.inspectionIssue.map {
                        AssistantIntegrationActionNotice.failed(
                            AssistantIntegrationActionFailure($0)
                        )
                    } ?? .inspectionUnavailable(target)
                publishAssistantIntegrationNotice(notice, for: target)
                return
            }
            publishAssistantIntegrationNotice(
                inspection.isCurrent
                    ? .inspectionCurrent(target)
                    : .inspectionUnchanged(target),
                for: target
            )
        }
    }

    private func completeAgentSkillInstall(
        _ result: AgentSkillMutationResult,
        target: AgentSkillTarget,
        token: UUID,
        announce: Bool
    ) {
        guard finishAssistantIntegrationWork(.installation, target: target, token: token) else {
            return
        }
        agentSkillSnapshotStates[target] = .loaded(result.snapshot)
        if announce {
            publishAssistantIntegrationNotice(
                result.change.changed ? .installed(target) : .verified(target),
                for: target
            )
            statusMessage = "\(target.label) integration files installed"
        }
    }

    private func completeAgentSkillRemoval(
        _ result: AgentSkillMutationResult,
        target: AgentSkillTarget,
        token: UUID
    ) {
        guard finishAssistantIntegrationWork(.removal, target: target, token: token) else {
            return
        }
        agentSkillSnapshotStates[target] = .loaded(result.snapshot)
        let notice: AssistantIntegrationActionNotice =
            result.change.changed ? .removed(target) : .alreadyRemoved(target)
        publishAssistantIntegrationNotice(notice, for: target)
        statusMessage = notice.message
    }

    private func completeAssistantIntegrationFailure(
        _ error: Error,
        kind: AssistantIntegrationWorkKind,
        target: AgentSkillTarget,
        token: UUID,
        announce: Bool = true
    ) {
        guard finishAssistantIntegrationWork(kind, target: target, token: token) else { return }
        if announce {
            publishAssistantIntegrationNotice(
                .failed(assistantIntegrationActionFailure(error)),
                for: target
            )
        }
        let operation = kind == .removal ? "removal" : "install"
        writeBootstrapLog(
            "assistant integration \(operation) failed target=\(target.rawValue): \(error)"
        )
        // Lifecycle operations are transactional, but a fresh background
        // inspection still keeps Settings truthful after any OS-level failure.
        startAgentSkillInspection(target, feedback: .silent)
    }

    private func beginAssistantIntegrationWork(
        _ kind: AssistantIntegrationWorkKind,
        target: AgentSkillTarget
    ) -> UUID? {
        let token = UUID()
        var registry = assistantIntegrationWorkRegistry
        guard registry.start(kind, for: target, token: token) else { return nil }
        assistantIntegrationWorkRegistry = registry
        return token
    }

    @discardableResult
    private func finishAssistantIntegrationWork(
        _ kind: AssistantIntegrationWorkKind,
        target: AgentSkillTarget,
        token: UUID
    ) -> Bool {
        var registry = assistantIntegrationWorkRegistry
        guard registry.finish(kind, for: target, token: token) else { return false }
        assistantIntegrationWorkRegistry = registry
        agentSkillTasks[target] = nil
        return true
    }

    /// Exact paths remain available in the dedicated resolution sheet, where
    /// the user explicitly reviews them; arbitrary error details stay in logs.
    private func assistantIntegrationActionFailure(_ error: Error) -> AssistantIntegrationActionFailure {
        guard let issue = error as? AssistantIntegrationError else {
            return .unknown
        }
        return AssistantIntegrationActionFailure(issue)
    }

    private func assistantIntegrationInspectionIssueDetail(
        _ issue: AssistantIntegrationError
    ) -> String {
        switch issue {
        case .configMissing:
            return "Open OpenClaw once to create its settings, then check again"
        case .malformedConfiguration:
            return "OpenClaw settings need repair before setup can continue"
        case .sourceMissing:
            return "Reinstall Screenlogger to restore its integration files"
        case .destinationNeedsUpgrade:
            return "Integration update required"
        case .destinationNotOwned:
            return "Integration location is already in use"
        case .unsafeDestination:
            return "Unsafe integration location was left unchanged"
        case .replacementFailed:
            return "Integration check failed; existing files were preserved"
        }
    }

    private func publishAssistantIntegrationNotice(
        _ notice: AssistantIntegrationActionNotice,
        for target: AgentSkillTarget
    ) {
        assistantIntegrationActionNotices[target] = notice
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: notice.message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

}

private enum AgentSkillInspectionFeedback: Sendable {
    case silent
    case automaticMaintenance
    case availability
    case inspectionStatus
}

private struct CLIInstallationArtifacts: Sendable {
    let executable: URL
    let framework: URL
}
