//
//  AppDelegate.swift
//  AIMacro
//
//  Created by Kiyong Kim on 6/30/25.
//

import Cocoa
import ApplicationServices

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    /// Menu bar status item — clicking it toggles the main window. Held as a
    /// strong reference so it stays in the system menu bar for the app's
    /// lifetime.
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Move legacy ~/Library/Application Support/GolfReservation/ to AIMacro/
        // before any storage singleton (ScenarioStore/ActionStore/OCRSnapshotStore)
        // touches the new path. Must run first.
        Self.migrateLegacyAppSupportIfNeeded()
        Permissions.requestAll()
        wirePreferencesMenu()
        setupGlobalObservers()
        setupStatusItem()
        attachWindowDelegate()
    }

    // MARK: - Status bar item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // SF Symbol that mirrors the app icon's design — a cursor with
            // radial "click" rays. Falls back through progressively simpler
            // cursor symbols so we never end up with a blank status item.
            let symbolNames = ["cursorarrow.rays",
                               "cursorarrow.click.2",
                               "cursorarrow.click",
                               "cursorarrow"]
            for name in symbolNames {
                if let img = NSImage(systemSymbolName: name,
                                     accessibilityDescription: "Macroony") {
                    img.isTemplate = true
                    button.image = img
                    break
                }
            }
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // Receive both click types so we can branch left → toggle window,
            // right (or ctrl-click) → show context menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Macroony"
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRight {
            showStatusContextMenu()
        } else {
            toggleMainWindow()
        }
    }

    private func showStatusContextMenu() {
        guard let button = statusItem.button else { return }

        let menu = NSMenu()

        let show = NSMenuItem(title: "앱 표시",
                              action: #selector(showMainWindowFromMenu),
                              keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "종료",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        // popUp(positioning:at:in:) anchors the menu just below the status
        // button — same placement Apple uses for status-item menus.
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    @objc private func showMainWindowFromMenu() {
        guard let window = mainWindow() else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleMainWindow() {
        guard let window = mainWindow() else { return }
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func mainWindow() -> NSWindow? {
        return NSApp.windows.first(where: { $0.contentViewController is ViewController })
    }

    private func attachWindowDelegate() {
        // Defer to next runloop tick — the storyboard's main window finishes
        // wiring after applicationDidFinishLaunching returns.
        DispatchQueue.main.async { [weak self] in
            self?.mainWindow()?.delegate = self
        }
    }

    // MARK: - Reopen / close behavior

    /// Dock icon click while no window is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = mainWindow() {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    private func wirePreferencesMenu() {
        // App menu title is "Macroony" after the rebrand (see Main.storyboard).
        // Lookup-by-title still works at the storyboard level even though the
        // Swift module / target name stays "AIMacro".
        guard let menu = NSApp.mainMenu?.item(withTitle: "Macroony")?.submenu,
              let prefsItem = menu.item(withTitle: "Preferences…") else { return }
        prefsItem.action = #selector(openPreferences(_:))
        prefsItem.target = self
    }

    @objc func openPreferences(_ sender: Any?) {
        SettingsWindowController.shared.present()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    /// Return false so closing the main window doesn't quit the app — combined
    /// with `windowShouldClose(_:)` below this means the window simply hides
    /// and a click on the menu-bar item or the Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Intercept the red traffic-light click — hide the window instead of
    /// tearing it down so we can show it again instantly without rebuilding
    /// the whole view hierarchy.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

extension AppDelegate {
    /// One-time migration when the app was renamed from GolfReservation → AIMacro.
    /// Moves the legacy `Application Support/GolfReservation/` folder (scenarios.json,
    /// actions.sqlite3, snapshots/) to the new `AIMacro/` location so existing user
    /// data survives the rename.
    static func migrateLegacyAppSupportIfNeeded() {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: false) else { return }
        let legacy = base.appendingPathComponent("GolfReservation")
        let target = base.appendingPathComponent("AIMacro")
        // Only migrate when legacy exists AND target hasn't been created yet.
        // If both exist (e.g. a partial migration on a prior failed launch),
        // leave the legacy folder alone — the user's current data is in target.
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: target.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: target)
            AppLogger.shared.log("[Migration] Application Support: GolfReservation → AIMacro")
        } catch {
            AppLogger.shared.log("[Migration] 실패: \(error.localizedDescription)")
        }
    }
}

