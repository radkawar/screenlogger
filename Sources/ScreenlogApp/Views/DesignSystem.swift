import ScreenlogCore
import SwiftUI

/// Small semantic tokens shared by Screenlogger's live macOS surfaces.
///
/// Prefer native controls and system materials first. These values exist to
/// keep spacing and status colors consistent, not to create custom web chrome.
enum SLDesign {
    /// Library and Timeline share one tested workspace floor so moving between
    /// primary surfaces never makes the window unexpectedly grow.
    static let workspaceMinimumWidth: CGFloat = 820
    static let workspaceMinimumHeight: CGFloat = 540
    static let workspaceMinimumSize = CGSize(
        width: workspaceMinimumWidth,
        height: workspaceMinimumHeight
    )
    static let librarySidebarWidth: CGFloat = 224

    static let titleFont = Font.system(.title2, design: .default).weight(.semibold)
    static let sectionFont = Font.headline
    static let bodyFont = Font.body
    static let metadataFont = Font.caption

    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space10: CGFloat = 10
    static let space12: CGFloat = 12
    static let space14: CGFloat = 14
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32
    static let space48: CGFloat = 48

    /// Minimum pointer target for compact toolbar and icon-only controls.
    /// The symbol may remain visually smaller while the full target is easy
    /// to acquire with a mouse, trackpad, Switch Control, or Voice Control.
    static let compactControlTarget: CGFloat = 28

    static let radius: CGFloat = 10
    static let cardRadius: CGFloat = 10
    static let pillRadius: CGFloat = 14
    static let panelRadius: CGFloat = 12
    static let thumbRadius: CGFloat = 8

    /// Status colors adapt with the active macOS appearance and accessibility
    /// contrast instead of baking light-mode RGB values into every surface.
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let error = Color(nsColor: .systemRed)
    static let accentBlue = Color(nsColor: .systemBlue)
}

/// Feature-owned capture recovery shared by surfaces that can start or resume
/// automatic capture. Expected privacy and disk pauses use their dedicated
/// status controls instead of appearing here as failures.
struct SLCaptureIssueBanner: View {
    @EnvironmentObject private var model: AppModel

    let issue: CaptureIssue
    let context: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SLDesign.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.callout.weight(.semibold))
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if issue.canRetry {
                Button("Retry") { model.retryCaptureIssue() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("capture.issue.\(context).retry")
            }
            Button("Dismiss") { model.dismissCaptureIssue() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("capture.issue.\(context).dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(SLDesign.warning.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.issue.\(context)")
    }
}

/// Compact product-wide capture status for native window toolbars.
/// The resolver owns state priority and copy; this view only maps its typed
/// semantics to SwiftUI controls and the initiating Setup return path.
struct SLCaptureStatusToolbarView: View {
    @EnvironmentObject private var model: AppModel

    let setupOrigin: CaptureSetupOrigin
    let accessibilityIdentifier: String

    var body: some View {
        let status = model.captureStatusPresentation()
        let toolbar = CaptureStatusToolbarResolver.resolve(status)
        Group {
            if let action = toolbar.action {
                Button {
                    perform(action)
                } label: {
                    Label(toolbar.title, systemImage: toolbar.symbolName)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(toolbar.title)
                .accessibilityValue(status.compactLabel)
                .accessibilityHint(toolbar.actionHint ?? status.detail)
            } else {
                Label(toolbar.title, systemImage: toolbar.symbolName)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(toolbar.title)
                    .accessibilityValue(status.compactLabel)
                    .accessibilityHint(status.detail)
            }
        }
        .font(.callout.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier(accessibilityIdentifier)
        .help(toolbar.actionHint ?? status.detail)
    }

    private func perform(_ action: CaptureStatusToolbarAction) {
        switch action {
        case .perform(let primaryAction):
            model.performCaptureStatusPrimaryAction(primaryAction, setupOrigin: setupOrigin)
        case .stopCapture:
            model.performKeyboardShortcutCaptureToggle()
        }
    }
}

extension CaptureStatusTone {
    var swiftUIColor: Color {
        switch self {
        case .success: return SLDesign.success
        case .warning: return SLDesign.warning
        case .working: return .accentColor
        case .neutral: return .secondary
        }
    }
}

extension View {
    /// Keeps compact controls native-looking without shrinking their hit area.
    func slCompactControlTarget() -> some View {
        frame(
            minWidth: SLDesign.compactControlTarget,
            minHeight: SLDesign.compactControlTarget
        )
        .contentShape(Rectangle())
    }

    /// A restrained adaptive surface for the few places that need grouping.
    func slElevatedPanel(radius: CGFloat = SLDesign.panelRadius) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    /// Search presentation retained for compact floating search surfaces.
    func slSearchPill() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
    }

    /// A compact token for active refinements, with text remaining primary.
    func slQuietChip(selected: Bool) -> some View {
        font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
            )
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.85))
    }
}
