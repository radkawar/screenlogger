import AppKit
import ScreenlogCore
import SwiftUI

/// One quiet origin/time line. The title already carries the application name
/// when no window title was recorded, so that fallback is not repeated here.
struct LibraryResultProvenance: View {
    let result: FTSResult
    let display: LibraryResultPresentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: SLDesign.space4) {
            SLAppIconView(bundleID: result.bundleID, size: 12)
                .accessibilityHidden(true)
            Text(display.context)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(SLDesign.metadataFont)
        .foregroundStyle(.secondary)
        .help(display.fullTimestamp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.accessibilityContext)
    }
}

/// Visual result card with a captured still and concise provenance.
struct SearchResultCard: View {
    let result: FTSResult
    let semanticHit: SemanticSearchHit?
    let selected: Bool
    let keyboardFocused: Bool
    let interactionEnabled: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onShowInSessions: () -> Void
    /// Supplied by the parent, which already observes the model. Observing it
    /// here would invalidate every card in the grid on any model change.
    let onDelete: () -> Void
    private let display: LibraryResultPresentation
    @State private var hovering = false

    init(
        result: FTSResult,
        semanticHit: SemanticSearchHit? = nil,
        selected: Bool,
        keyboardFocused: Bool,
        interactionEnabled: Bool,
        onSelect: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onShowInSessions: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.result = result
        self.semanticHit = semanticHit
        self.selected = selected
        self.keyboardFocused = keyboardFocused
        self.interactionEnabled = interactionEnabled
        self.onSelect = onSelect
        self.onOpen = onOpen
        self.onShowInSessions = onShowInSessions
        self.onDelete = onDelete
        display = LibraryResultPresentation(result: result, semanticHit: semanticHit)
    }

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
                        Button("Show in Sessions", action: onShowInSessions)
                            .accessibilityIdentifier("library.result.context.show-in-sessions")
                        if let domain = result.domain, !domain.isEmpty {
                            Button("Copy domain") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(domain, forType: .string)
                            }
                        }
                        if let snip = display.text.cleanedSnippet {
                            Button("Copy snippet") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(snip, forType: .string)
                            }
                        }
                        Divider()
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete Moment...", systemImage: "trash")
                        }
                        .accessibilityIdentifier("library.result.context.delete")
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default, onSelect)
                    .accessibilityAction(named: "Select for Preview", onSelect)
                    .accessibilityAction(named: "Open in Timeline", onOpen)
                    .accessibilityAction(named: "Show in Sessions", onShowInSessions)
                    .accessibilityAction(named: "Delete Moment", onDelete)
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
            .accessibilityLabel(display.text.title)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("library.result.\(result.frameID)")
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            LibraryThumbnail(
                frameID: result.frameID,
                path: result.imagePath,
                isCompacted: result.isCompacted,
                priority: selected ? .inspector : .card
            )
            .aspectRatio(16 / 10, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: SLDesign.thumbRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SLDesign.thumbRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: SLDesign.space4) {
                Text(display.text.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let snippet = display.highlightedExcerpt {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                resultMetadata
            }
            .padding(.horizontal, SLDesign.space4)
        }
        .padding(SLDesign.space8)
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
        VStack(alignment: .leading, spacing: SLDesign.space4) {
            LibraryResultProvenance(result: result, display: display)
            if let semanticHit { SemanticResultSourceLabel(hit: semanticHit) }
            if let source = result.transcriptSource {
                Label(source.label, systemImage: source == .microphone ? "mic.fill" : "waveform")
                    .font(SLDesign.metadataFont)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Transcript source: \(source.label)")
            }
        }
    }

    private var accessibilityValue: String {
        [
            display.accessibilityContext, display.text.excerpt, knownPreviewAccessibilityStatus,
            semanticHit.map { SemanticSearchPresentation.sourceLabel($0.kind) },
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private var knownPreviewAccessibilityStatus: String? {
        if !result.isCompacted,
            result.imagePath == nil || result.imagePath?.isEmpty == true
        {
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
    let semanticHit: SemanticSearchHit?
    let interactionEnabled: Bool
    let onOpen: () -> Void
    private let display: LibraryResultPresentation

    init(
        result: FTSResult,
        presentation: Presentation,
        semanticHit: SemanticSearchHit? = nil,
        interactionEnabled: Bool,
        onOpen: @escaping () -> Void
    ) {
        self.result = result
        self.presentation = presentation
        self.semanticHit = semanticHit
        self.interactionEnabled = interactionEnabled
        self.onOpen = onOpen
        display = LibraryResultPresentation(result: result, semanticHit: semanticHit)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                previewContent
                    .padding(SLDesign.space16)
            }

            Divider()

            HStack {
                Spacer(minLength: 0)
                Button(action: onOpen) {
                    Label("Open in Timeline", systemImage: "arrow.right")
                }
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .font(.callout)
                .slCompactControlTarget()
                .disabled(!interactionEnabled)
                .accessibilityHint(
                    interactionEnabled
                        ? "Opens this moment in Timeline"
                        : "Available when the current Library search finishes"
                )
                .accessibilityIdentifier("library.result.inspector.open")
            }
            .padding(SLDesign.space12)
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
        VStack(alignment: .leading, spacing: SLDesign.space16) {

            LibraryThumbnail(
                frameID: result.frameID,
                path: result.imagePath,
                isCompacted: result.isCompacted,
                contentMode: .fit,
                showsStatusDetail: true,
                statusAccessibilityIdentifier: "library.result.inspector.preview-status",
                priority: .inspector
            )
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: SLDesign.thumbRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SLDesign.thumbRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }

            Text(display.text.title)
                .font(SLDesign.sectionFont)
                .lineLimit(3)
                .accessibilityIdentifier("library.result.inspector.selection.\(result.frameID)")

            if let snippet = display.highlightedExcerpt {
                Text(snippet)
                    .font(.callout)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: SLDesign.space8) {
                LibraryResultProvenance(result: result, display: display)
                if let semanticHit { SemanticResultSourceLabel(hit: semanticHit) }
                if let source = result.transcriptSource {
                    Label(
                        "Transcript from \(source.label)",
                        systemImage: source == .microphone ? "mic.fill" : "waveform"
                    )
                    .font(SLDesign.metadataFont)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Prepared once when a result view receives its inputs, not while hover,
/// selection focus or thumbnail loading repeatedly evaluates its body.
struct LibraryResultPresentation {
    let text: LibraryResultTextPresentation
    let highlightedExcerpt: AttributedString?
    let context: String
    let accessibilityContext: String
    let fullTimestamp: String

    init(result: FTSResult, semanticHit: SemanticSearchHit?) {
        text = LibraryResultTextPresentation(
            title: result.title,
            appLabel: result.searchAppLabel,
            domain: result.domain,
            snippet: result.snippet,
            allowsUnmarkedExcerpt: result.transcriptSource != nil || semanticHit != nil
        )
        fullTimestamp = SLTimeFormat.full(result.timestampMs)
        let origins = [text.appContext, text.domainContext].compactMap { $0 }
        let timestamp =
            "\(SLTimeFormat.dayLabel(result.timestampMs)), "
            + SLTimeFormat.shortTime(result.timestampMs)
        context = (origins + [timestamp]).joined(separator: " \u{00B7} ")
        accessibilityContext = (origins + [fullTimestamp]).joined(separator: ", ")
        if let excerpt = text.excerpt {
            var attributed = AttributedString(excerpt)
            for range in text.matches {
                guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                    let upper = AttributedString.Index(range.upperBound, within: attributed)
                else { continue }
                attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
            highlightedExcerpt = attributed
        } else {
            highlightedExcerpt = nil
        }
    }
}

extension FTSResult {
    fileprivate var searchAppLabel: String {
        SearchSnippet.parse(displayName)?.text
            ?? SLAppIdentity.displayName(bundleID: bundleID)
    }

    /// Identifies the moment in the deletion review sheet. The sheet itself
    /// reports the exact moment, file, and byte counts.
    var libraryDeletionDetail: String {
        "\(searchAppLabel) at \(SLTimeFormat.full(timestampMs))."
            + " Screenlogger removes every display capture from this moment."
    }
}
