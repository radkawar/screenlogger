import ScreenlogCore
import SwiftUI

/// Application-specific exclusions, ordered from active protection to apps the
/// user can add. The parent pane owns navigation and search state.
struct ExcludedApplicationsSettingsContent: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAllAvailableApplications = false

    let query: String
    let restoreDefaults: () -> Void

    var body: some View {
        SettingsSectionStack {
            privacyProtection

            if !filteredExcludedApps.isEmpty {
                excludedApplications
            }

            availableApplications
            systemInterfaces
            restoreDefaultsSection
        }
    }

    private var privacyProtection: some View {
        let category = ExclusionCategory.passwordManagers
        let isEnabled = model.isExclusionCategoryEnabled(category)
        let policy = ExclusionPolicyPresentation.broaderCategory(
            name: category.label,
            isEnabled: isEnabled,
            matchingContent: "password manager applications"
        )
        return VStack(alignment: .leading, spacing: 8) {
            ExclusionsSectionHeader(
                title: "Privacy Protection",
                detail: "Choose broader app protections before managing individual applications."
            )
            SettingsCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "eye.slash.circle.fill")
                            .foregroundStyle(SLDesign.success)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screenlogger")
                                .font(.body.weight(.medium))
                            Text("Screenlogger windows never appear in captures.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Label("Always Excluded", systemImage: "checkmark.shield.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(SLDesign.success)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Screenlogger, always excluded")
                    .accessibilityHint("Screenlogger windows never appear in captures")
                    .accessibilityIdentifier("exclusions.applications.screenlogger")

                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                    ExclusionToggleRow(
                        icon: category.systemImage,
                        title: category.label,
                        detail: category.detail,
                        isOn: isEnabled,
                        policy: policy,
                        outcomeIdentifier: "exclusions.applications.outcome.category.password-managers"
                    ) {
                        model.applyExclusionCategory(category, enabled: $0)
                    }

                    if !passwordManagersOnThisMac.isEmpty {
                        Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                        DisclosureGroup {
                            VStack(spacing: 0) {
                                ForEach(passwordManagersOnThisMac, id: \.bundleID) { app in
                                    passwordManagerRow(app)
                                    if app.bundleID != passwordManagersOnThisMac.last?.bundleID {
                                        Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                                    }
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("Password managers found on this Mac")
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private var excludedApplications: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExclusionsSectionHeader(
                title: "Excluded Applications (\(filteredExcludedApps.count))",
                detail: queryIsEmpty ? ExclusionPolicyPresentation.futureMomentsNotice : nil
            )
            SettingsCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(filteredExcludedApps, id: \.self) { bundleID in
                        excludedApplicationRow(bundleID)
                        if bundleID != filteredExcludedApps.last {
                            Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                        }
                    }
                }
            }
        }
    }

    private var availableApplications: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExclusionsSectionHeader(
                title: "Add an Application",
                detail: "Applications without a matching rule can appear in future moments."
            )
            SettingsCard(padding: 0) {
                VStack(spacing: 0) {
                    switch model.applicationDiscoveryLoadState {
                    case .loading:
                        loadingApplications
                    case .failed:
                        failedApplications
                    case .loaded where filteredInstalledApps.isEmpty:
                        let content = applicationEmptyContent
                        ExclusionsEmptyState(
                            title: content.title,
                            detail: content.detail,
                            identifier: content.identifier
                        )
                    case .loaded:
                        ForEach(displayedInstalledApps, id: \.bundleID) { app in
                            availableApplicationRow(app)
                            if app.bundleID != displayedInstalledApps.last?.bundleID {
                                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                            }
                        }
                        if filteredInstalledApps.count > displayedInstalledApps.count {
                            Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                            Button {
                                showingAllAvailableApplications = true
                            } label: {
                                Label(
                                    "Show \(filteredInstalledApps.count - displayedInstalledApps.count) More",
                                    systemImage: "chevron.down"
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("exclusions.applications.show-more")
                        }
                    }
                }
            }
        }
    }

    private var systemInterfaces: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExclusionsSectionHeader(
                title: "System Interfaces",
                detail: "Privacy-sensitive macOS surfaces that Screenlogger can skip."
            )
            SettingsCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(SystemExclusionApp.allCases) { app in
                        let explicitlyExcluded = isExplicitlyExcluded(app.rawValue)
                        let policy = applicationPolicy(
                            bundleID: app.rawValue,
                            displayName: app.label,
                            explicitlyExcluded: explicitlyExcluded
                        )
                        ExclusionToggleRow(
                            icon: app.systemImage,
                            title: app.label,
                            detail: "Privacy-sensitive macOS interface.",
                            isOn: explicitlyExcluded,
                            policy: policy,
                            outcomeIdentifier: "exclusions.applications.outcome.\(app.id)"
                        ) {
                            model.setSystemAppExcluded(app, excluded: $0)
                        }
                        if app != SystemExclusionApp.allCases.last {
                            Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                        }
                    }
                }
            }
        }
    }

    private var restoreDefaultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExclusionsSectionHeader(title: "Reset")
            SettingsCard(padding: 0) {
                Button(action: restoreDefaults) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restore Default Exclusions...")
                            Text("Replace custom exclusions with Screenlogger's privacy defaults.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows a confirmation before restoring privacy defaults")
            }
        }
    }

    private var loadingApplications: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Finding applications...")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finding applications")
        .accessibilityIdentifier("exclusions.applications.loading")
    }

    private var failedApplications: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SLDesign.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Applications couldn't be loaded")
                    .font(.caption.weight(.medium))
                Text("Screenlogger couldn't read the apps on this Mac. Your exclusions are unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Retry") {
                Task { await model.refreshDiscoveredApplications() }
            }
            .controlSize(.small)
            .accessibilityHint("Try loading installed and running applications again")
            .accessibilityIdentifier("exclusions.applications.retry")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Applications couldn't be loaded")
        .accessibilityHint("Your exclusions are unchanged. Choose Retry to try again.")
        .accessibilityIdentifier("exclusions.applications.error")
    }

    private func passwordManagerRow(_ app: (bundleID: String, name: String, running: Bool)) -> some View {
        let explicitlyExcluded = isExplicitlyExcluded(app.bundleID)
        let policy = applicationPolicy(
            bundleID: app.bundleID,
            displayName: app.name,
            explicitlyExcluded: explicitlyExcluded
        )
        return HStack(spacing: 12) {
            SLAppIconView(bundleID: app.bundleID, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.callout)
                if app.running {
                    Text("Running")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ExclusionOutcomeLabel(
                    presentation: policy,
                    identifier: "exclusions.applications.outcome.\(app.bundleID)"
                )
            }
            Spacer()
            Toggle(
                "Exclude \(app.name)",
                isOn: Binding(
                    get: {
                        policy.outcome == .neverCapture
                    },
                    set: { on in
                        if on { model.addExclusion(app.bundleID) } else { model.removeExclusion(app.bundleID) }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(model.isExclusionCategoryEnabled(.passwordManagers))
            .help(policy.detail)
            .accessibilityLabel("Exclude \(app.name)")
            .accessibilityValue(
                SettingsAccessibilityValue.onOff(policy.outcome == .neverCapture)
            )
            .accessibilityHint(policy.accessibilityHint)
        }
        .padding(.leading, 30)
        .padding(.vertical, 6)
    }

    private func excludedApplicationRow(_ bundleID: String) -> some View {
        let displayName = SLAppIdentity.displayName(bundleID: bundleID)
        let policy = applicationPolicy(
            bundleID: bundleID,
            displayName: displayName,
            explicitlyExcluded: true
        )
        return HStack(spacing: 12) {
            SLAppIconView(bundleID: bundleID, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.body)
                ExclusionOutcomeLabel(
                    presentation: policy,
                    identifier: "exclusions.applications.outcome.\(bundleID)"
                )
            }
            Spacer()
            Toggle(
                "Exclude \(displayName)",
                isOn: Binding(
                    get: { true },
                    set: { on in if !on { model.removeExclusion(bundleID) } }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .accessibilityLabel("Exclude \(displayName)")
            .accessibilityValue(SettingsAccessibilityValue.onOff(true))
            .accessibilityHint(policy.accessibilityHint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func availableApplicationRow(_ app: DiscoveredApplication) -> some View {
        let explicitlyExcluded = isExplicitlyExcluded(app.bundleID)
        let policy = applicationPolicy(
            bundleID: app.bundleID,
            displayName: app.name,
            explicitlyExcluded: explicitlyExcluded
        )
        return HStack(spacing: 12) {
            SLAppIconView(bundleID: app.bundleID, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .lineLimit(1)
                ExclusionOutcomeLabel(
                    presentation: policy,
                    identifier: "exclusions.applications.outcome.\(app.bundleID)"
                )
            }
            Spacer()
            Toggle(
                "Exclude \(app.name)",
                isOn: Binding(
                    get: { policy.outcome == .neverCapture },
                    set: { on in
                        if on { model.addExclusion(app.bundleID) } else { model.removeExclusion(app.bundleID) }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!applicationCategoryNames(bundleID: app.bundleID).isEmpty)
            .accessibilityLabel("Exclude \(app.name)")
            .accessibilityValue(
                SettingsAccessibilityValue.onOff(policy.outcome == .neverCapture)
            )
            .accessibilityHint(policy.accessibilityHint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var filteredExcludedApps: [String] {
        let systemIDs = Set(SystemExclusionApp.allCases.map { $0.rawValue.lowercased() })
        let inheritedPasswordManagers =
            model.isExclusionCategoryEnabled(.passwordManagers)
            ? Set(ExclusionCatalog.passwordManagerBundleIDs)
            : Set<String>()
        let excluded = model.excludedBundles.filter { bundleID in
            !systemIDs.contains(bundleID.lowercased())
                && !inheritedPasswordManagers.contains(bundleID.lowercased())
        }
        guard !normalizedQuery.isEmpty else { return excluded }
        return excluded.filter {
            $0.localizedCaseInsensitiveContains(normalizedQuery)
                || SLAppIdentity.displayName(bundleID: $0).localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var filteredInstalledApps: [DiscoveredApplication] {
        guard case .loaded(let installedApps) = model.applicationDiscoveryLoadState else {
            return []
        }
        let available = installedApps.filter {
            !isExplicitlyExcluded($0.bundleID)
                && !ScreenloggerCapturePrivacy.isScreenlogger(bundleID: $0.bundleID)
                && applicationCategoryNames(bundleID: $0.bundleID).isEmpty
        }
        guard !normalizedQuery.isEmpty else { return available }
        return available.filter {
            $0.bundleID.localizedCaseInsensitiveContains(normalizedQuery)
                || $0.name.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var displayedInstalledApps: [DiscoveredApplication] {
        if showingAllAvailableApplications || !normalizedQuery.isEmpty {
            return filteredInstalledApps
        }
        return Array(filteredInstalledApps.prefix(80))
    }

    private var applicationEmptyContent: (title: String, detail: String, identifier: String) {
        if !queryIsEmpty {
            return (
                "No applications match '\(query.trimmingCharacters(in: .whitespacesAndNewlines))'",
                "Try a different name or clear the search.",
                "exclusions.applications.no-matches"
            )
        }
        guard case .loaded(let discoveredApplications) = model.applicationDiscoveryLoadState,
            !discoveredApplications.isEmpty
        else {
            return (
                "No applications available",
                "Screenlogger didn't find any installed or running applications.",
                "exclusions.applications.empty"
            )
        }
        return (
            "All applications are already excluded",
            "They appear in the Excluded Applications section above.",
            "exclusions.applications.all-excluded"
        )
    }

    private var passwordManagersOnThisMac: [(bundleID: String, name: String, running: Bool)] {
        ExclusionCatalog.installedOrRunningPasswordManagers()
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var queryIsEmpty: Bool { normalizedQuery.isEmpty }

    private func applicationPolicy(
        bundleID: String,
        displayName: String,
        explicitlyExcluded: Bool
    ) -> ExclusionPolicyPresentation {
        ExclusionPolicyPresentation.application(
            displayName: displayName,
            bundleID: bundleID,
            explicitlyExcluded: explicitlyExcluded,
            categoryNames: applicationCategoryNames(bundleID: bundleID)
        )
    }

    private func applicationCategoryNames(bundleID: String) -> [String] {
        let normalizedBundleID = bundleID.lowercased()
        return ExclusionCategory.allCases.compactMap { category in
            guard model.isExclusionCategoryEnabled(category),
                category.bundleIDs.contains(normalizedBundleID)
            else { return nil }
            return category.label
        }
    }

    private func isExplicitlyExcluded(_ bundleID: String) -> Bool {
        model.excludedBundles.contains(bundleID.lowercased())
    }
}
