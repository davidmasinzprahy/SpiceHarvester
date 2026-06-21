import Foundation
import os

final class SHServerRegistryStore {
    private enum Keys {
        static let servers = "sh.serverRegistry"
    }

    private let defaults: UserDefaults
    private let keyStore: SHAPIKeyStoring
    private let log = Logger(subsystem: "com.spiceharvester", category: "ServerRegistry")

    init(defaults: UserDefaults = .standard, keyStore: SHAPIKeyStoring = SHKeychain()) {
        self.defaults = defaults
        self.keyStore = keyStore
    }

    func loadServers() -> [SHServerConfig] {
        guard let data = defaults.data(forKey: Keys.servers) else {
            return defaultServers
        }
        do {
            var servers = try SHJSON.decoder().decode([SHServerConfig].self, from: data)
            // Jednorázová migrace: starý blob měl `apiKey` v JSONu (plaintext).
            // Přesuň ho do Keychainu a UserDefaults přepiš bez plaintext klíčů.
            let migrated = migrateLegacyPlaintextKeys(from: data)
            // Dohydratuj klíče z Keychainu (apiKey není v Codable, takže je "").
            for i in servers.indices {
                servers[i].apiKey = keyStore.loadAPIKey(for: servers[i].id) ?? ""
            }
            if migrated {
                saveServers(servers)
            }
            return servers
        } catch {
            log.error("Failed to decode server registry, using defaults: \(error.localizedDescription, privacy: .public)")
            return defaultServers
        }
    }

    func saveServers(_ servers: [SHServerConfig]) {
        // `apiKey` je mimo Codable → do UserDefaults jdou jen ne-tajná pole.
        do {
            let data = try SHJSON.encoder(prettyPrinted: false).encode(servers)
            defaults.set(data, forKey: Keys.servers)
        } catch {
            log.error("Failed to encode server registry: \(error.localizedDescription, privacy: .public)")
        }
        // Klíče zvlášť do Keychainu (prázdný klíč se tam smaže).
        for server in servers {
            keyStore.store(apiKey: server.apiKey, for: server.id)
        }
    }

    /// Smaže Keychain klíč odebraného serveru, ať nezůstávají osiřelé záznamy.
    func removeAPIKey(for serverID: UUID) {
        keyStore.remove(for: serverID)
    }

    /// Z legacy JSON blobu (kde `apiKey` byl ještě součástí) přesune neprázdné
    /// klíče do Keychainu. Vrací `true`, pokud se něco zmigrovalo (volající pak
    /// přepíše UserDefaults bez plaintext klíčů). Existující Keychain hodnotu
    /// nepřepisuje — bezpečné při opakování i po pádu uprostřed migrace.
    private func migrateLegacyPlaintextKeys(from data: Data) -> Bool {
        guard let legacy = try? SHJSON.decoder().decode([LegacyServerKey].self, from: data) else {
            return false
        }
        var migratedAny = false
        for entry in legacy {
            guard let key = entry.apiKey, !key.isEmpty else { continue }
            if keyStore.loadAPIKey(for: entry.id) == nil {
                keyStore.store(apiKey: key, for: entry.id)
                migratedAny = true
            }
        }
        return migratedAny
    }

    /// Minimalistický tvar pro čtení legacy `apiKey` ze starého blobu.
    private struct LegacyServerKey: Decodable {
        let id: UUID
        let apiKey: String?
    }

    private var defaultServers: [SHServerConfig] {
        [
            SHServerConfig(name: "Local LM Studio", baseURL: "http://localhost:1234/v1", apiKey: ""),
            SHServerConfig(name: "Local MLX", baseURL: "http://localhost:8000/v1", apiKey: "")
        ]
    }
}
