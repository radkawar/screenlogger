import AppKit
import ScreenlogCore
import SwiftUI

// MARK: - Shared identity / time helpers

enum SLAppIdentity {
    // Both caches are bounded. Screenlogger resolves an identity for every
    // Library card, filter, and ribbon source, so an unbounded cache keeps
    // one full icon family per app and per size alive for the life of the
    // process even after the surface that asked for it is gone.
    private static let nameCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 512
        return cache
    }()

    private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    private static let placeholderCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 16
        return cache
    }()

    static func displayName(bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "Moment" }
        if let cached = nameCache.object(forKey: bundleID as NSString) {
            return cached as String
        }
        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
        } else {
            name = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
        nameCache.setObject(name as NSString, forKey: bundleID as NSString)
        return name
    }

    static func iconCacheKey(bundleID: String?, size: CGFloat) -> String {
        "\(bundleID ?? "")-\(Int(size))"
    }

    /// Already-resolved icon, or nil. This is a pure cache read and is the only
    /// icon lookup a view body may perform.
    static func cachedIcon(bundleID: String?, size: CGFloat = 28) -> NSImage? {
        iconCache.object(forKey: iconCacheKey(bundleID: bundleID, size: size) as NSString)
    }

    /// Resolve and cache one app icon. LaunchServices and the icon family read
    /// are synchronous filesystem work, so callers must keep this off the body
    /// path and read `cachedIcon(bundleID:size:)` while laying out.
    @discardableResult
    static func icon(bundleID: String?, size: CGFloat = 28) -> NSImage {
        let key = iconCacheKey(bundleID: bundleID, size: size) as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let image: NSImage
        if let bundleID, !bundleID.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: size, height: size)
            image = icon
        } else {
            image = placeholderIcon(size: size)
        }
        iconCache.setObject(image, forKey: key, cost: Int(size * size * 4))
        return image
    }

    /// Neutral stand-in shown while an icon has not been resolved yet. Shared
    /// per size so a body pass never allocates one.
    static func placeholderIcon(size: CGFloat) -> NSImage {
        let key = "placeholder-\(Int(size))" as NSString
        if let cached = placeholderCache.object(forKey: key) { return cached }
        let fallback =
            NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: size, height: size))
        fallback.size = NSSize(width: size, height: size)
        placeholderCache.setObject(fallback, forKey: key)
        return fallback
    }

    static func applicationURL(bundleID: String?) -> URL? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}

// MARK: - App icon view

struct SLAppIconView: View {
    let bundleID: String?
    var size: CGFloat = 28

    private struct ResolvedIcon {
        let key: String
        let image: NSImage
    }

    @State private var resolved: ResolvedIcon?

    private var iconSize: CGFloat { size * 2 }

    private var iconKey: String {
        SLAppIdentity.iconCacheKey(bundleID: bundleID, size: iconSize)
    }

    var body: some View {
        // The cache is consulted first so a warm icon is identical to what a
        // synchronous lookup produced. A miss draws the shared placeholder and
        // is resolved in `task`, which keeps LaunchServices and the icon family
        // read out of every layout pass.
        let image =
            SLAppIdentity.cachedIcon(bundleID: bundleID, size: iconSize)
            ?? resolved.flatMap { $0.key == iconKey ? $0.image : nil }
            ?? SLAppIdentity.placeholderIcon(size: iconSize)
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .task(id: iconKey) {
                let key = iconKey
                if let cached = SLAppIdentity.cachedIcon(bundleID: bundleID, size: iconSize) {
                    resolved = ResolvedIcon(key: key, image: cached)
                    return
                }
                let requestedBundleID = bundleID
                let requestedSize = iconSize
                let image = await Task.detached(priority: .utility) {
                    SLAppIdentity.icon(bundleID: requestedBundleID, size: requestedSize)
                }.value
                guard !Task.isCancelled, key == iconKey else { return }
                resolved = ResolvedIcon(key: key, image: image)
            }
    }
}

struct SLFaviconView: View {
    let domain: String
    var size: CGFloat = 14
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
            } else {
                Image(nsImage: FaviconCache.shared.placeholder(for: domain, size: size))
                    .resizable()
                    .frame(width: size, height: size)
            }
        }
        .task(id: domain) {
            let resolved = await FaviconCache.shared.image(for: domain)
            image = resolved
        }
    }
}
