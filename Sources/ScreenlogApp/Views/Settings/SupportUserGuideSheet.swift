import Dispatch
import SwiftUI

/// A concise offline guide for the everyday journeys people need most.
struct SupportUserGuideSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SupportGuideTopic? = .gettingStarted
    let onDismiss: () -> Void

    var body: some View {
        NavigationSplitView {
            List(SupportGuideTopic.allCases, selection: $selection) { topic in
                Label {
                    Text(topic.title)
                } icon: {
                    Image(systemName: topic.systemImage)
                        .foregroundStyle(.secondary)
                }
                .tag(topic)
                .accessibilityHint(topic.summary)
                .accessibilityIdentifier("settings.guide.topic.\(topic.rawValue)")
            }
            .listStyle(.sidebar)
            .navigationTitle("Screenlogger Guide")
            .navigationSplitViewColumnWidth(min: 184, ideal: 205, max: 240)
            .accessibilityLabel("Guide topics")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Divider()
                Label("Available offline", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SLDesign.space16)
                    .background(.bar)
                    .accessibilityIdentifier("settings.guide.offline")
            }
        } detail: {
            guideDetail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, idealWidth: 780, minHeight: 470, idealHeight: 540)
        .tint(model.accentSwiftUIColor)
        .accentColor(model.accentSwiftUIColor)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDismiss)
                    .accessibilityIdentifier("settings.guide.done")
            }
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    @ViewBuilder
    private var guideDetail: some View {
        if let topic = selection {
            ScrollView {
                VStack(alignment: .leading, spacing: SLDesign.space24) {
                    guideHeader(topic)
                    topicActions(topic)
                    ForEach(topic.sections) { section in
                        guideSection(section)
                    }
                }
                .padding(SLDesign.space24)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle(topic.title)
            .accessibilityIdentifier("settings.guide.detail.\(topic.rawValue)")
        } else {
            ContentUnavailableView(
                "Choose a Topic",
                systemImage: "book",
                description: Text("Select a guide topic in the sidebar.")
            )
        }
    }

    private func guideHeader(_ topic: SupportGuideTopic) -> some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            Text(topic.title)
                .font(SLDesign.titleFont)
                .accessibilityAddTraits(.isHeader)
            Text(topic.summary)
                .font(SLDesign.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func guideSection(_ section: SupportGuideSection) -> some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            Text(section.title)
                .font(SLDesign.sectionFont)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: SLDesign.space8) {
                ForEach(Array(section.points.enumerated()), id: \.offset) { index, point in
                    HStack(alignment: .firstTextBaseline, spacing: SLDesign.space8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                            .accessibilityHidden(true)
                        Text(point)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, SLDesign.space4)
        }
    }

    @ViewBuilder
    private func topicActions(_ topic: SupportGuideTopic) -> some View {
        switch topic {
        case .gettingStarted:
            if model.isRecording {
                guideAction("Review Capture Settings", systemImage: "record.circle") {
                    model.openProductSettings(.captureStatus)
                }
                .accessibilityIdentifier("settings.guide.action.gettingStarted")
            } else {
                guideAction("Finish Setup", systemImage: "checklist") {
                    model.showPermissions(origin: .settingsGuide)
                }
                .accessibilityIdentifier("settings.guide.action.gettingStarted")
            }
        case .librarySearch:
            guideAction("Open Library", systemImage: "books.vertical") {
                model.openSearchWindow()
            }
            .accessibilityIdentifier("settings.guide.action.librarySearch")
        case .timeline:
            guideAction("Open Timeline", systemImage: "clock.arrow.circlepath") {
                model.openMainShell(origin: .direct)
            }
            .accessibilityIdentifier("settings.guide.action.timeline")
        case .privacyExclusions:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    privacyGuideActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    privacyGuideActions
                }
            }
        case .troubleshooting:
            if model.permissions.isCaptureReady {
                guideAction("Review Capture Status", systemImage: "stethoscope") {
                    model.openProductSettings(.captureStatus)
                }
                .accessibilityIdentifier("settings.guide.action.troubleshooting")
            } else {
                guideAction("Finish Permissions Setup", systemImage: "exclamationmark.shield") {
                    model.showPermissions(origin: .settingsGuide)
                }
                .accessibilityIdentifier("settings.guide.action.troubleshooting")
            }
        }
    }

    @ViewBuilder
    private var privacyGuideActions: some View {
        guideAction("Review Privacy", systemImage: "hand.raised") {
            model.openProductSettings(.privacyPermissions)
        }
        .accessibilityIdentifier("settings.guide.action.privacy")
        guideAction("Review Exclusions", systemImage: "eye.slash", prominent: false) {
            model.openProductSettings(.exclusionsApplications)
        }
        .accessibilityIdentifier("settings.guide.action.exclusions")
    }

    @ViewBuilder
    private func guideAction(
        _ title: String,
        systemImage: String,
        prominent: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button {
            onDismiss()
            // Let the sheet finish relinquishing key-window focus before the
            // destination window or settings pane is activated.
            DispatchQueue.main.async(execute: action)
        } label: {
            Label(title, systemImage: systemImage)
        }
        if prominent {
            button
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Close the guide and \(title.lowercased())")
        } else {
            button
                .buttonStyle(.bordered)
                .accessibilityHint("Close the guide and \(title.lowercased())")
        }
    }
}

