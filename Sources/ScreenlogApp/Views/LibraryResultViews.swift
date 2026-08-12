import AppKit
import ScreenlogCore
import SwiftUI

/// A consistent origin row for Library results. Browser captures keep the
/// application that hosted the page as well as the website that was visited.
struct LibraryResultProvenance: View {
    let result: FTSResult
    let iconSize: CGFloat
    let font: Font
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if let domain = displayDomain {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        applicationIdentity
                        Divider()
                            .frame(height: iconSize)
                            .accessibilityHidden(true)
                        websiteIdentity(domain)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        applicationIdentity
                        websiteIdentity(domain)
                    }
                }
            } else {
                applicationIdentity
            }
        }
        .font(font)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var applicationIdentity: some View {
        HStack(spacing: 5) {
            SLAppIconView(bundleID: result.bundleID, size: iconSize)
            Text(result.searchAppLabel)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        }
    }

    private func websiteIdentity(_ domain: String) -> some View {
        HStack(spacing: 5) {
            SLFaviconView(domain: domain, size: iconSize)
            Text(domain)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        }
    }

    private var displayDomain: String? {
        guard let domain = result.domain?.trimmingCharacters(in: .whitespacesAndNewlines),
            !domain.isEmpty
        else { return nil }
        return domain
    }

    private var accessibilityLabel: String {
        guard let displayDomain else {
            return "Application: \(result.searchAppLabel)"
        }
        return "Application: \(result.searchAppLabel), website: \(displayDomain)"
    }
}

/// Visual result card with a captured still and concise provenance.
struct SearchResultCard: View {
    let result: FTSResult
    let selected: Bool
    let keyboardFocused: Bool
    let interactionEnabled: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if interactionEnabled {
                baseCard
                    // Recognize selection and opening simultaneously. The first click can
                    // update Preview immediately while a completed double-click still
                    // follows the native Mac convention of opening the moment.
                    .gesture(TapGesture(count: 1).onEnded { onSelect() })
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
                    .contextMenu {
                        Button("Open in Timeline") { onOpen() }
                        if let domain = result.domain, !domain.isEmpty {
                            Button("Copy domain") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(domain, forType: .string)
                            }
                        }
                        if let snip = result.searchCleanedSnippet, !snip.isEmpty {
                            Button("Copy snippet") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(snip, forType: .string)
                            }
                        }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default, onSelect)
                    .accessibilityAction(named: "Select for Preview", onSelect)
                    .accessibilityAction(named: "Open in Timeline", onOpen)
            } else {
                baseCard
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityRemoveTraits(.isButton)
            }
        }
    }

    private var baseCard: some View {
        cardContent
            .help(cardHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(result.searchDisplayTitle), \(accessibilityProvenance)")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("library.result.\(result.frameID)")
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            LibraryThumbnail(
                path: result.imagePath,
                isCompacted: result.isCompacted
            )
            .aspectRatio(16 / 10, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: SLDesign.thumbRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SLDesign.thumbRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(result.searchDisplayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let snippet = cardSnippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                resultMetadata
            }
            .padding(.horizontal, 2)
        }
        .padding(8)
        .background(
            selected
                ? Color.accentColor.opacity(keyboardFocused ? 0.14 : 0.08)
                : Color(nsColor: .controlBackgroundColor).opacity(
                    hovering && interactionEnabled ? 0.55 : 0
                ),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    selected
                        ? Color.accentColor.opacity(keyboardFocused ? 0.98 : 0.52)
                        : Color.clear,
                    lineWidth: keyboardFocused && selected ? 2 : 1
                )
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var cardHelp: String {
        guard interactionEnabled else {
            return "Previous result. Available when the current search finishes."
        }
        if keyboardFocused && selected {
            return "Selected for keyboard navigation. Return opens in Timeline."
        }
        return selected
            ? "Selected for Preview. Double-click to open."
            : "Select for Preview. Double-click to open."
    }

    private var accessibilityHint: String {
        guard interactionEnabled else {
            return "Previous result shown read-only while the current search updates."
        }
        return selected
            ? "Selected for Preview. Use the Open in Timeline action to open this moment."
            : "Select this moment for Preview."
    }

    private var resultMetadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let source = result.transcriptSource {
                Label(source.label, systemImage: source == .microphone ? "mic.fill" : "waveform")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Transcript source: \(source.label)")
            }
            provenance
            resultTime
        }
    }

    private var provenance: some View {
        LibraryResultProvenance(result: result, iconSize: 13, font: .caption)
    }

    private var resultTime: some View {
        Text(
            "\(SLTimeFormat.dayLabel(result.timestampMs)), "
                + SLTimeFormat.shortTime(result.timestampMs)
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.tertiary)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        .help(SLTimeFormat.full(result.timestampMs))
    }

    private var accessibilityProvenance: String {
        guard let domain = result.domain?.trimmingCharacters(in: .whitespacesAndNewlines),
            !domain.isEmpty
        else { return result.searchAppLabel }
        return "\(result.searchAppLabel), \(domain)"
    }

    private var cardSnippet: String? {
        guard let snippet = result.searchCleanedSnippet,
            snippet.caseInsensitiveCompare(result.searchDisplayTitle) != .orderedSame
        else { return nil }
        return snippet
    }

    private var accessibilityValue: String {
        [SLTimeFormat.full(result.timestampMs), cardSnippet, knownPreviewAccessibilityStatus]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var knownPreviewAccessibilityStatus: String? {
        if result.isCompacted {
            return "Preview available in Timeline. Opening this moment requests its preview."
        }
        if result.imagePath == nil || result.imagePath?.isEmpty == true {
            return "Preview no longer stored. Searchable text and details are still available."
        }
        return nil
    }
}

