import SwiftUI

struct PrivacySettingsGroup<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            Label {
                Text(title)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
            .font(SLDesign.sectionFont)
            .accessibilityAddTraits(.isHeader)

            SettingsCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
            }
        }
    }
}

struct PrivacySettingsRow<Trailing: View>: View {
    let icon: String
    var iconColor: Color = .secondary
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        SettingsCardRow(
            icon: icon,
            iconColor: iconColor,
            title: title,
            subtitle: detail,
            trailing: trailing
        )
    }
}

struct PrivacySettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
    }
}

struct PrivacyStatusLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}
