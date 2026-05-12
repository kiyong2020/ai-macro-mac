//
//  ViewController.swift
//  AIMacro
//
//  Created by Kiyong Kim on 6/30/25.
//

import Cocoa
import RxSwift
import RxCocoa
import UniformTypeIdentifiers

class ViewController: NSViewController {
    @IBOutlet weak var tableView: NSTableView!
    @IBOutlet weak var datePicker: DateTimePickerControl!
    @IBOutlet weak var startButton: NSButton!
    @IBOutlet weak var groupTab: NSSegmentedControl!
    @IBOutlet weak var imageView: NSImageView!

    let actions = BehaviorSubject<[AutoAction]>(value: [])

    private var mousePoint: CGPoint?
    private let keyboardListener = GlobalKeyListener()
    private let mouseListener = MouseListener()
    private lazy var runner = AutomationRunner(mouseListener: mouseListener,
                                                keyboardListener: keyboardListener)
    private lazy var cellFactory = ActionCellFactory(mouseListener: mouseListener)
    private lazy var detailBuilder = ActionDetailBuilder(mouseListener: mouseListener)
    /// Right-hand detail pane container. The actual form is rebuilt every
    /// time the table selection or the underlying scenario changes.
    private var detailContainer: NSView!
    private var detailContent: NSView?
    /// Per-detail subscriptions — disposed and replaced when a different
    /// action is selected so old bindings don't leak across switches.
    private var detailBag = DisposeBag()

    private var disposeBag = DisposeBag()
    private var actionsBag = DisposeBag()

    private let isRunning = BehaviorSubject(value: false)
    private var logTextView: NSTextView!

    // Programmatic status panel widgets (built in setupStatusPanel)
    private var statusLabel: NSTextField!
    private var progressLabel: NSTextField!
    private var errorLabel: NSTextField!
    private var progressBar: GradientProgressBar!

    private var task: Task<Void, Error>?
    private var timer: WallClockScheduler?
    private var countdownTick: Timer?
    private var elapsedTick: Timer?

    /// Index of the currently-running action; mirrored from runner.currentIndex on
    /// the main thread so the table delegate can read it synchronously.
    private var currentRunningIndex: Int?

    /// Programmatic scenario picker — replaces the segmented control. The
    /// popup is built in `setupScenarioControls()` and populated from
    /// `ScenarioStore.shared.scenarios`. The old `groupTab` outlet is kept
    /// alive (just hidden) so the storyboard's IBAction wiring still resolves.
    private var scenarioPopup: NSPopUpButton!
    private var currentScenarioIndex: Int = 0
    /// Anchor button for the scenario-edit popover (rename + delete).
    private var scenarioEditButton: NSButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupStatusAndLogView()

