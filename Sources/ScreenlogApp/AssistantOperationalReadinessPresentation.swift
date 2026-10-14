import ScreenlogCore

struct AssistantOperationalReadinessPresentation: Equatable {
    enum Tone: Equatable {
        case neutral
        case attention
        case success
    }

    enum PrimaryAction: Equatable {
        case installIntegration
        case resolveIntegration
        case openLocalTools
        case none
    }

    let badge: String
    let detail: String
    let tone: Tone
    let actionTitle: String?
    let primaryAction: PrimaryAction

    static func make(
        readiness: AssistantIntegrationOperationalReadiness,
        target: AssistantIntegrationTarget
    ) -> Self {
        switch readiness {
        case .localConnectionVerified:
            return Self(
                badge: "Connection verified",
                detail:
                    "Screenlogger verified its connection files and Terminal command. Screenlogger has not tested a search inside \(target.label). Restart \(target.label) after installation. Then try a small search there.",
                tone: .success,
                actionTitle: nil,
                primaryAction: .none
            )
        case .blocked(let blocker):
            return blocked(blocker, target: target)
        }
    }

    private static func blocked(
        _ blocker: AssistantIntegrationOperationalBlocker,
        target: AssistantIntegrationTarget
    ) -> Self {
        switch blocker {
        case .assistantHost(.notDetected):
            return unavailableHost(
                badge: "Not detected",
                detail: "Install \(target.label) on this Mac before adding its connection."
            )
        case .assistantHost(.notUsable):
            return unavailableHost(
                badge: "Compatible host needed",
                detail: "The detected app cannot run Screenlogger's connection. Install \(target.label) or its command-line tool."
            )
        case .integrationFiles(let issue):
            return integrationFiles(issue)
        case .managedCLI(let issue):
            return managedCLI(issue)
        case .shellCommand(let issue):
            return shellCommand(issue)
        case .bridge(let issue):
            return bridge(issue)
        case .liveVerification(let issue):
            return liveVerification(issue)
        }
    }

    private static func unavailableHost(badge: String, detail: String) -> Self {
        Self(
            badge: badge,
            detail: detail,
            tone: .neutral,
            actionTitle: nil,
            primaryAction: .none
        )
    }

    private static func integrationFiles(_ issue: AssistantIntegrationFilesIssue) -> Self {
        switch issue {
        case .notInstalled:
            return setupFiles(badge: "Not connected", actionTitle: "Install")
        case .updateAvailable:
            return setupFiles(badge: "Update available", actionTitle: "Update")
        case .setupIncomplete:
            return setupFiles(badge: "Finish setup", actionTitle: "Finish Setup")
        case .blocked:
            return Self(
                badge: "Needs attention",
                detail: "The connection location needs review before Screenlogger changes it.",
                tone: .attention,
                actionTitle: "Resolve...",
                primaryAction: .resolveIntegration
            )
        }
    }

    private static func setupFiles(badge: String, actionTitle: String) -> Self {
        Self(
            badge: badge,
            detail: "Install the Screenlogger connection files. Then complete Command Setup.",
            tone: .attention,
            actionTitle: actionTitle,
            primaryAction: .installIntegration
        )
    }

    private static func managedCLI(_ issue: AssistantIntegrationManagedCLIIssue) -> Self {
        let detail: String
        switch issue {
        case .notInstalled:
            detail = "The managed Terminal command is not installed."
        case .installing:
            detail = "Screenlogger is installing the managed Terminal command."
        case .removing:
            detail = "Screenlogger is removing the managed Terminal command."
        case .updateAvailable:
            detail = "The managed Terminal command needs an update."
        case .verificationUnavailable:
            detail = "Screenlogger cannot verify the installed command against this app."
        case .conflict:
            detail = "Another item is using the managed command location."
        case .failed:
            detail = "The managed command needs recovery in Command Setup."
        }
        return localTools(detail: detail)
    }

    private static func shellCommand(_ issue: AssistantIntegrationShellCommandIssue) -> Self {
        let detail: String
        switch issue {
        case .notChecked:
            detail = "Check whether your login shell finds Screenlogger's managed command."
        case .missing:
            detail = "Terminal cannot find the managed screenlog command."
        case .checkFailed:
            detail = "Screenlogger could not complete the login-shell check."
        case .shadowed:
            detail = "Terminal finds a different screenlog command before the managed copy."
        }
        return localTools(detail: detail)
    }

    private static func bridge(_ issue: AssistantIntegrationBridgeIssue) -> Self {
        let detail: String
        switch issue {
        case .disabled:
            detail = "Turn on the private connection in Command Setup."
        case .starting:
            detail = "The private connection is starting."
        case .unavailable:
            detail = "The private connection is unavailable. Try again."
        }
        return localTools(detail: detail)
    }

    private static func localTools(detail: String) -> Self {
        Self(
            badge: "Finish Command Setup",
            detail: detail,
            tone: .attention,
            actionTitle: "Open Command Setup",
            primaryAction: .openLocalTools
        )
    }

    private static func liveVerification(
        _ issue: AssistantIntegrationLiveVerificationIssue
    ) -> Self {
        let badge: String
        let detail: String
        switch issue {
        case .notRun:
            badge = "Not verified"
            detail = "Verify the Screenlogger command before using this connection."
        case .failed(.appUnavailable):
            badge = "App unavailable"
            detail = "The managed command could not reach Screenlogger."
        case .failed(.protocolMismatch):
            badge = "Update required"
            detail = "The app and managed command do not use a compatible protocol."
        case .failed(.versionMismatch):
            badge = "Command mismatch"
            detail = "The verified command does not match this version of Screenlogger."
        case .failed(.invalidResponse):
            badge = "Unexpected response"
            detail = "The managed command returned a response Screenlogger could not verify."
        case .failed(.commandFailed):
            badge = "Verification failed"
            detail = "The managed command found a Library problem or could not complete its check."
        }
        return localTools(detail: detail, badge: badge)
    }

    private static func localTools(detail: String, badge: String) -> Self {
        Self(
            badge: badge,
            detail: detail,
            tone: .attention,
            actionTitle: "Open Command Setup",
            primaryAction: .openLocalTools
        )
    }
}
