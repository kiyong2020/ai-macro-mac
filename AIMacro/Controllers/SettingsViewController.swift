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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "설정"
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

    private let randomDelayField = NSTextField()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        randomDelayField.stringValue = String(Preferences.maxRandomDelay)
        randomDelayField.delegate = self
    }

    private func buildUI() {
        let colX: CGFloat = 150
        let fieldW: CGFloat = 240
        let rowH: CGFloat = 22

        func addRow(title: String, field: NSView, y: CGFloat) {
            let lbl = NSTextField(labelWithString: title)
            lbl.frame = NSRect(x: 16, y: y, width: colX - 4, height: rowH)
            lbl.alignment = .right
            field.frame = NSRect(x: colX + 16, y: y, width: fieldW, height: rowH)
            view.addSubview(lbl)
            view.addSubview(field)
        }

        let y = view.frame.height - 44

        // Random-delay max (seconds, double). 0 disables the jitter. We parse
        // manually in controlTextDidChange — attaching a NumberFormatter to the
        // field rejects partial input like "1." while typing, so the decimal
        // point appears to be ignored.
        randomDelayField.placeholderString = "0.0"
        randomDelayField.alignment = .right
        addRow(title: "랜덤 딜레이 최대(초):", field: randomDelayField, y: y)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === randomDelayField {
            Preferences.maxRandomDelay = Double(field.stringValue) ?? 0
        }
    }
}
