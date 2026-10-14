import ScreenlogCore
import SwiftUI

/// Final, destructive checkpoint after a Library backup passes verification.
struct LibraryRestoreReviewSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let review: LibraryRestoreReview

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                reviewContent
                    .padding(24)
            }
            .frame(height: preferredContentHeight)

            Divider()
            actionBar
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.bar)
        }
        .frame(minWidth: 440, idealWidth: 500, maxWidth: 640)
        .interactiveDismissDisabled(model.libraryRestoreState == .restoring)
        .accessibilityIdentifier("storage.library-restore.review")
        .onExitCommand {
            guard model.libraryRestoreState != .restoring else { return }
            cancel()
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: SLDesign.space24) {
            HStack(alignment: .top, spacing: SLDesign.space16) {
                Image(systemName: "arrow.counterclockwise")
                    .font(SLDesign.sectionFont)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SLDesign.space8) {
                    Text("Replace Captured History?")
                        .font(SLDesign.titleFont)
                    Text("This backup passed Screenlogger's database, file, and checksum checks.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Grid(alignment: .leading, horizontalSpacing: SLDesign.space16, verticalSpacing: SLDesign.space8) {
                GridRow {
                    Text("Backup").foregroundStyle(.secondary)
                    Text(review.archive.deletingPathExtension().lastPathComponent)
                        .lineLimit(1)
                        .help(review.archive.path)
                }
                GridRow {
                    Text("Created").foregroundStyle(.secondary)
                    Text(review.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    Text(AppModel.formatByteSize(review.manifest.totalBytes))
                }
            }
            .font(SLDesign.bodyFont)

            Text(
                "Screenlogger replaces your current captured history. It does not merge the two Libraries. Screenlogger pauses capture and keeps the current Library until the replacement is active. If activation fails, Screenlogger automatically restores the current Library. Settings and exclusions remain unchanged."
            )
            .font(SLDesign.bodyFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                restoreProgress
                Spacer()
                restoreDecisionButtons
            }

            VStack(alignment: .trailing, spacing: 10) {
                restoreProgress
                    .frame(maxWidth: .infinity, alignment: .leading)
                restoreDecisionButtons
            }
        }
    }

    @ViewBuilder
    private var restoreProgress: some View {
        if model.libraryRestoreState == .restoring {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Replacing Library...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Replacing Library")
        }
    }

    private var restoreDecisionButtons: some View {
        HStack(spacing: 10) {
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .disabled(model.libraryRestoreState == .restoring)
                .accessibilityIdentifier("storage.library-restore.cancel")
            Button("Replace Captured History", role: .destructive) {
                model.confirmLibraryRestore()
            }
            .disabled(model.libraryRestoreState == .restoring)
            .accessibilityLabel("Replace Captured History permanently")
            .accessibilityHint("Replace the current captured history with the verified backup")
            .accessibilityIdentifier("storage.library-restore.confirm")
        }
    }

    private var preferredContentHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 560 : 410
    }

    private func cancel() {
        model.cancelLibraryRestoreReview()
        dismiss()
    }
}
