import Foundation
import ScreenlogCore

@MainActor
extension AppModel {
    func buildLibraryAssistantHandoffPrompt() throws -> LibraryAssistantHandoffPrompt {
        let parsed = SearchOperatorParser.parse(searchQuery)

        let application = joinedExplicitValues([
            parsed.rawApp,
            searchAppFilter.map { SLAppIdentity.displayName(bundleID: $0) },
        ])
        let website = joinedExplicitValues([
            parsed.rawSite,
            searchDomainFilter,
        ])

        var dateConstraints: [String] = []
        if let value = parsed.rawDate { dateConstraints.append("On \(value)") }
        if let value = parsed.rawSince { dateConstraints.append("Since \(value)") }
        if let value = parsed.rawBefore { dateConstraints.append("Before \(value)") }

        let session: String? = {
            guard searchSessionScoped, let selectedSession else { return nil }
            return
                "\(selectedSession.appLabel), \(SLTimeFormat.full(selectedSession.startMs)) to \(SLTimeFormat.full(selectedSession.endMs))"
        }()

        return try LibraryAssistantHandoffPromptBuilder.build(
            LibraryAssistantHandoffRequest(
                authoredText: parsed.ftsText,
                constraints: LibraryAssistantHandoffConstraints(
                    application: application,
                    website: website,
                    date: dateConstraints.isEmpty
                        ? nil
                        : dateConstraints.joined(separator: ", "),
                    time: searchTimeFilter.map { $0.label.capitalized },
                    session: session
                )
            )
        )
    }

    func assistantHandoffDestinations() -> [AssistantHandoffDestination] {
        #if DEBUG
            if let destinations = AppUITestFixture.assistantHandoffDestinationsIfRequested() {
                return destinations
            }
        #endif
        return AgentSkillTarget.allCases.compactMap { target in
            // This is availability for a user-reviewed transfer, not proof that
            // the assistant loaded the integration or completed a search.
            guard assistantOperationalReadiness(for: target).canOfferReviewedHandoff,
                let snapshot = agentSkillSnapshotState(target).snapshot
            else { return nil }
            return AssistantHandoffLaunchService.destination(
                for: target,
                presence: snapshot.presence
            )
        }
    }

    func assistantHandoffRoutingDecision(
        for destinations: [AssistantHandoffDestination]
    ) -> LibraryAssistantRoutingDecision {
        return LibraryAssistantRoutingPolicy.decide(
            capableTargets: destinations.map(\.target),
            preference: libraryAssistantRoutingPreference
        )
    }

    /// Prefer the one assistant that is already present when Settings is the
    /// recovery destination. With several detected assistants there is no
    /// truthful single row to focus, so the shared Assistant Connections
    /// section remains the destination.
    func assistantSettingsRecoveryTarget() -> AssistantIntegrationTarget? {
        let detected = AssistantIntegrationTarget.allCases.filter { target in
            agentSkillSnapshotState(target).snapshot?.presence.isPresent == true
        }
        return detected.count == 1 ? detected[0] : nil
    }

    private func joinedExplicitValues(_ values: [String?]) -> String? {
        var seen = Set<String>()
        let unique = values.compactMap { value -> String? in
            guard let value else { return nil }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return normalized
        }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }
}
