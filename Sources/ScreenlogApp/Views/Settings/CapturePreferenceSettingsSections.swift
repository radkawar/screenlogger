import AppKit
import ScreenlogCore
import SwiftUI

struct CaptureDisplaySettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var connectedDisplayCount = max(1, NSScreen.screens.count)

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCardRow(
                    icon: "rectangle.on.rectangle",
                    title: "Displays",
                    subtitle: CaptureDisplaySettingsCopy.summary(model.captureDisplayMode)
                ) {
                    EmptyView()
                }

                Picker("Displays to capture", selection: $model.captureDisplayMode) {
                    ForEach(CaptureDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Displays to capture")
                .accessibilityValue(model.captureDisplayMode.label)
                .accessibilityHint("Choose whether Screenlogger follows your active display or saves every connected display")
                .accessibilityIdentifier("capture.displays.picker")

                Label(
                    CaptureDisplaySettingsCopy.connectionNote(
                        model.captureDisplayMode,
                        count: connectedDisplayCount
                    ),
                    systemImage: connectedDisplayCount > 1 ? "display.2" : "display"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if model.captureDisplayMode == .all {
                    Divider()

                    Label(
                        "Excluded apps are removed from every display. If the active app, website, or private browser is protected, the entire moment is skipped.",
                        systemImage: "hand.raised"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("capture.displays.privacy-note")
                }
            }
        }
        .accessibilityIdentifier("capture.displays")
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification
            )
        ) { _ in
            connectedDisplayCount = max(1, NSScreen.screens.count)
        }
    }
}

struct CaptureTimingSettingsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsCard(padding: 0) {
            VStack(spacing: 0) {
                SettingsCardRow(
                    icon: "timer",
                    title: "Capture Interval",
                    subtitle: "How often Screenlogger saves a still while capture is on."
                ) {
                    Text(CaptureSettingsCopy.interval(model.intervalSeconds))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .trailing)
                }
                .padding(14)

                HStack(spacing: 10) {
                    Text("More often")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $model.intervalSeconds, in: 0.5...10, step: 0.5)
                        .accessibilityLabel("Capture interval")
                        .accessibilityValue(CaptureSettingsCopy.interval(model.intervalSeconds))
                        .accessibilityHint("Choose how often Screenlogger saves a still")
                        .accessibilityIdentifier("capture.interval.slider")
                    Text("Less often")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)

                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                Label(
                    "On battery, capture waits at least 5 seconds and uses lighter text recognition.",
                    systemImage: "battery.25percent"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .accessibilityIdentifier("capture.timing.battery-note")

                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                SettingsCardRow(
                    icon: "moon.zzz",
                    title: "Pause When Inactive",
                    subtitle: model.pauseOnInactivity
                        ? "Stops saving after 5 minutes without keyboard or pointer activity, then resumes when you return."
                        : "Continues saving while this Mac is idle."
                ) {
                    Toggle("Pause When Inactive", isOn: $model.pauseOnInactivity)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Pause When Inactive")
                        .accessibilityValue(
                            SettingsAccessibilityValue.onOff(model.pauseOnInactivity)
                        )
                        .accessibilityHint("Pause after five minutes without keyboard or pointer activity")
                        .accessibilityIdentifier("capture.pause-on-inactivity.toggle")
                }
                .padding(14)
            }
        }
        .accessibilityIdentifier("capture.timing")
    }
}

