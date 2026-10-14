import ScreenlogCore
import SwiftUI

struct LibraryContentModeBar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: LibraryContentMode
    @State private var isRefreshing = false
    // Native controls update local state first. Publish workspace changes
    // after SwiftUI completes the control's update.
    @State private var controlSelection: LibraryContentMode

    init(selection: Binding<LibraryContentMode>) {
        _selection = selection
        _controlSelection = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        HStack(spacing: 10) {
            Picker("Library view", selection: $controlSelection) {
                ForEach(LibraryContentMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading sessions")
                        .accessibilityIdentifier("library.sessions.refreshing")
                }
                Button {
                    Task {
                        guard !isRefreshing else { return }
                        isRefreshing = true
                        await model.loadSessions()
                        isRefreshing = false
                    }
                } label: {
                    Label("Refresh Sessions", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isRefreshing || model.libraryRestoreState == .restoring)
                .help("Refresh Sessions")
                .accessibilityIdentifier("library.sessions.refresh")
            }
        }
        .frame(minHeight: 24)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.content-mode.bar")
        .onChange(of: controlSelection) { _, value in
            if selection != value { selection = value }
        }
        .onChange(of: selection) { _, value in
            if controlSelection != value { controlSelection = value }
        }
    }
}

struct LibrarySessionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isRefreshing = false
    @State private var selectedSessionStartMs: Int64?
    @State private var renameTarget: SessionRow?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !model.sessions.isEmpty, model.timelineIssue == .refreshSessions {
                Label("Sessions could not load. Select Refresh Sessions.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("library.sessions.refresh-error")
            }

            if model.libraryRestoreState == .restoring {
                ProgressView("Restoring Library")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.sessions.isEmpty, isRefreshing {
                ProgressView("Loading Sessions")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("library.sessions.loading")
            } else if model.sessions.isEmpty, model.timelineIssue == .refreshSessions {
                ContentUnavailableView {
                    Label("Sessions Could Not Load", systemImage: "exclamationmark.circle")
                } description: {
                    Text("Screenlogger could not load your recording sessions.")
                } actions: {
                    Button("Try Again") { refresh() }
                }
                .accessibilityIdentifier("library.sessions.error")
            } else if model.sessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "rectangle.stack.badge.clock",
                    description: Text("Sessions appear here after Screenlogger captures activity.")
                )
                .accessibilityIdentifier("library.sessions.empty")
            } else {
                HSplitView {
                    sessionList
                        .frame(minWidth: 240, idealWidth: 270, maxWidth: 320)
                    sessionDetail
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.sessions")
        .sheet(item: $renameTarget) { session in
            SessionRenameEditor(session: session)
        }
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
        .onChange(of: model.sessions) { _, sessions in
            if model.libraryWorkspaceNavigation.selectedSessionStartMs == nil {
                model.libraryWorkspaceNavigation.selectedSessionStartMs = sessions.first?.startMs
            }
        }
        .onChange(of: model.libraryWorkspaceNavigation.selectedSessionStartMs, initial: true) { _, value in
            if selectedSessionStartMs != value { selectedSessionStartMs = value }
        }
        .onChange(of: selectedSessionStartMs) { _, value in
            if model.libraryWorkspaceNavigation.selectedSessionStartMs != value {
                model.libraryWorkspaceNavigation.selectedSessionStartMs = value
            }
        }
    }

    private var sessionList: some View {
        let sections = model.sessionSidebarSections
        return ScrollViewReader { proxy in
            List(selection: $selectedSessionStartMs) {
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
                // Native key dispatch can run inside a SwiftUI view update.
                DispatchQueue.main.async { open(selectedSession) }
                return .handled
            }
            .onExitCommand {
                listFocused = false
            }
            .onChange(of: selectedSessionStartMs, initial: true) { _, value in
                if let value { proxy.scrollTo(value, anchor: .center) }
            }
            .accessibilityLabel("All recording sessions")
            .accessibilityValue("\(model.sessions.count) sessions")
            .accessibilityIdentifier("library.sessions.list")
        }
    }

    private func sessionRow(_ session: SessionRow, showsDate: Bool) -> some View {
        HStack(spacing: SLDesign.space16) {
            SLAppIconView(bundleID: session.primaryBundleID, size: 28)
            VStack(alignment: .leading, spacing: SLDesign.space4) {
                Text(session.customName ?? timeRange(session, showsDate: showsDate))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .lineLimit(2)
                Text(session.customName == nil ? session.appLabel : timeRange(session, showsDate: showsDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(SessionPinning.summaryLabel(for: session))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SLDesign.space8)
        .contentShape(Rectangle())
        .tag(session.startMs)
        .id(session.startMs)
        .contextMenu {
            Button("Open in Timeline") { open(session) }
            Button("Rename\u{2026}") { rename(session) }
                .accessibilityIdentifier("library.session.context.rename")
            Button(model.isSessionPinned(session) ? "Unpin Session" : "Pin Session") {
                model.togglePinSession(session)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAction(named: "Open in Timeline") { open(session) }
        .accessibilityAction(named: "Rename") { rename(session) }
        .accessibilityAction(
            named: model.isSessionPinned(session) ? "Unpin Session" : "Pin Session"
        ) {
            model.togglePinSession(session)
        }
        .accessibilityLabel(sessionAccessibilityLabel(session))
        .accessibilityHint("Select this session to show its details")
        .accessibilityIdentifier("library.session.\(session.startMs)")
    }

    @ViewBuilder
    private var sessionDetail: some View {
        if let selectedSession {
            LibrarySessionDetail(
                session: selectedSession,
                mediaGeneration: model.previewMediaGeneration,
                onOpen: { open(selectedSession) },
                onRename: { rename(selectedSession) }
            )
            .id(selectedSession.startMs)
        } else {
            ContentUnavailableView(
                "Select a Session",
                systemImage: "rectangle.stack",
                description: Text("Select a session to show its details.")
            )
        }
    }

    private var selectedSession: SessionRow? {
        guard let selectedStartMs = selectedSessionStartMs else {
            return nil
        }
        return model.sessions.first { $0.startMs == selectedStartMs }
    }

    private func open(_ session: SessionRow) {
        model.libraryWorkspaceNavigation.selectedSessionStartMs = session.startMs
        model.openLibrarySession(session)
    }

    private func rename(_ session: SessionRow) {
        // Context menus can belong to an unselected row. Explicitly select
        // the target, while keeping sheet ownership outside the detail's ID.
        selectedSessionStartMs = session.startMs
        renameTarget = session
    }

    private func refresh() {
        Task {
            guard !isRefreshing else { return }
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
        "\(session.customName ?? timeRange(session, showsDate: false)), \(timeRange(session, showsDate: true)), started in \(session.appLabel), "
            + SessionPinning.summaryLabel(for: session)
    }
}

private struct SessionPreviewIdentity: Hashable {
    let startMs: Int64
    let endMs: Int64
    let momentCount: Int64
    let mediaGeneration: UInt64
    let captureIntervalMs: Int64
    let store: ObjectIdentifier?
}

private struct LibrarySessionDetail: View {
    let session: SessionRow
    let mediaGeneration: UInt64
    let onOpen: () -> Void
    let onRename: () -> Void

    @EnvironmentObject private var model: AppModel
    @State private var overview: SessionOverview?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var showsRecordingMethod = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLDesign.space16) {
                header
                Divider()
                if let overview {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: SLDesign.space24) {
                            representativeMoments(overview)
                                .frame(minWidth: 360, maxWidth: .infinity)
                            activityBreakdown(overview)
                                .frame(width: 208)
                        }
                        VStack(alignment: .leading, spacing: SLDesign.space24) {
                            representativeMoments(overview)
                            Divider()
                            activityBreakdown(overview)
                        }
                    }
                }
                if isLoading {
                    ProgressView("Loading recorded activity")
                        .controlSize(.small)
                        .accessibilityIdentifier("library.sessions.detail.loading")
                } else if loadFailed {
                    VStack(alignment: .leading, spacing: SLDesign.space8) {
                        Text("The session overview could not load.")
                            .foregroundStyle(.secondary)
                        Button("Try Again") { Task { await loadOverview() } }
                    }
                    .accessibilityIdentifier("library.sessions.detail.error")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SLDesign.space16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session overview")
        .accessibilityValue(dateRange)
        .accessibilityIdentifier("library.sessions.detail")
        .task(id: previewIdentity) { await loadOverview() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            VStack(alignment: .leading, spacing: SLDesign.space4) {
                Text(session.customName ?? timeRange)
                    .font(SLDesign.titleFont)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("library.sessions.detail.name")
                Text(session.customName == nil ? sessionDate : dateRange)
                    .font(SLDesign.metadataFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("library.sessions.detail.range")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SLDesign.space8) { sessionFacts }
                    VStack(alignment: .leading, spacing: SLDesign.space4) { sessionFacts }
                }
                .font(SLDesign.metadataFont.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.sessions.detail.selection.\(session.startMs)")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: SLDesign.space8) {
                    openAction
                    secondaryActions
                }
                VStack(alignment: .leading, spacing: SLDesign.space8) {
                    openAction
                    HStack(spacing: SLDesign.space8) { secondaryActions }
                }
            }
        }
    }

    @ViewBuilder
    private var sessionFacts: some View {
        if let overview {
            Text("\(duration(overview.coveredDurationMs)) recorded")
                .accessibilityIdentifier("library.sessions.detail.coverage")
        }
        Text("\(duration(session.durationMs)) elapsed \u{00B7} \(session.momentCount) \(session.momentCount == 1 ? "moment" : "moments")")
            .accessibilityIdentifier("library.sessions.detail.summary")
    }

    private var openAction: some View {
        Button("Open in Timeline", systemImage: "arrow.up.forward", action: onOpen)
            .accessibilityIdentifier("library.sessions.detail.open")
    }

    @ViewBuilder
    private var secondaryActions: some View {
        Button("Rename", systemImage: "pencil", action: onRename)
            .accessibilityIdentifier("library.sessions.detail.rename")
        Button(
            model.isSessionPinned(session) ? "Unpin" : "Pin",
            systemImage: model.isSessionPinned(session) ? "pin.slash" : "pin"
        ) { model.togglePinSession(session) }
    }

    private func activityBreakdown(_ overview: SessionOverview) -> some View {
        VStack(alignment: .leading, spacing: SLDesign.space24) {
            applications(overview)
            domains(overview)
            Button("About recorded time", systemImage: "info.circle") {
                showsRecordingMethod = true
            }
            .buttonStyle(.borderless)
            .font(SLDesign.metadataFont)
            .accessibilityIdentifier("library.sessions.detail.method")
            .popover(isPresented: $showsRecordingMethod) {
                VStack(alignment: .leading, spacing: SLDesign.space16) {
                    Text("About recorded time").font(SLDesign.sectionFont)
                    Text(
                        "Recorded time is estimated from captures, not attention. One display counts per moment; app changes split time at the midpoint."
                    )
                    Text(
                        "Gaps of \(duration(overview.gapThresholdMs)) or more are left out, based on the current capture cadence. Nothing is added before the first capture or after the last."
                    )
                    Text("Website time comes from captured browser context and is already included in application time.")
                }
                .font(SLDesign.bodyFont)
                .padding(SLDesign.space24)
                .frame(width: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.sessions.detail.activity")
    }

    private func applications(_ overview: SessionOverview) -> some View {
        VStack(alignment: .leading, spacing: SLDesign.space12) {
            Text(overview.applicationCount > overview.applications.count ? "Top apps" : "Apps")
                .font(SLDesign.sectionFont)
            ForEach(overview.applications) { item in
                HStack(spacing: SLDesign.space8) {
                    SLAppIconView(bundleID: item.identifier.isEmpty ? nil : item.identifier, size: 20)
                    Text(item.displayName)
                        .lineLimit(1)
                        .help(item.displayName)
                    Spacer(minLength: SLDesign.space8)
                    Text(duration(item.durationMs))
                        .font(SLDesign.metadataFont.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .font(SLDesign.bodyFont)
                .accessibilityElement(children: .combine)
            }
            if overview.applications.isEmpty {
                Text("No app activity recorded.").foregroundStyle(.secondary)
            } else if overview.applicationCount > overview.applications.count {
                Text(
                    "\(overview.applicationCount - overview.applications.count) more \(overview.applicationCount - overview.applications.count == 1 ? "app" : "apps")"
                )
                .font(SLDesign.metadataFont)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.sessions.detail.applications")
    }

    private func domains(_ overview: SessionOverview) -> some View {
        VStack(alignment: .leading, spacing: SLDesign.space12) {
            Text(overview.domainCount > overview.domains.count ? "Top websites" : "Websites")
                .font(SLDesign.sectionFont)
            if overview.domains.isEmpty {
                Text("No websites recorded.")
                    .font(SLDesign.bodyFont)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(overview.domains) { item in
                    HStack(spacing: SLDesign.space8) {
                        Text(item.displayName)
                            .lineLimit(1)
                            .help(item.displayName)
                            .textSelection(.enabled)
                        Spacer(minLength: SLDesign.space8)
                        Text(duration(item.durationMs))
                            .font(SLDesign.metadataFont.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .font(SLDesign.bodyFont)
                    .accessibilityElement(children: .combine)
                }
                if overview.domainCount > overview.domains.count {
                    Text("\(overview.domainCount - overview.domains.count) more websites")
                        .font(SLDesign.metadataFont)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.sessions.detail.domains")
    }

    private func representativeMoments(_ overview: SessionOverview) -> some View {
        VStack(alignment: .leading, spacing: SLDesign.space12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sampled moments").font(SLDesign.sectionFont)
                Spacer(minLength: SLDesign.space8)
                Text("\(overview.moments.count) of \(session.momentCount)")
                    .font(SLDesign.metadataFont.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240), spacing: SLDesign.space16)],
                alignment: .leading,
                spacing: SLDesign.space24
            ) {
                ForEach(overview.moments) { moment in
                    let presentation = LibraryResultTextPresentation(
                        title: moment.title, appLabel: moment.appLabel, domain: moment.domain,
                        snippet: nil, allowsUnmarkedExcerpt: false)
                    Button {
                        model.openLibrarySession(session, at: moment.timestampMs)
                    } label: {
                        VStack(alignment: .leading, spacing: SLDesign.space8) {
                            LibraryThumbnail(
                                frameID: moment.id,
                                path: moment.imagePath,
                                isCompacted: moment.videoID != nil,
                                contentMode: .fit,
                                showsStatusDetail: true,
                                priority: .inspector
                            )
                            .clipShape(RoundedRectangle(cornerRadius: SLDesign.thumbRadius))
                            HStack(alignment: .firstTextBaseline, spacing: SLDesign.space8) {
                                Text(
                                    Date(timeIntervalSince1970: Double(moment.timestampMs) / 1_000),
                                    format: .dateTime.hour().minute().second()
                                )
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                                Text(
                                    [presentation.appContext, presentation.domainContext].compactMap { $0 }.joined(separator: " \u{00B7} ")
                                )
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                            .font(SLDesign.metadataFont)
                            Text(presentation.title)
                                .font(SLDesign.bodyFont)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open this moment in Timeline")
                    .accessibilityHint("Opens this exact capture in Timeline")
                    .accessibilityIdentifier("library.sessions.detail.moment.\(moment.id)")
                }
            }
            if overview.moments.isEmpty {
                Text("No captured moments are available.").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.sessions.detail.moments")
    }

    private var previewIdentity: SessionPreviewIdentity {
        SessionPreviewIdentity(
            startMs: session.startMs,
            endMs: session.endMs,
            momentCount: session.momentCount,
            mediaGeneration: mediaGeneration,
            captureIntervalMs: Int64((model.intervalSeconds * 1_000).rounded()),
            store: model.store.map(ObjectIdentifier.init)
        )
    }

    private var timeRange: String {
        let start = Date(timeIntervalSince1970: TimeInterval(session.startMs) / 1_000)
        let end = Date(timeIntervalSince1970: TimeInterval(session.endMs) / 1_000)
        return "\(start.formatted(date: .omitted, time: .shortened)) to "
            + end.formatted(date: .omitted, time: .shortened)
    }

    private var sessionDate: String {
        let start = Date(timeIntervalSince1970: TimeInterval(session.startMs) / 1_000)
        let end = Date(timeIntervalSince1970: TimeInterval(session.endMs) / 1_000)
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return start.formatted(date: .complete, time: .omitted)
        }
        return "\(start.formatted(date: .abbreviated, time: .omitted)) to "
            + end.formatted(date: .abbreviated, time: .omitted)
    }

    private var dateRange: String {
        let start = Date(timeIntervalSince1970: TimeInterval(session.startMs) / 1_000)
        let end = Date(timeIntervalSince1970: TimeInterval(session.endMs) / 1_000)
        return "\(start.formatted(date: .abbreviated, time: .shortened)) to "
            + end.formatted(date: .abbreviated, time: .shortened)
    }

    private func duration(_ milliseconds: Int64) -> String {
        Duration.milliseconds(milliseconds).formatted(.time(pattern: .hourMinuteSecond))
    }

    @MainActor
    private func loadOverview() async {
        isLoading = true
        loadFailed = false
        guard let store = model.store, model.libraryRestoreState != .restoring else {
            isLoading = false
            loadFailed = true
            return
        }
        let identity = previewIdentity
        let selectedSession = session
        do {
            let loaded = try await store.readAsync {
                try $0.sessionOverview(
                    session: selectedSession,
                    expectedCaptureIntervalMs: identity.captureIntervalMs
                )
            }
            guard !Task.isCancelled, previewIdentity == identity,
                model.libraryRestoreState != .restoring,
                model.libraryWorkspaceNavigation.selectedSessionStartMs == session.startMs
            else { return }
            overview = loaded
            isLoading = false
        } catch {
            guard !Task.isCancelled, previewIdentity == identity,
                model.libraryRestoreState != .restoring,
                model.libraryWorkspaceNavigation.selectedSessionStartMs == session.startMs
            else { return }
            isLoading = false
            loadFailed = true
        }
    }
}

private struct SessionRenameEditor: View {
    let session: SessionRow

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var nameDraft: String
    @State private var isSavingName = false
    @State private var nameSaveFailed = false
    @FocusState private var nameFocused: Bool

    init(session: SessionRow) {
        self.session = session
        _nameDraft = State(initialValue: session.customName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SLDesign.space16) {
            Text("Rename Session").font(SLDesign.sectionFont)
            Text("The name stays with this session as new moments are recorded.")
                .font(SLDesign.bodyFont)
                .foregroundStyle(.secondary)
            TextField("Session name", text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .disabled(isSavingName)
                .onSubmit { saveName(nameDraft) }
                .accessibilityIdentifier("library.sessions.rename.field")
            if nameSaveFailed {
                Text("The name could not be saved. Try again.")
                    .font(SLDesign.metadataFont)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("library.sessions.rename.error")
            }
            HStack {
                Button("Reset Name") { saveName(nil) }
                    .disabled(session.customName == nil || isSavingName)
                    .accessibilityIdentifier("library.sessions.rename.reset")
                Spacer()
                if isSavingName { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSavingName)
                    .accessibilityIdentifier("library.sessions.rename.cancel")
                Button("Save") { saveName(nameDraft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingName)
                    .accessibilityIdentifier("library.sessions.rename.save")
            }
        }
        .padding(SLDesign.space24)
        .frame(width: 440)
        .interactiveDismissDisabled(isSavingName)
        .onAppear { nameFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.sessions.rename.target.\(session.startMs)")
    }

    private func saveName(_ name: String?) {
        guard !isSavingName else { return }
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        isSavingName = true
        nameSaveFailed = false
        Task {
            do {
                try await model.renameSession(session, to: name)
                dismiss()
            } catch {
                nameSaveFailed = true
            }
            isSavingName = false
        }
    }
}
