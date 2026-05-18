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

    /// Held while we're either running or waiting in the cross-window run queue.
    /// Nil while idle. Set in `requestRunSlot()` and cleared on natural finish
    /// or user-initiated stop.
    private var coordinatorToken: RunCoordinator.Token?

    /// Sidebar "+ Add Action" button — disabled when the current scenario is
    /// locked because another window is running it.
    private var addActionButton: NSButton?

    /// Translucent overlay covering the detail pane while editing is locked.
    private var detailLockOverlay: NSView?

    /// Invoked whenever the user switches to a different scenario or the
    /// currently-loaded scenario is replaced/renamed. MainWindowController
    /// uses this to keep the window/tab title in sync with the selection.
    var onScenarioSelectionChanged: (() -> Void)?
    private var logTextView: NSTextView!
    /// The log area's scroll view + the height constraint we animate when
    /// the user toggles it open/closed via `logToggleButton`.
    private var logScrollView: NSScrollView!
    private var logHeightConstraint: NSLayoutConstraint!
    private var logToggleButton: NSButton!
    private let logOpenHeight: CGFloat = 140

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

    /// Single button showing the currently-selected scenario's name. Clicking
    /// it opens the scenario edit popover (rename / delete / pick-another).
    /// Built in `setupScenarioControls()`. The old `groupTab` outlet is kept
    /// alive (just hidden) so the storyboard's IBAction wiring still resolves.
    private var scenarioButton: NSButton!
    private var currentScenarioIndex: Int = 0

    /// Storyboard settings gear button, captured in `setupSettingsButtonIcon()`
    /// so other top-right widgets (e.g. the flow-mode picker) can anchor to it.
    private var settingsButton: NSButton?
    /// FlowMode picker placed just below the settings gear. Populated from
    /// `FlowModeStore` and refreshed on `FlowModeStore.didChangeNotification`.
    private var flowModePopup: NSPopUpButton!
    /// Anchor button for the FlowMode rename/delete popover (mirrors
    /// `scenarioButton`).
    private var flowModeEditButton: NSButton!
    private var currentFlowModeIndex: Int = 0

    /// Backs undo/redo for scenario + action edits. The Edit menu's
    /// `undo:` / `redo:` items resolve through the responder chain to
    /// this manager via the `undoManager` override below.
    private let undoCoordinator = UndoCoordinator()

    override var undoManager: UndoManager? {
        return undoCoordinator.manager
    }

    /// The Edit menu's Undo/Redo items target the First Responder. We
    /// implement them explicitly so the responder-chain lookup definitely
    /// finds something — NSResponder's default `undo:`/`redo:` aren't
    /// universally available across SDK versions.
    @IBAction func undo(_ sender: Any?) {
        if undoCoordinator.manager.canUndo { undoCoordinator.manager.undo() }
    }

    @IBAction func redo(_ sender: Any?) {
        if undoCoordinator.manager.canRedo { undoCoordinator.manager.redo() }
    }

    /// Enable/disable Undo + Redo menu items based on the coordinator's state.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return undoCoordinator.manager.canUndo
        case #selector(redo(_:)): return undoCoordinator.manager.canRedo
        default: return true
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupStatusAndLogView()

        datePicker.dateValue = Date()
        datePicker.toolTip = L("Auto-start time — sequence runs when this time is reached")
        startButton.toolTip = L("Start / Stop")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = -1
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 5)

        bindIsRunning()
        bindRunnerState()
        bindKeyboardListener()
        bindCoordinatorLock()

        setupScenarioControls()
        setupSettingsButtonIcon()
        setupFlowModePicker()
        setupMasterDetailLayout()
        setupActionTableMenu()
        restoreLastSelectedScenario()
        refreshScenarioPopup()
        loadCurrentScenario()

        // Initial baseline — subsequent mutations register inverses against
        // this snapshot. Must come after the first loadCurrentScenario so
        // `selectedRow` matches what the user actually sees.
        undoCoordinator.bind(to: self)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The window becomes the first responder when nothing else owns it;
        // making the view controller's view the firstResponder lets the
        // responder-chain `undo:` / `redo:` action land on us when no text
        // field has focus.
        view.window?.makeFirstResponder(view)
    }

    /// True after `applyInitialScenarioId(_:)` has set a specific scenario.
    /// Used to suppress the global `Preferences.lastScenarioId` fallback in
    /// `viewDidLoad` so per-window restore values aren't clobbered.
    private var didApplyInitialScenarioId = false

    /// Look up the scenario whose UUID matches the last saved selection and
    /// set `currentScenarioIndex` accordingly so `refreshScenarioPopup` shows
    /// it. Falls back to index 0 if no match (e.g. that scenario was deleted).
    /// Skipped when the window controller has already seeded a per-window
    /// scenario via `applyInitialScenarioId(_:)`.
    private func restoreLastSelectedScenario() {
        if didApplyInitialScenarioId { return }
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
        let addButton = NSButton(title: L("＋ Add Action"),
                                 target: self,
                                 action: #selector(showAppendActionMenu(_:)))
        addButton.bezelStyle = .roundRect
        addButton.controlSize = .regular
        addButton.toolTip = L("Append new action to current flow")
        addButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addButton)
        self.addActionButton = addButton

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

        // When a name is edited in the detail pane, reflect it in the list
        // and snapshot for undo. Name lives on the action directly (not a
        // BehaviorSubject) so the throttled merge in `loadCurrentScenario`
        // doesn't see it — capture explicitly here.
        detailBuilder.onActionRenamed = { [weak self] in
            self?.tableView.reloadData()
            self?.undoCoordinator.captureIfChanged()
        }

        // Disable checkbox in the detail pane: repaint the list so the row
        // greys out (or comes back) immediately.
        detailBuilder.onActionDisabledToggled = { [weak self] in
            self?.tableView.reloadData()
            self?.undoCoordinator.captureIfChanged()
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
        // Force layout to fully resolve now so the freshly-built form
        // settles before the user sees it — without this, NSStackView's
        // intrinsic-size measurements can race with constraint resolution
        // and produce intermittent inter-row spacing on selection changes.
        detailContainer.needsLayout = true
        detailContainer.layoutSubtreeIfNeeded()
    }

    // MARK: - View setup

    @objc private func toggleLogView() {
        applyLogVisibility(open: !Preferences.isLogOpen, animated: true)
    }

    private func applyLogVisibility(open: Bool, animated: Bool) {
        Preferences.isLogOpen = open
        let symbol = open ? "chevron.down" : "chevron.up"
        logToggleButton.image = NSImage(systemSymbolName: symbol,
                                        accessibilityDescription: "로그 토글")
        // Hide the scroll view when collapsed so it doesn't intercept clicks
        // or render a sliver behind layer-backed content.
        logScrollView.isHidden = !open
        let newHeight: CGFloat = open ? logOpenHeight : 0
        guard animated else {
            logHeightConstraint.constant = newHeight
            view.layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            self.logHeightConstraint.animator().constant = newHeight
            self.view.layoutSubtreeIfNeeded()
        }, completionHandler: nil)
    }

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
        statusLabel.stringValue = L("Ready")
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

        // Chevron toggle for opening / closing the bottom log view. Lives in
        // the status panel's top-right corner so it stays visible whether
        // the log itself is open or collapsed.
        let toggleBtn = NSButton()
        toggleBtn.bezelStyle = .recessed
        toggleBtn.isBordered = false
        toggleBtn.imagePosition = .imageOnly
        toggleBtn.contentTintColor = .secondaryLabelColor
        toggleBtn.target = self
        toggleBtn.action = #selector(toggleLogView)
        toggleBtn.toolTip = L("Show / hide log")
        toggleBtn.translatesAutoresizingMaskIntoConstraints = false
        logToggleButton = toggleBtn

        statusPanel.addSubview(statusLabel)
        statusPanel.addSubview(progressLabel)
        statusPanel.addSubview(progressBar)
        statusPanel.addSubview(errorLabel)
        statusPanel.addSubview(toggleBtn)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusPanel.leadingAnchor, constant: 12),
            statusLabel.topAnchor.constraint(equalTo: statusPanel.topAnchor, constant: 6),
            toggleBtn.trailingAnchor.constraint(equalTo: statusPanel.trailingAnchor, constant: -8),
            toggleBtn.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            toggleBtn.widthAnchor.constraint(equalToConstant: 22),
            toggleBtn.heightAnchor.constraint(equalToConstant: 18),
            // Progress label sits just to the left of the toggle button.
            progressLabel.trailingAnchor.constraint(equalTo: toggleBtn.leadingAnchor, constant: -8),
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
        logScrollView = scrollView
        // The height constraint is animated when the user toggles the log
        // open/closed. Captured here so `toggleLogView` can mutate it.
        logHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: logOpenHeight)

        NSLayoutConstraint.activate([
            statusPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusPanel.topAnchor.constraint(equalTo: imageView.bottomAnchor),
            statusPanel.heightAnchor.constraint(equalToConstant: 56),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: statusPanel.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            logHeightConstraint,
        ])

        bindLogView()
        applyLogVisibility(open: Preferences.isLogOpen, animated: false)
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
                // If we held (or were waiting for) a slot in the cross-window
                // run queue, release it now so other windows can proceed.
                if let token = self.coordinatorToken {
                    RunCoordinator.shared.cancel(token: token)
                    self.coordinatorToken = nil
                }
                self.statusLabel.stringValue = "준비"
                self.progressLabel.stringValue = ""
                self.progressBar.isHidden = true
                self.progressBar.doubleValue = 0
            }
        }.disposed(by: disposeBag)
    }

    /// Watch the cross-window coordinator. Whenever the scenario that's
    /// currently being executed (anywhere in the app) matches the one this
    /// window is showing, lock the edit surface.
    private func bindCoordinatorLock() {
        RunCoordinator.shared.activeScenarioId
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] activeId in
                guard let self = self else { return }
                let mine = self.currentScenarioIdString()
                self.applyEditingLock(activeId != nil && activeId == mine)
            }).disposed(by: disposeBag)

        // When the queue mutates and we hold a queued token, refresh the
        // status label so "대기 중 (N번째)" stays accurate.
        RunCoordinator.shared.queueDidChange
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] _ in
                self?.refreshQueueStatus()
            }).disposed(by: disposeBag)
    }

    private func refreshQueueStatus() {
        guard let token = coordinatorToken,
              let pos = RunCoordinator.shared.queuePosition(of: token) else { return }
        statusLabel.stringValue = "⏸ 대기 중 (\(pos)번째)"
    }

    /// Show/hide the lock overlay on the detail pane and gate mutation entry
    /// points (add-action button, table reorder, right-click delete).
    private func applyEditingLock(_ locked: Bool) {
        addActionButton?.isEnabled = !locked

        if locked {
            if detailLockOverlay == nil, let container = detailContainer {
                let overlay = NSVisualEffectView()
                overlay.material = .hudWindow
                overlay.blendingMode = .withinWindow
                overlay.state = .active
                overlay.translatesAutoresizingMaskIntoConstraints = false
                let label = NSTextField(labelWithString: "🔒 다른 창에서 실행 중 — 편집 잠금")
                label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                overlay.addSubview(label)
                container.addSubview(overlay, positioned: .above, relativeTo: nil)
                NSLayoutConstraint.activate([
                    overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    overlay.topAnchor.constraint(equalTo: container.topAnchor),
                    overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                ])
                detailLockOverlay = overlay
            }
        } else {
            detailLockOverlay?.removeFromSuperview()
            detailLockOverlay = nil
        }
    }

    /// True iff this window's currently-displayed scenario is being executed
    /// (in this or any other window).
    private var isCurrentScenarioLocked: Bool {
        guard let active = try? RunCoordinator.shared.activeScenarioId.value() else {
            return false
        }
        return active == currentScenarioIdString()
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
                } else if code == 53 {
                    // ESC aborts the in-progress flow — same teardown path as
                    // the Stop button (cancels the Task, releases the queue
                    // slot, stops the runner).
                    AppLogger.shared.log("⏹ ESC 키로 중단")
                    self.isRunning.onNext(false)
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

        // Single button showing the selected scenario name; clicking it opens
        // the same edit popover the old "편집" button used (which also lets the
        // user switch to a different scenario from the list inside).
        scenarioButton = NSButton(title: "",
                                  target: self,
                                  action: #selector(showScenarioEditPopover))
        scenarioButton.bezelStyle = .roundRect
        scenarioButton.controlSize = .regular
        scenarioButton.toolTip = L("Manage flows")
        scenarioButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scenarioButton)

        NSLayoutConstraint.activate([
            // Pin to the leading edge with the same 14pt inset the redesign
            // uses for its toolbar — the storyboard's hidden segmented
            // control was positioned further right and we no longer want to
            // inherit that offset.
            scenarioButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            scenarioButton.topAnchor.constraint(equalTo: groupTab.topAnchor),
            scenarioButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])

        // Cross-Runner sync: any window's add/rename/delete/duplicate calls
        // ScenarioStore.save() which posts this notification. Other Runners
        // must rebuild their popup immediately so the pulldown reflects the
        // current list across windows.
        NotificationCenter.default.addObserver(
            forName: ScenarioStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScenarioStoreChange()
        }
    }

    /// React to a scenario list mutation that may have originated from a
    /// different Runner window. Re-resolve the displayed scenario by UUID
    /// (its index can shift when entries are added/removed), refresh the
    /// popup, and reload the scenario only if the one we were showing was
    /// deleted elsewhere.
    private func handleScenarioStoreChange() {
        guard scenarioButton != nil else { return }
        let store = ScenarioStore.shared
        let displayedId = currentScenarioIdString()

        let stillExists: Bool
        if let id = displayedId,
           let idx = store.scenarios.firstIndex(where: { $0.id.uuidString == id }) {
            currentScenarioIndex = idx
            stillExists = true
        } else {
            currentScenarioIndex = min(currentScenarioIndex, max(0, store.scenarios.count - 1))
            stillExists = false
        }

        refreshScenarioPopup()

        if !stillExists {
            persistCurrentScenarioSelection()
            loadCurrentScenario()
            undoCoordinator.resetBaseline()
        }
    }

    /// Replace the storyboard "설정" text button with a gear SF Symbol so
    /// the toolbar reads as a row of consistent small icons. We don't have
    /// an IBOutlet for the button, so locate it by walking the view tree
    /// for the NSButton wired to `onSettings:`.
    private func setupSettingsButtonIcon() {
        func find(in view: NSView) -> NSButton? {
            if let btn = view as? NSButton, btn.action == #selector(onSettings(_:)) {
                return btn
            }
            for sub in view.subviews {
                if let found = find(in: sub) { return found }
            }
            return nil
        }
        guard let btn = find(in: view) else { return }
        settingsButton = btn

        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbolNames = ["gearshape", "gear"]
        for name in symbolNames {
            if let gear = NSImage(systemSymbolName: name, accessibilityDescription: "설정")?
                .withSymbolConfiguration(cfg) {
                btn.image = gear
                btn.imagePosition = .imageOnly
                btn.title = ""
                btn.toolTip = L("Settings")
                btn.contentTintColor = .secondaryLabelColor
                break
            }
        }
    }

    /// Build the FlowMode picker + edit button and pin it just below the
    /// settings gear in the top-right corner. Falls back to the view's
    /// top-trailing if the settings button wasn't found (storyboard mismatch
    /// — shouldn't happen).
    private func setupFlowModePicker() {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(onChangeFlowMode(_:))
        popup.controlSize = .small
        popup.translatesAutoresizingMaskIntoConstraints = false
        flowModePopup = popup

        let addBtn = NSButton(title: "＋",
                              target: self,
                              action: #selector(onAddFlowMode(_:)))
        addBtn.bezelStyle = .roundRect
        addBtn.controlSize = .small
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.toolTip = L("Add flow")

        let editBtn = NSButton(title: "편집",
                               target: self,
                               action: #selector(showFlowModeEditPopover))
        editBtn.bezelStyle = .roundRect
        editBtn.controlSize = .small
        editBtn.translatesAutoresizingMaskIntoConstraints = false
        editBtn.toolTip = L("Rename / delete flow")
        flowModeEditButton = editBtn

        let stack = NSStackView(views: [addBtn, popup, editBtn])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let topAnchor: NSLayoutYAxisAnchor
        let trailingAnchor: NSLayoutXAxisAnchor
        let topConstant: CGFloat
        if let anchor = settingsButton {
            topAnchor = anchor.bottomAnchor
            trailingAnchor = anchor.trailingAnchor
            topConstant = 6
        } else {
            topAnchor = view.topAnchor
            trailingAnchor = view.trailingAnchor
            topConstant = 40
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: topConstant),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        refreshFlowModePopup()

        NotificationCenter.default.addObserver(
            forName: FlowModeStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshFlowModePopup()
            // `.nextScenario` detail rows are keyed by the FlowMode list,
            // so rebuild the detail pane when modes are added/renamed/deleted.
            self?.refreshDetailPane()
        }
    }

    private func refreshFlowModePopup() {
        guard let popup = flowModePopup else { return }
        popup.removeAllItems()
        let modes = FlowModeStore.shared.flowModes
        for mode in modes {
            popup.addItem(withTitle: mode.name)
        }
        let safeIndex = min(max(0, currentFlowModeIndex), modes.count - 1)
        if modes.indices.contains(safeIndex) {
            popup.selectItem(at: safeIndex)
            currentFlowModeIndex = safeIndex
        }
        updateFlowModeEditButtonState()
    }

    @objc private func onChangeFlowMode(_ sender: Any?) {
        let idx = flowModePopup.indexOfSelectedItem
        guard FlowModeStore.shared.flowModes.indices.contains(idx) else { return }
        currentFlowModeIndex = idx
        updateFlowModeEditButtonState()
        // Selection hook — wire to whatever consumes the active FlowMode.
    }

    /// 첫 번째(디폴트) 모드는 이름 변경/삭제가 불가능하므로 편집 버튼 자체를
    /// 비활성화한다.
    private func updateFlowModeEditButtonState() {
        flowModeEditButton?.isEnabled = currentFlowModeIndex != 0
    }

    @objc private func onAddFlowMode(_ sender: Any?) {
        let store = FlowModeStore.shared
        let baseName = store.flowModes.indices.contains(currentFlowModeIndex)
            ? store.flowModes[currentFlowModeIndex].name
            : "Mode"
        let newName = "New \(baseName)"
        store.add(FlowMode(name: newName))
        currentFlowModeIndex = store.flowModes.count - 1
        refreshFlowModePopup()
        AppLogger.shared.log("➕ 모드 추가: \(newName)")
    }

    /// Rename / delete dialog for the currently-selected FlowMode. Mirrors
    /// `showScenarioEditPopover()`.
    @objc private func showFlowModeEditPopover() {
        let store = FlowModeStore.shared
        guard store.flowModes.indices.contains(currentFlowModeIndex) else { return }
        let current = store.flowModes[currentFlowModeIndex]

        let alert = NSAlert()
        alert.messageText = "모드 편집"
        alert.informativeText = "이름을 변경하거나 모드를 삭제할 수 있습니다."

        let input = NSTextField(string: current.name)
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input

        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        // 마지막 남은 모드는 삭제할 수 없으므로 버튼 자체를 노출하지 않는다.
        let canDelete = store.flowModes.count > 1
        if canDelete {
            alert.addButton(withTitle: "삭제")
        }

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed != current.name else { return }
            store.rename(at: currentFlowModeIndex, to: trimmed)
            refreshFlowModePopup()
        case .alertThirdButtonReturn where canDelete:
            onDeleteFlowMode()
        default:
            break
        }
    }

    @objc private func onDeleteFlowMode() {
        let store = FlowModeStore.shared
        guard store.flowModes.count > 1 else {
            AppLogger.shared.log("⚠️ 마지막 모드는 삭제할 수 없습니다.")
            return
        }
        guard store.flowModes.indices.contains(currentFlowModeIndex) else { return }

        let alert = NSAlert()
        alert.messageText = "모드를 삭제하시겠습니까?"
        alert.informativeText = store.flowModes[currentFlowModeIndex].name
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn {
            let removedName = store.flowModes[currentFlowModeIndex].name
            store.delete(at: currentFlowModeIndex)
            currentFlowModeIndex = max(0, currentFlowModeIndex - 1)
            refreshFlowModePopup()
            AppLogger.shared.log("🗑 모드 삭제: \(removedName)")
        }
    }

    /// Update the scenario button's title to the currently-selected scenario
    /// name. Clamps `currentScenarioIndex` to the store's bounds and falls
    /// back to a placeholder label when there are no scenarios.
    private func refreshScenarioPopup() {
        let store = ScenarioStore.shared
        let safeIndex = min(max(0, currentScenarioIndex), store.scenarios.count - 1)
        if store.scenarios.indices.contains(safeIndex) {
            currentScenarioIndex = safeIndex
            scenarioButton.title = store.scenarios[safeIndex].name
        } else {
            scenarioButton.title = L("Manage flows")
        }
    }

    /// Push the currently-selected scenario's actions into `self.actions`,
    /// hook up per-action UserDefaults persistence, and refresh the table.
    /// Pass `selectRow` to override the default "select row 0" behavior — e.g.
    /// callers that just inserted a row want the new row selected instead.
    private func loadCurrentScenario(selectRow: Int? = nil) {
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
                .subscribe { [weak self] _ in
                    a.save()
                    self?.undoCoordinator.captureIfChanged()
                }
                .disposed(by: actionsBag)
        }
        tableView.reloadData()

        if !actions.isEmpty {
            let target = max(0, min(selectRow ?? 0, actions.count - 1))
            tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            tableView.scrollRowToVisible(target)
        } else {
            refreshDetailPane()
        }
        onScenarioSelectionChanged?()
    }

    @objc private func addEmptyScenario(_ sender: Any?) {
        let store = ScenarioStore.shared
        let baseName = store.scenarios.indices.contains(currentScenarioIndex)
            ? store.scenarios[currentScenarioIndex].name
            : "Flow"
        let newName = "New \(baseName)"
        store.add(Scenario(name: newName, actions: []))
        currentScenarioIndex = store.scenarios.count - 1
        persistCurrentScenarioSelection()
        refreshScenarioPopup()
        loadCurrentScenario()
        undoCoordinator.captureIfChanged()
        AppLogger.shared.log("➕ 플로우 추가: \(newName)")
    }

    @objc private func duplicateCurrentScenario(_ sender: Any?) {
        let store = ScenarioStore.shared
        guard store.scenarios.indices.contains(currentScenarioIndex) else { return }
        let source = store.scenarios[currentScenarioIndex]
        let newName = uniqueScenarioName(basedOn: source.name)
        guard store.duplicate(at: currentScenarioIndex, newName: newName) != nil else { return }
        // ScenarioStore.duplicate appends, so the copy lives at the end.
        currentScenarioIndex = store.scenarios.count - 1
        persistCurrentScenarioSelection()
        refreshScenarioPopup()
        loadCurrentScenario()
        undoCoordinator.captureIfChanged()
        AppLogger.shared.log("➕ 플로우 복제: \(source.name) → \(newName)")
    }

    /// "<name> 복사", "<name> 복사 2", ... — avoids name collisions in the
    /// popup so duplicates are visually distinguishable from the source.
    private func uniqueScenarioName(basedOn base: String) -> String {
        let store = ScenarioStore.shared
        let existing = Set(store.scenarios.map { $0.name })
        let first = "\(base) 복사"
        if !existing.contains(first) { return first }
        var n = 2
        while existing.contains("\(first) \(n)") { n += 1 }
        return "\(first) \(n)"
    }

    /// Holds the active SequenceRecorder so its underlying CGEventTap stays
    /// alive — recorders self-destruct when this reference drops.
    private var sequenceRecorder: SequenceRecorder?
    /// Floating HUD shown during sequence recording. Non-interactive
    /// (`ignoresMouseEvents = true`) so the user's clicks pass through to
    /// whatever they're demonstrating on.
    private var recordingHUD: NSPanel?

    @objc private func beginSequenceRecording(_ sender: Any?) {
        guard sequenceRecorder == nil else { return }

        // Create the empty flow first so captured actions have somewhere to
        // land. Reusing the empty-flow path keeps naming + selection logic
        // in one place.
        addEmptyScenario(sender)
        let flowName = ScenarioStore.shared.scenarios.indices.contains(currentScenarioIndex)
            ? ScenarioStore.shared.scenarios[currentScenarioIndex].name
            : ""
        AppLogger.shared.log("⏺ 시퀀스 녹화 시작: \(flowName) — ESC 로 종료")

        showRecordingHUD()
        // Step out of the way so the user sees the app they're demonstrating
        // on, matching the action-edit picker behavior. The HUD is a floating
        // .nonactivatingPanel so it stays visible across the app handoff.
        ActionDetailBuilder.setMainWindowHidden(true, anchor: self.view)

        let recorder = SequenceRecorder()
        sequenceRecorder = recorder
        recorder.onAction = { [weak self] action in
            self?.appendRecordedAction(action)
        }
        recorder.onEnd = { [weak self] in
            self?.finishSequenceRecording()
        }
        recorder.start()
    }

    /// Insert a recorded action at the end of the current flow and refresh
    /// the table so the user sees it appear live.
    private func appendRecordedAction(_ action: AutoAction) {
        let store = ScenarioStore.shared
        guard store.scenarios.indices.contains(currentScenarioIndex) else { return }
        let scenario = store.scenarios[currentScenarioIndex]
        action.group = scenario.name
        action.save()
        store.insertAction(action,
                           inScenarioAt: currentScenarioIndex,
                           atActionIndex: scenario.actions.count)
        loadCurrentScenario()
        undoCoordinator.captureIfChanged()
    }

    private func finishSequenceRecording() {
        sequenceRecorder = nil
        ActionDetailBuilder.setMainWindowHidden(false, anchor: self.view)
        hideRecordingHUD()
        let count = (try? actions.value().count) ?? 0
        AppLogger.shared.log("⏹ 시퀀스 녹화 종료 — \(count)개 액션")
    }

    private func showRecordingHUD() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let backdrop = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true
        backdrop.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "🔴  녹화 중 — ESC 키로 종료")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
        ])

        panel.contentView = backdrop

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let pf = panel.frame
            let x = visible.midX - pf.width / 2
            let y = visible.maxY - pf.height - 30
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        recordingHUD = panel
    }

    private func hideRecordingHUD() {
        recordingHUD?.orderOut(nil)
        recordingHUD = nil
    }

    /// Lazy-instantiated manager window: left list of every scenario with
    /// drag-to-reorder + a [+] menu, right pane editing the selected
    /// scenario's name with a 삭제 button.
    private lazy var scenarioListEditor: ScenarioListEditorWindowController = {
        let editor = ScenarioListEditorWindowController()
        editor.onBeginSequenceRecording = { [weak self] in
            self?.beginSequenceRecording(nil)
        }
        editor.onMutated = { [weak self] in
            self?.undoCoordinator.captureIfChanged()
        }
        editor.onScenarioSelected = { [weak self] scenarioId in
            self?.selectScenario(byId: scenarioId)
        }
        return editor
    }()

    @objc private func showScenarioEditPopover() {
        scenarioListEditor.present(selectedScenarioIndex: currentScenarioIndex)
    }

    /// Re-point the picker + currently-loaded scenario at the scenario with
    /// the given UUID. Invoked from the manager window when the user picks a
    /// row there so the main view tracks the editor's selection.
    private func selectScenario(byId id: UUID) {
        let store = ScenarioStore.shared
        guard let idx = store.scenarios.firstIndex(where: { $0.id == id }) else { return }
        guard idx != currentScenarioIndex else { return }
        currentScenarioIndex = idx
        persistCurrentScenarioSelection()
        refreshScenarioPopup()
        loadCurrentScenario()
        undoCoordinator.resetBaseline()
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
        insertAboveMenuItem = NSMenuItem(title: L("Insert Above"), action: nil, keyEquivalent: "")
        insertAboveMenuItem.submenu = makeActionTypeMenu(insertOffset: 0)
        menu.addItem(insertAboveMenuItem)

        insertBelowMenuItem = NSMenuItem(title: L("Insert Below"), action: nil, keyEquivalent: "")
        insertBelowMenuItem.submenu = makeActionTypeMenu(insertOffset: 1)
        menu.addItem(insertBelowMenuItem)

        // Empty area clicked → 동작 추가 (append). The submenu's items also
        // route through `insertActionFromMenu`, which appends when
        // `tableView.clickedRow < 0`.
        appendMenuItem = NSMenuItem(title: L("Add Action"), action: nil, keyEquivalent: "")
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
            (L("🖱  Click"), .click),
            (L("⬇  Scroll"), .scroll),
            (L("✋  Drag"), .drag),
            (L("⌨︎  Key"), .key),
            // 통합 대기 — 디테일 패널에서 시간/클릭/엔터 중 선택. 신규 생성
            // 시 기본값은 시간 대기.
            (L("⏱  Wait"), .wait(type: .time)),
            (L("🔍  OCR"), .ocr),
            (L("📝  Script"), .script(code: "")),
            // Hidden from the picker until needed again — `.setURL` /
            // `.openChrome` are Chrome-specific and superseded by `.openBrowser`.
            // Runtime / detail UI / persistence for these types stays intact
            // so old scenarios still load and run.
            // ("🌐  URL", .setURL(url: "")),
            // ("🆕  새창", .openChrome(url: "")),
            (L("🌐🪟  Browser"), .openBrowser(url: "")),
            (L("🪟  Window Frame"), .windowFrame),
            (L("➡️  Go to Flow"), .nextScenario),
            (L("🤖  AI Generate"), .aiGen),
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

    /// Build menu items for the static File → 새로만들기 → 액션 추가 submenu.
    /// Items target First Responder so the active window's ViewController
    /// receives `appendActionFromMenu(_:)` and appends to its current scenario.
    static func buildAppendActionSubmenuItems() -> [NSMenuItem] {
        let types: [(String, AutoAction.ActionType)] = [
            (L("🖱  Click"), .click),
            (L("⬇  Scroll"), .scroll),
            (L("✋  Drag"), .drag),
            (L("⌨︎  Key"), .key),
            (L("⏱  Wait"), .wait(type: .time)),
            (L("🔍  OCR"), .ocr),
            (L("📝  Script"), .script(code: "")),
            (L("🌐🪟  Browser"), .openBrowser(url: "")),
            (L("🪟  Window Frame"), .windowFrame),
            (L("➡️  Go to Flow"), .nextScenario),
            (L("🤖  AI Generate"), .aiGen),
        ]
        return types.map { (label, type) in
            let item = NSMenuItem(title: label,
                                  action: #selector(appendActionFromMenu(_:)),
                                  keyEquivalent: "")
            item.representedObject = ActionInsertSpec(offset: 0, type: type)
            return item
        }
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
    @objc func showAppendActionMenu(_ sender: Any?) {
        let menu = makeAppendActionTypeMenu()
        if let view = sender as? NSView {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: view.bounds.height + 2),
                       in: view)
        } else if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: self.view)
        }
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
        loadCurrentScenario(selectRow: insertIndex)
        undoCoordinator.captureIfChanged()
        AppLogger.shared.log("➕ 액션 추가: \(newAction.name) @ \(insertIndex)")
    }

    @objc private func deleteClickedAction() {
        if isCurrentScenarioLocked {
            AppLogger.shared.log("🔒 다른 창에서 실행 중 — 삭제 불가")
            return
        }
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
        undoCoordinator.captureIfChanged()
        AppLogger.shared.log("🗑 액션 삭제: \(removed.name)")
    }

    /// Sensible default per action type so a freshly-inserted row isn't blank.
    private func makeDefaultAction(type: AutoAction.ActionType, group: String) -> AutoAction {
        let name: String
        // User-configured baseline (Settings → "액션 기본 딜레이"). Becomes
        // the floor for every new action's delay; per-type minimums below
        // raise it further for action types that need more time.
        let userDefault = max(0, Preferences.defaultActionDelay)
        var delay: Double = max(0.1, userDefault)
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
        case .ocr:                    name = "글자인식 클릭"; delay = max(0.5, userDefault); count = 200
        case .script:                 name = "스크립트"
        case .setURL:                 name = "URL설정"
        case .openChrome:             name = "새창"
        case .openBrowser:            name = "브라우저"; delay = max(0.3, userDefault)
        case .windowFrame:            name = "창프레임"
        case .nextScenario:           name = "플로우 이동"
        case .aiGen:                  name = "AI 생성"; delay = max(0.3, userDefault); count = 400
        }
        let action = AutoAction(type: type, group: group, name: name,
                                point: .zero, delay: delay, count: count, text: text)
        // `.nextScenario` ignores `action.delay` at runtime — its per-
        // FlowMode delay map is the source of truth. Seed each existing
        // FlowMode with the user's configured default so the edit screen
        // doesn't show empty (zero) rows for a fresh action.
        if case .nextScenario = type, userDefault > 0 {
            let defId = FlowModeStore.shared.flowModes.first?.id.uuidString
            for mode in FlowModeStore.shared.flowModes {
                action.setNextScenarioDelay(userDefault,
                                            forModeId: mode.id.uuidString,
                                            defaultModeId: defId)
            }
        }
        return action
    }

    @objc private func onDeleteScenario() {
        let store = ScenarioStore.shared
        guard store.scenarios.count > 1 else {
            AppLogger.shared.log("⚠️ 마지막 플로우는 삭제할 수 없습니다.")
            return
        }
        guard store.scenarios.indices.contains(currentScenarioIndex) else { return }

        let alert = NSAlert()
        alert.messageText = "플로우를 삭제하시겠습니까?"
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
            undoCoordinator.captureIfChanged()
            AppLogger.shared.log("🗑 플로우 삭제: \(removedName)")
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
            self?.requestRunSlot()
        }
    }

    /// Called when the scheduled-time countdown fires. Asks the coordinator
    /// for a turn — if no other window is running, fires immediately;
    /// otherwise queues and surfaces "⏸ 대기 중 (N번째)" until we're up.
    private func requestRunSlot() {
        guard let sid = currentScenarioIdString() else {
            isRunning.onNext(false)
            return
        }
        let token = RunCoordinator.shared.requestRun(scenarioId: sid,
                                                     owner: self) { [weak self] in
            self?.beginRun()
        }
        coordinatorToken = token
        if RunCoordinator.shared.queuePosition(of: token) != nil {
            refreshQueueStatus()
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
        // Tag the runner with which scenario it's about to execute, so
        // `.aiGen` can tell the server which flow not to branch back to.
        let store = ScenarioStore.shared
        if store.scenarios.indices.contains(currentScenarioIndex) {
            let scenario = store.scenarios[currentScenarioIndex]
            runner.currentScenarioId = scenario.id.uuidString
            runner.currentScenarioName = scenario.name
        } else {
            runner.currentScenarioId = nil
            runner.currentScenarioName = nil
        }
        // Pin the active FlowMode for the duration of this run so
        // `.nextScenario` actions can pick a per-mode target.
        let modes = FlowModeStore.shared.flowModes
        if modes.indices.contains(currentFlowModeIndex) {
            runner.currentFlowModeId = modes[currentFlowModeIndex].id.uuidString
        } else {
            runner.currentFlowModeId = nil
        }
        self.task = Task { [weak self] in
            guard let self = self else { return }
            try? await self.runner.run(try! self.actions.value())

            // The just-finished sequence asked us to chain to another
            // scenario via a `.nextScenario` action. Move the popup +
            // action list and kick off a fresh run. If we can't honour
            // the request (no next scenario, unknown id, etc.) fall
            // through and finish normally.
            if let request = self.runner.nextScenarioRequest,
               try! self.isRunning.value(),
               self.advanceScenario(for: request) {
                // `.nextScenario` emits no input events, so it's a safe
                // yield point: release the slot, then re-request one for
                // the chained scenario. This lets any waiting window run
                // first; the chained run rejoins the back of the queue.
                if let oldToken = self.coordinatorToken {
                    RunCoordinator.shared.finish(token: oldToken)
                    self.coordinatorToken = nil
                }
                self.requestRunSlot()
                return
            }

            // Sequence complete (no chaining). Release the slot before
            // flipping isRunning so the next queued window can start.
            if let token = self.coordinatorToken {
                RunCoordinator.shared.finish(token: token)
                self.coordinatorToken = nil
            }
            self.isRunning.onNext(false)
            self.statusLabel.stringValue = L("✓ Done")
        }
    }

    /// Resolve the `.nextScenario` action's target and move the popup /
    /// action list to it. Returns false when the request can't be honoured
    /// (already at the last scenario for `.next`, or an unknown id for
    /// `.specific`) so the caller knows to stop running.
    private func advanceScenario(for request: AutomationRunner.NextScenarioRequest) -> Bool {
        let store = ScenarioStore.shared
        let target: Int
        switch request {
        case .next:
            let nextIndex = currentScenarioIndex + 1
            guard store.scenarios.indices.contains(nextIndex) else {
                AppLogger.shared.log("➡️ 다음 플로우 없음 — 자동화 종료")
                return false
            }
            target = nextIndex
        case .specific(let id):
            guard let idx = store.scenarios.firstIndex(where: { $0.id.uuidString == id }) else {
                AppLogger.shared.log("⚠️ 플로우를 찾지 못함 (id=\(id)) — 자동화 종료")
                return false
            }
            target = idx
        }
        currentScenarioIndex = target
        persistCurrentScenarioSelection()
        refreshScenarioPopup()
        loadCurrentScenario()
        AppLogger.shared.log("➡️ 플로우 전환: \(store.scenarios[target].name)")
        return true
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
            refreshScenarioPopup()
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

        // Loading a document is a hard reset — drop the undo history so the
        // user can't accidentally undo back into pre-load state and end up
        // with a partially-applied mix.
        undoManager?.removeAllActions()
        undoCoordinator.resetBaseline()
    }

    // MARK: - MainWindowController integration

    /// Returns the UUID string of the scenario currently displayed in this
    /// window, or nil if no scenario is selected. Used by RunCoordinator to
    /// route the cross-window edit lock and by MainWindowController to
    /// persist per-window selection.
    func currentScenarioIdString() -> String? {
        let scenarios = ScenarioStore.shared.scenarios
        guard scenarios.indices.contains(currentScenarioIndex) else { return nil }
        return scenarios[currentScenarioIndex].id.uuidString
    }

    /// Override the saved-last-scenario restore for this specific window.
    /// MainWindowController sets this before viewDidLoad runs the first time;
    /// no-op if scenarios haven't been seeded yet.
    func applyInitialScenarioId(_ id: String?) {
        guard let id = id else { return }
        let scenarios = ScenarioStore.shared.scenarios
        if let idx = scenarios.firstIndex(where: { $0.id.uuidString == id }) {
            currentScenarioIndex = idx
            // Mark so viewDidLoad's `restoreLastSelectedScenario()` doesn't
            // clobber this per-window selection with the global preference.
            didApplyInitialScenarioId = true
            // viewDidLoad may not have fired yet (storyboard hasn't loaded
            // the view). When it runs, refreshScenarioPopup/loadCurrentScenario
            // will pick up the new index. If it already ran, update the UI.
            if scenarioButton != nil {
                refreshScenarioPopup()
                loadCurrentScenario()
            }
        }
    }

    /// Stop any active run + release the coordinator slot. Called by
    /// MainWindowController.windowWillClose so a closed window doesn't
    /// leave the cross-window queue stuck.
    func prepareForWindowClose() {
        if try! isRunning.value() {
            isRunning.onNext(false)  // cleanup cancels token + stops runner
        } else if let token = coordinatorToken {
            RunCoordinator.shared.cancel(token: token)
            coordinatorToken = nil
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

// MARK: - Undo / Redo

extension ViewController: UndoSnapshotTarget {
    func makeUndoSnapshot() -> UndoSnapshot {
        // Capture the full tree (groups + ordering) so undo doesn't
        // collapse the user's group structure into a flat list.
        let payload = ScenarioStore.shared.tree.map { $0.toJSON() }
        let data = (try? JSONSerialization.data(withJSONObject: payload,
                                                options: [.sortedKeys])) ?? Data()
        return UndoSnapshot(scenariosData: data,
                            currentScenarioIndex: currentScenarioIndex,
                            selectedRow: tableView.selectedRow)
    }

    func applyUndoSnapshot(_ snapshot: UndoSnapshot) {
        let store = ScenarioStore.shared
        guard let raw = try? JSONSerialization.jsonObject(with: snapshot.scenariosData),
              let arr = raw as? [[String: Any]] else { return }
        let restoredTree = arr.compactMap { ScenarioNode.fromJSON($0) }
        let restored: [Scenario] = restoredTree.flatMap { node -> [Scenario] in
            switch node {
            case .group(let g):    return g.scenarios
            case .scenario(let s): return [s]
            }
        }

        // Identify actions that vanished so their per-action SQLite + OCR
        // snapshot rows can be reclaimed. Anything still present has its
        // values written back so a subsequent `restore()` reads the
        // snapshot's values rather than stale rows.
        let oldIds = Set(store.scenarios.flatMap { $0.actions.map { $0.id } })
        let newIds = Set(restored.flatMap { $0.actions.map { $0.id } })
        for id in oldIds.subtracting(newIds) {
            ActionStore.shared.delete(id: id)
            OCRSnapshotStore.shared.delete(actionId: id)
        }
        for scenario in restored {
            for action in scenario.actions {
                action.group = scenario.name
                action.save()
            }
        }

        store.replaceAll(tree: restoredTree)

        let safeIndex = max(0, min(snapshot.currentScenarioIndex, restored.count - 1))
        currentScenarioIndex = safeIndex
        persistCurrentScenarioSelection()
        refreshScenarioPopup()
        loadCurrentScenario(selectRow: snapshot.selectedRow)
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
        // Don't allow reordering while the scenario is being executed (in
        // any window) — mutating the list out from under the runner is the
        // user-facing manifestation of "edit lock during run".
        if isCurrentScenarioLocked { return nil }
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
        undoCoordinator.captureIfChanged()
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
