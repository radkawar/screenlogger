import ScreenlogCore
import SwiftUI

/// An explicit one-shot capture that never changes the automatic-capture
/// preference. Progress, success, failure, and recovery remain in this card.
struct CaptureOnceSettingsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCardRow(
                    icon: "camera.viewfinder",
                    title: "Capture Once",
                    subtitle: subtitle
                ) {
                    control
                }

                feedback
            }
        }
        .disabled(model.isDatabaseReclamationRunning)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.manual.card")
    }

    private var subtitle: String {
        if model.isDatabaseReclamationRunning {
            return "Screenlogger is reclaiming database space. Capture is unavailable until this finishes."
        }
        switch model.captureOnceState {
        case .idle:
            if model.libraryStartupIssue != nil {
                return "The Library must be available before Screenlogger can save a capture."
            }
            if !model.permissions.isCaptureReady {
                return "Screen Recording and Accessibility are required to save a capture."
            }
            return model.capturePauseReason?.userDescription
                ?? "Save the current screen without changing automatic capture."
        case .inProgress:
            return "Capturing the current screen and recognizing text..."
        case .success:
            return successSubtitle
        case .failure(let failure):
            return failure.userMessage
        }
    }

    @ViewBuilder
    private var control: some View {
        switch CaptureOnceSettingsControl.resolve(
            state: model.captureOnceState,
            captureReady: model.permissions.isCaptureReady
        ) {
        case .capture(let title):
            captureButton(
                title,
                identifier: title == "Capture Now" ? "capture.manual.start" : "capture.manual.again"
            )
        case .reviewSetup:
            reviewSetupButton
        case .progress:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Capture in progress")
                .accessibilityIdentifier("capture.manual.progress")
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var feedback: some View {
        switch model.captureOnceState {
        case .idle, .inProgress:
            EmptyView()

        case .success:
            Divider()
            Label(successLabel, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SLDesign.success)
                .accessibilityIdentifier("capture.manual.feedback")

        case .failure(let failure):
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    failureLabel(failure)
                    Spacer(minLength: 8)
                    recoveryControls(for: failure)
                }

                VStack(alignment: .leading, spacing: 10) {
                    failureLabel(failure)
                    recoveryControls(for: failure)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capture.manual.feedback")
        }
    }

    private var successSubtitle: String {
        let count = model.lastCaptureDisplayCount
        return count > 1
            ? "Screenlogger saved \(count) displays to your Library."
            : "Screenlogger saved the capture to your Library."
    }

    private var successLabel: String {
        let count = model.lastCaptureDisplayCount
        return count > 1 ? "\(count) displays saved" : "Capture saved"
    }

    private func failureLabel(_ failure: CaptureOnceFailure) -> some View {
        Label(failure.userTitle, systemImage: failure.settingsSystemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(failure == .permissionRequired ? SLDesign.warning : Color.primary)
    }

    private func captureButton(_ title: String, identifier: String) -> some View {
        Button(title) {
            Task { await model.captureOnce() }
        }
        .controlSize(.small)
        .help("Capture the current screen once")
        .disabled(model.libraryStartupIssue != nil)
        .accessibilityIdentifier(identifier)
    }

    private var reviewSetupButton: some View {
        Button("Allow \(missingCapturePermission?.title ?? "Required Permission")...") {
            model.showPermissions(
                origin: .settings,
                preferredPermission: missingCapturePermission
            )
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .accessibilityHint(
            "Open \(missingCapturePermission?.title ?? "required permission") guidance"
        )
        .accessibilityIdentifier("capture.manual.setup")
    }

    private var missingCapturePermission: ScreenlogPermission? {
        model.permissions.primaryMissingRequiredPermission
    }

    private func recoveryControls(for failure: CaptureOnceFailure) -> some View {
        HStack(spacing: 10) {
            if failure == .permissionRequired {
                if model.permissions.isCaptureReady {
                    retryButton(isPrimary: true)
                } else {
                    reviewSetupButton
                }
            } else {
                retryButton()

                recoveryButton(for: failure)
            }
        }
    }

    @ViewBuilder
    private func retryButton(isPrimary: Bool = false) -> some View {
        if isPrimary {
            Button("Retry") {
                Task { await model.captureOnce() }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("capture.manual.retry")
        } else {
            Button("Retry") {
                Task { await model.captureOnce() }
            }
            .controlSize(.small)
            .accessibilityIdentifier("capture.manual.retry")
        }
    }

    @ViewBuilder
    private func recoveryButton(for failure: CaptureOnceFailure) -> some View {
        switch failure {
        case .permissionRequired:
            EmptyView()
        case .lowDiskSpace:
            Button("Storage Settings") {
                model.openProductSettings(.storageManagement)
            }
            .controlSize(.small)
            .accessibilityHint("Review storage use and cleanup options")
            .accessibilityIdentifier("capture.manual.storage")
        case .excludedContent:
            Button("Manage Exclusions") {
                model.openProductSettings(.exclusionsApplications)
            }
            .controlSize(.small)
            .accessibilityHint("Review apps, websites, and private browsing exclusions")
            .accessibilityIdentifier("capture.manual.exclusions")
        case .privateBrowsing, .browserAddressUnavailable:
            Button("Manage Websites") {
                model.openProductSettings(.exclusionsWebsites)
            }
            .controlSize(.small)
            .accessibilityHint("Review website exclusions and strict website protection")
            .accessibilityIdentifier("capture.manual.exclusions")
        case .displayUnavailable, .encodingFailed, .captureFailed:
            EmptyView()
        }
    }
}

extension CaptureOnceFailure {
    fileprivate var settingsSystemImage: String {
        switch self {
        case .permissionRequired: return "exclamationmark.shield"
        case .lowDiskSpace: return "externaldrive.badge.exclamationmark"
        case .excludedContent: return "eye.slash"
        case .privateBrowsing: return "hand.raised"
        case .browserAddressUnavailable: return "globe.badge.chevron.backward"
        case .displayUnavailable, .encodingFailed, .captureFailed:
            return "exclamationmark.triangle"
        }
    }
}
