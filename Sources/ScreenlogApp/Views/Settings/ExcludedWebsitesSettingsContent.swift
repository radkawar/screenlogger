import ScreenlogCore
import SwiftUI

/// Website-specific exclusion status and controls. Website matching is only as
/// reliable as the active browser address, so permission and strict-protection
/// state stay adjacent to the controls they affect.
struct ExcludedWebsitesSettingsContent: View {
    private enum InputFeedback {
        case success(String)
        case error(String)

        var message: String {
            switch self {
            case .success(let message), .error(let message): return message
            }
        }

        var isError: Bool {
            if case .error = self { return true }
            return false
        }

        var systemImage: String { isError ? "exclamationmark.circle" : "checkmark.circle" }
    }

    @EnvironmentObject private var model: AppModel
    @Binding var filterQuery: String
    @State private var websiteEntry = ""
    @State private var inputFeedback: InputFeedback?
    @State private var showingAllRecordedDomains = false
    @State private var showingAllExcludedDomains = false

    private let collapsedDomainLimit = 8

    var body: some View {
        SettingsSectionStack {
            addressAvailability

            if !model.permissions.accessibility {
                accessibilityRecovery
            }

            addWebsite
            privacyProtection
            websiteFilter
            recentlyRecorded

            if !filteredExcludedDomains.isEmpty {
                excludedDomains
            }
        }
    }

    private var addressAvailability: some View {
        SettingsCard {
            SettingsCardRow(
                icon: "globe.badge.chevron.backward",
                title: "Website matching needs the active address",
                subtitle:
                    "\(ExclusionPolicyPresentation.websiteAddressScope) \(ExclusionPolicyPresentation.entireBrowserGuarantee)"
            ) {
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("How website exclusions work")
        .accessibilityHint(ExclusionPolicyPresentation.websiteScopeAccessibilityHint)
        .accessibilityIdentifier("exclusions.websites.scope")
    }

    private var accessibilityRecovery: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                accessibilityRecoveryMessage
                Spacer(minLength: 8)
                accessibilityRecoveryButton
            }

            VStack(alignment: .leading, spacing: 10) {
                accessibilityRecoveryMessage
                accessibilityRecoveryButton
            }
        }
        .padding(12)
        .background(SLDesign.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: SettingsChrome.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsChrome.cardRadius)
                .strokeBorder(SLDesign.warning.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exclusions.website.accessibility-warning")
    }

    private var accessibilityRecoveryMessage: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(SLDesign.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(accessibilityTitle)
                    .font(.callout.weight(.semibold))
                Text(accessibilityDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
        }
    }

    private var accessibilityRecoveryButton: some View {
        Button("Open System Settings") {
            model.openAccessibilitySettings()
        }
        .controlSize(.small)
        .accessibilityHint("Open macOS Accessibility privacy settings")
    }