struct SearchResultInspector: View {
    enum Presentation {
        case pane
        case popover
    }

    let result: FTSResult
    let presentation: Presentation
    let interactionEnabled: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                previewContent
                    .padding(16)
            }

            Divider()

            HStack {
                Button(action: onOpen) {
                    Label("Open in Timeline", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!interactionEnabled)
                .accessibilityHint(
                    interactionEnabled
                        ? "Opens this moment in Timeline"
                        : "Available when the current Library search finishes"
                )
                .accessibilityIdentifier("library.result.inspector.open")
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(inspectorBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected moment preview")
    }

    @ViewBuilder
    private var inspectorBackground: some View {
        switch presentation {
        case .pane:
            Color(nsColor: .controlBackgroundColor).opacity(0.28)
        case .popover:
            Color.clear
        }
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label("Selected Moment", systemImage: "sidebar.right")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(SLTimeFormat.shortTime(result.timestampMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(SLTimeFormat.full(result.timestampMs))
            }

            LibraryThumbnail(
                path: result.imagePath,
                isCompacted: result.isCompacted,
                contentMode: .fit,
                showsStatusDetail: true,
                statusAccessibilityIdentifier: "library.result.inspector.preview-status"
            )
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: SLDesign.thumbRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SLDesign.thumbRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(result.searchDisplayTitle)
                    .font(.headline)
                    .lineLimit(3)
                    .accessibilityIdentifier("library.result.inspector.selection.\(result.frameID)")

                LibraryResultProvenance(
                    result: result,
                    iconSize: 16,
                    font: .subheadline.weight(.medium)
                )

                Text(SLTimeFormat.full(result.timestampMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if let snippet = result.searchCleanedSnippet,
                snippet.caseInsensitiveCompare(result.searchDisplayTitle) != .orderedSame
            {
                Divider().opacity(0.5)
                Text(snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }

            if let source = result.transcriptSource {
                Label(
                    "Transcript from \(source.label)",
                    systemImage: source == .microphone ? "mic.fill" : "waveform"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension FTSResult {
    fileprivate var searchDisplayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if let snippet = searchCleanedSnippet, !snippet.isEmpty {
            return snippet
        }
        return searchAppLabel
    }

    fileprivate var searchAppLabel: String {
        displayName.flatMap { $0.isEmpty ? nil : $0 }
            ?? SLAppIdentity.displayName(bundleID: bundleID)
    }

    fileprivate var searchCleanedSnippet: String? {
        guard let snippet = snippet?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty else {
            return nil
        }
        return
            snippet
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
