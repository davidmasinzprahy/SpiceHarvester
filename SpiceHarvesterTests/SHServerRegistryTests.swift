import Testing
import Foundation
@testable import SpiceHarvester

/// In-memory náhrada Keychainu pro testy — žádné systémové prompty.
final class InMemoryAPIKeyStore: SHAPIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func store(apiKey: String, for serverID: UUID) {
        lock.withLock {
            if apiKey.isEmpty { storage[serverID] = nil } else { storage[serverID] = apiKey }
        }
    }
    func loadAPIKey(for serverID: UUID) -> String? {
        lock.withLock { storage[serverID] }
    }
    func remove(for serverID: UUID) {
        lock.withLock { _ = storage.removeValue(forKey: serverID) }
    }
    var count: Int { lock.withLock { storage.count } }
}

struct SHServerRegistryTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-registry-\(UUID().uuidString)")!
    }

    @Test func apiKeyGoesToKeychainNotPlaintextAndRoundtrips() {
        let defaults = freshDefaults()
        let keys = InMemoryAPIKeyStore()
        let store = SHServerRegistryStore(defaults: defaults, keyStore: keys)

        var server = SHServerConfig(name: "Proxy", baseURL: "https://x/v1", apiKey: "SECRET123")
        store.saveServers([server])

        // Plaintext klíč nesmí být v UserDefaults blobu.
        let raw = defaults.data(forKey: "sh.serverRegistry")!
        let json = String(data: raw, encoding: .utf8)!
        #expect(!json.contains("SECRET123"))
        // Ale je v key store a hydratuje se zpět při loadu.
        #expect(keys.loadAPIKey(for: server.id) == "SECRET123")
        let loaded = store.loadServers()
        #expect(loaded.first?.apiKey == "SECRET123")

        // Vyprázdnění klíče ho z key store smaže.
        server.apiKey = ""
        store.saveServers([server])
        #expect(keys.loadAPIKey(for: server.id) == nil)
    }

    @Test func migratesLegacyPlaintextKeyAndStripsIt() throws {
        let defaults = freshDefaults()
        let keys = InMemoryAPIKeyStore()
        let id = UUID()
        // Starý formát: apiKey ještě v JSONu.
        let legacy = """
        [{"id":"\(id.uuidString)","name":"S","baseURL":"http://x/v1","apiKey":"LEGACY999"}]
        """
        defaults.set(Data(legacy.utf8), forKey: "sh.serverRegistry")

        let store = SHServerRegistryStore(defaults: defaults, keyStore: keys)
        let loaded = store.loadServers()

        // Klíč se zmigroval do key store i na vrácený model.
        #expect(keys.loadAPIKey(for: id) == "LEGACY999")
        #expect(loaded.first?.apiKey == "LEGACY999")
        // UserDefaults blob už plaintext klíč neobsahuje (přepsán).
        let rewritten = String(data: defaults.data(forKey: "sh.serverRegistry")!, encoding: .utf8)!
        #expect(!rewritten.contains("LEGACY999"))
    }

    @Test func removeAPIKeyClearsKeychainEntry() {
        let defaults = freshDefaults()
        let keys = InMemoryAPIKeyStore()
        let store = SHServerRegistryStore(defaults: defaults, keyStore: keys)

        let server = SHServerConfig(name: "S", baseURL: "http://x/v1", apiKey: "K")
        store.saveServers([server])
        #expect(keys.count == 1)

        store.removeAPIKey(for: server.id)
        #expect(keys.loadAPIKey(for: server.id) == nil)
    }
}
