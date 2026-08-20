import Foundation

/// Whether Ask Assistant is a primary Library control, and where an invoked
/// ask should go. The button and Command-Return share this policy.
enum LibraryAssistantAskAction: Equatable, Sendable {
    case hidden
    case openIntegrations
    case openHandoff
}

enum LibraryAssistantAskPolicy {
    static func resolve(
        hasQuery: Bool,
        connectionCount: Int
    ) -> LibraryAssistantAskAction {
        guard hasQuery else { return .hidden }
        return connectionCount > 0 ? .openHandoff : .openIntegrations
    }

    static func isPrimaryControlVisible(hasQuery: Bool) -> Bool {
        switch resolve(hasQuery: hasQuery, connectionCount: 0) {
        case .hidden:
            return false
        case .openIntegrations, .openHandoff:
            return true
        }
    }
}
