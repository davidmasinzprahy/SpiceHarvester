//
//  SpiceHarvesterApp.swift
//  SpiceHarvester
//
//  Created by David Mašín on 22.06.2025.
//

import SwiftUI
import AppKit
import UserNotifications

/// Published by every ContentView so menu commands operating on the
/// view-model (Otevřít projekt, Uložit projekt, Otevřít nedávné…)
/// can target the currently-focused window's vm rather than always
/// the primary's. Without this routing, Open Recent in a scratch
/// window would silently load the project into primary.
struct FocusedViewModelKey: FocusedValueKey {
    typealias Value = SHDocumentViewModel
}

extension FocusedValues {
    var focusedViewModel: SHDocumentViewModel? {
        get { self[FocusedViewModelKey.self] }
        set { self[FocusedViewModelKey.self] = newValue }
    }
}

@main
struct SpiceHarvesterApp: App {
    @NSApplicationDelegateAdaptor(SHAppDelegate.self) var appDelegate
    /// App-level sdílený stav (server registr, prefs, recents, služby). Jedna
    /// instance pro celou appku, injektovaná do každého document okna i do Settings.
    @State private var global = SHGlobalState()
    /// Resolves to the focused window's view-model (primary or scratch).
    /// Menu commands route through this so project ops act on the
    /// expected window. Falls back to the App-level `vm` (primary) when
    /// nothing is focused yet (e.g. at app launch before any window
    /// has come to front).
    @FocusedValue(\.focusedViewModel) private var focusedVM
    /// Environment hook to open the secondary "scratch" window from menu
    /// commands. Only available macOS 13+, which is below our deployment
    /// target so no @available guard needed.
    @Environment(\.openWindow) private var openWindow

    /// View-model that menu commands should operate on — focused window
    /// when one is up, primary as fallback. Centralised so every menu
    /// item uses the same routing without scattering ternaries.
    /// V document-based appce není „primary" okno — menu commands cílí na
    /// zaměřený dokument. `nil`, když není v popředí žádné document okno
    /// (např. Settings/Help). Commands se pak vypnou.
    private var targetVM: SHDocumentViewModel? { focusedVM }


