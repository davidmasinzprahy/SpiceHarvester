import Foundation
import Security

/// Abstrakce nad úložištěm API klíčů — kvůli testovatelnosti (reálný Keychain
/// by v testech mohl vyvolat systémové prompty / být nedostupný).
protocol SHAPIKeyStoring: Sendable {
    /// Uloží klíč pro daný server. Prázdný klíč znamená „smazat".
    func store(apiKey: String, for serverID: UUID)
    /// Vrátí uložený klíč nebo `nil`, pokud žádný není.
    func loadAPIKey(for serverID: UUID) -> String?
    /// Smaže klíč pro daný server (no-op, pokud neexistuje).
    func remove(for serverID: UUID)
}

/// Per-app Keychain (generic password) úložiště API klíčů. Sandboxovaná aplikace
/// bez `keychain-access-groups` používá svůj vlastní bucket — funguje OOTB bez
/// extra entitlementu. Účet = `serverID.uuidString`, service = konstantní.
///
/// Nahrazuje dřívější plaintext uložení klíče v UserDefaults (viz
/// `docs/P2_BACKLOG_DEFERRED.md`).
struct SHKeychain: SHAPIKeyStoring {
    var service = "DavidMasin.SpiceHarvester.apiKey"

    func store(apiKey: String, for serverID: UUID) {
        // Prázdný klíč nedrž v Keychainu — uklidíme případný starý záznam.
        guard !apiKey.isEmpty else { remove(for: serverID); return }

        let data = Data(apiKey.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString
        ]
        // Nejdřív zkus update existujícího; když nic není, přidej.
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func loadAPIKey(for serverID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    func remove(for serverID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
