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

    let serverStore: SHServerRegistryStore

    init(serverStore: SHServerRegistryStore = SHServerRegistryStore()) {
        self.serverStore = serverStore
        self.servers = serverStore.loadServers()
    }
}
