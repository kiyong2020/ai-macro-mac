//
//  MainWindowController.swift
//  AIMacro
//
//  Owns one main window + its ViewController. Multiple instances coexist;
//  each gets its own AutomationRunner via the ViewController's lazy var.
//  Cross-window run serialization lives in `RunCoordinator`.
//

import Cocoa

class MainWindowController: NSWindowController, NSWindowDelegate {

    /// Stable UUID for this window. Used by Preferences to persist
    /// "which windows were open + their frames" across launches.
    let windowId = UUID()

    /// Runner number used in the window title ("Runner1", "Runner2", …).
    /// Assigned by `WindowRegistry` when the window registers; freed on
    /// close and reused by the next opened window so numbers stay low.
    var runnerNumber: Int = 0 {
        didSet { applyRunnerTitle() }
    }

    /// Optional scenario id to select when the embedded ViewController
    /// finishes loading. Set by AppDelegate before showing the window;
    /// nil means "use the saved last-selected scenario".
    var pendingScenarioId: String?

    /// Optional runner number to assign on register, used by restore-on-launch
    /// to preserve the user's original numbering across relaunches.
    var pendingRunnerNumber: Int?

    private weak var mainViewController: ViewController?

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.delegate = self
        // Native macOS window tabbing — every MainWindowController shares
        // the same `tabbingIdentifier`, so Cmd+N automatically tabs into
        // the existing window instead of opening a free-floating one.
        // The user can still drag a tab off to detach it.
        window?.tabbingMode = .preferred
        window?.tabbingIdentifier = "com.minseyesoft.aimacro.main"
        if let vc = contentViewController as? ViewController {
            mainViewController = vc
            vc.applyInitialScenarioId(pendingScenarioId)
        }
        applyRunnerTitle()
    }

    private func applyRunnerTitle() {
        guard runnerNumber > 0 else { return }
        window?.title = "Runner\(runnerNumber)"
    }

    /// Called by AppDelegate when the user picks New from the File menu.
    /// Restores a saved frame if one was passed.
    func present(at frame: NSRect? = nil) {
        if let frame = frame {
            window?.setFrame(frame, display: false)
        } else if window?.frame == .zero {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Tear down the Runner permanently and remove it from the registry.
    /// Closing the window alone no longer triggers this — it just hides.
    /// Call this when there's an explicit user action to discard a Runner.
    func deleteRunner() {
        mainViewController?.prepareForWindowClose()
        WindowRegistry.shared.unregister(self)
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Hide-only — the Runner stays alive in the registry so the user
        // can bring this window back via the status-bar dropdown. The
        // AutomationRunner + its listeners keep running while hidden.
        // Persist the layout once the orderOut has settled so a crash now
        // doesn't bring this hidden window back on next launch.
        DispatchQueue.main.async {
            WindowRegistry.shared.persistOpenWindows()
        }
    }
}

/// Tracks every MainWindowController instance so we can iterate them
/// (for status-bar "show app", for window-state persistence, etc.).
final class WindowRegistry {
    static let shared = WindowRegistry()

    private(set) var windows: [MainWindowController] = []

    /// Set when the app is shutting down. Termination triggers
    /// `windowWillClose` for each tab in some macOS versions — without this
    /// flag, the cascade would persist a shrinking list, ultimately saving
    /// an empty array and erasing the user's window layout for next launch.
    var isTerminating = false

    private init() {}

    func register(_ wc: MainWindowController) {
        guard !windows.contains(where: { $0 === wc }) else { return }
        // Pick the runner number: honor a pending value from restore if it
        // isn't already in use; otherwise grab the lowest unused positive int
        // so numbering stays compact across open/close cycles.
        let inUse = Set(windows.map { $0.runnerNumber })
        let assigned: Int
        if let pending = wc.pendingRunnerNumber, pending > 0, !inUse.contains(pending) {
            assigned = pending
        } else {
            var n = 1
            while inUse.contains(n) { n += 1 }
            assigned = n
        }
        wc.pendingRunnerNumber = nil
        wc.runnerNumber = assigned
        windows.append(wc)
        // Persist eagerly so a force-quit / Xcode-stop / crash doesn't drop
        // the new window from the saved layout.
        persistOpenWindows()
    }

    func unregister(_ wc: MainWindowController) {
        windows.removeAll { $0 === wc }
        // Skip during termination — see `isTerminating` doc.
        if !isTerminating { persistOpenWindows() }
    }

    /// Force a specific runner number onto an already-registered window,
    /// swapping with whichever (if any) window currently holds that number.
    /// Used by restore-on-launch to re-apply the saved layout's numbering.
    func renumber(_ wc: MainWindowController, to desired: Int) {
        guard desired > 0, wc.runnerNumber != desired else { return }
        if let conflicting = windows.first(where: { $0.runnerNumber == desired && $0 !== wc }) {
            let previous = wc.runnerNumber
            conflicting.runnerNumber = previous > 0 ? previous : nextFreeNumber(excluding: desired)
        }
        wc.runnerNumber = desired
    }

    private func nextFreeNumber(excluding reserved: Int) -> Int {
        let inUse = Set(windows.map { $0.runnerNumber }).union([reserved])
        var n = 1
        while inUse.contains(n) { n += 1 }
        return n
    }

    /// Capture every *visible* window's (scenarioId, frame, runnerNumber)
    /// tuple for restore on the next launch. Hidden Runners (windows the
    /// user closed during the session) are excluded — they live in memory
    /// for dropdown access but don't survive the next launch.
    func persistOpenWindows() {
        let entries: [[String: Any]] = windows.compactMap { wc in
            guard let window = wc.window, window.isVisible,
                  let vc = wc.contentViewController as? ViewController else { return nil }
            var entry: [String: Any] = [
                "frame": NSStringFromRect(window.frame),
                "runnerNumber": wc.runnerNumber,
            ]
            if let sid = vc.currentScenarioIdString() {
                entry["scenarioId"] = sid
            }
            return entry
        }
        UserDefaults.standard.set(entries, forKey: "openWindows.v1")
    }

    struct SavedWindow {
        let scenarioId: String?
        let frame: NSRect?
        let runnerNumber: Int?
    }

    static func savedOpenWindows() -> [SavedWindow] {
        guard let raw = UserDefaults.standard.array(forKey: "openWindows.v1") as? [[String: Any]] else {
            return []
        }
        return raw.map { dict in
            let sid = dict["scenarioId"] as? String
            let frame: NSRect? = {
                guard let s = dict["frame"] as? String else { return nil }
                let r = NSRectFromString(s)
                return r == .zero ? nil : r
            }()
            let n = dict["runnerNumber"] as? Int
            return SavedWindow(scenarioId: sid, frame: frame, runnerNumber: n)
        }
    }
}
