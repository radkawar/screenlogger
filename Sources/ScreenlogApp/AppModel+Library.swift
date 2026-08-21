import AppKit
import Foundation
import ScreenlogCore
import SwiftUI

/// Why Library is being presented.
///
/// Keeping these entry points distinct prevents an ordinary global Library
/// reopen from silently adopting Timeline's selected-session scope. Find also
/// gets the native replace-the-current-query behavior users expect from Command-F.
enum LibraryPresentationIntent: Equatable {
    case show
    case find
    case timelineContext

    var usesSelectedTimelineSession: Bool {
        self == .timelineContext
    }

    var selectsExistingQuery: Bool {
        self == .find
    }
}

/// Library/session shell behavior and user-facing handoff actions.
///
/// This extension intentionally communicates with replay and search through AppModel's
/// observable state and methods; it does not own capture lifecycle.
@MainActor
extension AppModel {
    // MARK: - Main shell

    /// Open Timeline as a new navigation handoff.
    ///
    /// Callers restoring an existing Timeline window should use
    /// `showMainShell()` so a retained Back to Library path is not rewritten.
    func openMainShell(origin: TimelineNavigationOrigin) {
        timelineNavigationOrigin = origin
        MainShellController.shared.show(model: self, focusSearch: false)
    }

    /// Bring Timeline forward without changing how the user arrived there.
    func showMainShell() {
        MainShellController.shared.show(model: self, focusSearch: false)
    }

    /// Present Timeline from a global Show command.
    ///
    /// Deminiaturizing is restoration and must preserve a result's Back to
    /// Library path. Invoking Show Timeline on an already presented workspace
    /// is an explicit direct route and clears that temporary handoff.
    func showMainShellFromGlobalRoute() {
        if MainShellController.shared.isMiniaturized {
            showMainShell()
        } else {
            openMainShell(origin: .direct)
        }
    }

    /// Open the Library for a specific user intent.
    func openSearchWindow(intent: LibraryPresentationIntent = .show) {
        // Any explicit Library presentation completes a Library handoff. Leaving
        // the old origin alive behind the Library lets a later direct Timeline
        // route expose a stale Back button.
        if timelineNavigationOrigin.returnsToLibrary {
            timelineNavigationOrigin = .direct
        }
        SearchWindowController.shared.show(model: self, intent: intent)
    }

    func closeSearchWindow() {
        SearchWindowController.shared.hide()
    }

    func closeMainShell() {
        MainShellController.shared.hide()
    }

    func toggleMainShell() {
        MainShellController.shared.toggle(model: self)
    }

    func enterShellSearch(intent: LibraryPresentationIntent = .show) {
        let alreadySearching = shellSearchMode
        shellSearchMode = true
        refreshRecentSearchQueries()
        // Only an explicit search from Timeline may adopt its selected session.
        // Global Library and Find presentations preserve the user's current
        // filter choice instead of silently turning this scope back on.
        let enablesSessionScope =
            intent.usesSelectedTimelineSession
            && selectedSession != nil
            && !searchSessionScoped
        if enablesSessionScope {
            searchSessionScoped = true
        }
        refreshSearchAutocomplete()
        // Catalog scan is relatively expensive - only on first enter (or empty catalogs).
        if !alreadySearching || (searchAppCatalog.isEmpty && searchSiteCatalog.isEmpty) {
            Task { await refreshSearchCatalogs() }
        }
        if enablesSessionScope {
            startLibrarySearch()
        }
    }

    func exitShellSearch() {
        shellSearchMode = false
        shellFocusSearch = false
        showSearchOperatorMenu = false
        searchAutocompleteRows = []
    }

    /// Currently selected session row (sessions sidebar), if any.
    var selectedSession: SessionRow? {
        guard let idx = selectedSessionIndex, sessions.indices.contains(idx) else { return nil }
        return sessions[idx]
    }

    /// Whether the 'In session' chip is available.
    var canFilterSearchBySession: Bool { selectedSession != nil }

