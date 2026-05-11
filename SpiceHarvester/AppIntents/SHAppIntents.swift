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
        "Spustí Spice Harvester pipeline. Volitelně přepiš režim a název promptu — vstupní/výstupní složka, server a model se vždy berou z uložené konfigurace aplikace."
    )
    /// Brings the app forward before perform() so the running view-model
    /// observer is alive to receive the ping. Without this, perform() runs
    /// while the app is in the background or terminated and the
    /// NotificationCenter post lands in nowhere.
    static var openAppWhenRun: Bool = true

    @Parameter(
        title: "Režim",
        description: "Volitelné. Pokud zůstane prázdné, použije se režim nastavený v aplikaci."
    )
    var mode: SHExtractionModeIntent?

    @Parameter(
        title: "Název promptu",
        description: "Volitelné. Název souboru z prompt složky (např. lekarska-zprava.md). Pokud zůstane prázdné, použije se aktuálně načtený prompt."
    )
    var promptName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Spustit Spice Harvester") {
            \.$mode
            \.$promptName
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Hand any per-run overrides to the running vm BEFORE we kick
        // off the run. The vm observer applies them onto `config`
        // synchronously (MainActor.assumeIsolated inside the block) so
        // by the time `runAll` reads `config.extractionMode` the new
        // value is in place. Sending an empty userInfo is fine — the
        // observer no-ops when both keys are absent.
        var overrides: [String: Any] = [:]
        if let mode { overrides["mode"] = mode.rawValue }
        if let promptName, !promptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overrides["promptName"] = promptName
        }
        if !overrides.isEmpty {
            NotificationCenter.default.post(
                name: SHIntentNotifications.applyParameters,
                object: nil,
                userInfo: overrides
            )
        }

        // Subscribe to the completion notification BEFORE posting
        // runAll. The continuation closure is invoked synchronously
        // by `withCheckedContinuation`, so the observer is in place
        // before `NotificationCenter.default.post(runAll)` returns —
        // a very fast cache-only run can't finish in the gap.
        // Shortcuts may invoke this intent repeatedly in a workflow,
        // so the observer self-removes inside the resume block.
        let summary: SHRunSummaryPayload = await withCheckedContinuation { cont in
            // Reference-type box so the observer block can read back
            // its own token (assigned right after addObserver returns)
            // without tripping "mutated after capture by sendable
            // closure" — the box is captured by reference; only its
            // single field is mutated, both writes serialized on the
            // main actor.
            let box = SHObserverTokenBox()
            box.token = NotificationCenter.default.addObserver(
                forName: SHIntentNotifications.runDidComplete,
                object: nil,
                queue: .main
            ) { notification in
                if let t = box.token { NotificationCenter.default.removeObserver(t) }
                let info = notification.userInfo ?? [:]
                let payload = SHRunSummaryPayload(
                    outcome: info["outcome"] as? String ?? "unknown",
                    documentCount: info["documentCount"] as? Int ?? 0,
                    csvPath: info["csvPath"] as? String ?? "",
                    statusText: info["statusText"] as? String ?? ""
                )
                cont.resume(returning: payload)
            }
            NotificationCenter.default.post(
                name: SHIntentNotifications.runAll,
                object: nil
            )
        }

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

/// Plain-old struct for the run-summary userInfo dictionary the vm
/// posts. Kept local to the AppIntent file because nobody else needs
/// it — the vm assembles the dict from primitive values and the
/// intent decodes it back out.
private struct SHRunSummaryPayload: Sendable {
    let outcome: String
    let documentCount: Int
    let csvPath: String
    let statusText: String
}

/// Reference-type holder for an `NSObjectProtocol` observer token so a
/// `@Sendable` closure can read the token assigned right after
/// `addObserver` returned. Without the box, capturing a `var token` in
/// the observer's @Sendable closure trips the "mutated after capture"
/// warning. `@unchecked Sendable` is safe here because all reads /
/// writes are serialized on the main actor (the observer registers
/// with `queue: .main` and the assignment happens on the calling
/// MainActor frame inside `perform`).
private final class SHObserverTokenBox: @unchecked Sendable {
    var token: NSObjectProtocol?
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
    /// Posted by the intent BEFORE `runAll`. UserInfo carries any
    /// per-run overrides (`mode`, `promptName`). The vm observer
    /// applies them onto `config` so the next runAll picks them up.
    /// Absent keys = use the value already in `config`.
    static let applyParameters = Notification.Name("DavidMasin.SpiceHarvester.intents.applyParameters")
    /// Posted by the vm after `executeRun` settles. UserInfo:
    ///   - `outcome` (String): "success" / "cancelled" / "failed" / "notStarted"
    ///   - `documentCount` (Int): number of documents in the latest extraction result set
    ///   - `csvPath` (String): absolute path to `results.csv`, or "" if none was written
    ///   - `statusText` (String): the user-visible status line at the moment of completion
    static let runDidComplete = Notification.Name("DavidMasin.SpiceHarvester.intents.runDidComplete")
}
