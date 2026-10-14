import AppKit
import ScreenlogCore
import SwiftUI

// MARK: - SwiftUI content

struct PermissionsHelperView: View {
    private enum DecisionFocus: Hashable {
        case primary
    }

    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var showingMissingAppHelp = false
    @State private var openedPermission: ScreenlogPermission?
    @State private var pendingPermissionTransition = false
    @State private var firstRunWaitIsLong = false
    @FocusState private var decisionFocus: DecisionFocus?
    @AccessibilityFocusState private var decisionAccessibilityFocus: DecisionFocus?
    let origin: CaptureSetupOrigin
    let preferredPermission: ScreenlogPermission?
    let onDismiss: () -> Void
    let onStart: () -> Void
    let onDone: () -> Void
    let onOpenScreen: () -> Void
    let onOpenAccessibility: () -> Void
    let onRefresh: () -> Void
    let onRelaunch: () -> Void

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Screenlogger"
    }

    private var appURL: URL {
        Bundle.main.bundleURL
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SLDesign.space24) {
                    header
                    PermissionsSetupProgress(
                        screenRecordingAllowed: model.permissions.screenRecording,
                        accessibilityAllowed: model.permissions.accessibility,
                        currentPermission: nextRequiredPermission,
                        isRecording: model.isRecording
                    )
                    if model.permissions.isCaptureReady {
                        currentStateCard
                    }
                    if let permission = nextRequiredPermission {
                        PermissionsNextActionCard(
                            permission: permission,
                            journeyState: model.permissionJourney.state(for: permission)
                        )
                    }
                    if showsOptionalAudioSetup {
                        FirstRunAudioSetupCard(
                            isEnabled: Binding(
                                get: { model.audioTranscriptionEnabled },
                                set: {
                                    model.setFirstRunAudioTranscriptionEnabledFromUserAction($0)
                                }
                            ),
                            computerAudioEnabled: $model.computerAudioTranscriptionEnabled,
                            microphoneEnabled: Binding(
                                get: { model.microphoneTranscriptionEnabled },
                                set: {
                                    model.setMicrophoneTranscriptionEnabledFromUserAction($0)
                                }
                            ),
                            microphoneAuthorization: model.microphoneAuthorization,
                            onMicrophonePermission: {
                                model.retryMicrophoneAuthorizationFromUserAction()
                            }
                        )
                    }
                    if let openedPermission,
                        !model.permissions.screenRecording || !model.permissions.accessibility
                    {
                        PermissionsMissingAppHelp(
                            isExpanded: $showingMissingAppHelp,
                            appURL: appURL,
                            appName: appName,
                            permission: openedPermission,
                            settingsResult: model.permissionSettingsResult,
                            onRetry: retryOpenedPermission
                        )
                    }
                    PermissionsPrivacySummary(
                        screenRecordingAllowed: model.permissions.screenRecording,
                        accessibilityAllowed: model.permissions.accessibility,
                        audioTranscriptionEnabled: model.audioTranscriptionEnabled,
                        microphoneEnabled: model.audioTranscriptionEnabled
                            && model.microphoneTranscriptionEnabled
                            && model.microphoneAuthorization == .authorized
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SLDesign.space24)
            }

            Divider()
            actionBar
        }
        .frame(minWidth: 460, idealWidth: 620, minHeight: 428, idealHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(model.accentSwiftUIColor)
        .accentColor(model.accentSwiftUIColor)
        .onAppear {
            DispatchQueue.main.async {
                decisionFocus = .primary
                decisionAccessibilityFocus = .primary
            }
        }
        .onExitCommand {
            if isFirstRunWaiting {
                onDismiss()
            } else if model.isRecording || isFirstRunReady {
                onDone()
            } else {
                onDismiss()
            }
        }
        .onChange(of: model.permissions.screenRecording) { wasGranted, granted in
            handlePermissionChange(
                permission: .screenRecording,
                wasGranted: wasGranted,
                isGranted: granted
            )
        }
        .onChange(of: model.permissions.accessibility) { wasGranted, granted in
            handlePermissionChange(
                permission: .accessibility,
                wasGranted: wasGranted,
                isGranted: granted
            )
        }
        .onChange(of: model.permissions.isCaptureReady) { _, isReady in
            guard isReady else { return }
            // The primary control changes identity when the second permission
            // arrives. Re-establish keyboard focus so Space and Return activate
            // Start Capture without requiring a pointer click.
            decisionFocus = nil
            DispatchQueue.main.async {
                decisionFocus = .primary
                decisionAccessibilityFocus = .primary
            }
        }
        .onChange(of: controlActiveState) { _, activeState in
            guard activeState == .key else { return }
            presentPendingPermissionTransitionIfPossible()
        }
        .task(id: isFirstRunWaiting) {
            firstRunWaitIsLong = false
            guard isFirstRunWaiting else { return }
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, isFirstRunWaiting else { return }
            firstRunWaitIsLong = true
        }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            Text("Get Screenlogger Ready")
                .font(SLDesign.titleFont)
                .accessibilityAddTraits(.isHeader)
            Text(headerDetail)
                .font(SLDesign.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var timedPauseActive: Bool {
        model.recordingPausedUntil.map { $0 > Date() } == true
    }

    private var showsOptionalAudioSetup: Bool {
        origin == .directFirstRun
            && model.permissions.isCaptureReady
            && !model.isRecording
            && AudioTranscriptionSupport.isAvailable
    }

    private var nextRequiredPermission: ScreenlogPermission? {
        if let preferredPermission,
            !model.permissions.isGranted(preferredPermission)
        {
            return preferredPermission
        }
        return model.permissions.primaryMissingRequiredPermission
    }

    private var headerDetail: String {
        if model.permissions.missingRequiredPermissions.count == 2 {
            return "Allow the two required macOS permissions. Then choose whether capture starts."
        }
        if let nextRequiredPermission {
            return "Allow \(nextRequiredPermission.title). Then choose whether capture starts."
        }
        if showsOptionalAudioSetup {
            return "Capture permissions are ready. Audio transcription is optional before you start."
        }
        if isFirstRunWaiting {
            return "Capture is on. Screenlogger is saving your first searchable moment."
        }
        if isFirstRunReady {
            return "Your first searchable moment is ready in Library."
        }
        return "Permissions are ready. You control when capture is on."
    }

    private var currentStateCard: some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            Text(currentState.title)
                .font(SLDesign.sectionFont)
            Text(currentState.detail)
                .font(SLDesign.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(currentState.title)
        .accessibilityValue(currentState.detail)
        .accessibilityIdentifier("setup.current-state")
    }

    private var currentState: (title: String, detail: String) {
        if model.isDatabaseReclamationRunning {
            let status = model.captureStatusPresentation()
            return (status.headline, status.detail)
        }
        if model.captureIssue == .startFailed {
            return (
                "Capture did not start",
                "Your existing Library remains available. Choose Start Capture to try again."
            )
        }
        if isFirstRunWaiting {
            return (
                firstRunWaitIsLong
                    ? "Still saving your first moment"
                    : "Saving your first moment",
                firstRunWaitIsLong
                    ? "Screenlogger needs more time. Capture is still on. You can wait or stop capture and open Library."
                    : "Keep this window open while Screenlogger saves and indexes one searchable moment."
            )
        }
        if isFirstRunReady {
            return (
                "First moment is searchable",
                "Screenlogger saved it in your Library. Capture remains on when you open it."
            )
        }
        if let until = model.recordingPausedUntil, until > Date() {
            return (
                "Capture is paused",
                "It will resume at \(until.formatted(date: .omitted, time: .shortened)), or you can resume now."
            )
        }
        if model.isRecording {
            return (
                "Capture is on",
                "Screenlogger is saving searchable moments on this Mac."
            )
        }
        return (
            "Ready to start",
            "Capture is still off and will not start until you choose Start Capture."
        )
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: SLDesign.space16) {
            Text(actionGuidance)
                .font(SLDesign.metadataFont)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(actionGuidance)
                .accessibilityIdentifier("setup.return-guidance")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: SLDesign.space8) {
                    if showsRefreshButton {
                        refreshButton
                    }
                    Spacer(minLength: SLDesign.space16)
                    decisionButtons
                }

                VStack(alignment: .trailing, spacing: SLDesign.space8) {
                    decisionButtons
                    if showsRefreshButton {
                        refreshButton
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, SLDesign.space24)
        .padding(.vertical, SLDesign.space16)
        .background(.bar)
    }

    private var refreshButton: some View {
        Button("Check Again", systemImage: "arrow.clockwise", action: onRefresh)
            .help("Refresh permission status")
            .accessibilityHint("Checks the current macOS permission status")
            .accessibilityIdentifier("setup.refresh")
    }

    private var showsRefreshButton: Bool {
        openedPermission != nil
    }

    private var actionGuidance: String {
        if !model.permissions.isCaptureReady {
            return CaptureSetupGuidance.missingPermissionFooter(for: origin)
        }
        if isFirstRunWaiting {
            return "Screenlogger will let you continue as soon as the first moment is safely stored."
        }
        if isFirstRunReady {
            return "Open Library to see your first searchable moment."
        }
        if model.isRecording {
            return "Done returns you to \(origin.returnSurfaceName)."
        }
        return CaptureSetupGuidance.readyFooter(for: origin)
    }

    @ViewBuilder
    private var decisionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SLDesign.space8) {
                decisionButtonContent
            }

            VStack(alignment: .trailing, spacing: SLDesign.space8) {
                decisionButtonContent
            }
        }
    }

    @ViewBuilder
    private var decisionButtonContent: some View {
        if model.permissions.isCaptureReady {
            if isFirstRunWaiting {
                keepCaptureOffButton
                HStack(spacing: SLDesign.space8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving first moment...")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Saving first searchable moment")
                .accessibilityIdentifier("setup.first-value.progress")
            } else if isFirstRunReady {
                Button("Open Library", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .focused($decisionFocus, equals: .primary)
                    .accessibilityFocused($decisionAccessibilityFocus, equals: .primary)
                    .accessibilityHint("Open Library while capture remains on")
                    .accessibilityIdentifier("setup.open-library")
            } else if model.isRecording {
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .focused($decisionFocus, equals: .primary)
                    .accessibilityFocused($decisionAccessibilityFocus, equals: .primary)
                    .accessibilityHint("Close setup while capture remains on")
                    .accessibilityIdentifier("setup.done")
            } else {
                keepCaptureOffButton
                Button(action: onStart) {
                    Label(
                        timedPauseActive ? "Resume Capture" : "Start Capture",
                        systemImage: timedPauseActive ? "play.fill" : "record.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isDatabaseReclamationRunning)
                .keyboardShortcut(.defaultAction)
                .focused($decisionFocus, equals: .primary)
                .accessibilityFocused($decisionAccessibilityFocus, equals: .primary)
                .accessibilityHint(
                    timedPauseActive
                        ? "Resume saving searchable moments now and return to \(origin.returnSurfaceName)"
                        : "Begin saving searchable moments on this Mac and continue to \(origin.returnSurfaceName)"
                )
                .accessibilityIdentifier(
                    timedPauseActive ? "setup.resume-capture" : "setup.start-capture"
                )
            }
        } else {
            keepCaptureOffButton
            if nextPermissionNeedsRelaunch {
                Button("Quit & Reopen Screenlogger", action: onRelaunch)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .focused($decisionFocus, equals: .primary)
                    .accessibilityFocused($decisionAccessibilityFocus, equals: .primary)
                    .accessibilityHint(
                        "Quit and reopen Screenlogger so macOS can finish applying Screen Recording access"
                    )
                    .accessibilityIdentifier("setup.relaunch")
            } else {
                Button(primaryPermissionActionTitle) {
                    guard let permission = nextRequiredPermission else { return }
                    openedPermission = permission
                    showingMissingAppHelp = true
                    switch permission {
                    case .screenRecording:
                        onOpenScreen()
                    case .accessibility:
                        onOpenAccessibility()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .focused($decisionFocus, equals: .primary)
                .accessibilityFocused($decisionAccessibilityFocus, equals: .primary)
                .accessibilityLabel(primaryPermissionActionTitle)
                .accessibilityHint(primaryPermissionActionHint)
                .accessibilityIdentifier(primaryPermissionActionIdentifier)
            }
        }
    }

    private var nextPermissionNeedsRelaunch: Bool {
        guard let permission = nextRequiredPermission else { return false }
        return model.permissionJourney.state(for: permission) == .restartRequired
    }

    private var primaryPermissionActionTitle: String {
        guard let permission = nextRequiredPermission else { return "Check Permissions" }
        switch model.permissionJourney.action(for: permission) {
        case .request:
            return "Allow \(permission.title)"
        case .openSettings:
            return "Open \(permission.title) Settings"
        case .none:
            return "Check Permissions"
        }
    }

    private var primaryPermissionActionHint: String {
        guard let permission = nextRequiredPermission else {
            return "Check the current macOS permission status"
        }
        switch model.permissionJourney.action(for: permission) {
        case .request:
            return "Request \(permission.title) access and open its macOS privacy pane when needed"
        case .openSettings:
            return "Open the \(permission.title) pane without requesting access again"
        case .none:
            return "Check the current macOS permission status"
        }
    }

    private var primaryPermissionActionIdentifier: String {
        nextRequiredPermission == .accessibility
            ? "setup.open-accessibility" : "setup.open-screen-recording"
    }

    private var keepCaptureOffButton: some View {
        Button(keepCaptureOffTitle, action: onDismiss)
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .accessibilityHint(keepCaptureOffHint)
            .accessibilityIdentifier("setup.keep-off")
    }

    private var keepCaptureOffTitle: String {
        guard origin == .directFirstRun else { return "Keep Capture Off" }
        return isFirstRunWaiting ? "Stop & Open Library" : "Keep Off & Open Library"
    }

    private var keepCaptureOffHint: String {
        if origin == .directFirstRun {
            if isFirstRunWaiting {
                return "Stop capture, close setup, and open Library"
            }
            return "Remember that capture should remain off, close setup, and open Library"
        }
        let closeAction = "Close setup and remember that capture should remain off"
        guard origin.returnsToInitiatingSurface else { return closeAction }
        return "\(closeAction), then return to \(origin.returnSurfaceName)"
    }

    private var isFirstRunWaiting: Bool {
        origin == .directFirstRun && model.firstRunValueProgress.isWaiting
    }

    private var isFirstRunReady: Bool {
        origin == .directFirstRun && model.firstRunValueProgress.isReady
    }

    private func handlePermissionChange(
        permission: ScreenlogPermission,
        wasGranted: Bool,
        isGranted: Bool
    ) {
        guard !wasGranted, isGranted,
            openedPermission == permission
        else { return }

        // Only a permission that changed after this Setup flow opened the
        // matching System Settings pane should move focus. Background refreshes
        // and an already-configured launch keep the user's current locus.
        openedPermission = nil
        showingMissingAppHelp = false
        pendingPermissionTransition = true
        presentPendingPermissionTransitionIfPossible()
    }

    private func presentPendingPermissionTransitionIfPossible() {
        guard pendingPermissionTransition,
            controlActiveState == .key
        else { return }

        pendingPermissionTransition = false
        DispatchQueue.main.async {
            decisionFocus = .primary
            decisionAccessibilityFocus = .primary
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: permissionTransitionAnnouncement,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }

    private var permissionTransitionAnnouncement: String {
        if !model.permissions.screenRecording {
            return "Next, allow Screen Recording."
        }
        if !model.permissions.accessibility {
            return "Screen Recording allowed. Next, allow Accessibility."
        }
        let primaryAction = timedPauseActive ? "Resume Capture" : "Start Capture"
        return "Both permissions are allowed. Choose \(primaryAction) or Keep Capture Off."
    }

    private func retryOpenedPermission() {
        guard let openedPermission else { return }
        switch openedPermission {
        case .screenRecording: model.openScreenSettings()
        case .accessibility: model.openAccessibilitySettings()
        }
    }
}
