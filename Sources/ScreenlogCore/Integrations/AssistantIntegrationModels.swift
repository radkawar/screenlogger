import Foundation

/// Assistants supported by both the app and `screenlog skill`.
public enum AssistantIntegrationTarget: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case cursor
    case codex
    case grok
    case openclaw

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .grok: return "Grok Build"
        case .openclaw: return "OpenClaw"
        }
    }

    public var agentRootName: String? {
        switch self {
        case .claude: return ".claude"
        case .cursor: return ".cursor"
        // Codex discovers user-scoped skills from the shared agent directory.
        case .codex: return ".agents"
        case .grok: return ".grok"
        case .openclaw: return nil
        }
    }
}

/// Filesystem state for an assistant integration directory.
public enum AssistantIntegrationState: Equatable, Sendable {
    case missing
    case currentLink
    case currentCopy
    case staleLink(String)
    case staleCopy
    case brokenLink(String)
    case conflict

    public var isCurrent: Bool {
        self == .currentLink || self == .currentCopy
    }

    /// Stale content bearing Screenlogger's manifest can be safely upgraded or
    /// removed. Broken links and unrelated nodes cannot be authenticated.
    public var isOwned: Bool {
        switch self {
        case .currentLink, .currentCopy, .staleLink, .staleCopy:
            return true
        case .missing, .brokenLink, .conflict:
            return false
        }
    }

    public var requiresForce: Bool {
        switch self {
        case .brokenLink, .conflict: return true
        default: return false
        }
    }

    public var statusDescription: String {
        switch self {
        case .missing: return "not installed"
        case .currentLink: return "installed (current symlink)"
        case .currentCopy: return "installed (current copy)"
        case .staleLink: return "needs upgrade (previous symlink)"
        case .staleCopy: return "needs upgrade (copied content differs)"
        case .brokenLink: return "blocked by a broken symlink"
        case .conflict: return "blocked by an unrelated file"
        }
    }
}

public struct AssistantIntegrationInspection: Equatable, Sendable {
    public let target: AssistantIntegrationTarget
    public let destination: URL
    public let state: AssistantIntegrationState
    /// Only OpenClaw requires an explicit configuration entry.
    public let isRegistered: Bool?

    public init(
        target: AssistantIntegrationTarget,
        destination: URL,
        state: AssistantIntegrationState,
        isRegistered: Bool?
    ) {
        self.target = target
        self.destination = destination
        self.state = state
        self.isRegistered = isRegistered
    }

    public var isCurrent: Bool {
        state.isCurrent && (isRegistered ?? true)
    }

    public var isOwned: Bool {
        state.isOwned
    }

    public var readiness: AssistantIntegrationReadiness {
        if state.requiresForce { return .blocked(state) }
        if !state.isCurrent {
            return state.isOwned ? .updateAvailable : .notInstalled
        }
        if isRegistered == false { return .setupIncomplete }
        return .ready
    }

    /// Relaunch maintenance upgrades only a previously installed integration
    /// that Screenlogger can still authenticate. Missing and blocked targets
    /// remain untouched.
    public var needsAutomaticMaintenance: Bool {
        guard isOwned else { return false }
        switch readiness {
        case .updateAvailable, .setupIncomplete:
            return true
        case .ready, .notInstalled, .blocked:
            return false
        }
    }
}

/// User-facing readiness shared by Settings and `screenlog skill status`.
public enum AssistantIntegrationReadiness: Equatable, Sendable {
    case ready
    case notInstalled
    case updateAvailable
    case setupIncomplete
    case blocked(AssistantIntegrationState)

    public var statusDescription: String {
        switch self {
        case .ready: return "ready"
        case .notInstalled: return "not installed"
        case .updateAvailable: return "update available"
        case .setupIncomplete: return "setup incomplete"
        case .blocked(let state): return state.statusDescription
        }
    }
}

