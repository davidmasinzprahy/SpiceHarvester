//
//  SpiceHarvesterApp.swift
//  SpiceHarvester
//
//  Created by David Mašín on 22.06.2025.
//

import SwiftUI
import AppKit

@main
struct SpiceHarvesterApp: App {
    @NSApplicationDelegateAdaptor(SHAppDelegate.self) var appDelegate
    /// Single source of truth for both the main window and the Settings scene.
    /// Hoisted to App level so the Settings sheet (Cmd+,) sees the same state
    /// the main window does.
    @State private var vm = SHAppViewModel()
    @State private var showHelp = false

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm, showHelp: $showHelp)
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

            CommandGroup(replacing: .help) {
                Button("Nápověda Spice Harvester") {
                    showHelp = true
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            SettingsView(vm: vm)
        }
    }
}

/// Adapts the main window on launch. Height always uses the full available
/// work area so the app avoids an initial vertical scrollbar whenever the
/// current display has enough room; on large screens only the width is capped
/// to the UI's natural working size.
final class SHAppDelegate: NSObject, NSApplicationDelegate {
    private let compactPreferredWidth: CGFloat = 1200
    private let largePreferredWidth: CGFloat = 1320
    private let largeScreenWidthThreshold: CGFloat = 1440
    private let largeScreenHeightThreshold: CGFloat = 1100

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI creates its window slightly after `applicationDidFinishLaunching`;
        // hop one run loop tick so `NSApp.mainWindow` / `NSApp.windows` is populated.
        DispatchQueue.main.async { [weak self] in
            self?.resizeMainWindowForCurrentScreen()
        }
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
    }
}
