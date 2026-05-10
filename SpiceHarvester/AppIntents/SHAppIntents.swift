import Foundation
import AppKit
import AppIntents

/// AppIntents bridge for Shortcuts.app, Spotlight and Siri integration. Each
/// intent is a stateless verb that opens the app (so we have a window context
/// for UI-driven side effects) and posts a `NotificationCenter` ping which the
/// running view-model picks up.
///
/// Why notifications and not direct calls?
///   `AppIntent.perform()` runs from a fresh actor context; the intent type
///   has no reference to the live `SHAppViewModel`. Using NotificationCenter
///   keeps the dependency one-way (intent → vm) without forcing the
///   view-model to expose a global singleton or hooking into SwiftUI's
///   environment from outside the SwiftUI graph.
@available(macOS 13.0, *)
struct RunSpiceHarvesterIntent: AppIntent {
    static var title: LocalizedStringResource = "Spustit extrakci"
    static var description = IntentDescription(
        "Spustí Spice Harvester pipeline s aktuálně uloženou konfigurací (vstupní složka + server + prompt)."
    )
    /// Brings the app forward before perform() so the running view-model
    /// observer is alive to receive the ping. Without this, perform() runs
    /// while the app is in the background or terminated and the
    /// NotificationCenter post lands in nowhere.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: SHIntentNotifications.runAll,
            object: nil
        )
        return .result()
    }
}

/// Mirrors the Output toolbar button — handy from Shortcuts when chaining
/// Spice Harvester output into another action (e.g. "extract → upload to
/// Drive → notify on Slack").
@available(macOS 13.0, *)
struct OpenOutputFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Otevřít výstupní složku"
    static var description = IntentDescription(
        "Otevře aktuálně nastavenou výstupní složku ve Finderu."
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: SHIntentNotifications.openOutput,
            object: nil
        )
        return .result()
    }
}

/// Registers the intents with Shortcuts so they appear in the gallery and as
/// suggestions in Spotlight. macOS 14+ also surfaces `phrases` to Siri.
@available(macOS 13.0, *)
struct SpiceHarvesterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunSpiceHarvesterIntent(),
            phrases: [
                "Spusť \(.applicationName)",
                "Spusť extrakci v \(.applicationName)",
                "Run \(.applicationName)",
                "Extract with \(.applicationName)"
            ],
            shortTitle: "Spustit extrakci",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: OpenOutputFolderIntent(),
            phrases: [
                "Otevři výstup \(.applicationName)",
                "Open output of \(.applicationName)"
            ],
            shortTitle: "Otevřít výstup",
            systemImageName: "folder"
        )
    }
}

/// Notification names used as the bridge between AppIntent.perform() (which
/// runs without view-model access) and the running SHAppViewModel observer.
/// Keeping them in one place so the producer (intent) and consumer (vm)
/// agree on the contract without a circular import.
enum SHIntentNotifications {
    static let runAll = Notification.Name("DavidMasin.SpiceHarvester.intents.runAll")
    static let openOutput = Notification.Name("DavidMasin.SpiceHarvester.intents.openOutput")
}
