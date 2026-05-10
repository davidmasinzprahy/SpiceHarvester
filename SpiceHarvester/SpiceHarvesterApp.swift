//
//  SpiceHarvesterApp.swift
//  SpiceHarvester
//
//  Created by David Mašín on 22.06.2025.
//

import SwiftUI
import AppKit
import UserNotifications

/// `FocusedValueKey` published by every ContentView (primary + scratch).
/// Its value is the binding to that window's `showHelp` flag, so the
/// Help command can toggle the *focused* window's sheet rather than
/// always toggling the primary window's. Without this, Cmd+? from a
/// scratch window opened the primary's help sheet — coordination
/// violation across windows.
struct ShowHelpFocusedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var showHelpBinding: Binding<Bool>? {
        get { self[ShowHelpFocusedKey.self] }
        set { self[ShowHelpFocusedKey.self] = newValue }
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
    @State private var showHelp = false
    /// `@FocusedValue` so the Help command in `.commands` can read the
    /// currently-focused window's help binding. Falls back to primary
    /// `showHelp` when no window publishes a binding (edge case).
    @FocusedValue(\.showHelpBinding) private var focusedShowHelp
    /// Environment hook to open the secondary "scratch" window from menu
    /// commands. Only available macOS 13+, which is below our deployment
    /// target so no @available guard needed.
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(vm: vm, showHelp: $showHelp)
                .focusedSceneValue(\.showHelpBinding, $showHelp)
        }
        // `.defaultSize` is the SwiftUI fallback for first-launch dimensions; the
        // AppDelegate below then adapts the actual launch frame to the current screen.
        .defaultSize(width: 1180, height: 980)
        .commands {
            // Replace the boilerplate "New Window" with the run controls users
            // actually need; Cmd+R / Cmd+. mirror Xcode's run/stop muscle memory.
            CommandGroup(replacing: .newItem) {
                Button("Spustit") {
                    Task { await vm.runAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!vm.canRunAll || vm.isRunning)

                Button("Přerušit") {
                    vm.cancelRun()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!vm.isRunning)

                Divider()

                Button("Předzpracování") {
                    Task { await vm.runPreprocessing() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!vm.canRunPreprocessing || vm.isRunning)

                Button("Extrakce") {
                    Task { await vm.runExtraction() }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!vm.canRunExtraction || vm.isRunning)

                Divider()

                Button("Otevřít výstup") {
                    vm.openOutput()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!vm.canOpenOutput)
            }

            // Režim extrakce zkratky. Cmd+1/2/3 přepínají FAST / SEARCH /
            // CONSOLIDATE bez nutnosti scrollovat na segmented picker. Pro
            // power-usery, kteří iterují prompt s různými režimy, je
            // klikání myší výrazný friction point.
            CommandGroup(after: .toolbar) {
                Button("Režim FAST") {
                    vm.config.extractionMode = .fast
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(vm.isRunning)

                Button("Režim SEARCH") {
                    vm.config.extractionMode = .search
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(vm.isRunning)

                Button("Režim CONSOLIDATE") {
                    vm.config.extractionMode = .consolidate
                }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(vm.isRunning)
            }

            CommandGroup(replacing: .help) {
                Button("Nápověda Spice Harvester") {
                    // Toggle the currently-focused window's help binding
                    // when we have one (multi-window scenario); fall back
                    // to the primary's binding so Cmd+? at app launch
                    // (no window focused yet) still works.
                    if let focusedShowHelp {
                        focusedShowHelp.wrappedValue = true
                    } else {
                        showHelp = true
                    }
                }
                .keyboardShortcut("?", modifiers: .command)
            }

            // File → Save / Open project: pragmatic stand-in for full
            // DocumentGroup migration. Saves a JSON snapshot of folders +
            // server selection + prompt + mode; loading restores those
            // fields without disturbing global server registry or perf
            // tuning. See `SHAppViewModel.SHProjectSnapshot`.
            CommandGroup(after: .saveItem) {
                Divider()
                Button("Uložit projekt jako…") {
                    _ = vm.saveProjectAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                // Saving an empty project (no folders, no prompt) yields
                // a JSON file with just empty strings — useless to the
                // user. Require at least input + output set, or a prompt,
                // before offering the save.
                .disabled(vm.isRunning || !vm.canSaveProject)

                Button("Otevřít projekt…") {
                    let outcome = vm.openProject()
                    SHAppDelegate.handleOpenProjectOutcome(outcome)
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(vm.isRunning)

                Divider()

                // Multi-window — opens a *scratch* secondary window with
                // its own view-model. Differences vs the primary window:
                //   - Doesn't persist config to UserDefaults (would clash
                //     with primary's slot — last write wins is confusing).
                //   - Server registry, recents, and prompt history are
                //     loaded from UserDefaults at init so the user has
                //     access to their saved servers, but changes don't
                //     write back.
                //   - Closing the scratch window discards its config;
                //     persistence is via `Uložit projekt jako…` only.
                // Pragmatic stand-in for full DocumentGroup migration —
                // see `docs/P2_BACKLOG_DEFERRED.md`.
                Button("Nové okno") {
                    openWindow(id: "scratch", value: UUID())
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
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
    }
}

/// Hosts a scratch ContentView with its own view-model. Doesn't persist
/// config back to UserDefaults — see the rationale on the `Nové okno`
/// menu item. Help sheet flag is local because the primary window's
/// help-flag would be a coordination headache across windows for no
/// real benefit (each window can show its own help if requested).
///
/// `@State` initializer is lazy on macOS 14+/iOS 17+ — the
/// `SHAppViewModel(persistenceMode: .scratch)` expression evaluates once
/// per view instance, not on every body recomputation. Our deployment
/// target is macOS 15.6 so this pattern is safe; on older OS versions
/// SwiftUI would re-evaluate the initializer on rebuild and we'd need
/// the `@State var vm: SHAppViewModel?` + `.onAppear` workaround.
struct SHScratchRoot: View {
    @State private var vm = SHAppViewModel(persistenceMode: .scratch)
    @State private var showHelp = false

    var body: some View {
        ContentView(vm: vm, showHelp: $showHelp)
            // Publish this scratch window's help binding so Cmd+?
            // resolves to it when this window is focused, not to the
            // primary's. See `ShowHelpFocusedKey` on the App scene.
            .focusedSceneValue(\.showHelpBinding, $showHelp)
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
}
