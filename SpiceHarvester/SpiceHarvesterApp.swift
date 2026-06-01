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
    typealias Value = SHAppViewModel
}

extension FocusedValues {
    var focusedViewModel: SHAppViewModel? {
        get { self[FocusedViewModelKey.self] }
        set { self[FocusedViewModelKey.self] = newValue }
    }
}

@main
struct SpiceHarvesterApp: App {
    @NSApplicationDelegateAdaptor(SHAppDelegate.self) var appDelegate
    /// Primary window's view-model + help-sheet flag. Settings scene shares
    /// this instance so changes in the Settings sheet (Cmd+,) reflect in the
    /// primary window's runtime state. Secondary scratch windows (Cmd+Shift+N)
    /// have their own per-window view-model so configurations don't fight
    /// over the same UserDefaults slot.
    @State private var vm = SHAppViewModel()
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
    private var targetVM: SHAppViewModel { focusedVM ?? vm }

    /// Compact label for a recent-project URL shown in the
    /// `File → Otevřít nedávné…` submenu. Strips the redundant
    /// `.spiceharvester.json` suffix and tildeifies the parent path so
    /// `~/Documents/medical/foo.spiceharvester.json` reads as
    /// `foo · ~/Documents/medical`. Long composites are truncated with
    /// `…/lastFolder` so macOS doesn't render a 600 pt-wide menu when
    /// the project lives in a deeply-nested external drive path.
    private func recentProjectMenuTitle(_ url: URL) -> String {
        var name = url.lastPathComponent
        if name.hasSuffix(".spiceharvester.json") {
            name = String(name.dropLast(".spiceharvester.json".count))
        } else if name.hasSuffix(".json") {
            name = String(name.dropLast(".json".count))
        }
        let parent = (url.deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath
        let combined = "\(name) · \(parent)"
        guard combined.count > 64 else { return combined }
        // Keep the project name in full, truncate the parent. macOS menu
        // ellipsis convention: `…/lastSegment` preserves the most
        // recognizable component (the project's containing folder).
        let parentURL = URL(fileURLWithPath: parent)
        let lastSegment = parentURL.lastPathComponent
        return "\(name) · …/\(lastSegment)"
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(vm: vm)
                .focusedSceneValue(\.focusedViewModel, vm)
                .onAppear {
                    appDelegate.primaryViewModel = vm
                }
        }
        // `.defaultSize` is the SwiftUI fallback for first-launch dimensions; the
        // AppDelegate below then adapts the actual launch frame to the current screen.
        .defaultSize(width: 1180, height: 980)
        .commands {
            // ┌──────────────────────────────────────────────────────────┐
            // │ File menu — purely document / project operations.        │
            // │ Run/Stop and mode switching moved to dedicated Pipeline  │
            // │ menu below (matches Xcode/Logic/Final Cut convention for │
            // │ process-driven apps).                                    │
            // └──────────────────────────────────────────────────────────┘

            // File → Nové okno + Otevřít projekt (Cmd+N replacement;
            // .newItem default is "New Window" which Spice Harvester
            // doesn't need — we have scratch via Cmd+Shift+N).
            CommandGroup(replacing: .newItem) {
                Button("Nové okno (scratch)") {
                    openWindow(id: "scratch", value: UUID())
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button("Otevřít projekt…") {
                    let outcome = targetVM.openProject()
                    SHAppDelegate.handleOpenProjectOutcome(outcome)
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(targetVM.isRunning)

                // Open Recent submenu — fed by the focused vm's
                // `recentProjectURLs`, written on every saveProjectAs /
                // openProject success. Click → `openProject(at:)`
                // bypasses NSOpenPanel and uses stored security-scoped
                // bookmark so the read succeeds across app restarts.
                Menu("Otevřít nedávné") {
                    ForEach(Array(targetVM.recentProjectURLs.enumerated()), id: \.element) { _, url in
                        Button(recentProjectMenuTitle(url)) {
                            let outcome = targetVM.openProject(at: url)
                            SHAppDelegate.handleOpenProjectOutcome(outcome)
                        }
                        .disabled(targetVM.isRunning)
                    }
                    if !targetVM.recentProjectURLs.isEmpty {
                        Divider()
                        Button("Vyčistit seznam") {
                            targetVM.clearRecentProjects()
                        }
                    }
                }
                .disabled(targetVM.recentProjectURLs.isEmpty)
            }

            // File → Uložit projekt jako… (Cmd+Shift+S, placed after .saveItem)
            CommandGroup(after: .saveItem) {
                Divider()
                Button("Uložit projekt jako…") {
                    _ = targetVM.saveProjectAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(targetVM.isRunning || !targetVM.canSaveProject)

                Button("Otevřít výsledek...") {
                    _ = targetVM.openSpiceResultFile()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(targetVM.isRunning || targetVM.loadedResult != nil)

                Button("Otevřít výstup ve Finderu") {
                    targetVM.openOutput()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!targetVM.canOpenOutput)
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
                    Task { await targetVM.runAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!targetVM.canRunAll || targetVM.isRunning || targetVM.loadedResult != nil)

                Button("Přerušit") {
                    targetVM.cancelRun()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!targetVM.isRunning)

                Divider()

                Button("Předzpracování") {
                    Task { await targetVM.runPreprocessing() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!targetVM.canRunPreprocessing || targetVM.isRunning || targetVM.loadedResult != nil)

                Button("Extrakce") {
                    Task { await targetVM.runExtraction() }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!targetVM.canRunExtraction || targetVM.isRunning || targetVM.loadedResult != nil)

                Divider()

                // Režim extrakce zkratky. Moved from .toolbar placement
                // — mode is pipeline-behavior config, not view state.
                //
                // Gating on `focusedVM == nil` disables Cmd+1/2/3 when
                // the Settings scene is in front (Settings doesn't
                // publish `.focusedViewModel`). Without this, the user
                // could accidentally flip the main window's extraction
                // mode while typing in a Settings text field — the
                // shortcut is bound globally by SwiftUI commands.
                Button("Režim FAST") { targetVM.config.extractionMode = .fast }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(focusedVM == nil || targetVM.isRunning || targetVM.loadedResult != nil)
                Button("Režim SEARCH") { targetVM.config.extractionMode = .search }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(focusedVM == nil || targetVM.isRunning || targetVM.loadedResult != nil)
                Button("Režim CONSOLIDATE") { targetVM.config.extractionMode = .consolidate }
                    .keyboardShortcut("3", modifiers: .command)
                    .disabled(focusedVM == nil || targetVM.isRunning || targetVM.loadedResult != nil)

                Divider()

                // Manual server ping outside the 30 s ambient health
                // watcher loop. Useful right after restarting LM Studio:
                // user clicks Re-check, gets immediate green/red feedback
                // instead of waiting up to 30 s for the next scheduled ping.
                Button("Znovu ověřit zdraví serveru") {
                    Task { await targetVM.recheckServerNow() }
                }
                .disabled(!targetVM.isSelectedServerVerified || targetVM.isRunning)
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

        // Settings sheet is intentionally always bound to the *primary*
        // window's view-model. Performance prefs (concurrency, throttle,
        // request timeout, OCR backend, cache toggle) are app-level
        // global tuning — having Settings follow the focused window
        // would mean scratch windows could silently override those
        // values, surprising the next primary-window run. By design.
        Settings {
            SettingsView(vm: vm)
        }

        // Scratch / secondary window. Each open creates a fresh window
        // with its own ContentView + view-model (see SHScratchRoot)
        // because WindowGroup(for: UUID.self) emits one window per
        // unique value.
        WindowGroup(id: "scratch", for: UUID.self) { _ in
            SHScratchRoot()
        }
        .defaultSize(width: 1180, height: 980)

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

/// Hosts a scratch ContentView with its own view-model. Doesn't persist
/// config back to UserDefaults — see the rationale on the `Nové okno`
/// menu item.
///
/// `@State` initializer is lazy on macOS 14+/iOS 17+ — the
/// `SHAppViewModel(persistenceMode: .scratch)` expression evaluates once
/// per view instance, not on every body recomputation. Our deployment
/// target is macOS 15.6 so this pattern is safe; on older OS versions
/// SwiftUI would re-evaluate the initializer on rebuild and we'd need
/// the `@State var vm: SHAppViewModel?` + `.onAppear` workaround.
struct SHScratchRoot: View {
    @State private var vm = SHAppViewModel(persistenceMode: .scratch)

    var body: some View {
        ContentView(vm: vm)
            // Same routing for project ops: Open Recent / Save Project
            // / Open Project in menu now act on whichever window is
            // focused, not the App-level primary.
            .focusedSceneValue(\.focusedViewModel, vm)
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
    weak var primaryViewModel: SHAppViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Become the notification delegate so we can respond to action
        // buttons ("Otevřít výstup") on completion notifications. Without
        // a delegate, the notification UI shows but tapping the action
        // is a no-op.
        UNUserNotificationCenter.current().delegate = self

        // Register completion category + request authorization once per
        // process. Previously this lived in SHAppViewModel.init which
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
    /// from `SHAppViewModel.postCompletionNotification` carry the
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
    func application(_ application: NSApplication, open: [URL]) {
        guard let url = open.first, !url.pathExtension.isEmpty else { return }
        // Only handle our own UTI — ignore unrelated drops.
        guard url.pathExtension == "spice-result.json" else { return }
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
        _ = vm.openSpiceResultFile(url)
    }
}
