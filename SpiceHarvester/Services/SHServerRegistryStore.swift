import Foundation
import os

final class SHServerRegistryStore {
    private enum Keys {
        static let servers = "sh.serverRegistry"
    }

    private let defaults: UserDefaults
    private let log = Logger(subsystem: "com.spiceharvester", category: "ServerRegistry")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadServers() -> [SHServerConfig] {
        guard let data = defaults.data(forKey: Keys.servers) else {
            return defaultServers
        }
        do {
            return try SHJSON.decoder().decode([SHServerConfig].self, from: data)
        } catch {
            log.error("Failed to decode server registry, using defaults: \(error.localizedDescription, privacy: .public)")
            return defaultServers
        }
    }

    func saveServers(_ servers: [SHServerConfig]) {
        do {
            let data = try SHJSON.encoder(prettyPrinted: false).encode(servers)
            defaults.set(data, forKey: Keys.servers)
        } catch {
            log.error("Failed to encode server registry: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var defaultServers: [SHServerConfig] {
        [
            SHServerConfig(name: "Local LM Studio", baseURL: "http://localhost:1234/v1", apiKey: ""),
            SHServerConfig(name: "Local MLX", baseURL: "http://localhost:8000/v1", apiKey: "")
        ]
    }
}
