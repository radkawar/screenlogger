import SwiftUI

/// Capture settings are ordered from the decision a person needs to make now
/// to controls they are likely to change less often. Each section owns one
/// concern so capture state and preference editing cannot drift together.
struct CaptureSettingsPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.cardSpacing) {
            CaptureStatusSettingsSection()
                .settingsDestinationAnchor(.captureStatus)

            if let issue = model.captureIssue {
                SLCaptureIssueBanner(issue: issue, context: "settings")
            }

            CaptureOnceSettingsSection()
                .settingsDestinationAnchor(.captureOnce)
            CaptureDisplaySettingsSection()
                .settingsDestinationAnchor(.captureDisplays)
            CaptureTimingSettingsSection()
                .settingsDestinationAnchor(.captureTiming)
            CaptureImageSettingsSection()
            CaptureTextRecognitionSettingsSection()
            AudioTranscriptionSettingsSection()
                .settingsDestinationAnchor(.captureAudio)
        }
        .onChange(of: model.permissions.isCaptureReady) { _, granted in
            guard granted else { return }
            model.reconcileCaptureOnceAfterPermissionGrant()
        }
        .task {
            await model.refreshPermissions(force: false)
        }
    }
}
