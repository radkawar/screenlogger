import ScreenlogCore
import SwiftUI

struct PrivacyProtectionSettingsSection: View {
    @EnvironmentObject private var model: AppModel

    let openExclusions: () -> Void

    var body: some View {
        PrivacySettingsGroup("Exclusions", systemImage: "eye.slash") {
            PrivacySettingsRow(
                icon: "app.badge.checkmark",
                title: "Excluded apps and websites",
                detail: exclusionSummary
            ) {
                Button("Manage Exclusions...", action: openExclusions)
                    .controlSize(.small)
                    .accessibilityHint("Shows the apps and detectable websites Screenlogger will not capture")
                    .accessibilityIdentifier("privacy.exclusions.manage")
            }.padding(SLDesign.space16)
        }
        .accessibilityIdentifier("privacy.protection")
    }

    private var exclusionSummary: String {
        var protections: [String] = []
        if model.isExclusionCategoryEnabled(.passwordManagers) {
            protections.append("password managers")
        }
        if model.isExclusionCategoryEnabled(.banks) {
            protections.append("bank websites")
        }

        let systemIDs = Set(SystemExclusionApp.allCases.map { $0.rawValue.lowercased() })
        let passwordManagerIDs =
            model.isExclusionCategoryEnabled(.passwordManagers)
            ? Set(ExclusionCatalog.passwordManagerBundleIDs)
            : Set<String>()
        let appCount = model.excludedBundles.filter {
            !systemIDs.contains($0.lowercased())
                && !passwordManagerIDs.contains($0.lowercased())
        }.count
        let bankDomains =
            model.isExclusionCategoryEnabled(.banks)
            ? Set(ExclusionCatalog.bankDomains)
            : Set<String>()
        let siteCount = model.excludedDomains.filter { !bankDomains.contains($0) }.count

        var parts: [String] = []
        if !protections.isEmpty {
            parts.append("Built-in protection is on for \(Self.joinedList(protections))")
        }
        if appCount > 0 {
            parts.append("\(appCount) additional \(appCount == 1 ? "app is" : "apps are") excluded")
        }
        if siteCount > 0 {
            parts.append("\(siteCount) additional \(siteCount == 1 ? "website is" : "websites are") excluded")
        }
        return parts.isEmpty
            ? "No app or website exclusions are enabled."
            : parts.joined(separator: ". ") + "."
    }

    private static func joinedList(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        if items.count == 1 { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
