import ScreenlogCore
import SwiftUI

/// The authoritative automatic-capture state and its most useful next action.
/// Expected privacy pauses remain visibly enabled because Screenlogger will
/// resume on its own when the protected activity ends.
struct CaptureStatusSettingsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        statusSummary
                        Spacer(minLength: 12)
                        statusAction
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        statusSummary
                        statusAction
                    }
                }

                Divider()

                Label(
                    CaptureLocalProcessingCopy.caption(
                        intervalSeconds: model.intervalSeconds,
                        isSaving: CaptureLocalProcessingCopy.isActivelySaving(status)
                    ),
                    systemImage: "internaldrive"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("capture.status.local-processing")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.status.overview")
    }

    private var statusSummary: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: status.symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(status.tone.swiftUIColor)
                .frame(width: 34, height: 34)
                .background(
                    status.tone.swiftUIColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.headline)
                    .font(.body.weight(.semibold))
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status.scope == .library ? "Library status" : "Capture status")
            .accessibilityValue(status.headline)
            .accessibilityHint(status.detail)
            .accessibilityIdentifier("capture.status.summary")
        }
    }

    @ViewBuilder
    private var statusAction: some View {
        switch status.primaryAction {
        case .retryLibrary:
            Button {
                performStatusAction(.retryLibrary)
            } label: {
                Text(status.actionLabel ?? "Try Again")
            }
            .controlSize(.small)
            .accessibilityHint(status.actionHint ?? "Try opening the Library again")
            .accessibilityIdentifier("capture.library.retry")

        case .setupCapture(let permission):
            Button(status.actionLabel ?? "Set Up...") {
                performStatusAction(.setupCapture(permission))
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Set up \(permission.title) permission")
            .accessibilityHint(status.actionHint ?? "Open \(permission.title) setup")
            .accessibilityIdentifier("capture.automatic.setup")

        case .manageStorage:
            Button(status.actionLabel ?? "Manage Storage...") {
                performStatusAction(.manageStorage)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Review storage use and cleanup options")
            .accessibilityIdentifier("capture.automatic.storage")

        case .reviewWebsiteExclusions:
            Button(status.actionLabel ?? "Review Exclusions...") {
                performStatusAction(.reviewWebsiteExclusions)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Review strict website protection or allow Accessibility access")
            .accessibilityIdentifier("capture.automatic.exclusions")

        case .retryCapture(let issue):
            HStack(spacing: 10) {
                Button(status.actionLabel ?? "Try Again") {
                    performStatusAction(.retryCapture(issue))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .accessibilityHint(status.actionHint ?? "Try the failed capture action again")
                .accessibilityIdentifier("capture.automatic.retry")

                if status.controls.canStop {
                    automaticCaptureToggle
                }
            }

        case .startCapture, .resumeCapture:
            automaticCaptureControls

        case nil:
            if status.scope == .library {
                HStack(spacing: 7) {
                    if status.tone == .working {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                    Text(status.compactDetail ?? status.compactLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                automaticCaptureControls
            }
        }
    }

    private var automaticCaptureControls: some View {
        HStack(spacing: 10) {
            if status.primaryAction == .resumeCapture {
                Button("Resume") {
                    performStatusAction(.resumeCapture)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Resume automatic capture now")
                .accessibilityIdentifier("capture.automatic.resume")
            } else if status.controls.canSchedulePause {
                Button("Pause for 1 Hour") {
                    model.pauseRecordingForOneHour()
                }
                .controlSize(.small)
                .accessibilityHint("Temporarily pause automatic capture")
                .accessibilityIdentifier("capture.automatic.pause")
            }

            automaticCaptureToggle
        }
    }

    private var automaticCaptureToggle: some View {
        Toggle(
            "Automatic Capture",
            isOn: Binding(
                get: { model.automaticCaptureEnabled },
                set: { requestedValue in
                    guard requestedValue != model.automaticCaptureEnabled else { return }
                    model.setAutomaticCaptureEnabled(requestedValue)
                }
            )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityLabel("Automatic Capture")
        .accessibilityValue(SettingsAccessibilityValue.onOff(model.automaticCaptureEnabled))
        .accessibilityHint(automaticCaptureHint)
        .accessibilityIdentifier("capture.automatic.toggle")
    }

    private var automaticCaptureHint: String {
        if status.primaryAction == .resumeCapture {
            return "Turn off automatic capture and cancel the scheduled resume"
        }
        return model.automaticCaptureEnabled
            ? "Turn off automatic capture"
            : "Start automatic capture"
    }

    private var status: CaptureStatusPresentation {
        model.captureStatusPresentation()
    }

    private func performStatusAction(_ action: CaptureStatusPrimaryAction) {
        model.performCaptureStatusPrimaryAction(action, setupOrigin: .settings)
    }
}
