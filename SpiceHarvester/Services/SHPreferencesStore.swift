import Foundation
import os

/// Persistence app-level předvoleb (`SHAppPreferences`) do UserDefaults.
/// Analogické `SHServerRegistryStore` / `SHConfigStore`.
final class SHPreferencesStore {
    private enum Keys { static let prefs = "sh.appPreferences" }
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "com.spiceharvester", category: "Preferences")

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> SHAppPreferences {
        guard let data = defaults.data(forKey: Keys.prefs) else { return SHAppPreferences() }
        do { return try SHJSON.decoder().decode(SHAppPreferences.self, from: data) }
        catch {
            log.error("Failed to decode preferences, using defaults: \(error.localizedDescription, privacy: .public)")
            return SHAppPreferences()
        }
    }

    func save(_ prefs: SHAppPreferences) {
        do { defaults.set(try SHJSON.encoder(prettyPrinted: false).encode(prefs), forKey: Keys.prefs) }
        catch { log.error("Failed to encode preferences: \(error.localizedDescription, privacy: .public)") }
    }
}
