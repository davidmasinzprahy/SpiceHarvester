import Foundation
import os

final class SHConfigStore {
    private enum Keys {
        static let appConfig = "sh.appConfig"
    }

    private let defaults: UserDefaults
    private let log = Logger(subsystem: "com.spiceharvester", category: "ConfigStore")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SHAppConfig {
        guard let data = defaults.data(forKey: Keys.appConfig) else {
            return SHAppConfig()
        }
        do {
            return try SHJSON.decoder().decode(SHAppConfig.self, from: data)
        } catch {
            // Don't silently swallow – when a new field is added without a migration
            // the user would otherwise lose their config with no diagnostic.
            log.error("Failed to decode SHAppConfig, using defaults: \(error.localizedDescription, privacy: .public)")
            return SHAppConfig()
        }
    }

    func save(_ config: SHAppConfig) {
        do {
            let data = try SHJSON.encoder(prettyPrinted: false).encode(config)
            defaults.set(data, forKey: Keys.appConfig)
        } catch {
            log.error("Failed to encode SHAppConfig: \(error.localizedDescription, privacy: .public)")
        }
    }
}