    var body: some Scene {
        DocumentGroup(newDocument: { SHProjectDocument() }) { configuration in
            ContentView(document: configuration.document, global: global)
        }
        .commands {
            // ┌──────────────────────────────────────────────────────────┐
            // │ File menu — purely document / project operations.        │
            // │ Run/Stop and mode switching moved to dedicated Pipeline  │
            // │ menu below (matches Xcode/Logic/Final Cut convention for │
            // │ process-driven apps).                                    │
            // └──────────────────────────────────────────────────────────┘

            // New / Open / Open Recent / Save / Save As / Duplicate / Rename
            // dodává nativně DocumentGroup. Zůstávají jen app-specifické akce.
            CommandGroup(after: .saveItem) {
                Button("Otevřít výsledek...") {
                    _ = targetVM?.openSpiceResultFile()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(targetVM == nil || targetVM?.isRunning == true || targetVM?.loadedResult != nil)

                Button("Otevřít výstup ve Finderu") {
                    targetVM?.openOutput()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(targetVM?.canOpenOutput != true)
            }

            // ┌──────────────────────────────────────────────────────────┐
            // │ Pipeline menu — top-level menu for all run / stop /      │
            // │ mode / server actions. CommandMenu adds a custom menu    │
            // │ between Edit/View and Window in macOS native menu bar.   │
            // │ Actions route through `targetVM` so a scratch window in  │
            // │ focus controls its own pipeline, not the primary's.      │
            // └──────────────────────────────────────────────────────────┘
            CommandMenu("Pipeline") {
                Button("Spustit") {
                    Task { await targetVM?.runAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(targetVM?.canRunAll != true || targetVM?.isRunning == true || targetVM?.loadedResult != nil)

                Button("Přerušit") {
                    targetVM?.cancelRun()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(targetVM?.isRunning != true)

                Divider()

                Button("Předzpracování") {
                    Task { await targetVM?.runPreprocessing() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(targetVM?.canRunPreprocessing != true || targetVM?.isRunning == true || targetVM?.loadedResult != nil)

                Button("Extrakce") {
                    Task { await targetVM?.runExtraction() }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(targetVM?.canRunExtraction != true || targetVM?.isRunning == true || targetVM?.loadedResult != nil)

                Divider()

                // Cache je per-projekt → akce patří k zaměřenému dokumentu, ne do
                // app-level Settings (proto přesunuto sem z Cache tabu).
                Button("Vyčistit cache") {
                    Task { await targetVM?.clearCache() }
                }
                .disabled(targetVM == nil || targetVM?.isRunning == true)

                Divider()

                // Režim extrakce zkratky. `focusedVM == nil` vypne Cmd+1/2/3,
                // když je v popředí Settings/Help (nepublikují focusedViewModel).
                Button("Režim FAST") { targetVM?.config.extractionMode = .fast }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(focusedVM == nil || targetVM?.isRunning == true || targetVM?.loadedResult != nil)
                Button("Režim SEARCH") { targetVM?.config.extractionMode = .search }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(focusedVM == nil || targetVM?.isRunning == true || targetVM?.loadedResult != nil)
                Button("Režim CONSOLIDATE") { targetVM?.config.extractionMode = .consolidate }
                    .keyboardShortcut("3", modifiers: .command)
                    .disabled(focusedVM == nil || targetVM?.isRunning == true || targetVM?.loadedResult != nil)

                Divider()

                Button("Znovu ověřit zdraví serveru") {
                    Task { await targetVM?.recheckServerNow() }
                }
                .disabled(targetVM?.isSelectedServerVerified != true || targetVM?.isRunning == true)
            }

            CommandGroup(replacing: .help) {
                Button("Nápověda Spice Harvester") {
                    // Help lives in its own WindowGroup so the macOS
                    // window manager treats it as a standalone window
                    // — when the user has tabbed multiple
                    // SpiceHarvester windows together, a sheet would
                    // attach to the shared parent NSWindow and bleed
                    // into every tab. A separate window also gives
                    // the user the option to keep help open
                    // side-by-side while working.
                    openWindow(id: "help")
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        // Settings je app-level (Cmd+,) — binduje na sdílený `global` (prefs).
        // Per-projekt akce (Vyčistit cache) jsou v Pipeline menu, ne tady.
        Settings {
            SettingsView(global: global)
        }

        // Help window — `Window` (not `WindowGroup`) because Help is
        // semantically a singleton: pressing Cmd+? twice should
        // focus the existing window, not spawn a second one.
        // `WindowGroup` even with an id: parameter still permits
        // multiple instances when openWindow fires repeatedly,
        // which would leave the user with stacked duplicate help
        // windows. `Window` scene auto-focuses the existing
        // instance on `openWindow(id:)`. Also a Window scene
        // doesn't merge into tabbed-window groups (different
        // window class), so Help is truly independent.
        Window("Nápověda Spice Harvester", id: "help") {
            HelpWindowView()
        }
        .defaultSize(width: 760, height: 720)
    }
}

/// Adapts the main window on launch. Height always uses the full available
/// work area so the app avoids an initial vertical scrollbar whenever the
/// current display has enough room; on large screens only the width is capped
/// to the UI's natural working size.
/// User-facing alert for the `openProject` outcomes that need
/// explanation. `success` and `cancelled` paths fall through silently
/// (statusBar already carries the success message). The "needs repick"
/// case is the important one: project file holds path strings but the
/// sandbox bookmarks for those paths weren't in the registry, so the
/// user must re-Vybrat them via the folder rows before Run will work.
@MainActor
extension SHAppDelegate {
    static func handleOpenProjectOutcome(_ outcome: SHOpenProjectOutcome) {
        switch outcome {
        case .success, .cancelled:
            return
        case .successNeedsRepick(_, let stalePaths):
            let alert = NSAlert()
            alert.messageText = "Projekt načten — některé složky vyžadují opětovný výběr"
            alert.informativeText = """
            macOS sandbox vyžaduje, abys cesty z projektu znovu vybral přes tlačítko „Vybrat" u každé složky. Bez toho aplikace nedostane přístup k souborům.

            Cesty bez přístupu:
            \(stalePaths.map { "• \($0)" }.joined(separator: "\n"))
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Rozumím")
            alert.runModal()
        case .failed(let error):
            let alert = NSAlert(error: error)
            alert.messageText = "Otevření projektu selhalo"
            alert.runModal()
        }
    }
}

final class SHAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let compactPreferredWidth: CGFloat = 1200
    private let largePreferredWidth: CGFloat = 1320
    private let largeScreenWidthThreshold: CGFloat = 1440
    private let largeScreenHeightThreshold: CGFloat = 1100
    /// AppKit's autosave key for the main window frame. Once a frame has
    /// been written under this name (Cocoa stores it in NSGlobalDomain
    /// under `NSWindow Frame {key}`), `setFrameUsingName` restores it on
    /// future launches — so the user's manual resize / move sticks.
    private let mainWindowAutosaveName = "SpiceHarvesterMainWindow"
    /// Pointer to the primary window's view-model, set once in
    /// `applicationDidFinishLaunching` so delegate methods like
    /// `application(_:openURLs:)` can access it.
    weak var primaryViewModel: SHDocumentViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Become the notification delegate so we can respond to action
        // buttons ("Otevřít výstup") on completion notifications. Without
        // a delegate, the notification UI shows but tapping the action
        // is a no-op.
        UNUserNotificationCenter.current().delegate = self

        // Register completion category + request authorization once per
        // process. Previously this lived in SHDocumentViewModel.init which
        // re-fired for every scratch window the user opened — wasteful
        // and (with macOS' rate-limited prompt) potentially user-visible.
        registerCompletionNotificationCategory()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Intentionally ignored — denied auth degrades to in-app
            // banner only, which is fine.
        }

        // SwiftUI creates its window slightly after `applicationDidFinishLaunching`;
        // hop one run loop tick so `NSApp.mainWindow` / `NSApp.windows` is populated.
        DispatchQueue.main.async { [weak self] in
            self?.resizeMainWindowForCurrentScreen()
        }
    }

    /// Defines the "completion" notification category so banners posted
    /// from `SHDocumentViewModel.postCompletionNotification` carry the
    /// "Otevřít výstup" action button. Categories must be registered
    /// before any notification using them is posted; doing this once
    /// in app launch covers every subsequent post.
    private func registerCompletionNotificationCategory() {
        let openOutputAction = UNNotificationAction(
            identifier: SHCompletionNotification.openOutputActionID,
            title: "Otevřít výstup",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: SHCompletionNotification.categoryID,
            actions: [openOutputAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: – UNUserNotificationCenterDelegate

    /// Show the notification banner even when the app is in the foreground.
    /// Default macOS behavior suppresses banners for the active app — but
    /// for long batch runs the user is often in another app at completion
    /// time and we want consistent UX regardless of focus state.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handle the user clicking the "Otevřít výstup" action button on a
    /// completion notification. Bridge through `SHIntentNotifications`
    /// (already used by AppIntents) so we have one observer hook in the
    /// view-model — no need for a separate UNUserNotificationCenter
    /// observer there.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == SHCompletionNotification.openOutputActionID else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: SHIntentNotifications.openOutput, object: nil)
    }

    @MainActor
    private func resizeMainWindowForCurrentScreen() {
        // Pick the first real app window (`NSApp.mainWindow` isn't always set yet;
        // skip tiny helper windows by requiring a minimum size).
        let window = NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 })
            ?? NSApp.windows.first
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        window.titleVisibility = .hidden

        // Hook the window into AppKit's frame autosave system. After this
        // call, every subsequent move / resize is persisted, and the next
        // launch will read it back automatically. Whether we found a
        // saved frame determines if we apply the first-launch defaults
        // below — re-running our centering logic on every launch would
        // override the user's manual placement.
        let didRestore = window.setFrameUsingName(mainWindowAutosaveName)
        window.setFrameAutosaveName(mainWindowAutosaveName)
        if didRestore {
            return
        }

        let visible = screen.visibleFrame  // excludes menu bar & Dock in Cocoa coordinates

        let isLargeScreen = visible.width >= largeScreenWidthThreshold
            && visible.height >= largeScreenHeightThreshold

        let targetWidth: CGFloat
        if isLargeScreen {
            targetWidth = min(largePreferredWidth, visible.width)
        } else {
            targetWidth = min(max(window.frame.width, compactPreferredWidth), visible.width)
        }
        let targetHeight = visible.height

        // Center horizontally within the visible work area, bottom-aligned so the
        // window uses all vertical space between Dock and menu bar.
        let originX = visible.origin.x + (visible.width - targetWidth) / 2
        let originY = visible.origin.y
        let newFrame = NSRect(
            origin: NSPoint(x: originX, y: originY),
            size: NSSize(width: targetWidth, height: targetHeight)
        )

        window.setFrame(newFrame, display: true, animate: false)
        // Save the first-launch frame immediately so a quick quit-relaunch
        // doesn't lose it (autosave is normally written on resize / close).
        window.saveFrame(usingName: mainWindowAutosaveName)
    }

    // MARK: – Open .spice-result.json from Finder (CFBundleDocumentTypes)

    /// Called when the user opens a registered document type from Finder
    /// (double-click, "Open With"). Routes each URL to the primary view
    /// model so the loaded result appears in the UI.
    ///
    /// This fires regardless of which window (if any) is in front. The
    /// result is pushed into `vm.loadedResult` so it appears in the
    /// primary window's notification bar even if a scratch window was
    /// focused at the time of the open.
    /// Klasifikace souboru otevřeného z Finderu podle koncovky. Čistá funkce
    /// (testovatelná). Matchuje přes `lastPathComponent.hasSuffix` — `pathExtension`
    /// vrací jen `"json"`, takže by dvojité přípony `*.spiceharvester.json` /
    /// `*.spice-result.json` nikdy nesedly.
    nonisolated static func fileKind(for url: URL) -> SHOpenableFile {
        let name = url.lastPathComponent
        if name.hasSuffix(".spiceharvester.json") { return .project }
        if name.hasSuffix(".spice-result.json") { return .result }
        return .unsupported
    }

    func application(_ application: NSApplication, open: [URL]) {
        guard let url = open.first else { return }
        let kind = Self.fileKind(for: url)
        guard kind != .unsupported else { return }
        guard let vm = primaryViewModel else {
            // App is still launching — show an alert so the user knows
            // the open failed rather than silently dropping the file.
            let alert = NSAlert()
            alert.messageText = "Spice Harvester ještě nebyl spuštěn"
            alert.informativeText = "Počkejte na hlavní okno a zkuste otevřít soubor znovu."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        switch kind {
        case .result:
            _ = vm.openSpiceResultFile(url)
        case .project, .unsupported:
            // Projekty (`*.spiceharvester.json`) otevírá nativně DocumentGroup;
            // tady je neřešíme, ať nedojde k dvojímu otevření.
            return
        }
    }
}

/// Typ souboru, který umí aplikace otevřít z Finderu (dvojklik / drag na ikonu).
enum SHOpenableFile: Equatable {
    /// Projektový snapshot `*.spiceharvester.json` (Uložit projekt jako…).
    case project
    /// Per-document výsledek `*.spice-result.json`.
    case result
    /// Neznámý / nepodporovaný soubor — ignorovat.
    case unsupported
}
