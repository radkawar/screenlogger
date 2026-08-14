import AppKit
import ScreenlogCore
import SwiftUI

/// A display-sized still for Library cards and the inspector.
///
/// The shared preview pipeline resolves current still/video backing and decodes
/// close to the view's backing-pixel size. SwiftUI cancels the request when a
/// lazy-grid cell leaves the viewport, before queued decode work can begin.
struct LibraryThumbnail: View {
    let frameID: Int64
    let path: String?
    var isCompacted = false
    var contentMode: ContentMode = .fill
    var showsStatusDetail = false
    var statusAccessibilityIdentifier = ""
    var priority: PreviewImagePriority = .card

    @EnvironmentObject private var model: AppModel
    @Environment(\.displayScale) private var displayScale
    @State private var loadedImage: NSImage?
    @State private var loadedGeneration: UInt64?
    @State private var loadFailed = false
    @State private var mediaUnavailable = false

    @ViewBuilder
    var body: some View {
        if showsStatusDetail {
            VStack(alignment: .leading, spacing: 9) {
                thumbnailViewport
                    .aspectRatio(16 / 10, contentMode: .fit)

                if let previewStatus {
                    statusDetail(previewStatus)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(previewAccessibilityLabel)
            .accessibilityIdentifier(statusAccessibilityIdentifier)
        } else {
            thumbnailViewport
                .accessibilityElement(children: .contain)
                .accessibilityLabel(previewAccessibilityLabel)
                .accessibilityIdentifier(statusAccessibilityIdentifier)
        }
    }

    private var thumbnailViewport: some View {
        GeometryReader { geometry in
            thumbnailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .task(id: requestKey(for: geometry.size)) {
                    await loadImage(
                        for: geometry.size,
                        generation: model.previewMediaGeneration
                    )
                }
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let currentImage {
            Image(nsImage: currentImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: contentMode)
                .accessibilityLabel("Captured screenshot")
                .accessibilityIdentifier("library.preview.image.\(frameID)")
        } else if let previewStatus {
            placeholder(previewStatus)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }

    private func placeholder(_ status: PreviewStatus) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
            VStack(spacing: 5) {
                Image(systemName: status.systemImage)
                    .font(.system(size: showsStatusDetail ? 24 : 17, weight: .regular))
                if !showsStatusDetail {
                    Text(status.title)
                        .font(.caption.weight(.medium))
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(.secondary)
            .padding(12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilityLabel)
    }

    private func statusDetail(_ status: PreviewStatus) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: status.systemImage)
                .foregroundStyle(.secondary)
        }
    }

    private var previewStatus: PreviewStatus? {
        if mediaUnavailable || (!hasMediaHint && currentImage == nil) {
            return .noLongerStored
        }
        return loadFailed ? .unavailable : nil
    }

    private var previewAccessibilityLabel: String {
        if currentImage != nil { return "Captured screenshot" }
        if let previewStatus { return previewStatus.accessibilityLabel }
        return "Loading captured screenshot"
    }

    private var currentImage: NSImage? {
        guard loadedGeneration == model.previewMediaGeneration else { return nil }
        return loadedImage
    }

    private func requestKey(for size: CGSize) -> String {
        "\(frameID)|\(path ?? "")|\(targetMaxPixelSize(for: size))|\(isCompacted)|\(model.previewMediaGeneration)"
    }

    private var hasMediaHint: Bool {
        isCompacted || !(path?.isEmpty ?? true)
    }

    private func targetMaxPixelSize(for size: CGSize) -> Int {
        let exactPixels = max(size.width, size.height) * max(displayScale, 1)
        guard exactPixels.isFinite, exactPixels > 0 else { return 0 }
        // Stable buckets avoid duplicate card and inspector extraction while
        // still matching Retina presentation size closely.
        let buckets = [384, 768, 1_280, 2_048, 3_072, 4_096, 6_144]
        return buckets.first(where: { $0 >= Int(ceil(exactPixels)) }) ?? 6_144
    }

    @MainActor
    private func loadImage(for size: CGSize, generation: UInt64) async {
        if loadedGeneration != generation {
            loadedImage = nil
            loadedGeneration = nil
        }
        loadFailed = false
        mediaUnavailable = false

        guard hasMediaHint else {
            loadedImage = nil
            loadedGeneration = nil
            mediaUnavailable = true
            return
        }

        let maxPixelSize = targetMaxPixelSize(for: size)
        guard maxPixelSize > 0 else { return }
        guard let store = model.store else {
            loadFailed = true
            return
        }

        let scale = max(displayScale, 1)
        do {
            let cgImage = try await model.previewImagePipeline.image(
                frameID: frameID,
                store: store,
                maxPixelSize: maxPixelSize,
                priority: priority
            )
            try Task.checkCancellation()
            guard model.previewMediaGeneration == generation else { return }
            loadedImage = NSImage(
                cgImage: cgImage,
                size: NSSize(
                    width: CGFloat(cgImage.width) / scale,
                    height: CGFloat(cgImage.height) / scale
                )
            )
            loadedGeneration = generation
        } catch is CancellationError {
            return
        } catch let error as PreviewImagePipelineError
            where error == .mediaUnavailable || error == .momentMissing
        {
            guard model.previewMediaGeneration == generation else { return }
            loadedImage = nil
            loadedGeneration = nil
            mediaUnavailable = true
        } catch {
            guard model.previewMediaGeneration == generation else { return }
            loadedImage = nil
            loadedGeneration = nil
            loadFailed = true
        }
    }
}

private enum PreviewStatus {
    case noLongerStored
    case unavailable

    var systemImage: String {
        switch self {
        case .noLongerStored: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .unavailable: "photo.badge.exclamationmark"
        }
    }

    var title: String {
        switch self {
        case .noLongerStored: "Preview no longer stored"
        case .unavailable: "Preview unavailable"
        }
    }

    var detail: String {
        switch self {
        case .noLongerStored: "Searchable text and details are still available."
        case .unavailable: "The captured image could not be loaded."
        }
    }

    var accessibilityLabel: String {
        "\(title). \(detail)"
    }
}
