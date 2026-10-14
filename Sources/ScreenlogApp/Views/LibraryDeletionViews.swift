import ScreenlogCore
import SwiftUI

/// The required second step for every user-initiated deletion.
struct LibraryDeletionReviewSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let review: LibraryDeletionReview
    let isDeleting: Bool
    let issue: LibraryDeletionIssue?
    let onDelete: () -> Void
    let onCancel: () -> Void

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
        .frame(minWidth: 440, idealWidth: 500, maxWidth: 620)
        .interactiveDismissDisabled(isDeleting)
        .onExitCommand {
            guard !isDeleting else { return }
            onCancel()
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(review.title)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(review.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupBox("Deletion Review") {
                VStack(spacing: 0) {
                    reviewRow("Selected", value: momentCount(review.plan.requestedMomentCount))
                    Divider()
                    reviewRow("Will be deleted", value: momentCount(review.plan.affectedMomentCount))
                    Divider()
                    reviewRow("Local files", value: "\(review.plan.managedFileCount)")
                    Divider()
                    reviewRow("Estimated space", value: AppModel.formatByteSize(review.plan.estimatedManagedBytes))
                }
                .padding(.vertical, 2)
            }

            if review.plan.affectedMomentCount > review.plan.requestedMomentCount {
                let neighborCount = review.plan.affectedMomentCount - review.plan.requestedMomentCount
                Label(
                    "Some selected moments share a compressed video. If you delete this video, Screenlogger also removes \(neighborCount) adjacent \(neighborCount == 1 ? "moment" : "moments").",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(SLDesign.warning)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("library.deletion.review.shared-video-warning")
            }

            if review.plan.missingFileCount > 0 || review.plan.unmanagedFileCount > 0 {
                Label(fileCaveat, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("library.deletion.review.file-caveat")
            }

            if review.captureWasPaused {
                Label(
                    "Capture is paused until you complete this review.",
                    systemImage: "pause.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("library.deletion.review.capture-paused")
            }

            Label(
                "Review the details carefully. You cannot undo this deletion.",
                systemImage: "exclamationmark.circle"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(.red)
            .accessibilityIdentifier("library.deletion.review.irreversible-warning")

            if let issue {
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("library.deletion.review.issue")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                cancelButton
                deleteButton
            }

            VStack(alignment: .trailing, spacing: 10) {
                cancelButton
                deleteButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var cancelButton: some View {
        Button("Cancel", action: onCancel)
            .keyboardShortcut(.cancelAction)
            .disabled(isDeleting)
            .accessibilityIdentifier("library.deletion.review.cancel")
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            if isDeleting {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(deletingActionTitle)
                }
                .frame(minWidth: 120)
            } else {
                Text(deleteActionTitle)
                    .frame(minWidth: 104)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(isDeleting)
        .accessibilityLabel(
            isDeleting
                ? "Deleting \(momentCount(review.plan.affectedMomentCount))"
                : "\(deleteActionTitle) permanently"
        )
        .accessibilityHint("This action cannot be undone")
        .accessibilityIdentifier("library.deletion.review.confirm")
    }

    /// A routine one-moment confirmation should fit its content. Reviews that
    /// involve several moments, shared media, caveats, or an error keep the
    /// larger scrolling region needed to explain their expanded scope safely.
    private var preferredContentHeight: CGFloat {
        var height: CGFloat = usesCompactSingleMomentLayout ? 330 : 450

        if review.plan.affectedMomentCount > review.plan.requestedMomentCount {
            height += 52
        }
        if review.plan.missingFileCount > 0 || review.plan.unmanagedFileCount > 0 {
            height += 52
        }
        if review.captureWasPaused {
            height += 36
        }
        if issue != nil {
            height += 52
        }
        if dynamicTypeSize.isAccessibilitySize {
            height += 100
        }

        return min(height, 640)
    }

    private var usesCompactSingleMomentLayout: Bool {
        review.plan.requestedMomentCount == 1
            && review.plan.affectedMomentCount == 1
            && review.plan.missingFileCount == 0
            && review.plan.unmanagedFileCount == 0
            && issue == nil
    }

    private var deleteActionTitle: String {
        let count = review.plan.affectedMomentCount
        return count == 1 ? "Delete This Moment" : "Delete \(count) Moments"
    }

    private var deletingActionTitle: String {
        let count = review.plan.affectedMomentCount
        return count == 1 ? "Deleting This Moment..." : "Deleting \(count) Moments..."
    }

    private func reviewRow(_ label: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(value)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .foregroundStyle(.secondary)
                Text(value)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }

    private func momentCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "moment" : "moments")"
    }

    private var fileCaveat: String {
        var parts: [String] = []
        if review.plan.missingFileCount > 0 {
            parts.append(
                "Screenlogger will remove index entries for \(review.plan.missingFileCount) missing local \(review.plan.missingFileCount == 1 ? "file" : "files")"
            )
        }
        if review.plan.unmanagedFileCount > 0 {
            parts.append(
                "Screenlogger will not remove \(review.plan.unmanagedFileCount) \(review.plan.unmanagedFileCount == 1 ? "file" : "files") outside its Library"
            )
        }
        return parts.joined(separator: ". ") + "."
    }
}

struct LibraryDeletionRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onReview: (LibraryDeletionSelection, String, String) -> Void

    @State private var start: Date
    @State private var end: Date

    init(now: Date = Date(), onReview: @escaping (LibraryDeletionSelection, String, String) -> Void) {
        self.onReview = onReview
        let calendar = Calendar.current
        let initialStart = calendar.date(byAdding: .hour, value: -1, to: now) ?? now.addingTimeInterval(-3_600)
        _start = State(initialValue: initialStart)
        _end = State(initialValue: now)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Choose a Time Range")
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Screenlogger will show the exact number of moments before deleting anything.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    GroupBox("Range") {
                        VStack(spacing: 12) {
                            DatePicker("From", selection: $start, displayedComponents: [.date, .hourAndMinute])
                                .accessibilityIdentifier("library.deletion.range.start")
                            Divider()
                            DatePicker("To", selection: $end, displayedComponents: [.date, .hourAndMinute])
                                .accessibilityIdentifier("library.deletion.range.end")
                        }
                        .padding(.vertical, 4)
                    }

                    if !isValidRange {
                        Label("The end must be after the start.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("library.deletion.range.error")
                    }
                }
                .padding(24)
            }
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("library.deletion.range.cancel")
                Button("Review Deletion") {
                    let startMs = Int64(start.timeIntervalSince1970 * 1_000)
                    let endMs = Int64(end.timeIntervalSince1970 * 1_000)
                    let detail = "From \(Self.rangeFormatter.string(from: start)) through \(Self.rangeFormatter.string(from: end))."
                    onReview(.timeRange(startMs: startMs, endMs: endMs), "Delete This Time Range?", detail)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValidRange)
                .accessibilityHint("Shows the number of moments and files before anything is deleted")
                .accessibilityIdentifier("library.deletion.range.review")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.bar)
        }
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 640, minHeight: 380, idealHeight: 460, maxHeight: 680)
        .accessibilityIdentifier("library.deletion.range")
    }

    private var isValidRange: Bool { end > start }

    private static let rangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