        datePicker.dateValue = Date()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = -1
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 5)

        bindIsRunning()
        bindRunnerState()
        bindKeyboardListener()

        setupScenarioControls()
        setupMasterDetailLayout()
        setupActionTableMenu()
        restoreLastSelectedScenario()
        refreshScenarioPopup()
        loadCurrentScenario()
    }

    /// Look up the scenario whose UUID matches the last saved selection and
    /// set `currentScenarioIndex` accordingly so `refreshScenarioPopup` shows
    /// it. Falls back to index 0 if no match (e.g. that scenario was deleted).
    private func restoreLastSelectedScenario() {
        guard let savedId = Preferences.lastScenarioId else { return }
        let scenarios = ScenarioStore.shared.scenarios
        if let idx = scenarios.firstIndex(where: { $0.id.uuidString == savedId }) {
            currentScenarioIndex = idx
        }
    }

    /// Persist whichever scenario is currently selected.
    private func persistCurrentScenarioSelection() {
        let scenarios = ScenarioStore.shared.scenarios
        guard scenarios.indices.contains(currentScenarioIndex) else { return }
        Preferences.lastScenarioId = scenarios[currentScenarioIndex].id.uuidString
    }

    // MARK: - Master-detail layout

    private func setupMasterDetailLayout() {
        guard let scroll = tableView.enclosingScrollView else { return }

        // Narrow the table to a fixed-width sidebar — drop any existing
        // trailing-to-superview constraint first.
        for c in view.constraints {
            if (c.firstItem as? NSView) === scroll && c.firstAttribute == .trailing {
                c.isActive = false
            }
            if (c.secondItem as? NSView) === scroll && c.secondAttribute == .trailing {
                c.isActive = false
            }
        }
        scroll.widthAnchor.constraint(equalToConstant: 196).isActive = true

        // "+ 동작 추가" button at the top of the sidebar — pops the action-type
        // menu and appends to the current scenario. We unhook the scroll
        // view's existing top constraint and re-anchor it just below the
        // button so the storyboard's top-of-table position becomes the
        // top-of-button position.
        let addButton = NSButton(title: "＋ 동작 추가",
                                 target: self,
                                 action: #selector(showAppendActionMenu(_:)))
        addButton.bezelStyle = .roundRect
        addButton.controlSize = .regular
        addButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addButton)

        // Capture the scroll view's existing top constraint to the parent so we
        // can transfer it to the button.
        var scrollTopConstraint: NSLayoutConstraint?
        for c in view.constraints {
            if (c.firstItem as? NSView) === scroll && c.firstAttribute == .top {
                scrollTopConstraint = c
                break
            }
            if (c.secondItem as? NSView) === scroll && c.secondAttribute == .top {
                scrollTopConstraint = c
                break
            }
        }
        scrollTopConstraint?.isActive = false

        let buttonTop: NSLayoutConstraint
        if let old = scrollTopConstraint, let anchorView = (old.firstItem as? NSView) === scroll
            ? (old.secondItem as? NSView) : (old.firstItem as? NSView) {
            // Re-pin the button to whatever the scroll's top was anchored to,
            // preserving the storyboard's offset.
            let storyboardOffset = (old.firstItem as? NSView) === scroll ? old.constant : -old.constant
            buttonTop = addButton.topAnchor.constraint(equalTo: anchorView.bottomAnchor,
                                                      constant: storyboardOffset)
        } else {
            buttonTop = addButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 8)
        }

        NSLayoutConstraint.activate([
            buttonTop,
            addButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            addButton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            addButton.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 4),
        ])

        // The detail container fills the rest of the row to the right of the
        // table, vertically aligned with the button + table together.
        detailContainer = NSView()
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.addSubview(detailContainer)
        NSLayoutConstraint.activate([
            detailContainer.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detailContainer.topAnchor.constraint(equalTo: addButton.topAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        ])

        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .regular

        // Rebuild the detail when the user picks a different row.
        NotificationCenter.default.addObserver(
            forName: NSTableView.selectionDidChangeNotification,
            object: tableView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDetailPane()
        }

        // When a name is edited in the detail pane, reflect it in the list.
        detailBuilder.onActionRenamed = { [weak self] in
            self?.tableView.reloadData()
        }
    }

    /// Mount the form for the currently-selected action (or the empty state).
    private func refreshDetailPane() {
        detailContent?.removeFromSuperview()
        detailBag = DisposeBag()

        let actions = (try? actions.value()) ?? []
        let selected = tableView.selectedRow
        let action = actions.indices.contains(selected) ? actions[selected] : nil

        let view = detailBuilder.detailView(for: action, disposeBag: detailBag)
        view.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        detailContent = view
    }

    // MARK: - View setup

    private func setupStatusAndLogView() {
        // Repurpose imageView as a thin spacer; we no longer display anything in it.
        for c in imageView.constraints where c.firstAttribute == .height {
            c.isActive = false
        }
        imageView.heightAnchor.constraint(equalToConstant: 4).isActive = true
        imageView.image = nil

        // Detach the storyboard's "view.bottom == imageView.bottom" constraint so
        // we can stack the status panel and log scroll view below imageView.
        for c in view.constraints {
            if c.firstAttribute == .bottom,
               (c.secondItem as? NSView) === imageView,
               c.secondAttribute == .bottom {
                c.isActive = false
                break
            }
        }

        // ── Status panel ───────────────────────────────────────────────
        let statusPanel = NSView()
        statusPanel.translatesAutoresizingMaskIntoConstraints = false
        statusPanel.wantsLayer = true
        statusPanel.layer?.backgroundColor = NSColor(white: 0, alpha: 0.04).cgColor

        statusLabel = makeLabel(font: .systemFont(ofSize: 13, weight: .medium))
        statusLabel.stringValue = "준비"
        progressLabel = makeLabel(font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                  alignment: .right, color: .secondaryLabelColor)
        errorLabel = makeLabel(font: .systemFont(ofSize: 11), color: .systemRed)
        errorLabel.isHidden = true

        progressBar = GradientProgressBar()
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true

        statusPanel.addSubview(statusLabel)
        statusPanel.addSubview(progressLabel)
        statusPanel.addSubview(progressBar)
        statusPanel.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusPanel.leadingAnchor, constant: 12),
            statusLabel.topAnchor.constraint(equalTo: statusPanel.topAnchor, constant: 6),
            progressLabel.trailingAnchor.constraint(equalTo: statusPanel.trailingAnchor, constant: -12),
            progressLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            progressLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 8),

            progressBar.leadingAnchor.constraint(equalTo: statusPanel.leadingAnchor, constant: 12),
            progressBar.trailingAnchor.constraint(equalTo: statusPanel.trailingAnchor, constant: -12),
            progressBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            progressBar.heightAnchor.constraint(equalToConstant: 4),

            errorLabel.leadingAnchor.constraint(equalTo: statusPanel.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: statusPanel.trailingAnchor, constant: -12),
            errorLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 4),
            errorLabel.bottomAnchor.constraint(lessThanOrEqualTo: statusPanel.bottomAnchor, constant: -4),
        ])

        // ── Log view ───────────────────────────────────────────────────
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .textBackgroundColor

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont(name: "Menlo", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.backgroundColor = .textBackgroundColor
        tv.textColor = .labelColor
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 4, height: 4)
        scrollView.documentView = tv
        logTextView = tv

        view.addSubview(statusPanel)
        view.addSubview(scrollView)
        // Fixed heights so the table view above (whose bottom is anchored to
        // imageView.top) can absorb whatever vertical space is left. Using
        // greaterThanOrEqual here lets the panel/log over-stretch and collapses
        // the table to 0pt.
        NSLayoutConstraint.activate([
            statusPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusPanel.topAnchor.constraint(equalTo: imageView.bottomAnchor),
            statusPanel.heightAnchor.constraint(equalToConstant: 56),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: statusPanel.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 140),
        ])

        bindLogView()
    }

    private func makeLabel(font: NSFont,
                           alignment: NSTextAlignment = .left,
                           color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = font
        l.alignment = alignment
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    // MARK: - Bindings

    private func bindIsRunning() {
        isRunning.subscribe { [weak self] on in
            guard let self = self else { return }
            if on {
                self.startButton.title = "Stop"
                self.startButton.bezelColor = .red
            } else {
                self.startButton.title = "Start"
                self.startButton.bezelColor = .green
                self.task?.cancel()
                self.task = nil
                self.timer?.cancel()
                self.timer = nil
                self.countdownTick?.invalidate()
                self.countdownTick = nil
                self.elapsedTick?.invalidate()
                self.elapsedTick = nil
                self.runner.stop()
                self.statusLabel.stringValue = "준비"
                self.progressLabel.stringValue = ""
                self.progressBar.isHidden = true
                self.progressBar.doubleValue = 0
            }
        }.disposed(by: disposeBag)
    }

    private func bindRunnerState() {
        // Combine runner index/name into a status string and refresh the
        // active-row highlight in the table.
        runner.currentIndex
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] idx in
                guard let self = self else { return }
                let oldIdx = self.currentRunningIndex
                self.currentRunningIndex = idx

                var rows = IndexSet()
                if let oldIdx = oldIdx, oldIdx < self.tableView.numberOfRows { rows.insert(oldIdx) }
                if let newIdx = idx, newIdx < self.tableView.numberOfRows { rows.insert(newIdx) }
                if !rows.isEmpty {
                    self.tableView.reloadData(forRowIndexes: rows,
                                              columnIndexes: IndexSet(integer: 0))
                }
                if let newIdx = idx {
                    self.tableView.scrollRowToVisible(newIdx)
                }
            }).disposed(by: disposeBag)

        Observable.combineLatest(runner.currentIndex, runner.totalCount, runner.currentName)
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] idx, total, name in
                guard let self = self else { return }
                if let idx = idx, total > 0 {
                    self.statusLabel.stringValue = "▶ \(idx + 1) / \(total)  \(name)"
                    self.progressBar.isHidden = false
                    self.progressBar.doubleValue = Double(idx + 1) / Double(total)
                }
            }).disposed(by: disposeBag)

        runner.lastError
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] err in
                guard let self = self else { return }
                if let err = err {
                    self.errorLabel.stringValue = "⚠️ \(err)"
                    self.errorLabel.isHidden = false
                } else {
                    self.errorLabel.stringValue = ""
                    self.errorLabel.isHidden = true
                }
            }).disposed(by: disposeBag)
    }

    private func bindKeyboardListener() {
        keyboardListener.keyRelay.subscribe { [weak self] e in
            guard let self = self, let (code, shift) = e.element else { return }
            if try! self.isRunning.value() {
                if code == 36 || code == 76 {
                    self.runner.signalWaitDone()
                }
            } else {
                if let numStr = keyCodeToNumber(code) {
                    self.saveKey(number: numStr, shift: shift)
                }
            }
        }.disposed(by: disposeBag)
    }

    private func bindLogView() {
        AppLogger.shared.logText
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] text in
                guard let self = self else { return }
                let wasAtBottom = self.isLogAtBottom()
                let attributed = self.attributedLog(text)
                self.logTextView.textStorage?.setAttributedString(attributed)
                if wasAtBottom {
                    self.logTextView.scrollToEndOfDocument(nil)
                }
            }).disposed(by: disposeBag)
    }

    /// Render the raw log text with a tertiary-gray "[HH:mm:ss]" timestamp and
    /// a body color picked from the leading emoji marker, matching the
    /// redesign's color-coded severity convention.
    private func attributedLog(_ text: String) -> NSAttributedString {
        let monospace = NSFont(name: "Menlo", size: 11)
            ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let nsLine = line as NSString
            var bodyStart = 0
            // Recognize the "[HH:mm:ss] " prefix.
            if nsLine.length >= 11,
               nsLine.character(at: 0) == 0x5B /* "[" */,
               nsLine.character(at: 9) == 0x5D /* "]" */,
               nsLine.character(at: 10) == 0x20 /* " " */ {
                let prefix = nsLine.substring(to: 11)
                result.append(NSAttributedString(string: prefix, attributes: [
                    .font: monospace,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]))
                bodyStart = 11
            }
            let body = bodyStart > 0 ? nsLine.substring(from: bodyStart) : line
            result.append(NSAttributedString(string: body, attributes: [
                .font: monospace,
                .foregroundColor: Self.logBodyColor(for: body),
            ]))
            if i < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: monospace]))
            }
        }
        return result
    }

    private static func logBodyColor(for body: String) -> NSColor {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("▶")  { return .systemGreen }
        if trimmed.hasPrefix("✓")  { return .systemGreen }
        if trimmed.hasPrefix("✅")  { return .systemGreen }
        if trimmed.hasPrefix("⏹")  { return .secondaryLabelColor }
        if trimmed.hasPrefix("⚠️") || trimmed.hasPrefix("⚠")  { return .systemOrange }
        if trimmed.hasPrefix("⏱")  { return .systemOrange }
        if trimmed.hasPrefix("❌")  { return .systemRed }
        if trimmed.hasPrefix("🔐") || trimmed.hasPrefix("🪟")
            || trimmed.hasPrefix("🔍") || trimmed.hasPrefix("🆕")
            || trimmed.hasPrefix("🌐") { return .systemBlue }
        if trimmed.hasPrefix("➕") { return .systemBlue }
        if trimmed.hasPrefix("🗑") { return .secondaryLabelColor }
        return .labelColor
    }

    private func isLogAtBottom() -> Bool {
        guard let sv = logTextView.enclosingScrollView else { return true }
        let visible = sv.contentView.bounds
        let docHeight = logTextView.frame.height
        return visible.maxY >= docHeight - 30
    }

    // MARK: - Actions

    /// Storyboard-wired no-op. Kept so the existing IBAction binding on the
    /// (hidden) segmented control still resolves; the scenario popup drives
    /// loading via `onChangeScenario` instead.
    @IBAction @objc func onChangeGroup(_ : Any?) {}

    // MARK: - Scenario controls (programmatic)

    private func setupScenarioControls() {
        // Hide — but keep — the storyboard segmented control so the existing
        // IBAction connection and surrounding constraints still resolve.
        groupTab.isHidden = true

        func smallButton(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .roundRect
            b.controlSize = .small
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }

        // [+] popup [편집] — matches the redesign's scenario row. The
        // settings button on the right is the storyboard's existing 설정
        // button, already wired to `onSettings:`.
        let addBtn = smallButton("＋", #selector(onAddScenario))
        addBtn.toolTip = "현재 시나리오 복제"

        scenarioPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        scenarioPopup.target = self
        scenarioPopup.action = #selector(onChangeScenario(_:))
        scenarioPopup.translatesAutoresizingMaskIntoConstraints = false

        scenarioEditButton = smallButton("편집", #selector(showScenarioEditPopover))
        scenarioEditButton.toolTip = "시나리오 이름 변경 / 삭제"

        let stack = NSStackView(views: [addBtn, scenarioPopup, scenarioEditButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            // Pin to the leading edge with the same 14pt inset the redesign
            // uses for its toolbar — the storyboard's hidden segmented
            // control was positioned further right and we no longer want to
            // inherit that offset.
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.topAnchor.constraint(equalTo: groupTab.topAnchor),
            scenarioPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    private func refreshScenarioPopup() {
        scenarioPopup.removeAllItems()
        let store = ScenarioStore.shared
        for scenario in store.scenarios {
            scenarioPopup.addItem(withTitle: scenario.name)
        }
        let safeIndex = min(max(0, currentScenarioIndex), store.scenarios.count - 1)
        if store.scenarios.indices.contains(safeIndex) {
            scenarioPopup.selectItem(at: safeIndex)
            currentScenarioIndex = safeIndex
        }
    }

    @objc private func onChangeScenario(_ sender: Any?) {
        let idx = scenarioPopup.indexOfSelectedItem
        guard ScenarioStore.shared.scenarios.indices.contains(idx) else { return }
        currentScenarioIndex = idx
        persistCurrentScenarioSelection()
        loadCurrentScenario()
    }

    /// Push the currently-selected scenario's actions into `self.actions`,
    /// hook up per-action UserDefaults persistence, and refresh the table.
    private func loadCurrentScenario() {
        let store = ScenarioStore.shared
        guard store.scenarios.indices.contains(currentScenarioIndex) else { return }
        let actions = store.scenarios[currentScenarioIndex].actions
        self.actionsBag = DisposeBag()
        self.actions.onNext(actions)
        for a in actions {
            a.restore()
            Observable<Bool>.merge(a.point.map { _ in true },
                                   a.delay.map { _ in true },
                                   a.count.map { _ in true },
                                   a.text.map  { _ in true })
                .throttle(.milliseconds(500), scheduler: MainScheduler.instance)
                .subscribe { _ in a.save() }
                .disposed(by: actionsBag)
        }
        tableView.reloadData()

        // Auto-select the first row so the detail pane has something to show.
        if !actions.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            refreshDetailPane()
        }
    }

    @objc private func onAddScenario() {
        let store = ScenarioStore.shared
        guard store.scenarios.indices.contains(currentScenarioIndex) else { return }
        let baseName = store.scenarios[currentScenarioIndex].name
        let newName = "\(baseName) 복사본"
        if store.duplicate(at: currentScenarioIndex, newName: newName) != nil {
            currentScenarioIndex = store.scenarios.count - 1
            persistCurrentScenarioSelection()
            refreshScenarioPopup()
            loadCurrentScenario()
            AppLogger.shared.log("➕ 시나리오 추가: \(newName)")
        }
    }

    /// Modal dialog with a name text field and three buttons: 확인 / 취소 /
    /// 삭제. Replaces the previous NSPopover, which had focus / dismissal
    /// quirks.
    @objc private func showScenarioEditPopover() {
        let store = ScenarioStore.shared
        guard store.scenarios.indices.contains(currentScenarioIndex) else { return }
        let current = store.scenarios[currentScenarioIndex]

        let alert = NSAlert()
        alert.messageText = "시나리오 편집"
        alert.informativeText = "이름을 변경하거나 시나리오를 삭제할 수 있습니다."

        let input = NSTextField(string: current.name)
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input

        // Order matters — first button is the default (Return), second is
        // Cancel (Escape), the third is destructive.
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "삭제")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed != current.name else { return }
            store.rename(at: currentScenarioIndex, to: trimmed)
            refreshScenarioPopup()
        case .alertThirdButtonReturn:
            // Reuses the existing destructive-confirm flow.
            onDeleteScenario()
        default:
            break   // 취소
        }
    }

    // MARK: - Action editing (insert / delete / reorder)

    /// Pasteboard type used to drag-and-drop reorder rows in the action table.
    private static let actionRowDragType = NSPasteboard.PasteboardType("com.aimacro.actionRow")

    /// Strong references to context-menu items whose visibility we toggle
    /// per-click in `menuWillOpen` (depending on whether a row is clicked).
    private var insertAboveMenuItem: NSMenuItem!
    private var insertBelowMenuItem: NSMenuItem!
    private var appendMenuItem: NSMenuItem!
    private var deleteActionMenuItem: NSMenuItem!
    private var deleteSeparatorMenuItem: NSMenuItem!

    /// Build the right-click context menu attached to the action table.
    private func setupActionTableMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // Row clicked → 위에 추가 / 아래에 추가
        insertAboveMenuItem = NSMenuItem(title: "위에 추가", action: nil, keyEquivalent: "")
        insertAboveMenuItem.submenu = makeActionTypeMenu(insertOffset: 0)
        menu.addItem(insertAboveMenuItem)

        insertBelowMenuItem = NSMenuItem(title: "아래에 추가", action: nil, keyEquivalent: "")
        insertBelowMenuItem.submenu = makeActionTypeMenu(insertOffset: 1)
        menu.addItem(insertBelowMenuItem)

        // Empty area clicked → 동작 추가 (append). The submenu's items also
        // route through `insertActionFromMenu`, which appends when
        // `tableView.clickedRow < 0`.
        appendMenuItem = NSMenuItem(title: "동작 추가", action: nil, keyEquivalent: "")
        appendMenuItem.submenu = makeActionTypeMenu(insertOffset: 0)
        menu.addItem(appendMenuItem)

        deleteSeparatorMenuItem = NSMenuItem.separator()
        menu.addItem(deleteSeparatorMenuItem)

        deleteActionMenuItem = NSMenuItem(title: "삭제",
                                          action: #selector(deleteClickedAction),
                                          keyEquivalent: "")
        deleteActionMenuItem.target = self
        menu.addItem(deleteActionMenuItem)

        tableView.menu = menu
        tableView.registerForDraggedTypes([Self.actionRowDragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
    }

    private func makeActionTypeMenu(insertOffset: Int) -> NSMenu {
        let m = NSMenu()
        let types: [(String, AutoAction.ActionType)] = [
            ("🖱  클릭", .click),
            ("⬇  스크롤", .scroll),
            ("✋  드래그", .drag),
            ("⌨︎  키 입력", .key),
            // 통합 대기 — 디테일 패널에서 시간/클릭/엔터 중 선택. 신규 생성
            // 시 기본값은 시간 대기.
            ("⏱  대기", .wait(type: .time)),
            ("🔍  OCR", .ocr),
            ("📝  스크립트", .script(code: "")),
            // Hidden from the picker until needed again — `.setURL` /
            // `.openChrome` are Chrome-specific and superseded by `.openBrowser`.
            // Runtime / detail UI / persistence for these types stays intact
            // so old scenarios still load and run.
            // ("🌐  URL", .setURL(url: "")),
            // ("🆕  새창", .openChrome(url: "")),
            ("🌐🪟  브라우저", .openBrowser(url: "")),
            ("🪟  창프레임", .windowFrame),
        ]
        for (label, type) in types {
            let item = NSMenuItem(title: label,
                                  action: #selector(insertActionFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = ActionInsertSpec(offset: insertOffset, type: type)
            m.addItem(item)
        }
        return m
    }

    /// Wrapper for `representedObject` — enums with associated values aren't
    /// always preserved cleanly across the Objective-C bridge, so we box them.
    private final class ActionInsertSpec: NSObject {
        let offset: Int
        let type: AutoAction.ActionType
        init(offset: Int, type: AutoAction.ActionType) {
            self.offset = offset
            self.type = type
        }
    }

    @objc private func insertActionFromMenu(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? ActionInsertSpec else { return }
        let store = ScenarioStore.shared
        guard store.scenarios.indices.contains(currentScenarioIndex) else { return }
        let scenario = store.scenarios[currentScenarioIndex]

        let clicked = tableView.clickedRow
        let insertIndex: Int
        if clicked < 0 {
            insertIndex = scenario.actions.count   // empty area → append
        } else {
            insertIndex = max(0, min(clicked + spec.offset, scenario.actions.count))
        }
        appendOrInsertAction(of: spec.type, at: insertIndex, in: scenario)
    }

    /// Pop the action-type menu directly under the "+ 동작 추가" button.
    /// Routes all picks through `appendActionFromMenu` so the new row always
    /// lands at the end of the current scenario, regardless of whatever the
    /// table view's last `clickedRow` happened to be.
    @objc private func showAppendActionMenu(_ sender: NSButton) {
        let menu = makeAppendActionTypeMenu()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 2),
                   in: sender)
    }

    private func makeAppendActionTypeMenu() -> NSMenu {
        let m = makeActionTypeMenu(insertOffset: 0)
        for item in m.items {
            item.action = #selector(appendActionFromMenu(_:))
            item.target = self
        }
        return m
    }

    @objc private func appendActionFromMenu(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? ActionInsertSpec else { return }
        let store = ScenarioStore.shared
        guard store.scenarios.indices.contains(currentScenarioIndex) else { return }
        let scenario = store.scenarios[currentScenarioIndex]
        appendOrInsertAction(of: spec.type,
                             at: scenario.actions.count,
                             in: scenario)
    }

    private func appendOrInsertAction(of type: AutoAction.ActionType,
                                      at insertIndex: Int,
                                      in scenario: Scenario) {
        let store = ScenarioStore.shared
        let newAction = makeDefaultAction(type: type, group: scenario.name)
        // Persist defaults before loadCurrentScenario triggers a.restore()
        // — otherwise stale rows under the same id would overwrite them.
        newAction.save()
        store.insertAction(newAction,
                           inScenarioAt: currentScenarioIndex,
                           atActionIndex: insertIndex)
        loadCurrentScenario()
        AppLogger.shared.log("➕ 액션 추가: \(newAction.name) @ \(insertIndex)")
    }

    @objc private func deleteClickedAction() {
        let row = tableView.clickedRow
        let store = ScenarioStore.shared
        guard store.scenarios.indices.contains(currentScenarioIndex) else { return }
        let scenario = store.scenarios[currentScenarioIndex]
        guard scenario.actions.indices.contains(row) else { return }

        let removed = scenario.actions[row]
        let alert = NSAlert()
        alert.messageText = "액션을 삭제하시겠습니까?"
        alert.informativeText = removed.name
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        store.deleteAction(inScenarioAt: currentScenarioIndex, atActionIndex: row)
        loadCurrentScenario()
        AppLogger.shared.log("🗑 액션 삭제: \(removed.name)")
    }

    /// Sensible default per action type so a freshly-inserted row isn't blank.
    private func makeDefaultAction(type: AutoAction.ActionType, group: String) -> AutoAction {
        let name: String
        var delay: Double = 0.1
        var text: String = ""
        // count is 1 for click/scroll/key (반복 횟수); OCR overrides it to
        // serve as the scan-area size in px.
        var count: Int = 1
        switch type {
        case .click:                  name = "클릭"
        case .scroll:                 name = "스크롤"
        case .drag:                   name = "드래그"
        case .key:                    name = "키 입력"; text = ":enter"
        case .wait(let wt):
            switch wt {
            case .click: name = "클릭대기"
            case .enter: name = "엔터대기"
            case .time:  name = "시간대기"; text = "09:00:00"
            }
        case .ocr:                    name = "OCR"; delay = 0.5; count = 200
        case .script:                 name = "스크립트"
        case .setURL:                 name = "URL설정"
        case .openChrome:             name = "새창"
        case .openBrowser:            name = "브라우저"; delay = 0.3
        case .windowFrame:            name = "창프레임"
        }
        return AutoAction(type: type, group: group, name: "New " + name,
                          point: .zero, delay: delay, count: count, text: text)
    }

    @objc private func onDeleteScenario() {
        let store = ScenarioStore.shared
        guard store.scenarios.count > 1 else {
            AppLogger.shared.log("⚠️ 마지막 시나리오는 삭제할 수 없습니다.")
            return
        }
        guard store.scenarios.indices.contains(currentScenarioIndex) else { return }

        let alert = NSAlert()
        alert.messageText = "시나리오를 삭제하시겠습니까?"
        alert.informativeText = store.scenarios[currentScenarioIndex].name
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn {
            let removedName = store.scenarios[currentScenarioIndex].name
            store.delete(at: currentScenarioIndex)
            currentScenarioIndex = max(0, currentScenarioIndex - 1)
            persistCurrentScenarioSelection()
            refreshScenarioPopup()
            loadCurrentScenario()
            AppLogger.shared.log("🗑 시나리오 삭제: \(removedName)")
        }
    }

    @IBAction @objc func onSettings(_ sender: Any) {
        SettingsWindowController.shared.present()
    }

    @IBAction @objc func onStart(_ : Any) {
        if try! isRunning.value() {
            AppLogger.shared.log("⏹ 자동화 중지")
            isRunning.onNext(false)
            return
        }

        // Picker now exposes year/month/day + hour/minute, so use its full value.
        // Truncate to whole minutes — we don't expose seconds in the picker UI.
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: datePicker.dateValue)
        guard let scheduledDate = calendar.date(from: comps) else { return }

        AppLogger.shared.log("▶ 자동화 시작 (예약: \(scheduledDate))")
        self.isRunning.onNext(true)
        self.errorLabel.isHidden = true

        startCountdown(to: scheduledDate)
        self.timer = scheduleTask(at: scheduledDate) { [weak self] in
            self?.beginRun()
        }
    }

    private func startCountdown(to scheduledDate: Date) {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm"
        let scheduleStr = timeFmt.string(from: scheduledDate)

        countdownTick?.invalidate()
        countdownTick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let remaining = scheduledDate.timeIntervalSince(Date())
            if remaining <= 0 {
                timer.invalidate()
                return
            }
            let m = Int(remaining) / 60
            let s = remaining - Double(m * 60)
            self.statusLabel.stringValue = "⏰ 예약: \(scheduleStr)"
            self.progressLabel.stringValue = String(format: "T-%d:%05.2f", m, s)
        }
    }

    private func beginRun() {
        countdownTick?.invalidate()
        countdownTick = nil

        let startTime = Date()
        elapsedTick?.invalidate()
        elapsedTick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.progressLabel.stringValue = String(format: "T+%.2fs",
                                                     Date().timeIntervalSince(startTime))
        }
        self.task = Task { [weak self] in
            guard let self = self else { return }
            try? await self.runner.run(try! self.actions.value())
            self.isRunning.onNext(false)
            self.statusLabel.stringValue = "✓ 완료"
        }
    }

    func saveKey(number: String, shift: Bool) {
        var num = (Int(number) ?? 0)
        if num == 0 { num = 10 }
        let action = try! actions.value()[(num - 1) + (shift ? 10 : 0)]
        guard let point = mousePoint else { return }
        action.point.onNext(point)
    }
 
    @IBAction func saveDocument(_ sender: Any?) {
        var actionsDict = [String: Any]()
        for action in try! actions.value() {
            actionsDict[action.name] = action.toJSON()
        }
        let dict: [String: Any] = [
            "version": 1,
            "scenarioIndex": currentScenarioIndex,
            "preferences": [
                "maxRandomDelay": Preferences.maxRandomDelay,
            ],
            "actions": actionsDict,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) else { return }

        let panel = NSSavePanel()
        panel.title = "저장하기"
        panel.nameFieldStringValue = "\(currentScenarioSlug()).json"
        panel.allowedContentTypes = [.json]
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try jsonData.write(to: url)
                AppLogger.shared.log("💾 설정 저장: \(url.lastPathComponent)")
            } catch {
                AppLogger.shared.log("⚠️ 저장 실패: \(error.localizedDescription)")
            }
        }
    }

    @IBAction func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "불러오기"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard let self = self, result == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                self.applyLoadedSettings(json)
                AppLogger.shared.log("📂 설정 로드: \(url.lastPathComponent)")
            } catch {
                AppLogger.shared.log("⚠️ 로드 실패: \(error.localizedDescription)")
            }
        }
    }

    private func applyLoadedSettings(_ json: [String: Any]) {
        // Switch scenario first so the right action list is visible — the
        // store's per-action UserDefaults restore runs there, and we then
        // override individual values below from the JSON payload.
        let scenarios = ScenarioStore.shared.scenarios
        // Accept both new ("scenarioIndex") and legacy ("groupIndex") keys.
        let rawIndex = (json["scenarioIndex"] as? Int) ?? (json["groupIndex"] as? Int)
        if let idx = rawIndex, scenarios.indices.contains(idx) {
            currentScenarioIndex = idx
            persistCurrentScenarioSelection()
            scenarioPopup.selectItem(at: idx)
            loadCurrentScenario()
        }

        if let prefs = json["preferences"] as? [String: Any] {
            if let v = prefs["maxRandomDelay"] as? Double { Preferences.maxRandomDelay = v }
        }

        if let actionsDict = json["actions"] as? [String: Any] {
            let current = (try? actions.value()) ?? []
            for action in current {
                if let entry = actionsDict[action.name] as? [String: Any] {
                    try? action.set(json: entry)
                }
            }
            tableView.reloadData()
        }
    }

    private func currentScenarioSlug() -> String {
        let scenarios = ScenarioStore.shared.scenarios
        guard scenarios.indices.contains(currentScenarioIndex) else { return "scenario" }
        let name = scenarios[currentScenarioIndex].name
            .replacingOccurrences(of: " ", with: "_")
        return name.isEmpty ? "scenario" : name
    }
}

