import ScreenlogCore
import SwiftUI

struct SearchSettingsPane: View {
    var body: some View {
        SettingsSectionStack {
            SemanticSearchSettingsCard()
                .settingsDestinationAnchor(.searchSemanticSearch)
        }
    }
}

struct SemanticSearchSettingsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let controller = model.semanticSearchController {
            SemanticSearchSettingsContent(controller: controller, offline: model.airgapMode)
        } else {
            PrivacySettingsGroup("Meaning Search", systemImage: "magnifyingglass") {
                Text("Meaning Search is not available until the Library opens.")
                    .foregroundStyle(.secondary)
                    .padding(SLDesign.space16)
            }
        }
    }
}

private struct SemanticSearchSettingsContent: View {
    @ObservedObject var controller: SemanticSearchController
    let offline: Bool
    @State private var mode: SemanticSearchMode = .images
    @State private var actionTask: Task<Void, Never>?
    @State private var issue: String?
    @State private var removal: SemanticControlAction?
    @State private var installedForMode = false
    @State private var checkingModels = true

    private var status: SemanticFeatureStatus { controller.featureStatus }
    private var installing: Bool { status.phase == .downloading || status.phase == .verifying }
    private var busy: Bool { actionTask != nil }
    private var sourceChanged: Bool { mode != status.mode }
    private var modelSize: String {
        ByteCountFormatter.string(fromByteCount: SemanticModelManager.downloadBytes(for: mode), countStyle: .file)
    }

