import SwiftUI

struct ExclusionsSectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SLDesign.space4) {
            Text(title)
                .font(SLDesign.sectionFont)
                .foregroundStyle(.primary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct ExclusionToggleRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let icon: String
    let title: String
    let detail: String
    let isOn: Bool
    var isEnabled = true
    var help: String?
    var policy: ExclusionPolicyPresentation?
    var outcomeIdentifier: String?
    let set: (Bool) -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    identity
                    exclusionToggle
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        identity
                        Spacer(minLength: 8)
                        exclusionToggle
                            .padding(.top, 4)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        identity
                        exclusionToggle
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, SLDesign.space16)
        .padding(.vertical, SLDesign.space8)
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: SLDesign.space16) {
            Image(systemName: icon)
                .font(SLDesign.bodyFont)
                .foregroundStyle(.secondary)
                .frame(width: SettingsChrome.iconSize, height: SettingsChrome.iconSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SLDesign.space4) {
                Text(title)
                    .font(SLDesign.bodyFont.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(SLDesign.metadataFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let policy {
                    ExclusionOutcomeLabel(
                        presentation: policy,
                        identifier: outcomeIdentifier
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
    }

    private var exclusionToggle: some View {
        Toggle("Exclude \(title)", isOn: Binding(get: { isOn }, set: set))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!isEnabled)
            .help(help ?? policy?.detail ?? detail)
            .accessibilityLabel("Exclude \(title)")
            .accessibilityValue(SettingsAccessibilityValue.onOff(isOn))
            .accessibilityHint(help ?? policy?.accessibilityHint ?? detail)
    }
}

/// The compact outcome/provenance treatment shared by application and website
/// exclusions. Policy copy stays in `ExclusionPolicyPresentation`; this view
/// only renders it with native text and semantic symbols.
struct ExclusionOutcomeLabel: View {
    let presentation: ExclusionPolicyPresentation
    var identifier: String?

    var body: some View {
        identifiedContent
    }

    @ViewBuilder
    private var identifiedContent: some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 5) {
            Image(systemName: presentation.outcome.systemImage)
                .accessibilityHidden(true)
            Text(presentation.outcome.title)
                .fontWeight(.semibold)
            Divider()
                .frame(height: 10)
                .accessibilityHidden(true)
            Text(presentation.provenanceSummary)
        }
        .font(.caption2)
        .foregroundStyle(
            presentation.outcome == .neverCapture
                ? SLDesign.success : Color.secondary
        )
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.outcome.title)
        .accessibilityValue("\(presentation.provenanceSummary). \(presentation.detail)")
        .accessibilityHint(presentation.accessibilityHint)
    }
}

struct ExclusionsEmptyState: View {
    let title: String
    let detail: String
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityIdentifier(identifier)
    }
}