/// Explicit replacement intent shared by Settings and the CLI.
public enum AssistantIntegrationInstallMode: Sendable, Equatable {
    /// Install only when missing. Current installations are a no-op.
    case install
    /// Install when missing or upgrade authenticated stale content.
    case upgrade
    /// Re-publish current or stale authenticated content; never touch conflicts.
    case reinstallOwned
    /// Replace any destination. Reserved for an explicit CLI `--force`.
    case force
}

public struct AssistantIntegrationChange: Equatable, Sendable {
    public let inspection: AssistantIntegrationInspection
    public let changedURLs: [URL]

    public init(
        inspection: AssistantIntegrationInspection,
        changedURLs: [URL]
    ) {
        self.inspection = inspection
        self.changedURLs = changedURLs
    }

    public var changed: Bool { !changedURLs.isEmpty }
}

public enum AssistantIntegrationError: LocalizedError, Equatable, Sendable {
    case sourceMissing(String)
    case configMissing(String)
    case malformedConfiguration(String)
    case destinationNeedsUpgrade(String)
    case destinationNotOwned(String)
    case unsafeDestination(String)
    case replacementFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "Screenlogger integration resources are unavailable. Reinstall Screenlogger and try again."
        case .configMissing:
            return "OpenClaw configuration is unavailable. Install or open OpenClaw first."
        case .malformedConfiguration:
            return "OpenClaw configuration is invalid and was left unchanged."
        case .destinationNeedsUpgrade:
            return "The installed Screenlogger integration needs an explicit upgrade."
        case .destinationNotOwned:
            return "The integration location contains an item Screenlogger cannot authenticate, so it was left unchanged."
        case .unsafeDestination:
            return "Screenlogger refused an unsafe integration location."
        case .replacementFailed:
            return "The integration could not be replaced. The previous installation was preserved."
        }
    }
}

/// Work that may inspect or mutate an assistant integration. Settings uses
/// this value as its single source of truth for progress and duplicate-action
/// prevention while the filesystem work runs away from the main actor.
public enum AssistantIntegrationWorkKind: Equatable, Sendable {
    case inspection
    case installation
    case removal
}

/// Token registry for assistant-integration work. A token makes completion
/// generation-safe: an older task cannot publish over a newer request, and a
/// target can never have two filesystem mutations in flight at once.
public struct AssistantIntegrationWorkRegistry: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let kind: AssistantIntegrationWorkKind
        public let token: UUID

        public init(kind: AssistantIntegrationWorkKind, token: UUID) {
            self.kind = kind
            self.token = token
        }
    }

    public private(set) var entries: [AssistantIntegrationTarget: Entry]

    public init(entries: [AssistantIntegrationTarget: Entry] = [:]) {
        self.entries = entries
    }

    public func work(for target: AssistantIntegrationTarget) -> AssistantIntegrationWorkKind? {
        entries[target]?.kind
    }

    /// Returns false when any inspection or mutation already owns the target.
    /// Callers can therefore make every UI entry point idempotent.
    @discardableResult
    public mutating func start(
        _ kind: AssistantIntegrationWorkKind,
        for target: AssistantIntegrationTarget,
        token: UUID
    ) -> Bool {
        guard entries[target] == nil else { return false }
        entries[target] = Entry(kind: kind, token: token)
        return true
    }

    /// Completes only the exact generation that started the work.
    @discardableResult
    public mutating func finish(
        _ kind: AssistantIntegrationWorkKind,
        for target: AssistantIntegrationTarget,
        token: UUID
    ) -> Bool {
        guard entries[target] == Entry(kind: kind, token: token) else { return false }
        entries[target] = nil
        return true
    }

    /// Invalidates a task without allowing its eventual result to publish.
    @discardableResult
    public mutating func cancel(
        for target: AssistantIntegrationTarget,
        token: UUID
    ) -> Bool {
        guard entries[target]?.token == token else { return false }
        entries[target] = nil
        return true
    }
}