    var body: some View {
        PrivacySettingsGroup("Meaning Search", systemImage: "magnifyingglass") {
            VStack(alignment: .leading, spacing: SLDesign.space16) {
                HStack(alignment: .center, spacing: SLDesign.space16) {
                    VStack(alignment: .leading, spacing: SLDesign.space4) {
                        Text(status.enabled ? "On \u{2014} \(status.mode.label)" : "Off")
                            .font(SLDesign.bodyFont.weight(.medium))
                            .accessibilityIdentifier("settings.semantic.state")
                        Text("Find captures by appearance or meaning, on this Mac.")
                            .font(SLDesign.metadataFont)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Toggle(
                        "Meaning Search",
                        isOn: Binding(
                            get: { status.enabled },
                            set: { perform($0 ? .enable : .disable) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(
                        busy || installing || (!status.enabled && (!installedForMode || checkingModels || status.phase == .unsupported))
                    )
                    .help(
                        status.enabled || installedForMode ? "Turn Meaning Search on or off." : "Download models to enable Meaning Search."
                    )
                    .accessibilityValue(status.enabled ? "On" : "Off")
                    .accessibilityIdentifier("settings.semantic.enabled")
                }

                Divider()
                HStack(spacing: SLDesign.space8) {
                    Text("Search in")
                    Spacer()
                    Picker("Search in", selection: $mode) {
                        ForEach(SemanticSearchMode.allCases, id: \.self) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(busy || installing)
                    .accessibilityIdentifier("settings.semantic.mode")
                    if status.enabled && sourceChanged && installedForMode {
                        Button("Apply") { perform(.enable) }
                            .disabled(busy || checkingModels)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("settings.semantic.apply")
                    }
                }

                if installing {
                    downloadProgress
                } else if status.phase == .unsupported {
                    Text("Meaning Search requires a Mac with Apple silicon.")
                        .foregroundStyle(.secondary)
                } else if checkingModels {
                    ProgressView("Checking models\u{2026}")
                        .controlSize(.small)
                } else if !installedForMode {
                    HStack(alignment: .center, spacing: SLDesign.space16) {
                        VStack(alignment: .leading, spacing: SLDesign.space4) {
                            Label("Models not downloaded", systemImage: "arrow.down.circle")
                                .accessibilityIdentifier("settings.semantic.model-missing")
                            Text("\(modelSize) download \u{00B7} Stored on this Mac")
                                .font(SLDesign.metadataFont)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(status.enabled ? "Download & Apply" : "Download & Enable") {
                            perform(.downloadModels, enableWhenReady: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || offline)
                        .accessibilityIdentifier("settings.semantic.download-enable")
                    }
                    if offline {
                        Text("Turn off Offline Mode to download models.")
                            .font(SLDesign.metadataFont)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label(
                        status.enabled
                            ? "Models downloaded for \(mode.label)"
                            : "Models downloaded. Turn on Meaning Search to use them.",
                        systemImage: "checkmark.circle"
                    )
                    .font(SLDesign.metadataFont)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.semantic.model-ready")
                }

                if status.enabled && status.modelInstalled && !installing {
                    Divider()
                    indexingStatus
                }

                if let message = issue ?? (status.phase == .failed ? status.message : nil) {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(SLDesign.metadataFont)
                        .foregroundStyle(SLDesign.error)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings.semantic.message")
                }

                Divider()
                storageDetails
            }
            .padding(SLDesign.space16)
        }
        .onAppear { mode = status.mode }
        .onChange(of: status.mode) { _, value in mode = value }
        .task(id: "\(mode.rawValue):\(status.modelInstalled):\(installing)") {
            checkingModels = true
            defer { if !Task.isCancelled { checkingModels = false } }
            guard !installing else { return }
            do {
                let installed = try await controller.modelsAreInstalled(for: mode)
                guard !Task.isCancelled else { return }
                installedForMode = installed
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                installedForMode = false
                issue = error.localizedDescription
            }
        }
        .onDisappear { actionTask?.cancel() }
        .confirmationDialog(
            removal == .removeIndex ? "Remove Search Index?" : "Remove Downloaded Models?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let removal { perform(removal) }
                removal = nil
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text(
                removal == .removeIndex
                    ? "Meaning Search will turn off. Your captures, transcripts, and model files will stay on this Mac. Exact search will still work."
                    : "Meaning Search will turn off. Your captures, transcripts, and search index will stay on this Mac. Exact search will still work."
            )
        }
        .accessibilityIdentifier("settings.semantic.card")
    }

    private var downloadProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(status.phase == .verifying ? "Verifying models\u{2026}" : "Downloading models\u{2026}")
                Spacer()
                Button("Cancel") { perform(.disable) }
                    .disabled(busy)
                    .accessibilityIdentifier("settings.semantic.cancel-download")
            }
            ProgressView(value: Double(status.downloadedBytes), total: Double(max(1, status.downloadBytes)))
            Text(
                "\(ByteCountFormatter.string(fromByteCount: status.downloadedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: status.downloadBytes, countStyle: .file))"
            )
            .font(SLDesign.metadataFont.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("settings.semantic.download-progress")
    }

    private var indexingStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: SLDesign.space8) {
                Text(indexingTitle)
                    .font(SLDesign.bodyFont.weight(.medium))
                    .accessibilityIdentifier("settings.semantic.indexing-state")
                Spacer()
                if status.index.pendingSources > 0 && status.indexingPolicy != .manual {
                    Button("Index Now") { perform(.indexNow) }
                        .buttonStyle(.borderedProminent)
                        .help("Index while you use your Mac, including on battery power.")
                        .accessibilityIdentifier("settings.semantic.index-now")
                }
                if controller.indexingIsPaused || status.index.pendingSources > 0 {
                    Button(controller.indexingIsPaused ? "Resume Automatically" : "Pause") {
                        perform(controller.indexingIsPaused ? .resume : .pause)
                    }
                    .accessibilityIdentifier("settings.semantic.pause-resume")
                }
            }
            .disabled(busy)
            Text(
                "\(status.index.indexedSources.formatted()) indexed \u{00B7} \(status.index.pendingSources.formatted()) remaining"
                    + (status.index.failedSources > 0 ? " \u{00B7} \(status.index.failedSources.formatted()) failed" : "")
            )
            .font(SLDesign.metadataFont)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .accessibilityIdentifier("settings.semantic.coverage")
            if status.phase == .paused && !controller.indexingIsPaused, let message = status.message {
                Text(message)
                    .font(SLDesign.metadataFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var indexingTitle: String {
        if controller.indexingIsPaused { return "Indexing paused" }
        if status.phase == .paused { return "Waiting to index" }
        if status.phase == .indexing || status.indexingPolicy == .manual { return "Indexing\u{2026}" }
        if status.index.pendingSources > 0 { return "Ready to index" }
        if status.index.indexedSources == 0 { return "No captures to index" }
        return "Up to date"
    }

    private var storageDetails: some View {
        DisclosureGroup("Storage & Privacy") {
            VStack(alignment: .leading, spacing: SLDesign.space8) {
                LabeledContent("Models for \(mode.label)", value: installedForMode ? "\(modelSize) downloaded" : "Not downloaded")
                LabeledContent(
                    "Search index",
                    value: ByteCountFormatter.string(fromByteCount: status.index.vectorBytes, countStyle: .file)
                )
                Text("Search runs on this Mac. Downloads come from Hugging Face; your captures and queries are not sent.")
                Text("Automatic indexing waits for a minute of inactivity and a power connection. Index Now skips those waits.")
                Text("Models are stored separately from your Library storage limit.")
                Link("Model license: Apache 2.0", destination: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!)
                HStack {
                    Button("Remove Index\u{2026}", role: .destructive) { removal = .removeIndex }
                        .disabled(status.index.vectorCount == 0)
                        .accessibilityIdentifier("settings.semantic.remove-index")
                    Button("Remove Models\u{2026}", role: .destructive) { removal = .removeModels }
                        .accessibilityIdentifier("settings.semantic.remove-models")
                }
                .disabled(busy || installing)
            }
            .font(SLDesign.metadataFont)
            .foregroundStyle(.secondary)
            .padding(.top, SLDesign.space8)
        }
        .accessibilityIdentifier("settings.semantic.storage-details")
    }

    private func perform(_ action: SemanticControlAction, enableWhenReady: Bool = false) {
        guard actionTask == nil else { return }
        issue = nil
        actionTask = Task { @MainActor in
            defer { actionTask = nil }
            do {
                let requestedMode = action == .downloadModels || action == .enable ? mode : nil
                _ = try await controller.control(
                    .init(action: action, mode: requestedMode, enableWhenReady: enableWhenReady))
            } catch is CancellationError {
            } catch { issue = error.localizedDescription }
        }
    }
}