    func refreshRecentSearchQueries() {
        recentSearchQueries = recentSearchStore.all()
    }

    /// Reset all client-side search filters (content/app/domain/time/session).
    func clearSearchFilters() {
        searchContent = .all
        searchAppFilter = nil
        searchDomainFilter = nil
        searchTimeFilter = nil
        if selectedSession == nil {
            searchSessionScoped = false
        }
    }

    /// Compatibility reset for callers that intentionally discard every
    /// Library search criterion.
    func clearSearch() {
        clearLibrarySearch(.all)
    }

    func loadSessions() async {
        let issue = TimelineIssue.refreshSessions
        if timelineIssue == issue { timelineIssue = nil }
        guard let store else {
            if libraryStartupIssue == nil { timelineIssue = issue }
            return
        }
        do {
            let rows = try await store.readAsync { try $0.sessions(gapMs: 5 * 60 * 1000) }
            applySessionRefresh(rows)
        } catch {
            timelineIssue = issue
        }
    }

    /// Replace session metadata without silently changing the user's selected
    /// session. A scoped Library query is rerun whenever its SQL time bounds
    /// changed, including normal live-capture growth.
    func applySessionRefresh(_ rows: [SessionRow]) {
        // Read the selection and scope at application time. Both can change
        // while the SQLite read is suspended, and a stale snapshot must not
        // undo a user's newer navigation or filter choice.
        let selectedStartMs = selectedSession?.startMs
        let selectedEndMs = selectedSession?.endMs
        let isSearchSessionScoped = searchSessionScoped
        pinnedSessionIDs = sessionPinStore.pinnedIDs()
        sessions = sessionPinStore.sortedSessions(rows)
        if let selectedStartMs = libraryWorkspaceNavigation.selectedSessionStartMs,
            !sessions.contains(where: { $0.startMs == selectedStartMs })
        {
            libraryWorkspaceNavigation.selectedSessionStartMs = sessions.first?.startMs
        }
        guard let selectedStartMs else { return }

        selectedSessionIndex = sessions.firstIndex(where: { $0.startMs == selectedStartMs })
        if selectedSessionIndex == nil, isSearchSessionScoped {
            searchSessionScoped = false
        }
        if isSearchSessionScoped,
            selectedSession?.startMs != selectedStartMs
                || selectedSession?.endMs != selectedEndMs
        {
            startLibrarySearch()
        }
    }