    private var addWebsite: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExclusionsSectionHeader(
                title: "Exclude a Website",
                detail: "Add an explicit website rule for future moments."
            )
            SettingsCard(padding: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            websiteEntryField
                            excludeWebsiteButton
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            websiteEntryField
                            excludeWebsiteButton
                        }
                    }

                    if let inputFeedback {
                        Label(inputFeedback.message, systemImage: inputFeedback.systemImage)
                            .font(.caption)
                            .foregroundStyle(
                                inputFeedback.isError ? SLDesign.error : Color.secondary
                            )
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(inputFeedback.message)
                            .accessibilityIdentifier("exclusions.website.feedback")
                    }
                }
                .padding(12)
            }
        }
    }

    private var websiteEntryField: some View {
        TextField("example.com", text: $websiteEntry)
            .textFieldStyle(.roundedBorder)
            .onSubmit(addWebsiteFromEntry)
            .accessibilityLabel("Website to exclude")
            .accessibilityHint("Enter a website, then choose Exclude Website")
            // Keep the established identifier for routing and UI automation.
            .accessibilityIdentifier("exclusions.websites.search")
    }

    private var excludeWebsiteButton: some View {
        Button("Exclude Website", action: addWebsiteFromEntry)
            .disabled(normalizedWebsiteEntry.isEmpty)
            .accessibilityHint("Add the entered website to Screenlogger's exclusions")
            .accessibilityIdentifier("exclusions.website.add")
    }

    private var privacyProtection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExclusionsSectionHeader(
                title: "Privacy Protection",
                detail: "Choose broad protections before managing individual websites."
            )
            SettingsCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(websiteCategories) { category in
                        let isEnabled = model.isExclusionCategoryEnabled(category)
                        let policy = ExclusionPolicyPresentation.broaderCategory(
                            name: category.label,
                            isEnabled: isEnabled,
                            matchingContent: "matching websites"
                        )
                        ExclusionToggleRow(
                            icon: category.systemImage,
                            title: category.label,
                            detail: category.detail,
                            isOn: isEnabled,
                            policy: policy,
                            outcomeIdentifier: "exclusions.websites.outcome.category.\(category.id)"
                        ) {
                            model.applyExclusionCategory(category, enabled: $0)
                        }
                        Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                    }

                    let privateBrowsingPolicy = ExclusionPolicyPresentation.broaderCategory(
                        name: "Private Browsing Windows",
                        isEnabled: model.excludePrivateTabs,
                        matchingContent: "recognizable private browser windows"
                    )
                    ExclusionToggleRow(
                        icon: "eyeglasses",
                        title: "Private Browsing Windows",
                        detail: "Skip Safari Private, Chrome Incognito, Edge InPrivate, and similar windows when they can be identified.",
                        isOn: model.excludePrivateTabs,
                        policy: privateBrowsingPolicy,
                        outcomeIdentifier: "exclusions.websites.outcome.private-browsing"
                    ) {
                        model.excludePrivateTabs = $0
                    }

                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                    ExclusionToggleRow(
                        icon: "globe.badge.chevron.backward",
                        title: "Pause When Website Is Unknown",
                        detail: "Controls supported browsers only when their active address cannot be identified.",
                        isOn: model.pauseWhenBrowserAddressUnavailable,
                        policy: unknownAddressPolicy,
                        outcomeIdentifier: "exclusions.websites.outcome.unknown-address"
                    ) {
                        model.pauseWhenBrowserAddressUnavailable = $0
                    }
                    .accessibilityIdentifier("exclusions.website.pause-when-unknown")
                }
            }
        }
    }

    private var websiteFilter: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExclusionsSectionHeader(
                title: "Find in Website Lists",
                detail: "Filter recently recorded and explicitly excluded websites."
            )
            NativeFilterSearchField(
                text: $filterQuery,
                placeholder: "Filter websites",
                accessibilityIdentifier: "exclusions.websites.filter",
                accessibilityHelp: "Filters the website lists below without adding an exclusion."
            )
            .frame(height: 24)
        }
    }

    private var recentlyRecorded: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExclusionsSectionHeader(
                title: "Recently Recorded",
                detail: "Review each website's effective outcome and the rule that owns it."
            )
            SettingsCard(padding: 0) {
                VStack(spacing: 0) {
                    switch model.recordedDomainLoadState {
                    case .loading:
                        loadingRecordedDomains
                    case .failed(let issue):
                        failedRecordedDomains(issue)
                    case .loaded where filteredRecordedDomains.isEmpty:
                        let content = recordedDomainsEmptyContent
                        ExclusionsEmptyState(
                            title: content.title,
                            detail: content.detail,
                            identifier: content.identifier
                        )
                    case .loaded:
                        ForEach(displayedRecordedDomains, id: \.self) { domain in
                            recordedDomainRow(domain)
                            if domain != displayedRecordedDomains.last {
                                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                            }
                        }
                        if filteredRecordedDomains.count > displayedRecordedDomains.count {
                            catalogExpansionButton(
                                remaining: filteredRecordedDomains.count - displayedRecordedDomains.count,
                                action: { showingAllRecordedDomains = true }
                            )
                        }
                    }
                }
            }
            .accessibilityIdentifier("exclusions.websites.recent")
        }
    }

    private var excludedDomains: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExclusionsSectionHeader(
                title: "Excluded Websites (\(filteredExcludedDomains.count))",
                detail: ExclusionPolicyPresentation.futureMomentsNotice
            )
            SettingsCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(displayedExcludedDomains, id: \.self) { domain in
                        let policy = domainPolicy(domain)
                        HStack(spacing: 12) {
                            Image(systemName: "globe")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(domain)
                                ExclusionOutcomeLabel(
                                    presentation: policy,
                                    identifier: "exclusions.websites.outcome.excluded.\(domain)"
                                )
                            }
                            Spacer()
                            Toggle(
                                "Exclude \(domain)",
                                isOn: Binding(
                                    get: { true },
                                    set: { on in if !on { model.removeDomainExclusion(domain) } }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Exclude \(domain)")
                            .accessibilityHint(policy.accessibilityHint)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if domain != displayedExcludedDomains.last {
                            Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                        }
                    }
                    if filteredExcludedDomains.count > displayedExcludedDomains.count {
                        catalogExpansionButton(
                            remaining: filteredExcludedDomains.count - displayedExcludedDomains.count,
                            action: { showingAllExcludedDomains = true }
                        )
                    }
                }
            }
        }
    }

    private var loadingRecordedDomains: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading recently recorded websites...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading recently recorded websites")
        .accessibilityIdentifier("exclusions.websites.recent.loading")
    }

    private func failedRecordedDomains(_ issue: RecordedDomainLoadIssue) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SLDesign.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.caption.weight(.medium))
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(issue.recoveryAction.title) {
                Task { await model.refreshRecordedDomains() }
            }
            .controlSize(.small)
            .accessibilityHint(issue.recoveryAction.accessibilityHint)
            .accessibilityIdentifier("exclusions.websites.recent.retry")
        }
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(issue.title)
        .accessibilityValue(issue.message)
        .accessibilityHint(issue.recoveryAction.accessibilityHint)
        .accessibilityIdentifier("exclusions.websites.recent.error")
    }

    private func recordedDomainRow(_ domain: String) -> some View {
        let policy = domainPolicy(domain)
        return HStack(spacing: 12) {
            SLFaviconView(domain: domain, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(domain)
                    .lineLimit(1)
                ExclusionOutcomeLabel(
                    presentation: policy,
                    identifier: "exclusions.websites.outcome.recent.\(domain)"
                )
            }
            Spacer()
            Toggle(
                "Exclude \(domain)",
                isOn: Binding(
                    get: { model.isDomainEffectivelyExcluded(domain) },
                    set: { on in
                        if on { model.addDomainExclusion(domain) } else { model.removeDomainExclusion(domain) }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(isCoveredByCategory(domain))
            .help(policy.detail)
            .accessibilityLabel("Exclude \(domain)")
            .accessibilityValue(
                SettingsAccessibilityValue.onOff(policy.outcome == .neverCapture)
            )
            .accessibilityHint(policy.accessibilityHint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exclusions.websites.recent.domain.\(domain)")
    }

    private func catalogExpansionButton(remaining: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text("Show \(remaining) More")
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the remaining websites in this list")
    }

    private var filteredRecordedDomains: [String] {
        guard !normalizedQuery.isEmpty else { return availableRecordedDomains }
        return availableRecordedDomains.filter {
            $0.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var availableRecordedDomains: [String] {
        Array(Set(model.recordedDomainList.filter { !isExplicitlyExcluded($0) })).sorted()
    }

    private var filteredExcludedDomains: [String] {
        model.excludedDomains.filter {
            normalizedQuery.isEmpty || $0.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var displayedRecordedDomains: [String] {
        showingAllRecordedDomains
            ? filteredRecordedDomains
            : Array(filteredRecordedDomains.prefix(collapsedDomainLimit))
    }

    private var displayedExcludedDomains: [String] {
        showingAllExcludedDomains
            ? filteredExcludedDomains
            : Array(filteredExcludedDomains.prefix(collapsedDomainLimit))
    }

    private var recordedDomainsEmptyContent: (title: String, detail: String, identifier: String) {
        if model.recordedDomainList.isEmpty {
            return (
                "No recorded websites yet",
                "Websites appear here after browsing while capture is on.",
                "exclusions.websites.recent.empty"
            )
        }
        if availableRecordedDomains.isEmpty {
            return (
                "All recorded websites are already excluded",
                "Turn off a category above or manage individual exclusions below.",
                "exclusions.websites.recent.all-excluded"
            )
        }
        return (
            "No websites match '\(filterQuery.trimmingCharacters(in: .whitespacesAndNewlines))'",
            "Try a different website or clear the filter.",
            "exclusions.websites.recent.no-matches"
        )
    }

    private var normalizedQuery: String {
        filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedWebsiteEntry: String {
        websiteEntry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var websiteCategories: [ExclusionCategory] {
        ExclusionCategory.allCases.filter { !$0.domains.isEmpty }
    }

    private var accessibilityTitle: String {
        model.pauseWhenBrowserAddressUnavailable
            ? "Browser capture pauses without Accessibility access"
            : "Website exclusions need Accessibility access"
    }

    private var accessibilityDetail: String {
        model.pauseWhenBrowserAddressUnavailable
            ? unknownAddressPolicy.detail
            : "Without access, Screenlogger may not know which website is open. Turn on strict protection below or exclude the entire browser when you need a guaranteed block."
    }

    private func isCoveredByCategory(_ domain: String) -> Bool {
        !domainCategoryNames(domain).isEmpty && !isExplicitlyExcluded(domain)
    }

    private var unknownAddressPolicy: ExclusionPolicyPresentation {
        ExclusionPolicyPresentation.unknownBrowserAddress(
            strictProtectionEnabled: model.pauseWhenBrowserAddressUnavailable
        )
    }

    private func domainPolicy(_ domain: String) -> ExclusionPolicyPresentation {
        ExclusionPolicyPresentation.website(
            domain: domain,
            explicitlyExcluded: isExplicitlyExcluded(domain),
            categoryNames: domainCategoryNames(domain)
        )
    }

    private func domainCategoryNames(_ domain: String) -> [String] {
        guard let normalizedDomain = DomainExclusionParser.normalize(domain) else { return [] }
        return websiteCategories.compactMap { category in
            guard model.isExclusionCategoryEnabled(category),
                category.domains.contains(where: {
                    normalizedDomain == $0 || normalizedDomain.hasSuffix(".\($0)")
                })
            else { return nil }
            return category.label
        }
    }

    private func isExplicitlyExcluded(_ domain: String) -> Bool {
        guard let normalizedDomain = DomainExclusionParser.normalize(domain) else { return false }
        return model.excludedDomains.contains {
            normalizedDomain == $0 || normalizedDomain.hasSuffix(".\($0)")
        }
    }

    private func addWebsiteFromEntry() {
        guard !normalizedWebsiteEntry.isEmpty else { return }
        guard let domain = DomainExclusionParser.normalize(normalizedWebsiteEntry) else {
            inputFeedback = .error("Enter a website such as example.com.")
            return
        }
        _ = model.addDomainExclusion(domain)
        websiteEntry = ""
        inputFeedback = .success("Excluded \(domain)")
    }
}