// MARK: - Table

extension ViewController: NSMenuDelegate {
    /// Toggle visibility based on what the user right-clicked:
    ///   - Row clicked → "위에 추가" / "아래에 추가" + 삭제
    ///   - Empty area  → "동작 추가" (append) only
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === tableView.menu else { return }
        let rowClicked = tableView.clickedRow >= 0
        insertAboveMenuItem?.isHidden     = !rowClicked
        insertBelowMenuItem?.isHidden     = !rowClicked
        appendMenuItem?.isHidden          =  rowClicked
        deleteActionMenuItem?.isHidden    = !rowClicked
        deleteSeparatorMenuItem?.isHidden = !rowClicked
    }
}

extension ViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return try! actions.value().count
    }

    // MARK: Drag-to-reorder

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: ViewController.actionRowDragType)
        return item
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Only allow dropping between rows (not onto a row).
        return dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let str = item.string(forType: ViewController.actionRowDragType),
              let sourceRow = Int(str) else { return false }

        let store = ScenarioStore.shared
        guard store.scenarios.indices.contains(currentScenarioIndex) else { return false }
        let scenario = store.scenarios[currentScenarioIndex]
        guard scenario.actions.indices.contains(sourceRow) else { return false }

        // Removing the source first shifts the destination by one when the
        // drop is below the source — adjust accordingly.
        var destRow = row
        if destRow > sourceRow { destRow -= 1 }
        if sourceRow == destRow { return false }

        // 드래그&드랍은 실수로 트리거되기 쉬우므로 이동 전 확인.
        let movedName = scenario.actions[sourceRow].name
        let alert = NSAlert()
        alert.messageText = "액션 순서를 변경하시겠습니까?"
        alert.informativeText = "\(sourceRow + 1). \(movedName) → \(destRow + 1)번째 위치"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "이동")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        store.moveAction(inScenarioAt: currentScenarioIndex, from: sourceRow, to: destRow)
        loadCurrentScenario()
        return true
    }
}