    /// Refresh selected-session bounds when a retained Library window returns.
    /// A single tracked worker absorbs AppKit's show/key/deminiaturize event burst
    /// and is drained before a Library restore can replace SQLite on disk.
    func refreshScopedLibrarySearchForPresentation() {
        guard searchSessionScoped,
            libraryRestoreState != .restoring,
            libraryPresentationRefreshTask == nil
        else { return }

        libraryPresentationRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadSessions()
            self.libraryPresentationRefreshTask = nil
        }
    }

    func loadSession(at index: Int) async {
        guard sessions.indices.contains(index) else { return }
        await loadSession(sessions[index])
    }

    func loadSession(_ session: SessionRow) async {
        let issue = TimelineIssue.reloadSession(startMs: session.startMs)
        if timelineIssue == issue { timelineIssue = nil }
        dismissTimelineNotice()
        timelineLoadState = .loading
        guard let store else {
            timelineLoadState = .failed
            if libraryStartupIssue == nil { timelineIssue = issue }
            return
        }
        shellSearchMode = false
        stopReplay()
        do {
            let frames = try await store.readAsync {
                try $0.timeline(
                    session: session,
                    aroundTimestampMs: session.endMs,
                    before: 499,
                    after: 0
                )
                .sorted(by: TimelineFrame.chronologicalAscending)
            }
            selectedSessionIndex = sessions.firstIndex(where: { $0.startMs == session.startMs })
            if searchSessionScoped {
                startLibrarySearch()
            }
            timeline = frames
            selectedTimelineID = frames.last?.id ?? frames.first?.id
            timelineLoadState = .ready
            publishTimelineNotice(
                .timelineLoaded(scope: .session, momentCount: timelineMomentCount),
                announce: true
            )
        } catch {
            timelineLoadState = .failed
            timelineIssue = issue
        }
    }

    /// Open a session selected from Library while preserving the native Back
    /// to Library handoff used by individual search results.
    func openLibrarySession(_ session: SessionRow) {
        stopReplay()
        searchTask?.cancel()
        searchDebounceTask?.cancel()
        SearchWindowController.shared.hide()
        shellSearchMode = false
        stageHighlightTokens = []
        timelineLoadState = .loading
        openMainShell(origin: .librarySession)
        Task { await loadSession(session) }
    }

    /// Replaces the loaded detail window while retaining the selected session.
    /// The activity ribbon uses the session's true bounds, so any point in a
    /// long session can be requested without an unbounded query.
    func loadSelectedSessionWindow(
        aroundTimestampMs timestampMs: Int64,
        before: Int = 249,
        after: Int = 250
    ) async {
        guard let session = selectedSession, let store else { return }
        let target = min(session.endMs, max(session.startMs, timestampMs))
        timelineLoadState = .loading
        do {
            let frames = try await store.readAsync {
                try $0.timeline(
                    session: session,
                    aroundTimestampMs: target,
                    before: before,
                    after: after
                )
                .sorted(by: TimelineFrame.chronologicalAscending)
            }
            timeline = frames
            if let closest = frames.min(by: {
                abs($0.timestampMs - target) < abs($1.timestampMs - target)
            }) {
                selectTimelineFrame(id: closest.id)
            } else {
                selectedTimelineID = nil
            }
            timelineLoadState = .ready
        } catch {
            timelineLoadState = .failed
            timelineIssue = .reloadSession(startMs: session.startMs)
        }
    }

    var canLoadEarlierSessionWindow: Bool {
        guard let session = selectedSession, let first = timelineMomentFrames.first else { return false }
        return first.timestampMs > session.startMs
    }

    var canLoadLaterSessionWindow: Bool {
        guard let session = selectedSession, let last = timelineMomentFrames.last else { return false }
        return last.timestampMs < session.endMs
    }

    func loadEarlierSessionWindow() async {
        guard let first = timelineMomentFrames.first else { return }
        await loadSelectedSessionWindow(
            aroundTimestampMs: first.timestampMs - 1,
            before: 499,
            after: 0
        )
    }

    func loadLaterSessionWindow() async {
        guard let last = timelineMomentFrames.last else { return }
        await loadSelectedSessionWindow(
            aroundTimestampMs: last.timestampMs + 1,
            before: 0,
            after: 499
        )
    }

    func isSessionPinned(_ session: SessionRow) -> Bool {
        sessionPinStore.isPinned(session)
    }

    func togglePinSession(_ session: SessionRow) {
        let selectedStartMs = selectedSession?.startMs
        _ = sessionPinStore.toggle(session)
        pinnedSessionIDs = sessionPinStore.pinnedIDs()
        sessions = sessionPinStore.sortedSessions(sessions)
        if let selectedStartMs {
            selectedSessionIndex = sessions.firstIndex(where: { $0.startMs == selectedStartMs })
        }
    }

    var canCopySelectedFrameImage: Bool {
        if selectedFrameImage != nil { return true }
        guard selectedFramePreviewIssue == nil else { return false }
        if let path = selectedTimelineFrame?.imagePath, !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        {
            return true
        }
        return false
    }

    var canCopySelectedOCRText: Bool {
        guard let t = selectedTimelineFrame?.ocrText.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !t.isEmpty
    }

    var canOpenSelectedExternally: Bool {
        selectedExternalTarget != nil
    }

    func copySelectedFrameImage() {
        guard let frameID = selectedTimelineFrame?.id, let store else {
            publishTimelineMomentAction(.imageUnavailable)
            return
        }

        let worker = Task.detached(priority: .userInitiated) {
            guard let row = try await store.readAsync({ try $0.frame(id: frameID) }) else {
                throw FrameExtractor.ExtractError.imageGenerationFailed("frame not found")
            }
            return try await FrameExtractor.cgImage(forFrame: row, store: store)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let cgImage = try await worker.value
                let image = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                publishTimelineMomentAction(
                    pasteboard.writeObjects([image]) ? .imageCopied : .imageCopyFailed
                )
            } catch {
                publishTimelineMomentAction(.imageUnavailable)
            }
        }
    }

    func copySelectedOCRText() {
        let text = selectedTimelineFrame?.ocrText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            publishTimelineMomentAction(.textUnavailable)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        publishTimelineMomentAction(
            pb.setString(text, forType: .string) ? .textCopied : .textCopyFailed
        )
    }

    /// Open the URL, file, or app represented by the selected moment.
    func openSelectedExternally() {
        guard selectedTimelineFrame != nil else {
            publishTimelineMomentAction(.noMomentSelected)
            return
        }
        guard let target = selectedExternalTarget else {
            publishTimelineMomentAction(.sourceUnavailable)
            return
        }
        publishTimelineMomentAction(
            NSWorkspace.shared.open(target.url)
                ? .sourceOpened(label: target.label)
                : .sourceOpenFailed(label: target.label)
        )
    }

    private var selectedExternalTarget: SelectedTimelineExternalTarget? {
        guard let frame = selectedTimelineFrame else { return nil }
        if let rawURL = frame.url?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty,
            let url = URL(string: rawURL),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host != nil
        {
            let label = frame.domain?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayLabel =
                label.flatMap { $0.isEmpty ? nil : $0 }
                ?? url.host
                ?? "link"
            return SelectedTimelineExternalTarget(
                url: url,
                label: displayLabel
            )
        }
        if let domain = frame.domain?.trimmingCharacters(in: .whitespacesAndNewlines),
            !domain.isEmpty
        {
            var components = URLComponents()
            components.scheme = "https"
            components.host = domain
            if let url = components.url {
                return SelectedTimelineExternalTarget(url: url, label: domain)
            }
        }
        if let bundleID = frame.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleID.isEmpty,
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            let appLabel = frame.appLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return SelectedTimelineExternalTarget(
                url: appURL,
                label: appLabel.isEmpty ? "app" : appLabel
            )
        }
        return nil
    }

    /// Jump to previous/next activity segment in the loaded timeline.
    func stepSegment(by delta: Int) {
        guard !timeline.isEmpty else { return }
        normalizeTimelineChronologyIfNeeded()
        let ordered = timelineMomentFrames
        guard let cur = selectedTimelineFrame,
            let idx = selectedTimelineMomentIndex
        else {
            selectFirstTimelineMoment()
            return
        }
        let curSeg = cur.segmentID
        if delta < 0 {
            // Find last frame of previous different segment
            var i = idx - 1
            while i >= 0 {
                if ordered[i].segmentID != curSeg || curSeg == nil {
                    // land on first frame of that segment run
                    let targetSeg = ordered[i].segmentID
                    var j = i
                    while j > 0, ordered[j - 1].segmentID == targetSeg { j -= 1 }
                    selectTimelineMoment(at: j)
                    return
                }
                i -= 1
            }
            selectTimelineMoment(at: 0)
        } else {
            var i = idx + 1
            while i < ordered.count {
                if ordered[i].segmentID != curSeg || curSeg == nil {
                    selectTimelineMoment(at: i)
                    return
                }
                i += 1
            }
            if !ordered.isEmpty { selectTimelineMoment(at: ordered.count - 1) }
        }
    }

    func zoomStage(by factor: CGFloat) {
        guard selectedFrameImage != nil else { return }
        stageZoom = min(4.0, max(0.5, stageZoom * factor))
    }

    func resetStageZoom() {
        guard selectedFrameImage != nil else { return }
        stageZoom = 1.0
    }

    /// Load OCR boxes for Live Text overlay when selection changes.
    func loadOCRBoxesForSelection() {
        ocrBoxesTask?.cancel()
        if !selectedFrameOCRBoxes.isEmpty {
            selectedFrameOCRBoxes = []
        }
        guard let store, let id = selectedTimelineID else {
            return
        }

        // Pointer scrubbing can change selection at display cadence. Use the
        // same settled-selection gate as preview extraction so obsolete OCR
        // reads do not queue ahead of the moment the person actually chose.
        ocrBoxesTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .milliseconds(TimelinePreviewPolicy.selectionDebounceMilliseconds)
                )
                let boxes = try await store.readAsync { try $0.ocrBoxes(frameID: id) }
                guard let self, !Task.isCancelled, self.selectedTimelineID == id else { return }
                self.selectedFrameOCRBoxes = boxes
            } catch is CancellationError {
                // A newer selection owns both the pending read and presentation.
            } catch {
                guard let self, self.selectedTimelineID == id else { return }
                self.selectedFrameOCRBoxes = []
            }
        }
    }

    func applyExclusionCategory(_ category: ExclusionCategory, enabled: Bool) {
        preferences.set(enabled, forKey: category.defaultsKey)
        switch category {
        case .passwordManagers:
            exclusionStore.passwordManagersCategoryEnabled = enabled
        case .banks:
            // Domain pack matched dynamically - never write thousands of domains to UserDefaults.
            exclusionStore.banksCategoryEnabled = enabled
        }
        reloadExclusionsFromStore()
    }

    func isExclusionCategoryEnabled(_ category: ExclusionCategory) -> Bool {
        switch category {
        case .passwordManagers:
            return exclusionStore.passwordManagersCategoryEnabled
        case .banks:
            return exclusionStore.banksCategoryEnabled
        }
    }

    func setSystemAppExcluded(_ app: SystemExclusionApp, excluded: Bool) {
        if excluded { exclusionStore.add(app.rawValue) } else { exclusionStore.remove(app.rawValue) }
        reloadExclusionsFromStore()
    }

    var accentSwiftUIColor: Color {
        accentColorPreference.swiftUIColor
    }
}