private enum SupportGuideTopic: String, CaseIterable, Identifiable {
    case gettingStarted
    case librarySearch
    case timeline
    case privacyExclusions
    case troubleshooting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: return "Getting Started"
        case .librarySearch: return "Library & Search"
        case .timeline: return "Timeline"
        case .privacyExclusions: return "Privacy & Exclusions"
        case .troubleshooting: return "Troubleshooting"
        }
    }

    var systemImage: String {
        switch self {
        case .gettingStarted: return "checklist"
        case .librarySearch: return "books.vertical"
        case .timeline: return "clock.arrow.circlepath"
        case .privacyExclusions: return "hand.raised"
        case .troubleshooting: return "wrench.and.screwdriver"
        }
    }

    var summary: String {
        switch self {
        case .gettingStarted:
            return "Set up capture. Find Screenlogger on your Mac."
        case .librarySearch:
            return "Find saved moments with search words and filters."
        case .timeline:
            return "Review activity in time order and move through moments efficiently."
        case .privacyExclusions:
            return "Control what Screenlogger can capture and what it always skips."
        case .troubleshooting:
            return "Recover from the most common permission, capture, and Library issues."
        }
    }

    var sections: [SupportGuideSection] {
        switch self {
        case .gettingStarted:
            return [
                SupportGuideSection(
                    title: "Set up capture",
                    points: [
                        "Allow Screen Recording so Screenlogger can save visual moments.",
                        "Allow Accessibility so Screenlogger can apply exclusions and capture window, control, browser, and private-window context.",
                        "Choose Start Capture when setup is ready. You can pause or stop at any time.",
                    ]
                ),
                SupportGuideSection(
                    title: "Find Screenlogger",
                    points: [
                        "Use the menu bar icon for Library, Timeline, capture controls, and Settings.",
                        "Choose Hide Menu Bar Icon to remove it for the current session. Open Screenlogger again from Spotlight, Finder, or the Dock to restore it.",
                        "Open at Login and Dock visibility are optional in General settings.",
                    ]
                ),
            ]
        case .librarySearch:
            return [
                SupportGuideSection(
                    title: "Find a moment",
                    points: [
                        "Open Library. Enter search words in the search field.",
                        "Use time, app, site, or session filters when the first results are too broad.",
                        "Select a result to preview it. Open it in Timeline to see the adjacent moments.",
                        "Select Sessions. Select a session to show its details and latest moment. Select Open in Timeline to show the session in Timeline.",
                    ]
                ),
                SupportGuideSection(
                    title: "Useful shortcuts",
                    points: [
                        "Press Command-1 for Search, Command-2 for Sessions, or Command-3 for Timeline. Customize these in Keyboard Shortcuts settings.",
                        "Clear filters to return to results across your full Library.",
                    ]
                ),
            ]
        case .timeline:
            return [
                SupportGuideSection(
                    title: "Review activity",
                    points: [
                        "Choose a day and session. Move backward or forward through saved moments.",
                        "Use Space to play or pause. Use the arrow keys to move one moment at a time.",
                        "Use Option-Left or Option-Right to move between activity groups.",
                    ]
                ),
                SupportGuideSection(
                    title: "Inspect details",
                    points: [
                        "Zoom with Command-Plus, Command-Minus, or Command-0.",
                        "You can select recognized text when its overlay is on in Appearance settings.",
                    ]
                ),
            ]
        case .privacyExclusions:
            return [
                SupportGuideSection(
                    title: "Private by default",
                    points: [
                        "Screenlogger stores screenshots, recognized text, and search data on this Mac. Connected assistants can send retrieved content to their AI providers.",
                        "Diagnostics never include screenshots, recognized text, searches, or Library paths.",
                    ]
                ),
                SupportGuideSection(
                    title: "Choose what is skipped",
                    points: [
                        "Add apps or detectable websites in Exclusions settings.",
                        "Screenlogger skips private browsing and protected fields when it can detect them.",
                        "If website detection is unavailable, review the visible capture status before continuing.",
                    ]
                ),
            ]
        case .troubleshooting:
            return [
                SupportGuideSection(
                    title: "Capture is not running",
                    points: [
                        "Open Capture settings. Follow the current status action.",
                        "After a macOS permission change, quit Screenlogger if prompted. Then open Screenlogger again.",
                        "If storage is low, free space or adjust retention in Storage settings.",
                    ]
                ),
                SupportGuideSection(
                    title: "Library or search is unavailable",
                    points: [
                        "Use Try Again first. Screenlogger does not delete your existing Library.",
                        "Show the Library or its diagnostics when a recovery screen offers those actions.",
                        "Export diagnostics from Support if you need to share app status details. Diagnostics do not contain captured content.",
                    ]
                ),
            ]
        }
    }
}

private struct SupportGuideSection: Identifiable {
    let title: String
    let points: [String]

    var id: String { title }
}
