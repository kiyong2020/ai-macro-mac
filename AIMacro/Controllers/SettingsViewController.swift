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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
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

    private let serverURLField = NSTextField()
    private let userNameField = NSTextField()
    private let randomDelayField = NSTextField()
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "연결 안됨")
    private let connectButton = NSButton()
    private let lastCodeLabel = NSTextField(labelWithString: "-")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        bindSocket()
        serverURLField.stringValue = SocketService.shared.serverURL
        userNameField.stringValue = SocketService.shared.userName
        randomDelayField.stringValue = String(Preferences.maxRandomDelay)
        serverURLField.delegate = self
        userNameField.delegate = self
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

        var y = view.frame.height - 44

        serverURLField.placeholderString = Constants.defaultServerURL
        addRow(title: "서버 URL:", field: serverURLField, y: y)
        y -= 32

        userNameField.placeholderString = "사용자 이름"
        addRow(title: "사용자 이름:", field: userNameField, y: y)
        y -= 32

        // Random-delay max (seconds, double). 0 disables the jitter. We parse
        // manually in controlTextDidChange — attaching a NumberFormatter to the
        // field rejects partial input like "1." while typing, so the decimal
        // point appears to be ignored.
        randomDelayField.placeholderString = "0.0"
        randomDelayField.alignment = .right
        addRow(title: "랜덤 딜레이 최대(초):", field: randomDelayField, y: y)
        y -= 32

        // Status row
        let statusTitleLbl = NSTextField(labelWithString: "상태:")
        statusTitleLbl.frame = NSRect(x: 16, y: y, width: colX - 4, height: rowH)
        statusTitleLbl.alignment = .right
        statusDot.frame = NSRect(x: colX + 16, y: y + 5, width: 12, height: 12)
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 6
        statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        statusLabel.frame = NSRect(x: colX + 34, y: y, width: 180, height: rowH)
        view.addSubview(statusTitleLbl)
        view.addSubview(statusDot)
        view.addSubview(statusLabel)
        y -= 32

        // Last received code
        let codeTitleLbl = NSTextField(labelWithString: "수신 코드:")
        codeTitleLbl.frame = NSRect(x: 16, y: y, width: colX - 4, height: rowH)
        codeTitleLbl.alignment = .right
        lastCodeLabel.frame = NSRect(x: colX + 16, y: y, width: fieldW, height: rowH)
        view.addSubview(codeTitleLbl)
        view.addSubview(lastCodeLabel)
        y -= 40

        connectButton.title = "연결"
        connectButton.bezelStyle = .rounded
        connectButton.frame = NSRect(x: colX + 16, y: y, width: 100, height: 28)
        connectButton.target = self
        connectButton.action = #selector(onConnect)
        view.addSubview(connectButton)
    }

    private func bindSocket() {
        SocketService.shared.isConnected
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] connected in
                guard let self = self else { return }
                self.statusDot.layer?.backgroundColor = connected
                    ? NSColor.systemGreen.cgColor
                    : NSColor.systemRed.cgColor
                self.statusLabel.stringValue = connected ? "연결됨" : "연결 안됨"
                self.connectButton.title = connected ? "연결 해제" : "연결"
            }).disposed(by: disposeBag)

        SocketService.shared.receivedCode
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] code in
                self?.lastCodeLabel.stringValue = code
            }).disposed(by: disposeBag)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === userNameField {
            SocketService.shared.userName = field.stringValue
            SocketService.shared.connect()
        } else if field === serverURLField {
            SocketService.shared.serverURL = field.stringValue
        } else if field === randomDelayField {
            Preferences.maxRandomDelay = Double(field.stringValue) ?? 0
        }
    }

    @objc private func onConnect() {
        let connected = (try? SocketService.shared.isConnected.value()) ?? false
        if connected {
            SocketService.shared.disconnect()
        } else {
            SocketService.shared.serverURL = serverURLField.stringValue
            SocketService.shared.userName = userNameField.stringValue
            SocketService.shared.connect()
        }
    }
}
