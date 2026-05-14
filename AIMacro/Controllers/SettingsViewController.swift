//
//  SettingsViewController.swift
//  AIMacro
//

import Cocoa
import RxSwift

class SettingsWindowController: NSWindowController {
    static let shared: SettingsWindowController = {
        let vc = SettingsViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 186),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Settings")
        window.contentViewController = vc
        let wc = SettingsWindowController(window: window)
        return wc
    }()

    func present() {
        if !(window?.isVisible ?? false) {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

class SettingsViewController: NSViewController, NSTextFieldDelegate {
    private var disposeBag = DisposeBag()

    private let defaultDelayField = NSTextField()
    private let randomDelayField = NSTextField()
    private let permissionButton = NSButton()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 186))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        defaultDelayField.stringValue = String(Preferences.defaultActionDelay)
        defaultDelayField.delegate = self
        randomDelayField.stringValue = String(Preferences.maxRandomDelay)
        randomDelayField.delegate = self
    }

    private func buildUI() {
        let colX: CGFloat = 150
        let fieldW: CGFloat = 240
        let rowH: CGFloat = 22

        func addRow(title: String, field: NSView, y: CGFloat, height: CGFloat = 22) {
            let lbl = NSTextField(labelWithString: title)
            lbl.frame = NSRect(x: 16, y: y, width: colX - 4, height: rowH)
            lbl.alignment = .right
            field.frame = NSRect(x: colX + 16, y: y, width: fieldW, height: height)
            view.addSubview(lbl)
            view.addSubview(field)
        }

        var y = view.frame.height - 44

        // Global base delay (seconds, double) applied before every action,
        // on top of the action's own delay. Parsed manually so partial input
        // like "1." is accepted while the user types.
        defaultDelayField.placeholderString = "0.0"
        defaultDelayField.alignment = .right
        addRow(title: L("Action default delay (sec):"), field: defaultDelayField, y: y)
        y -= 36

        // Random-delay max (seconds, double). 0 disables the jitter. We parse
        // manually in controlTextDidChange — attaching a NumberFormatter to the
        // field rejects partial input like "1." while typing, so the decimal
        // point appears to be ignored.
        randomDelayField.placeholderString = "0.0"
        randomDelayField.alignment = .right
        addRow(title: L("Max random delay (sec):"), field: randomDelayField, y: y)
        y -= 36

        // Permission request button — re-triggers the three TCC prompts so
        // the user can re-grant access without restarting the app.
        permissionButton.title = L("Request")
        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionButton.action = #selector(onRequestPermissions)
        permissionButton.toolTip = L("Request Accessibility / Screen Recording / Apple Events at once.")
        addRow(title: L("System permissions:"), field: permissionButton, y: y, height: 28)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === defaultDelayField {
            Preferences.defaultActionDelay = Double(field.stringValue) ?? 0
        } else if field === randomDelayField {
            Preferences.maxRandomDelay = Double(field.stringValue) ?? 0
        }
    }

    @objc private func onRequestPermissions() {
        // Interactive mode: skip the preflight short-circuit and fall back
        // to opening System Settings when macOS won't re-prompt for a
        // previously-denied / already-decided permission.
        Permissions.requestAll(interactive: true)
        AppLogger.shared.log("🔐 시스템 권한 재요청")
    }
}
