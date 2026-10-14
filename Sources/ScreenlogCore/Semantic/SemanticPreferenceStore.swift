import Foundation

public enum SemanticPreferenceStore {
    public struct Snapshot: Equatable, Sendable {
        public var enabled: Bool
        public var mode: SemanticSearchMode

        public init(enabled: Bool = false, mode: SemanticSearchMode = .images) {
            self.enabled = enabled
            self.mode = mode
        }
    }

    public static func load(from defaults: UserDefaults = ScreenlogProcessPreferences.current) -> Snapshot {
        Snapshot(
            enabled: defaults.bool(forKey: ProductPreferenceKey.semanticSearchEnabled),
            mode: defaults.string(forKey: ProductPreferenceKey.semanticSearchMode)
                .flatMap(SemanticSearchMode.init(rawValue:)) ?? .images
        )
    }

    public static func save(_ snapshot: Snapshot, to defaults: UserDefaults = ScreenlogProcessPreferences.current) {
        defaults.set(snapshot.enabled, forKey: ProductPreferenceKey.semanticSearchEnabled)
        defaults.set(snapshot.mode.rawValue, forKey: ProductPreferenceKey.semanticSearchMode)
    }
}
