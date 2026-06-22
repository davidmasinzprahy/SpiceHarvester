import Foundation

/// App-level stav sdílený přes všechna okna/dokumenty. V document-based
/// architektuře (DocumentGroup) se vytvoří jednou v `SpiceHarvesterApp` a
/// injektuje do scén; `SHDocumentViewModel` k němu drží referenci.
///
/// Fáze 2: zatím vlastní **server registr** (nejjasnější „global" koncept —
/// servery jsou per-installation, ne per-projekt). Recents, služby a app prefs
/// se sem přesunou v navazujících krocích refactoru.
@MainActor
@Observable
final class SHGlobalState {
    /// Registr lokálních/LAN AI serverů (sdílený). Klíče jsou v Keychainu
    /// (viz `SHServerRegistryStore` / `SHKeychain`).
    var servers: [SHServerConfig]
    /// ID serveru, který naposledy prošel ověřením (`Ověřit server`).
    var verifiedServerID: UUID?
    /// Zda je ověřený server stále dosažitelný (ambient health watcher).
    var isVerifiedServerReachable: Bool = true

    /// App-level předvolby (Settings, Cmd+,) — sdílené přes všechny projekty
    /// (rozhodnutí A). Persistované přes `SHPreferencesStore`.
    var prefs: SHAppPreferences

    let serverStore: SHServerRegistryStore
    private let prefsStore: SHPreferencesStore

    init(serverStore: SHServerRegistryStore = SHServerRegistryStore(),
         prefsStore: SHPreferencesStore = SHPreferencesStore()) {
        self.serverStore = serverStore
        self.prefsStore = prefsStore
        self.servers = serverStore.loadServers()
        // Jednorázová migrace prefs z legacy `SHConfigStore` (před DocumentGroup
        // žily app prefs v `SHAppConfig`). Stará app stejně mazala folders/modely
        // při startu, takže obsah dokumentu se nemigruje — jen prefs.
        if prefsStore.hasSaved {
            self.prefs = prefsStore.load()
        } else {
            self.prefs = SHMigration.split(SHConfigStore().load()).prefs
            prefsStore.save(self.prefs)
        }
    }

    /// Uloží aktuální předvolby. Volá se z VM persistence (persistAll/Debounced).
    func savePreferences() {
        prefsStore.save(prefs)
    }
}