struct CaptureImageSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsAdvancedOptions = false

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCardRow(
                    icon: "camera.aperture",
                    title: "Image Quality",
                    subtitle: qualityHelp
                ) {
                    EmptyView()
                }

                Picker(
                    "Image quality",
                    selection: Binding(
                        get: { model.quality },
                        set: { model.setQuality($0) }
                    )
                ) {
                    ForEach(CaptureQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityHint("Higher quality uses more storage")
                .accessibilityIdentifier("capture.quality.picker")

                DisclosureGroup("Advanced image options", isExpanded: $showsAdvancedOptions) {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Maximum stored edge") {
                            Text(maximumImageEdgeLabel)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }

                        LabeledContent("File format") {
                            Picker("File format", selection: $model.stillEncoding) {
                                ForEach(StillEncodingPreference.allCases) { encoding in
                                    Text(encoding.label).tag(encoding)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                            .accessibilityHint("HEIC uses less storage; JPEG is easier to use outside Apple apps")
                            .accessibilityIdentifier("capture.encoding.picker")
                        }

                        Text("HEIC usually uses less storage. Choose JPEG if you often use exported stills outside Apple apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
                .accessibilityIdentifier("capture.image.advanced")
            }
        }
        .accessibilityIdentifier("capture.image")
    }

    private var qualityHelp: String {
        switch model.quality {
        case .standard:
            return "Standard saves compact images. Text recognition uses the same stored resolution."
        case .high:
            return "High saves sharper images. Text recognition uses the same stored resolution."
        case .ultra: return "Ultra saves the display at native resolution with minimal compression."
        }
    }

    private var maximumImageEdgeLabel: String {
        if model.maxDimension == CaptureQuality.nativeResolutionMaxDimension {
            return "Native display resolution"
        }
        return "\(model.maxDimension) pixels"
    }
}

struct CaptureTextRecognitionSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsAdvancedOptions = false

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCardRow(
                    icon: "text.viewfinder",
                    title: "Text Recognition",
                    subtitle: "Makes captures searchable on this Mac using the selected image quality."
                ) {
                    Label("On", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Language and performance", isExpanded: $showsAdvancedOptions) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Recognition languages")
                                .font(.callout.weight(.medium))
                            TextField("Use system languages", text: $model.ocrLanguagesCSV)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Text recognition languages")
                                .accessibilityHint("Enter comma-separated language codes, or leave empty to use system languages")
                                .accessibilityIdentifier("capture.ocr.languages")
                            Text("Leave empty to use system languages. Advanced: enter language codes such as en-US or en-US, fr-FR.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        SettingsCardRow(
                            icon: "arrow.triangle.2.circlepath",
                            title: "Reuse Text From Similar Captures",
                            subtitle: model.differentialOCREnabled
                                ? "Reduces processing and battery use when very little on screen changed."
                                : "Recognizes all visible text again for every capture."
                        ) {
                            Toggle(
                                "Reuse Text From Similar Captures",
                                isOn: $model.differentialOCREnabled
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Reuse Text From Similar Captures")
                            .accessibilityValue(
                                SettingsAccessibilityValue.onOff(model.differentialOCREnabled)
                            )
                            .accessibilityHint("Reuse recognized text when consecutive captures are visually similar")
                            .accessibilityIdentifier("capture.ocr.differential.toggle")
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
                .accessibilityIdentifier("capture.ocr.advanced")
            }
        }
        .accessibilityIdentifier("capture.text-recognition")
    }
}

struct AudioTranscriptionSettingsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsCard(padding: 0) {
            VStack(spacing: 0) {
                SettingsCardRow(
                    icon: "waveform.badge.mic",
                    title: "Audio Transcription",
                    subtitle: summary
                ) {
                    Toggle(
                        "Audio Transcription",
                        isOn: Binding(
                            get: { model.audioTranscriptionEnabled },
                            set: { model.setAudioTranscriptionEnabledFromUserAction($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!AudioTranscriptionSupport.isAvailable)
                    .accessibilityValue(
                        SettingsAccessibilityValue.onOff(model.audioTranscriptionEnabled)
                    )
                    .accessibilityHint("Transcribe selected audio sources on this Mac")
                    .accessibilityIdentifier("capture.audio.enabled.toggle")
                }
                .padding(14)

                if model.audioTranscriptionEnabled && AudioTranscriptionSupport.isAvailable {
                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                    sourceRow(
                        icon: "speaker.wave.2",
                        title: "Computer Audio",
                        subtitle: "Words played by apps are labeled Computer.",
                        isOn: $model.computerAudioTranscriptionEnabled,
                        identifier: "capture.audio.computer.toggle"
                    )

                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                    sourceRow(
                        icon: "mic",
                        title: "Microphone",
                        subtitle: microphoneSubtitle,
                        isOn: Binding(
                            get: { model.microphoneTranscriptionEnabled },
                            set: { model.setMicrophoneTranscriptionEnabledFromUserAction($0) }
                        ),
                        identifier: "capture.audio.microphone.toggle"
                    )

                    if model.microphoneTranscriptionEnabled,
                        model.microphoneAuthorization != .authorized
                    {
                        HStack {
                            Spacer()
                            Button(microphoneButtonTitle) {
                                model.retryMicrophoneAuthorizationFromUserAction()
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("capture.audio.microphone.permission")
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }

                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                    statusRow

                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                    VStack(alignment: .leading, spacing: 7) {
                        Label("Private by design", systemImage: "lock.shield")
                            .font(.callout.weight(.medium))
                        Text(
                            "Apple's speech model runs on this Mac. Screenlogger saves finalized text only and immediately discards audio samples. App and website exclusions and Private Browsing also pause transcription."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        Text(
                            "Browser note: macOS cannot reliably identify which background tab produced audio. A background tab may be transcribed when a different, allowed website is active."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                }
            }
        }
        .accessibilityIdentifier("capture.audio-transcription")
    }

    private var summary: String {
        guard AudioTranscriptionSupport.isAvailable else {
            return AudioTranscriptionSupport.requirementDescription
        }
        if model.audioTranscriptionEnabled {
            return "Adds what you say and hear to Library search. Audio is never saved."
        }
        return "Optional on-device transcripts for meetings, presentations, and calls."
    }

    private var microphoneSubtitle: String {
        switch model.microphoneAuthorization {
        case .authorized: return "Your voice is labeled You."
        case .notDetermined: return "Your voice is labeled You. Permission is requested only when you enable this."
        case .denied, .restricted: return "Microphone access is unavailable. Computer Audio can still be transcribed."
        }
    }

    private var microphoneButtonTitle: String {
        model.microphoneAuthorization == .notDetermined
            ? "Allow Microphone"
            : "Open Microphone Settings"
    }

    private func sourceRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        identifier: String
    ) -> some View {
        SettingsCardRow(icon: icon, title: title, subtitle: subtitle) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityValue(SettingsAccessibilityValue.onOff(isOn.wrappedValue))
                .accessibilityIdentifier(identifier)
        }
        .padding(14)
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.callout.weight(.medium))
                Text(model.audioTranscriptionStatus.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.audioTranscriptionStatus.phase == .preparing,
                    let progress = model.audioTranscriptionStatus.preparationProgress
                {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .padding(.top, 3)
                } else if model.audioTranscriptionStatus.phase == .recovering {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 8)
            if let statusActionTitle {
                Button(statusActionTitle) {
                    model.retryAudioTranscriptionFromUserAction()
                }
                .controlSize(.small)
                .accessibilityIdentifier("capture.audio.status.action")
            }
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.audio.status")
    }

    private var statusActionTitle: String? {
        AudioTranscriptionPermissionPresentation.statusActionTitle(
            phase: model.audioTranscriptionStatus.phase,
            microphoneAuthorization: model.microphoneAuthorization
        )
    }

    private var statusTitle: String {
        switch model.audioTranscriptionStatus.phase {
        case .unavailable: return "Unavailable"
        case .off: return "Off"
        case .permissionRequired: return "Microphone Permission Needed"
        case .preparing: return "Preparing On-Device Model"
        case .recovering: return "Reconnecting"
        case .active: return "Transcribing"
        case .privacyPaused: return "Paused for Privacy"
        case .capturePaused: return "Waiting for Capture"
        case .failed: return "Transcription Needs Attention"
        }
    }

    private var statusSymbol: String {
        switch model.audioTranscriptionStatus.phase {
        case .active: return "waveform.circle.fill"
        case .preparing: return "arrow.down.circle"
        case .recovering: return "arrow.triangle.2.circlepath"
        case .privacyPaused: return "lock.circle"
        case .failed, .permissionRequired: return "exclamationmark.circle"
        case .unavailable, .off, .capturePaused: return "waveform.circle"
        }
    }

    private var statusColor: Color {
        switch model.audioTranscriptionStatus.phase {
        case .active: return .green
        case .preparing, .recovering: return .accentColor
        case .privacyPaused: return .orange
        case .failed, .permissionRequired: return .red
        case .unavailable, .off, .capturePaused: return .secondary
        }
    }
}

enum CaptureSettingsCopy {
    static func interval(_ seconds: Double) -> String {
        CaptureLocalProcessingCopy.intervalLabel(seconds)
    }
}