extension AccentColorPreference {
    /// One app-owned palette powers Settings previews and every semantic
    /// selection/focus treatment. Core keeps only the persisted preference.
    var swiftUIColor: Color {
        switch self {
        case .system: return .accentColor
        case .azure: return Color(nsColor: .systemBlue)
        case .purple: return Color(nsColor: .systemPurple)
        case .pink: return Color(nsColor: .systemPink)
        case .orange: return Color(nsColor: .systemOrange)
        case .green: return Color(nsColor: .systemGreen)
        }
    }
}

extension AppModel {
    /// Sidebar: pinned block + day-grouped unpinned (Today / Yesterday / date).
    var sessionSidebarSections:
        (
            pinned: [(index: Int, session: SessionRow)],
            dayGroups: [(label: String, sessions: [(index: Int, session: SessionRow)])]
        )
    {
        let pins = pinnedSessionIDs
        var indexByKey: [String: Int] = [:]
        for (index, session) in sessions.enumerated() {
            indexByKey[session.pinKey] = index
        }
        let split = SessionPinning.sections(sessions, pinnedKeys: pins)
        let pinnedItems = split.pinned.compactMap { s -> (index: Int, session: SessionRow)? in
            guard let i = indexByKey[s.pinKey] else { return nil }
            return (i, s)
        }
        let dayGroups = split.dayGroups.map { group in
            let items = group.sessions.compactMap { s -> (index: Int, session: SessionRow)? in
                guard let i = indexByKey[s.pinKey] else { return nil }
                return (i, s)
            }
            return (label: group.label, sessions: items)
        }
        return (pinnedItems, dayGroups)
    }

    /// Date-grouped unpinned sessions (compat for callers expecting only day sections).
    var sessionsByDay: [(label: String, sessions: [(index: Int, session: SessionRow)])] {
        sessionSidebarSections.dayGroups
    }

}

private struct SelectedTimelineExternalTarget {
    let url: URL
    let label: String
}
