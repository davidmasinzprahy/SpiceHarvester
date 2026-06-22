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
///   has no reference to the live `SHDocumentViewModel`. Using NotificationCenter
///   keeps the dependency one-way (intent → vm) without forcing the
///   view-model to expose a global singleton or hooking into SwiftUI's
///   environment from outside the SwiftUI graph.

/// Shortcuts-facing mirror of `SHExtractionMode`. `AppEnum` is required for
/// `@Parameter` of an enum type — the Shortcuts editor renders a picker with
/// the case display names below. Raw values match `SHExtractionMode.rawValue`
/// so the vm observer can hydrate without a switch.
@available(macOS 13.0, *)
enum SHExtractionModeIntent: String, AppEnum {
    case fast
    case search
    case consolidate

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Režim extrakce")
    }

    static var caseDisplayRepresentations: [SHExtractionModeIntent: DisplayRepresentation] {
        [
            .fast: DisplayRepresentation(title: "FAST — rychlý, bez vyhledávání"),
            .search: DisplayRepresentation(title: "SEARCH — RAG (embedding + reranker)"),
            .consolidate: DisplayRepresentation(title: "CONSOLIDATE — vše do jednoho požadavku")
        ]
    }
}

@available(macOS 13.0, *)
struct RunSpiceHarvesterIntent: AppIntent {
    static var title: LocalizedStringResource = "Spustit extrakci"
    static var description = IntentDescription(
        "Spustí Spice Harvester pipeline. Volitelně přepiš režim, název promptu a cílovou záložku (podle vstupní složky). Vstupní/výstupní složka, server a model se vždy berou z uložené konfigurace dané záložky."
    )
    /// Brings the app forward before perform() so the user can see
    /// the run progress. Even though we now route via direct method
    /// call (not a NotificationCenter post that needs a live
    /// observer), keeping the app foregrounded matches user
    /// expectation and gives the vm a window to render into.
    static var openAppWhenRun: Bool = true

    @Parameter(
        title: "Režim",
        description: "Volitelné. Pokud zůstane prázdné, použije se režim nastavený v cílové záložce."
    )
    var mode: SHExtractionModeIntent?

    @Parameter(
        title: "Název promptu",
        description: "Volitelné. Název souboru z prompt složky (např. lekarska-zprava.md). Pokud zůstane prázdné, použije se aktuálně načtený prompt."
    )
    var promptName: String?

    @Parameter(
        title: "Cílová záložka (vstupní složka)",
        description: "Volitelné. Název vstupní složky té záložky, ve které se má extrakce spustit (např. EmbolieTesty). Pokud zůstane prázdné, spustí se v hlavní záložce."
    )
    var targetFolder: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Spustit Spice Harvester") {
            \.$mode
            \.$promptName
            \.$targetFolder
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Direct call on the resolved target vm — replaces the older
        // three-notification dance (applyParameters / runAll /
        // runDidComplete) which had cross-tab race conditions when
        // multiple windows were open. `runFromIntent` finds the right
        // vm by `targetFolder` (or falls back to primary), applies
        // overrides, awaits the run, restores overrides, returns
        // the summary.
        let summary = await SHDocumentViewModel.runFromIntent(
            targetFolder: targetFolder,
            mode: mode?.rawValue,
            promptName: promptName
        )

        // Two distinct return facets:
        //   - `value`: the path of the produced CSV (or short status
        //     when no CSV was written) so the next Shortcuts action
        //     can read the file / attach it / pipe it elsewhere.
        //   - `dialog`: human-readable summary spoken by Siri /
        //     displayed in Shortcuts' run banner.
        let returnValue: String = summary.csvPath.isEmpty
            ? "\(summary.outcome) · \(summary.documentCount)"
            : summary.csvPath
        let dialogText: String
        switch summary.outcome {
        case "success":
            dialogText = summary.csvPath.isEmpty
                ? "Spice Harvester: hotovo, žádné dokumenty"
                : "Spice Harvester: hotovo · \(summary.documentCount) dokumentů → \(summary.csvPath)"
        case "cancelled":
            dialogText = "Spice Harvester: přerušeno (\(summary.documentCount) dokumentů zpracováno)"
        case "failed":
            dialogText = "Spice Harvester: selhalo · \(summary.statusText)"
        case "notStarted":
            dialogText = "Spice Harvester: nespuštěno · \(summary.statusText)"
        default:
            dialogText = "Spice Harvester: \(summary.outcome)"
        }

        return .result(
            value: returnValue,
            dialog: IntentDialog(stringLiteral: dialogText)
        )
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
/// runs without view-model access) and the running SHDocumentViewModel observer.
///
/// **Only `openOutput` remains** — `RunSpiceHarvesterIntent` was
/// refactored to call `SHDocumentViewModel.runFromIntent` directly via the
/// process-wide vm registry, which is more robust than broadcasting
/// (no multi-vm race on the same notification, target tab is picked
/// by `inputFolder` name rather than the unconditional `.persistent`
/// fallback). `openOutput` stays because `SHAppDelegate`'s notification
/// action callback has no direct vm reference.
enum SHIntentNotifications {
    static let openOutput = Notification.Name("DavidMasin.SpiceHarvester.intents.openOutput")
}
