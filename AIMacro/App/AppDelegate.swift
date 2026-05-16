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
        populateAppendActionSubmenu()
        adoptStoryboardWindow()
        restoreAdditionalWindowsIfNeeded()
        // Watch app activations so picker sessions know which app to hand
        // focus back to when our window steps aside.
        PreviousAppTracker.shared.start()
    }

    /// The storyboard auto-instantiates one MainWindowController as the
    /// initial controller. Register it with the registry so it participates
    /// in close-tracking + persistence like any window opened later via Cmd+N.
    /// Falls back to opening a fresh window if the storyboard didn't seed one.
    private func adoptStoryboardWindow() {
        DispatchQueue.main.async {
            for w in NSApp.windows {
                if let wc = w.windowController as? MainWindowController {
                    WindowRegistry.shared.register(wc)
                    wc.window?.makeKeyAndOrderFront(nil)
                }
            }
            if WindowRegistry.shared.windows.isEmpty {
                self.openNewMainWindow()
            }
        }
    }

    /// Reopen windows the user had open at last quit (beyond the one window
    /// the storyboard already provides). Each restored entry seeds its own
    /// scenario selection, frame, and runner number.
    private func restoreAdditionalWindowsIfNeeded() {
        let saved = WindowRegistry.savedOpenWindows()
        guard !saved.isEmpty else { return }

        DispatchQueue.main.async {
            // Seed the storyboard-provided window with the first entry.
            // Adopt the saved runner number BEFORE register() runs so the
            // restored title matches the previous session.
            if let first = saved.first,
               let primary = WindowRegistry.shared.windows.first {
                if let n = first.runnerNumber, n > 0 {
                    // Already registered with an auto-assigned number —
                    // re-stamp via the registry so collisions don't slip in.
                    WindowRegistry.shared.renumber(primary, to: n)
                }
                if let vc = primary.contentViewController as? ViewController,
                   let sid = first.scenarioId {
                    vc.applyInitialScenarioId(sid)
                }
                if let frame = first.frame {
                    primary.window?.setFrame(frame, display: false)
                }
            }
            // Spawn extras.
            for entry in saved.dropFirst() {
                self.openNewMainWindow(scenarioId: entry.scenarioId,
                                       frame: entry.frame,
                                       runnerNumber: entry.runnerNumber)
            }
        }
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
            showRunnerListMenu()
        }
    }

    /// Left-click dropdown: lists every open Runner with its current state
    /// (idle / running / queued) and lets the user jump to any of them.
    private func showRunnerListMenu() {
        guard let button = statusItem.button else { return }
        let menu = buildRunnerListMenu()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    private func buildRunnerListMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Snapshot the run state once. The menu is transient — closing
        // and reopening picks up any changes since.
        let activeId: String? = try? RunCoordinator.shared.activeScenarioId.value()
        let pending = RunCoordinator.shared.pendingTokens()

        let runners = WindowRegistry.shared.windows
            .sorted { $0.runnerNumber < $1.runnerNumber }
        if runners.isEmpty {
            let none = NSMenuItem(title: "열려있는 Runner 없음",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for wc in runners {
                menu.addItem(makeRunnerMenuItem(for: wc,
                                                activeScenarioId: activeId,
                                                pending: pending))
            }
        }

        menu.addItem(.separator())

        let new = NSMenuItem(title: "New Runner",
                             action: #selector(newDocument(_:)),
                             keyEquivalent: "n")
        new.target = self
        menu.addItem(new)

        let quit = NSMenuItem(title: "종료",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private func makeRunnerMenuItem(for wc: MainWindowController,
                                    activeScenarioId: String?,
                                    pending: [RunCoordinator.Token]) -> NSMenuItem {
        let vc = wc.contentViewController as? ViewController
        let scenarioId = vc?.currentScenarioIdString()
        let scenarioName: String = {
            guard let sid = scenarioId else { return "(시나리오 없음)" }
            return ScenarioStore.shared.scenarios
                .first(where: { $0.id.uuidString == sid })?.name ?? "(알 수 없음)"
        }()

        // Queue tokens are owned by the ViewController, not the WindowController.
        let queueIdx = pending.firstIndex { $0.owner === (vc as AnyObject?) }
        let isRunning = scenarioId != nil && scenarioId == activeScenarioId
            && queueIdx == nil  // running means active, not pending

        let icon: String
        let suffix: String
        if isRunning {
            icon = "▶"; suffix = " (실행 중)"
        } else if let qi = queueIdx {
            icon = "⏸"; suffix = " (대기 \(qi + 1)번째)"
        } else {
            icon = "•"; suffix = ""
        }

        let item = NSMenuItem(title: "\(icon) Runner\(wc.runnerNumber) — \(scenarioName)\(suffix)",
                              action: #selector(focusRunnerWindow(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = wc
        return item
    }

    @objc private func focusRunnerWindow(_ sender: NSMenuItem) {
        guard let wc = sender.representedObject as? MainWindowController,
              let window = wc.window else { return }
        // If the user previously closed this tab and a sibling tab group
        // is still on screen, rejoin it instead of popping up as a lone
        // window — keeps the multi-tab layout consistent with what the
        // user had set up.
        if !window.isVisible {
            let anchor = WindowRegistry.shared.windows
                .compactMap { $0.window }
                .first(where: { $0 !== window && $0.isVisible })
            anchor?.addTabbedWindow(window, ordered: .above)
        }
        // Already-visible tab inside a group: switch the group's selection
        // to this specific tab before bringing it forward.
        if let group = window.tabGroup {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        ensureAtLeastOneMainWindow()
        for wc in WindowRegistry.shared.windows {
            wc.window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureAtLeastOneMainWindow() {
        if WindowRegistry.shared.windows.isEmpty {
            openNewMainWindow()
        }
    }

    /// Cmd+N (File → New) — open a fresh main window. Optionally seed its
    /// scenario selection + frame; both are used during restore-on-launch.
    @IBAction func newDocument(_ sender: Any?) {
        openNewMainWindow()
    }

    @discardableResult
    func openNewMainWindow(scenarioId: String? = nil,
                           frame: NSRect? = nil,
                           runnerNumber: Int? = nil) -> MainWindowController? {
        guard let storyboard = NSStoryboard.main else { return nil }
        guard let wc = storyboard.instantiateController(withIdentifier: "MainWindowController")
                as? MainWindowController else { return nil }
        wc.pendingScenarioId = scenarioId
        wc.pendingRunnerNumber = runnerNumber
        WindowRegistry.shared.register(wc)
        wc.present(at: frame)
        return wc
    }

    // MARK: - Reopen / close behavior

    /// Dock icon click while no window is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            ensureAtLeastOneMainWindow()
            for wc in WindowRegistry.shared.windows {
                wc.window?.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// Fill the static `File → 새로만들기 → 액션 추가` submenu with the same
    /// action-type list the sidebar `+` picker shows. Items target First
    /// Responder so the active window's ViewController handles the append.
    private func populateAppendActionSubmenu() {
        guard let main = NSApp.mainMenu,
              let item = findMenuItem(withTag: 9001, in: main),
              let submenu = item.submenu else { return }
        submenu.removeAllItems()
        for child in ViewController.buildAppendActionSubmenuItems() {
            submenu.addItem(child)
        }
    }

    private func findMenuItem(withTag tag: Int, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.tag == tag { return item }
            if let sub = item.submenu, let hit = findMenuItem(withTag: tag, in: sub) {
                return hit
            }
        }
        return nil
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
        // Persist before flipping the termination flag — captures the
        // current open list as the source of truth for next launch.
        WindowRegistry.shared.persistOpenWindows()
        // Block subsequent termination-driven `windowWillClose` cascades
        // from rewriting the list to an empty array on the way out.
        WindowRegistry.shared.isTerminating = true
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


/// Tracks the most recently active *other* app so picker sessions can
/// hand focus back when our window steps aside. `NSApp.deactivate()`
/// alone is unreliable while we still have visible (nonactivating)
/// panels — macOS may keep us frontmost, or pick an arbitrary app to
/// activate next. By caching the prior frontmost app via the workspace
/// activation notification we can explicitly target it.
final class PreviousAppTracker {
    static let shared = PreviousAppTracker()

    private(set) var previousApp: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private let myPid = ProcessInfo.processInfo.processIdentifier

    private init() {}

    /// Call once at app launch. Seeds with the current frontmost app (we
    /// may have launched while another app held focus) and then keeps the
    /// cache fresh on every workspace activation event — *unless* the
    /// activated app is us, in which case the cache holds onto whoever
    /// we just stole focus from.
    func start() {
        guard observer == nil else { return }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != myPid {
            previousApp = frontmost
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else { return }
            if app.processIdentifier != self.myPid {
                self.previousApp = app
            }
        }
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

