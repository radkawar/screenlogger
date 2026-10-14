import AppKit
import ScreenlogCore
import SwiftUI

/// A compact map for the temporary setup detour.
///
/// macOS permission changes happen in another app, so keeping both stages
/// visible prevents the System Settings trip from feeling like an unexplained
/// dead end. The final stage remains a choice: allowing permission never turns
/// capture on by itself.
struct PermissionsSetupProgress: View {
    let screenRecordingAllowed: Bool
    let accessibilityAllowed: Bool
    let currentPermission: ScreenlogPermission?
    let isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            Text(progressTitle)
                .font(SLDesign.metadataFont)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Setup progress, \(progressTitle)")
                .accessibilityIdentifier("setup.progress.summary")
            ViewThatFits(in: .horizontal) {
                horizontalProgress
                    .fixedSize(horizontal: true, vertical: false)
                verticalProgress
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.progress")
    }

    private var horizontalProgress: some View {
        HStack(spacing: SLDesign.space8) {
            screenRecordingStage
            connector(complete: screenRecordingAllowed)
            accessibilityStage
            connector(complete: accessibilityAllowed)
            captureStage
        }
    }

    private var verticalProgress: some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            screenRecordingStage
            accessibilityStage
            captureStage
        }
    }

    private var screenRecordingStage: some View {
        stage(
            title: "Screen Recording",
            symbol: screenRecordingAllowed ? "checkmark.circle.fill" : "1.circle.fill",
            state: permissionStageState(.screenRecording),
            identifier: "setup.progress.permission"
        )
    }

    private var accessibilityStage: some View {
        stage(
            title: "Accessibility",
            symbol: accessibilityAllowed ? "checkmark.circle.fill" : "2.circle.fill",
            state: permissionStageState(.accessibility),
            identifier: "setup.progress.accessibility"
        )
    }

    private var captureStage: some View {
        stage(
            title: "Capture Choice",
            symbol: isRecording ? "checkmark.circle.fill" : "3.circle.fill",
            state: isRecording
                ? .complete
                : (screenRecordingAllowed && accessibilityAllowed ? .current : .upcoming),
            identifier: "setup.progress.capture"
        )
    }

    private func connector(complete: Bool) -> some View {
        Capsule()
            .fill(complete ? Color.secondary : Color(nsColor: .separatorColor))
            .frame(width: SLDesign.space16, height: 1)
            .accessibilityHidden(true)
    }

    private enum StageState {
        case current
        case complete
        case upcoming
    }

    private var progressTitle: String {
        if isRecording { return "Setup complete" }
        if screenRecordingAllowed, accessibilityAllowed { return "Step 3 of 3" }
        if screenRecordingAllowed || accessibilityAllowed { return "Step 2 of 3" }
        return "Step 1 of 3"
    }

    private func permissionStageState(_ permission: ScreenlogPermission) -> StageState {
        let allowed =
            switch permission {
            case .screenRecording: screenRecordingAllowed
            case .accessibility: accessibilityAllowed
            }
        if allowed { return .complete }
        return currentPermission == permission ? .current : .upcoming
    }

    private func stage(
        title: String,
        symbol: String,
        state: StageState,
        identifier: String
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(SLDesign.metadataFont.weight(state == .current ? .semibold : .regular))
            .foregroundStyle(stageColor(state))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(stageAccessibilityValue(state))
            .accessibilityIdentifier(identifier)
    }

    private func stageColor(_ state: StageState) -> Color {
        switch state {
        case .current: return .accentColor
        case .complete: return .secondary
        case .upcoming: return .secondary
        }
    }

    private func stageAccessibilityValue(_ state: StageState) -> String {
        switch state {
        case .current: return "Current step"
        case .complete: return "Complete"
        case .upcoming: return "Not started"
        }
    }
}

