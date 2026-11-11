import Foundation

/// Remembers each app's volume by app key (bundle ID or `path:<executable>`),
/// plus the app pinned for the "pinned app" shortcuts.
@MainActor
final class SettingsStore {
    static let volumesKey = "volumes.v1"
    static let pinnedKey = "pinnedAppKey"

    private let defaults: UserDefaults
    private var volumes: [String: AppVolume]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.dictionary(forKey: Self.volumesKey) as? [String: Data] ?? [:]
        volumes = raw.compactMapValues { try? JSONDecoder().decode(AppVolume.self, from: $0) }
    }

    func volume(for key: String) -> AppVolume {
        volumes[key] ?? AppVolume()
    }

    func setVolume(_ volume: AppVolume, for key: String) {
        if volume == AppVolume() {
            volumes.removeValue(forKey: key)
        } else {
            volumes[key] = volume
        }
        save()
    }

    var pinnedAppKey: String? {
        get { defaults.string(forKey: Self.pinnedKey) }
        set { defaults.set(newValue, forKey: Self.pinnedKey) }
    }

    func resetAllVolumes() {
        volumes.removeAll()
        save()
    }

    private func save() {
        let raw = volumes.compactMapValues { try? JSONEncoder().encode($0) }
        defaults.set(raw, forKey: Self.volumesKey)
    }
}
