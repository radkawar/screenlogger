import Foundation
import OSLog

private let log = Logger(subsystem: "dev.screenlog", category: "exclusions")

/// UserDefaults-backed exclusion lists for apps (bundle IDs) and browser domains.
/// `RecordingEngine` skips storing a frame image when the frontmost app or active domain is excluded.
public final class ExclusionStore: @unchecked Sendable {
    public static let shared = ExclusionStore(userDefaults: ScreenlogProcessPreferences.current)

    public static let userDefaultsKey = "screenlog.excludedBundles"
    public static let domainsKey = "screenlog.excludedDomains"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var bundles: Set<String>
    private var domains: Set<String>

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        let rawBundles = userDefaults.stringArray(forKey: Self.userDefaultsKey) ?? []
        self.bundles = Set(
            rawBundles
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        let rawDomains = userDefaults.stringArray(forKey: Self.domainsKey) ?? []
        self.domains = Set(rawDomains.compactMap(DomainExclusionParser.normalize))
    }

    // MARK: - Bundle IDs (AppModel / UI API)

    public func allSorted() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return bundles.sorted()
    }

    public func contains(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        let key = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        defer { lock.unlock() }
        return bundles.contains(key)
    }

    @discardableResult
    public func add(_ bundleID: String) -> Bool {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        lock.lock()
        let inserted = bundles.insert(trimmed).inserted
        let snapshot = Array(bundles)
        lock.unlock()
        if inserted {
            defaults.set(snapshot.sorted(), forKey: Self.userDefaultsKey)
            log.info("excluded bundle \(trimmed, privacy: .private(mask: .hash))")
        }
        return inserted
    }

    public func remove(_ bundleID: String) {
        let key = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        bundles.remove(key)
        let snapshot = Array(bundles)
        lock.unlock()
        defaults.set(snapshot.sorted(), forKey: Self.userDefaultsKey)
    }

    public func replaceAll(_ ids: [String]) {
        let cleaned = Set(
            ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        lock.lock()
        bundles = cleaned
        lock.unlock()
        defaults.set(cleaned.sorted(), forKey: Self.userDefaultsKey)
    }

    // MARK: - Domains

    public func allDomainsSorted() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return domains.sorted()
    }

    @discardableResult
    public func addDomain(_ domain: String) -> Bool {
        guard let n = DomainExclusionParser.normalize(domain) else { return false }
        lock.lock()
        let inserted = domains.insert(n).inserted
        let snapshot = Array(domains)
        lock.unlock()
        defaults.set(snapshot.sorted(), forKey: Self.domainsKey)
        log.info("excluded domain \(n, privacy: .private(mask: .hash))")
        return inserted
    }

    public func removeDomain(_ domain: String) {
        guard let n = DomainExclusionParser.normalize(domain) else { return }
        lock.lock()
        domains.remove(n)
        let snapshot = Array(domains)
        lock.unlock()
        defaults.set(snapshot.sorted(), forKey: Self.domainsKey)
    }

    public func replaceAllDomains(_ list: [String]) {
        let cleaned = Set(list.compactMap(DomainExclusionParser.normalize))
        lock.lock()
        domains = cleaned
        lock.unlock()
        defaults.set(cleaned.sorted(), forKey: Self.domainsKey)
    }

    public func isDomainExcluded(_ domain: String?) -> Bool {
        guard let domain, !domain.isEmpty else { return false }
        guard let n = DomainExclusionParser.normalize(domain) else { return false }
        lock.lock()
        let excluded = domains
        lock.unlock()
        if excluded.contains(n) { return true }
        // Parent match: excluding "example.com" matches "docs.example.com"
        if excluded.contains(where: { n == $0 || n.hasSuffix(".\($0)") }) {
            return true
        }
        // Banks category: match full catalog dynamically (do not materialize 4k domains in UD).
        if banksCategoryEnabled {
            let banks = ExclusionCatalog.bankDomains
            if banks.contains(n) { return true }
            if banks.contains(where: { n == $0 || n.hasSuffix(".\($0)") }) {
                return true
            }
        }
        return false
    }

    /// Whether a browser preflight can prevent otherwise wasted capture work.
    /// Category domains are evaluated lazily and are not copied into defaults.
    public var hasWebsiteExclusions: Bool {
        lock.lock()
        let hasExplicitDomains = !domains.isEmpty
        lock.unlock()
        return hasExplicitDomains || banksCategoryEnabled
    }

    /// Whether the built-in bank-domain exclusion category is enabled.
    public var banksCategoryEnabled: Bool {
        get {
            if defaults.object(forKey: ProductPreferenceKey.excludeBanksCategory) != nil {
                return defaults.bool(forKey: ProductPreferenceKey.excludeBanksCategory)
            }
            return false
        }
        set {
            defaults.set(newValue, forKey: ProductPreferenceKey.excludeBanksCategory)
        }
    }

    /// Whether Password Managers category is on.
    public var passwordManagersCategoryEnabled: Bool {
        get {
            if defaults.object(forKey: ProductPreferenceKey.excludePasswordManagers) != nil {
                return defaults.bool(forKey: ProductPreferenceKey.excludePasswordManagers)
            }
            return true  // Privacy-first default
        }
        set {
            defaults.set(newValue, forKey: ProductPreferenceKey.excludePasswordManagers)
        }
    }

    // MARK: - Combined

    /// True when capture for this frontmost context should skip storing the image.
    public func isExcluded(bundleID: String?, domain: String?) -> Bool {
        if contains(bundleID) { return true }
        // Password-managers category: also match catalog IDs even if UI only listed installed ones.
        if passwordManagersCategoryEnabled, let bid = bundleID?.lowercased(), !bid.isEmpty {
            if ExclusionCatalog.passwordManagerBundleIDs.contains(bid) { return true }
        }
        if isDomainExcluded(domain) { return true }
        return false
    }

    /// Alias used by `RecordingEngine`.
    public func shouldExclude(bundleID: String?, domain: String?) -> Bool {
        isExcluded(bundleID: bundleID, domain: domain)
    }

    public func clearAll() {
        lock.lock()
        bundles.removeAll()
        domains.removeAll()
        lock.unlock()
        defaults.removeObject(forKey: Self.userDefaultsKey)
        defaults.removeObject(forKey: Self.domainsKey)
    }

}

/// Strict normalization shared by exclusion storage and Settings validation.
public enum DomainExclusionParser {
    public static func normalize(_ raw: String) -> String? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where: { $0.isWhitespace }) else { return nil }

        let hasScheme = input.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
        guard let components = URLComponents(string: hasScheme ? input : "https://\(input)"),
            components.user == nil,
            components.password == nil,
            components.port == nil,
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            var host = components.host?.lowercased(),
            !host.isEmpty
        else { return nil }

        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty, host.count <= 253 else { return nil }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard
            labels.allSatisfy({ label in
                guard !label.isEmpty,
                    label.count <= 63,
                    label.first != "-",
                    label.last != "-"
                else { return false }
                return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            })
        else { return nil }
        return host
    }
}