extension ViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let action = try! actions.value()[row]
        return cellFactory.cell(for: action, at: row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = ActiveRowView()
        rv.isActive = (row == currentRunningIndex)
        return rv
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 25
    }
}

/// Row view that paints a soft blue background when it's the currently-running
/// step, plus a 3pt left accent bar mirroring the redesign's "running" marker.
private final class ActiveRowView: NSTableRowView {
    var isActive: Bool = false {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isActive {
            NSColor.systemBlue.withAlphaComponent(0.18).setFill()
            dirtyRect.fill()

            // Left accent bar — vertically centered, ~60% row height, rounded right side.
            let barWidth: CGFloat = 3
            let barHeight = bounds.height * 0.6
            let barRect = NSRect(x: 0,
                                 y: (bounds.height - barHeight) / 2,
                                 width: barWidth,
                                 height: barHeight)
            NSColor.systemBlue.setFill()
            let path = NSBezierPath()
            path.appendRoundedRect(barRect, xRadius: 1.5, yRadius: 1.5)
            path.fill()
        } else {
            super.drawBackground(in: dirtyRect)
        }
    }
}

/// Flat horizontal progress bar with an accent → teal gradient fill, replacing
/// `NSProgressIndicator` to match the redesign. Exposes the same `doubleValue`
/// / `min/maxValue` / `isHidden` API surface used by the existing bindings.
final class GradientProgressBar: NSView {
    var minValue: Double = 0  { didSet { needsDisplay = true } }
    var maxValue: Double = 1  { didSet { needsDisplay = true } }
    var doubleValue: Double = 0 { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(bounds.height, bounds.width) / 2

        // Track
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        // Fill
        let span = max(maxValue - minValue, 0.0001)
        let frac = max(0, min(1, (doubleValue - minValue) / span))
        guard frac > 0 else { return }
        let fillRect = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(frac), height: bounds.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        let gradient = NSGradient(colors: [.controlAccentColor, .systemTeal])
        gradient?.draw(in: fillPath, angle: 0)
    }
}
