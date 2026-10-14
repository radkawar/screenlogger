import AppKit
import Foundation
import ScreenlogCore
import UniformTypeIdentifiers

/// Creates privacy-safe diagnostics snapshots and exports.
@MainActor
extension AppModel {
    // MARK: - Privacy-safe diagnostics

    func chooseDiagnosticsExportDestination() {
        guard !diagnosticsExportState.isExporting else { return }
        let panel = NSSavePanel()
        panel.title = "Export Screenlogger Diagnostics"
        panel.message =
            "Includes app and Library status only. Never includes screenshots, recognized text, searches, websites, or Library paths."
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [
            UTType(exportedAs: "dev.screenlog.diagnostics-bundle", conformingTo: .package)
        ]
        panel.nameFieldStringValue =
            "Screenlogger Diagnostics \(Self.diagnosticsDateFormatter.string(from: Date())).\(DiagnosticsBundleService.preferredExtension)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportDiagnostics(to: destination)
    }

    func exportDiagnostics(to destination: URL) {
        guard !diagnosticsExportState.isExporting else { return }
        diagnosticsExportState = .exporting
        recordDiagnostic(.diagnosticsExport, .started)

        let snapshot = diagnosticsSnapshot()
        let events = diagnosticsLog?.entries() ?? []
        let dataRoot = root
        diagnosticsExportTask?.cancel()
        diagnosticsExportTask = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    try DiagnosticsBundleService().export(
                        snapshot: snapshot,
                        events: events,
                        dataRoot: dataRoot,
                        to: destination
                    )
                }.value
                guard !Task.isCancelled else { return }
                self?.diagnosticsExportState = .completed(result.destination)
                self?.recordDiagnostic(.diagnosticsExport, .succeeded)
            } catch is CancellationError {
                return
            } catch {
                let exportError = (error as? DiagnosticsBundleError) ?? .creationFailed
                self?.diagnosticsExportState = .failed(exportError)
                self?.recordDiagnostic(.diagnosticsExport, .failed)
            }
            self?.diagnosticsExportTask = nil
        }
    }

    func revealDiagnosticsExport(_ destination: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    func dismissDiagnosticsExportStatus() {
        guard !diagnosticsExportState.isExporting else { return }
        diagnosticsExportState = .idle
    }

    private func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let build =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let frameCount = stats?.totalFrames ?? 0
        let unfinalizedCount = stats?.unfinalizedFrames ?? 0

        let libraryHealth: DiagnosticsSnapshot.Health
        if libraryStartupIssue != nil {
            libraryHealth = .unavailable
        } else if store == nil {
            libraryHealth = .unknown
        } else if unfinalizedCount > 0 {
            libraryHealth = .attention
        } else {
            libraryHealth = .healthy
        }

        let captureState: DiagnosticsSnapshot.CaptureState
        if libraryStartupIssue != nil {
            captureState = .unavailable
        } else if capturePauseReason != nil || (recordingPausedUntil.map { $0 > Date() } ?? false) {
            captureState = .paused
        } else {
            captureState = isRecording ? .capturing : .off
        }

        let pauseReason: String?
        if let capturePauseReason {
            pauseReason = capturePauseReason.rawValue
        } else if recordingPausedUntil.map({ $0 > Date() }) == true {
            pauseReason = "timed"
        } else {
            pauseReason = nil
        }

        return DiagnosticsSnapshot(
            app: .init(version: version, build: build, coreVersion: ScreenlogCore.version),
            system: .init(
                operatingSystemVersion: systemVersion,
                architecture: Self.diagnosticsArchitecture
            ),
            library: .init(
                health: libraryHealth,
                frameCount: frameCount,
                unfinalizedFrameCount: unfinalizedCount,
                managedBytes: librarySizeBytes,
                newestCaptureAge: Self.diagnosticsCaptureAge(for: stats?.maxTimestampMs)
            ),
            capture: .init(
                state: captureState,
                pauseReason: pauseReason,
                screenRecordingPermission: permissions.screenRecording,
                accessibilityPermission: permissions.accessibility
            )
        )
    }

    private static func diagnosticsCaptureAge(for timestampMilliseconds: Int64?) -> DiagnosticsSnapshot.NewestCaptureAge {
        guard let timestampMilliseconds else { return .none }
        let age = max(0, Date().timeIntervalSince1970 - Double(timestampMilliseconds) / 1_000)
        if age < 3_600 { return .withinHour }
        if age < 86_400 { return .withinDay }
        if age < 604_800 { return .withinWeek }
        return .older
    }

    private static var diagnosticsArchitecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }

    private static let diagnosticsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

}
