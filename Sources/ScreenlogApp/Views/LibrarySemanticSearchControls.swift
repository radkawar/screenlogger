import ScreenlogCore
import SwiftUI

struct LibrarySemanticSearchControls: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingEngine: LibrarySearchEngine?

    private var engineSelection: Binding<LibrarySearchEngine> {
        Binding(
            get: { pendingEngine ?? model.librarySearchEngine },
            set: { engine in
                guard engine != .related || model.relatedSearchIsAvailable else { return }
                let availabilityRevision = model.librarySearchEngineSelection.availabilityRevision
                pendingEngine = engine
                DispatchQueue.main.async {
                    guard pendingEngine == engine else { return }
                    pendingEngine = nil
                    model.setLibrarySearchEngine(engine, availabilityRevision: availabilityRevision)
                }
            }
        )
    }

    var body: some View {
        Menu {
            Button {
                engineSelection.wrappedValue = .exact
            } label: {
                if engineSelection.wrappedValue == .exact {
                    Label("Words", systemImage: "checkmark")
                } else {
                    Text("Words")
                }
            }
            Button {
                engineSelection.wrappedValue = .related
            } label: {
                if engineSelection.wrappedValue == .related {
                    Label("Meaning", systemImage: "checkmark")
                } else {
                    Text("Meaning")
                }
            }
            .disabled(!model.relatedSearchIsAvailable)
            .accessibilityIdentifier("library.search.related")

            Divider()

            Button(model.relatedSearchIsAvailable ? "Search Settings\u{2026}" : "Set Up Meaning Search\u{2026}") {
                model.openProductSettings(.searchSemanticSearch)
            }
            .accessibilityIdentifier("library.search.semantic-settings")
        } label: {
            Text(model.librarySearchEngine == .related ? "Meaning" : "Words")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Match words on screen or search by meaning")
        .accessibilityLabel("Search matching method")
        .accessibilityIdentifier("library.search.engine")
        .onChange(of: model.relatedSearchIsAvailable) { _, available in
            if !available { pendingEngine = nil }
        }
    }
}

struct LibraryIndexingCoverage: View {
    @ObservedObject var controller: SemanticSearchController
    @State private var requestingIndex = false
    @State private var issue: String?

    private var status: SemanticFeatureStatus { controller.featureStatus }

    var body: some View {
        if status.enabled && status.modelInstalled
            && (status.index.pendingSources > 0 || status.index.failedSources > 0 || issue != nil)
        {
            HStack(spacing: SLDesign.space8) {
                Text("Meaning")
                    .fontWeight(.medium)
                Text("\(status.index.indexedSources.formatted()) indexed")
                if status.index.pendingSources > 0 {
                    Text(
                        status.phase == .indexing
                            ? "Indexing \(status.index.pendingSources.formatted()) remaining"
                            : "\(status.index.pendingSources.formatted()) waiting")
                }
                if status.index.failedSources > 0 {
                    Text("\(status.index.failedSources.formatted()) failed")
                }
                if status.index.pendingSources > 0 && status.indexingPolicy != .manual {
                    Button("Index Now") {
                        requestingIndex = true
                        issue = nil
                        Task { @MainActor in
                            defer { requestingIndex = false }
                            do {
                                _ = try await controller.control(.init(action: .indexNow))
                            } catch {
                                issue = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(requestingIndex)
                    .accessibilityIdentifier("library.search.index-now")
                }
                if let issue {
                    Text(issue)
                        .foregroundStyle(SLDesign.error)
                }
            }
            .font(SLDesign.metadataFont)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(status.message ?? "Meaning searches indexed history only. Index Now also works while you use your Mac and on battery.")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.search.indexing-coverage")
        }
    }
}

struct SemanticResultSourceLabel: View {
    let hit: SemanticSearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(
                SemanticSearchPresentation.sourceLabel(hit.kind),
                systemImage: SemanticSearchPresentation.sourceSymbol(hit.kind))
            if hit.occurrenceCount > 1 {
                Text("\(hit.occurrenceCount) matching occurrences")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Cosine similarity: \(hit.score.formatted(.number.precision(.fractionLength(3)))). This value is not a probability.")
        .accessibilityIdentifier("library.result.semantic-source.\(hit.result.frameID)")
    }
}
