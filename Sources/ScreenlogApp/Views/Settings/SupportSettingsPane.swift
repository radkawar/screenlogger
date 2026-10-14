import Foundation
import ScreenlogCore
import SwiftUI

/// Support information lives in one predictable place instead of being mixed
/// into startup and privacy preferences.
struct SupportSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingDiagnosticsContents = false
    @State private var showingUserGuide = false
    @State private var showingVersionDetails = false
    @ObservedObject private var updates = AppUpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.cardSpacing) {
            SettingsCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsCardRow(
                        icon: "book",
                        title: "Screenlogger Guide",
                        subtitle: "Practical setup, privacy, and recovery help, built in and available offline."
                    ) {
                        Button {
                            showingUserGuide = true
                        } label: {
                            Label("Open Guide", systemImage: "arrow.right")
                        }
                        .controlSize(.small)
                        .accessibilityHint("Open the offline Screenlogger user guide")
                        .accessibilityIdentifier("settings.support.user-guide")
                    }.padding(SLDesign.space16)
                        .accessibilityIdentifier("settings.support.guide-summary")

                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                    SettingsCardRow(
                        icon: "stethoscope",
                        title: diagnosticsTitle,
                        subtitle: diagnosticsSubtitle
                    ) {
                        Button {
                            model.chooseDiagnosticsExportDestination()
                        } label: {
                            Label("Export Diagnostics...", systemImage: "square.and.arrow.up")
                        }
                        .controlSize(.small)
                        .disabled(model.diagnosticsExportState.isExporting)
                        .accessibilityHint("Choose where to save a privacy-safe support bundle")
                        .accessibilityIdentifier("settings.diagnostics.export")
                    }.padding(SLDesign.space16)
                        .accessibilityIdentifier("settings.diagnostics.summary")

                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                    DisclosureGroup(isExpanded: $showingDiagnosticsContents) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Included", systemImage: "checkmark.circle")
                                .font(.caption.weight(.semibold))
                            Text("App and macOS versions, Library status, permission and capture states, and recent app status events.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Label("Never included", systemImage: "hand.raised")
                                .font(.caption.weight(.semibold))
                            Text("Screenshots, recognized text, searches, websites, window titles, usernames, secrets, and Library paths.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("Review bundle contents", systemImage: "doc.text.magnifyingglass")
                            .font(.callout.weight(.medium))
                    }.padding(SLDesign.space16)
                        .accessibilityHint("Show what diagnostics include and what Screenlogger always leaves out")
                        .accessibilityIdentifier("settings.diagnostics.contents")

                    diagnosticsExportStatus.padding(.horizontal, SLDesign.space16)
                        .padding(.bottom, diagnosticsStatusIsVisible ? 14 : 0)
                }
            }
            .settingsDestinationAnchor(.supportGuide)
            .settingsDestinationAnchor(.supportDiagnostics)

            SettingsCard(padding: 0) {
                VStack(spacing: 0) {
                    SettingsCardRow(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Software Updates",
                        subtitle: updateSubtitle
                    ) {
                        Button("Check Now") {
                            updates.checkForUpdates()
                        }
                        .controlSize(.small)
                        .disabled(!updates.canCheckForUpdates)
                        .accessibilityHint(updateCheckAccessibilityHint)
                        .accessibilityIdentifier("settings.support.updates.check")
                    }.padding(SLDesign.space16)

                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                    SettingsCardRow(
                        icon: "clock.arrow.circlepath",
                        title: "Check Automatically",
                        subtitle: "Look for a newer signed release about once a day."
                    ) {
                        Toggle(
                            "Check Automatically",
                            isOn: Binding(
                                get: { updates.automaticallyChecksForUpdates },
                                set: { updates.setAutomaticallyChecksForUpdates($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Check for updates automatically")
                        .accessibilityValue(
                            SettingsAccessibilityValue.onOff(
                                updates.automaticallyChecksForUpdates
                            )
                        )
                        .accessibilityHint(
                            model.airgapMode
                                ? "The preference is saved, but checks stay paused while Screenlogger is offline"
                                : "Let Screenlogger check the signed update feed in the background"
                        )
                        .accessibilityIdentifier("settings.support.updates.automatic")
                    }.padding(SLDesign.space16)
                }
            }

            SettingsCard(padding: 0) {
                DisclosureGroup(isExpanded: $showingVersionDetails) {
                    VStack(spacing: 0) {
                        Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                        versionRow(
                            title: "App version and build",
                            value: appVersionString,
                            identifier: "settings.support.app-version"
                        )
                        Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                        versionRow(
                            title: "Capture and search engine",
                            value: ScreenlogCore.version,
                            identifier: "settings.support.engine-version"
                        )
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 10) {
                        Label("About Screenlogger", systemImage: "info.circle")
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 8)
                        Text(appVersionString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }.padding(SLDesign.space16)
                    .accessibilityHint("Show detailed app and engine versions")
                    .accessibilityIdentifier("settings.support.versions")
            }
        }
        .sheet(isPresented: $showingUserGuide) {
            SupportUserGuideSheet {
                showingUserGuide = false
            }
            .environmentObject(model)
        }
        .onReceive(model.$userGuidePresentationRequest.compactMap { $0 }) { requestID in
            showingUserGuide = true
            model.completeUserGuidePresentation(requestID)
        }
    }

    private var diagnosticsTitle: String {
        switch model.diagnosticsExportState {
        case .idle: return "Privacy-Safe Diagnostics"
        case .exporting: return "Creating Diagnostics..."
        case .completed: return "Diagnostics Ready"
        case .failed: return "Diagnostics Need Attention"
        }
    }

    private var updateSubtitle: String {
        if model.airgapMode {
            return "Paused while Keep Screenlogger Offline is enabled."
        }
        return updates.automaticallyChecksForUpdates
            ? "Screenlogger checks the signed release feed automatically."
            : "Check the signed release feed whenever you choose."
    }

    private var updateCheckAccessibilityHint: String {
        model.airgapMode
            ? "Turn off Keep Screenlogger Offline in Privacy settings first"
            : "Check for a newer cryptographically verified Screenlogger release"
    }

    private var diagnosticsSubtitle: String {
        switch model.diagnosticsExportState {
        case .idle:
            return "Save app and system status to a location you choose. Screenlogger does not send the bundle."
        case .exporting:
            return "Screenlogger is creating the bundle. It does not include screenshots or recognized text."
        case .completed:
            return "Screenlogger saved the bundle. You can share it if necessary."
        case .failed:
            return "Screenlogger did not send anything. Choose another location. Try again."
        }
    }

    private func versionRow(
        title: String,
        value: String,
        identifier: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
        }
        .padding(.vertical, 7)
    }

    private var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let short, let build {
            return "\(short) (\(build))"
        }
        return short ?? ScreenlogCore.version
    }

    private var diagnosticsStatusIsVisible: Bool {
        model.diagnosticsExportState != .idle
    }

    @ViewBuilder
    private var diagnosticsExportStatus: some View {
        switch model.diagnosticsExportState {
        case .idle:
            EmptyView()
        case .exporting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Creating your privacy-safe diagnostics bundle...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.diagnostics.progress")
        case .completed(let destination):
            VStack(alignment: .leading, spacing: 6) {
                Label("Diagnostics exported.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(SLDesign.success)
                HStack(spacing: 10) {
                    Button("Show in Finder") { model.revealDiagnosticsExport(destination) }
                        .buttonStyle(.borderless)
                        .tint(.primary)
                    Button("Done") { model.dismissDiagnosticsExportStatus() }
                        .buttonStyle(.borderless)
                        .tint(.primary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.diagnostics.completed")
        case .failed(let error):
            VStack(alignment: .leading, spacing: 6) {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(SLDesign.warning)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Try Again") { model.chooseDiagnosticsExportDestination() }
                        .buttonStyle(.borderless)
                        .tint(.primary)
                    Button("Dismiss") { model.dismissDiagnosticsExportStatus() }
                        .buttonStyle(.borderless)
                        .tint(.primary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.diagnostics.failed")
        }
    }
}
