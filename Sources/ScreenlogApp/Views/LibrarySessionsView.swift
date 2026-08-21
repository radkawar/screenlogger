import ScreenlogCore
import SwiftUI

struct LibraryContentModeBar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: LibraryContentMode

    var body: some View {
        HStack(spacing: 10) {
            Picker("Library view", selection: $selection) {
                ForEach(LibraryContentMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .accessibilityIdentifier("library.content-mode")

            if selection == .sessions {
                Text("\(model.sessions.count) session\(model.sessions.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("library.sessions.count")
            }

            Spacer()

            if selection == .sessions {
                Button {
                    Task { await model.loadSessions() }
                } label: {
                    Label("Refresh Sessions", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Refresh Sessions")
                .accessibilityIdentifier("library.sessions.refresh")
            }
        }
        .frame(minHeight: 24)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.content-mode.bar")
    }
}

struct LibrarySessionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isRefreshing = false
    @FocusState private var listFocused: Bool

    var body: some View {
        Group {
            if model.sessions.isEmpty, isRefreshing {
                ProgressView("Loading Sessions")
                    .controlSize(.small)
                    .accessibilityIdentifier("library.sessions.loading")
            } else if model.sessions.isEmpty, model.timelineIssue == .refreshSessions {
                ContentUnavailableView {
                    Label("Sessions Couldn't Load", systemImage: "exclamationmark.circle")
                } description: {
                    Text("Screenlogger couldn't load your recording sessions.")
                } actions: {
                    Button("Try Again") { refresh() }
                }
                .accessibilityIdentifier("library.sessions.error")
            } else if model.sessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions Yet",
                    systemImage: "rectangle.stack.badge.clock",
                    description: Text(
                        "Sessions appear here after Screenlogger captures activity."
                    )
                )
                .accessibilityIdentifier("library.sessions.empty")
            } else {
                sessionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.sessions")
        .task {
            // MainShell loads sessions when it opens. Re-entering this mode
            // should reuse that snapshot instead of rescanning the complete
            // Library every time SwiftUI remounts the view.
            if model.sessions.isEmpty {
                isRefreshing = true
                await model.loadSessions()
                isRefreshing = false
            }
            if model.libraryWorkspaceNavigation.selectedSessionStartMs == nil {
                model.libraryWorkspaceNavigation.selectedSessionStartMs =
                    model.selectedSession?.startMs ?? model.sessions.first?.startMs
            }
        }
    }

    private var sessionList: some View {
        let sections = model.sessionSidebarSections
        return List(selection: $model.libraryWorkspaceNavigation.selectedSessionStartMs) {
            if !sections.pinned.isEmpty {
                Section("Pinned") {
                    ForEach(sections.pinned.map { $0.session }) { session in
                        sessionRow(session, showsDate: true)
                    }
                }
            }

            ForEach(sections.dayGroups, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.sessions.map { $0.session }) { session in
                        sessionRow(session, showsDate: false)
                    }
                }
            }
        }
        .listStyle(.inset)
        .focused($listFocused)
        .focusable()
        .onKeyPress(.return) {
            guard let selectedSession else { return .ignored }
            open(selectedSession)
            return .handled
        }
        .onExitCommand {
            listFocused = false
            model.shellFocusSearch = true
        }
        .accessibilityLabel("All recording sessions")
        .accessibilityValue("\(model.sessions.count) sessions")
    }

    private func sessionRow(_ session: SessionRow, showsDate: Bool) -> some View {
        HStack(spacing: 12) {
            SLAppIconView(bundleID: session.primaryBundleID, size: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(timeRange(session, showsDate: showsDate))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Text("Started in \(session.appLabel)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(SessionPinning.summaryLabel(for: session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .tag(session.startMs)
        .onTapGesture(count: 2) { open(session) }
        .contextMenu {
            Button("Open in Timeline") { open(session) }
            Button(model.isSessionPinned(session) ? "Unpin Session" : "Pin Session") {
                model.togglePinSession(session)
            }
        }
        .accessibilityAction(named: "Open in Timeline") { open(session) }
        .accessibilityAction(
            named: model.isSessionPinned(session) ? "Unpin Session" : "Pin Session"
        ) {
            model.togglePinSession(session)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sessionAccessibilityLabel(session))
        .accessibilityIdentifier("library.session.\(session.startMs)")
    }

    private var selectedSession: SessionRow? {
        guard let selectedStartMs = model.libraryWorkspaceNavigation.selectedSessionStartMs else {
            return nil
        }
        return model.sessions.first { $0.startMs == selectedStartMs }
    }

    private func open(_ session: SessionRow) {
        model.libraryWorkspaceNavigation.selectedSessionStartMs = session.startMs
        model.openLibrarySession(session)
    }

    private func refresh() {
        Task {
            isRefreshing = true
            await model.loadSessions()
            isRefreshing = false
        }
    }

    private func timeRange(_ session: SessionRow, showsDate: Bool) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(session.startMs) / 1000)
        let end = Date(timeIntervalSince1970: TimeInterval(session.endMs) / 1000)
        let time =
            "\(start.formatted(date: .omitted, time: .shortened)) to "
            + end.formatted(date: .omitted, time: .shortened)
        guard showsDate else { return time }
        return "\(start.formatted(date: .abbreviated, time: .omitted)), \(time)"
    }

    private func sessionAccessibilityLabel(_ session: SessionRow) -> String {
        "\(timeRange(session, showsDate: true)), started in \(session.appLabel), "
            + SessionPinning.summaryLabel(for: session)
    }
}