struct FirstRunAudioSetupCard: View {
    @Binding var isEnabled: Bool
    @Binding var computerAudioEnabled: Bool
    @Binding var microphoneEnabled: Bool
    let microphoneAuthorization: MicrophoneAuthorization
    let onMicrophonePermission: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SLDesign.space16) {
            HStack(alignment: .center, spacing: SLDesign.space16) {
                VStack(alignment: .leading, spacing: SLDesign.space4) {
                    Text("Audio Transcription (Optional)")
                        .font(SLDesign.sectionFont)
                    Text("Search calls, meetings, and presentations with on-device transcripts.")
                        .font(SLDesign.metadataFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: SLDesign.space8)
                Toggle("Audio Transcription", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityValue(SettingsAccessibilityValue.onOff(isEnabled))
                    .accessibilityIdentifier("setup.audio.enabled")
            }
            if isEnabled {
                audioSourceRow(
                    title: "Computer Audio",
                    detail: "Transcribe words played by apps.",
                    symbol: "speaker.wave.2",
                    isOn: $computerAudioEnabled,
                    identifier: "setup.audio.computer"
                )
                audioSourceRow(
                    title: "Microphone",
                    detail: microphoneDetail,
                    symbol: "mic",
                    isOn: $microphoneEnabled,
                    identifier: "setup.audio.microphone"
                )
                if microphoneEnabled, microphoneAuthorization != .authorized {
                    Button(microphoneActionTitle, action: onMicrophonePermission)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("setup.audio.microphone.permission")
                }
            }
            Text("Apple's speech model runs on this Mac. Screenlogger saves only finalized text and discards raw audio.")
                .font(SLDesign.metadataFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.audio")
    }

    private var microphoneDetail: String {
        switch microphoneAuthorization {
        case .authorized:
            return "Transcribe your voice and label it You."
        case .notDetermined:
            return "Transcribe your voice. macOS asks only if you select this option."
        case .denied, .restricted:
            return "Microphone access is unavailable. Computer Audio still works."
        }
    }

    private var microphoneActionTitle: String {
        microphoneAuthorization == .notDetermined
            ? "Allow Microphone" : "Open Microphone Settings"
    }

    private func audioSourceRow(
        title: String,
        detail: String,
        symbol: String,
        isOn: Binding<Bool>,
        identifier: String
    ) -> some View {
        HStack(alignment: .center, spacing: SLDesign.space8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: SLDesign.space24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SLDesign.space4) {
                Text(title)
                    .font(SLDesign.bodyFont)
                Text(detail)
                    .font(SLDesign.metadataFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SLDesign.space8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityValue(SettingsAccessibilityValue.onOff(isOn.wrappedValue))
                .accessibilityIdentifier(identifier)
        }
    }
}

struct PermissionsPrivacySummary: View {
    private struct Fact {
        let title: String
        let symbol: String
        let identifier: String
    }

    let screenRecordingAllowed: Bool
    let accessibilityAllowed: Bool
    let audioTranscriptionEnabled: Bool
    let microphoneEnabled: Bool
    @State private var showingDetails = false

    private var facts: [Fact] {
        [
            Fact(
                title: "Saved on this Mac",
                symbol: "internaldrive",
                identifier: "setup.privacy.local"
            ),
            audioTranscriptionEnabled
                ? Fact(
                    title: "Raw audio is never saved",
                    symbol: "waveform.slash",
                    identifier: "setup.privacy.audio"
                )
                : Fact(
                    title: "No camera or microphone",
                    symbol: "mic.slash",
                    identifier: "setup.privacy.no-sensors"
                ),
            Fact(
                title: "Pause or turn off at any time",
                symbol: "pause.circle",
                identifier: "setup.privacy.control"
            ),
        ]
    }

    var body: some View {
        DisclosureGroup(isExpanded: $showingDetails) {
            VStack(alignment: .leading, spacing: SLDesign.space16) {
                Text(privacyDetail)
                    .font(SLDesign.bodyFont)
                    .fixedSize(horizontal: false, vertical: true)
                PermissionsStatusCard(
                    screenRecordingAllowed: screenRecordingAllowed,
                    accessibilityAllowed: accessibilityAllowed
                )
                VStack(alignment: .leading, spacing: SLDesign.space8) {
                    ForEach(facts, id: \.identifier) { fact in
                        Label(fact.title, systemImage: fact.symbol)
                            .font(SLDesign.metadataFont)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier(fact.identifier)
                    }
                }
            }
            .padding(.top, SLDesign.space16)
        } label: {
            VStack(alignment: .leading, spacing: SLDesign.space4) {
                Text("Privacy on This Mac")
                    .font(SLDesign.sectionFont)
                Text(privacySummary)
                    .font(SLDesign.metadataFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityHint("Show details about capture and privacy controls")
        .accessibilityIdentifier("setup.privacy-summary")
    }

    private var privacyDetail: String {
        let capture =
            "Screenlogger uses Screen Recording to save still images at intervals. Screenlogger uses Accessibility to apply exclusions and capture app context."
        guard audioTranscriptionEnabled else { return capture }
        let source = microphoneEnabled ? "computer and microphone audio" : "computer audio"
        return
            "\(capture) Optional on-device transcription processes \(source). Screenlogger saves finalized text only and immediately discards audio samples."
    }

    private var privacySummary: String {
        audioTranscriptionEnabled
            ? "Screenlogger saves data on this Mac, but never saves raw audio. You can change capture controls at any time."
            : "Screenlogger saves data on this Mac without a camera or microphone. You can change capture controls at any time."
    }
}

struct PermissionsStatusCard: View {
    let screenRecordingAllowed: Bool
    let accessibilityAllowed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SLDesign.space16) {
            permissionRow(
                title: "Screen Recording",
                detail: "Required to save still images and recognize visible text.",
                granted: screenRecordingAllowed,
                identifier: "setup.permission.screen-recording"
            )
            permissionRow(
                title: "Accessibility",
                detail: "Required to apply exclusions and capture app context.",
                granted: accessibilityAllowed,
                identifier: "setup.permission.accessibility"
            )
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: SLDesign.space4) {
            HStack(spacing: SLDesign.space8) {
                Text(title)
                    .font(SLDesign.bodyFont.weight(.medium))
                Spacer(minLength: SLDesign.space8)
                Text(granted ? "Allowed" : "Required")
                    .font(SLDesign.metadataFont)
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(SLDesign.metadataFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

struct PermissionsNextActionCard: View {
    let permission: ScreenlogPermission
    let journeyState: PermissionJourneyState

    var body: some View {
        VStack(alignment: .leading, spacing: SLDesign.space16) {
            Text("Allow \(permission.title)")
                .font(SLDesign.sectionFont)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: SLDesign.space8) {
                if permission == .screenRecording {
                    instructionRow(1, screenRecordingFirstInstruction)
                    instructionRow(2, "Turn on Screenlogger in the list.")
                    instructionRow(3, "Return here. If macOS asks, choose Quit & Reopen.")
                } else {
                    instructionRow(1, accessibilityFirstInstruction)
                    instructionRow(2, "Turn on Screenlogger in the list.")
                    instructionRow(3, "Return here. Screenlogger checks automatically.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.next-action")
    }

    private var screenRecordingFirstInstruction: String {
        switch journeyState {
        case .restartRequired:
            return "Choose Quit & Reopen Screenlogger below."
        case .awaitingSystemSettings, .requesting, .verificationFailed:
            return "Choose Open Screen Recording Settings below."
        case .needsRequest, .ready:
            return "Choose Allow Screen Recording below."
        }
    }

    private var accessibilityFirstInstruction: String {
        switch journeyState {
        case .awaitingSystemSettings, .restartRequired, .requesting, .verificationFailed:
            return "Choose Open Accessibility Settings below."
        case .needsRequest, .ready:
            return "Choose Allow Accessibility below."
        }
    }

    private func instructionRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SLDesign.space8) {
            Text("\(number).")
                .font(SLDesign.metadataFont.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: SLDesign.space16, alignment: .leading)
                .accessibilityHidden(true)
            Text(text)
                .font(SLDesign.bodyFont)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PermissionsMissingAppHelp: View {
    @Binding var isExpanded: Bool
    let appURL: URL
    let appName: String
    let permission: ScreenlogPermission
    let settingsResult: PermissionSettingsOpenResult?
    let onRetry: () -> Void

    var body: some View {
        DisclosureGroup(
            "Screenlogger is not in System Settings?",
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: SLDesign.space8) {
                Text(settingsResult?.instructions ?? manualInstructions)
                    .font(SLDesign.metadataFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup.drag-direction.\(permission.rawValue)")

                AppBundleDragChip(
                    url: appURL,
                    displayName: appName,
                    permission: permission
                )

                HStack(spacing: SLDesign.space8) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([appURL])
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("setup.reveal-app")

                    Button("Open \(permission.title) Again", action: onRetry)
                        .controlSize(.small)
                        .accessibilityIdentifier("setup.retry-settings")
                }
            }
            .padding(.top, SLDesign.space8)
        }
        .font(SLDesign.metadataFont.weight(.medium))
        .accessibilityHint("Shows help for adding Screenlogger to a macOS privacy list")
        .accessibilityIdentifier("setup.missing-app-help")
    }

    private var manualInstructions: String {
        "In System Settings, open \(permission.settingsPaneName). Use the Add button or drag Screenlogger into the list."
    }
}

private struct AppBundleDragChip: View {
    let url: URL
    let displayName: String
    let permission: ScreenlogPermission

    var body: some View {
        HStack(spacing: SLDesign.space8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
                .frame(width: SLDesign.space32, height: SLDesign.space32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SLDesign.space4) {
                Text(displayName)
                    .font(SLDesign.bodyFont.weight(.medium))
                    .lineLimit(1)
                Text("Drag into the \(permission.title) list")
                    .font(SLDesign.metadataFont)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: SLDesign.space8)

            Image(systemName: "hand.draw")
                .font(SLDesign.bodyFont)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(SLDesign.space8)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: SLDesign.thumbRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: SLDesign.thumbRadius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onDrag {
            AppBundleDragProvider.make(for: url)
        }
        .help("Drag \(displayName) into the System Settings privacy list")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName) app")
        .accessibilityHint("Drag this app into the open System Settings privacy list")
        .accessibilityAction(named: Text("Show in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .accessibilityIdentifier("setup.drag-app.\(permission.rawValue)")
    }
}
