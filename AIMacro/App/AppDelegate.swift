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
        requestAccessibilityPermission()
        requestScreenCapturePermission()
        requestAppleEventsPermission()
        wirePreferencesMenu()
        setupGlobalObservers()
        SocketService.shared.connect()
        setupStatusItem()
        attachWindowDelegate()
    }

    // MARK: - Status bar item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // SF Symbol — calendar with a clock badge fits the
            // scheduled-reservation use case.
            button.image = NSImage(systemSymbolName: "calendar.badge.clock",
                                   accessibilityDescription: "AIMacro")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // Receive both click types so we can branch left → toggle window,
            // right (or ctrl-click) → show context menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "AIMacro"
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
        guard let menu = NSApp.mainMenu?.item(withTitle: "AIMacro")?.submenu,
              let prefsItem = menu.item(withTitle: "Preferences…") else { return }
        prefsItem.action = #selector(openPreferences(_:))
        prefsItem.target = self
    }

    @objc func openPreferences(_ sender: Any?) {
        SettingsWindowController.shared.present()
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            showPermissionAlert(
                title: "손쉬운 사용 권한 필요",
                message: "마우스/키보드 제어를 위해 손쉬운 사용 권한이 필요합니다.\n시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 허용 후 앱을 재시작해주세요.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        }
    }

    private func requestScreenCapturePermission() {
        // CGPreflightScreenCaptureAccess() returns the cached TCC state without
        // prompting; CGRequestScreenCaptureAccess() adds the app to the system
        // settings list and shows the prompt the first time it's called.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            showPermissionAlert(
                title: "화면 기록 권한 필요",
                message: "OCR 기능을 위해 화면 기록 권한이 필요합니다.\n시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 허용 후 앱을 재시작해주세요.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        }
    }

    private func requestAppleEventsPermission() {
        // Trigger Apple Events permission for Chrome automation (setChromeURL)
        let script = NSAppleScript(source: "tell application \"System Events\" to return name of processes")
        script?.compileAndReturnError(nil)
    }

    private func showPermissionAlert(title: String, message: String, settingsURL: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "닫기")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: settingsURL)!)
        }
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

