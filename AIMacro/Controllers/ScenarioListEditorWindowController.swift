//
//  ScenarioListEditorWindowController.swift
//  AIMacro
//
//  Modal-style manager window invoked from the 편집 button next to the
//  scenario picker. Lists every scenario on the left with drag-to-reorder
//  and a [+] menu (빈 플로우 생성 / 현재 플로우 복제 / 시퀀스로 기록).
//  Right pane edits the selected scenario's name and exposes a 삭제 button.
//

import Cocoa

final class ScenarioListEditorWindowController: NSWindowController {

    // MARK: - Public surface

    /// Callback for "시퀀스로 기록" — recording is tightly coupled to the
    /// main ViewController (HUD + SequenceRecorder + window hide), so it's
    /// delegated back rather than reimplemented here. The editor closes
    /// before invoking this so the recorder can take over the screen.
    var onBeginSequenceRecording: (() -> Void)?

    /// Fired after any mutation that the parent VC needs to fold into its
    /// undo stack (`undoCoordinator.captureIfChanged()`). ScenarioStore
    /// posts its own change notification, but undo capture lives in VC.
    var onMutated: (() -> Void)?

    /// Fired when the user picks a different row so the parent VC can
    /// switch its popup selection. The editor itself drives the right
    /// pane; the parent just needs to keep its picker in sync.
    var onScenarioSelected: ((UUID) -> Void)?

    // MARK: - State

    /// Pasteboard type for drag-to-reorder within the scenario list.
    private static let dragType = NSPasteboard.PasteboardType("com.aimacro.scenarioListRow")

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var addButton: NSButton!
    private var nameField: NSTextField!
    private var actionCountLabel: NSTextField!
    private var deleteButton: NSButton!
    private var detailContainer: NSView!

    /// Currently-selected row in the editor's list. -1 when nothing is
    /// selected (e.g. the list is empty).
    private var selectedRow: Int = -1

    /// Set true while we're reloading the table programmatically, so the
    /// selection-changed delegate hook doesn't fire spurious side effects.
    private var isReloading = false

    // MARK: - Construction

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "플로우 관리"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Open the window centered on screen with the given scenario pre-selected.
    func present(selectedScenarioIndex: Int) {
        reload(selecting: selectedScenarioIndex)
        if !(window?.isVisible ?? false) {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Left column: + button on top of a bordered table.
        addButton = NSButton(title: "＋",
                             target: self,
                             action: #selector(showAddMenu(_:)))
        addButton.bezelStyle = .roundRect
        addButton.controlSize = .regular
        addButton.toolTip = "플로우 추가"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 22
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let col = NSTableColumn(identifier: .init("name"))
        col.title = "Flow"
        col.width = 220
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        self.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView = scroll

        // Right column: name editor + action count + delete + close.
        detailContainer = NSView()
        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: "이름")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        nameField = NSTextField()
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.target = self
        nameField.action = #selector(commitNameEdit(_:))
        nameField.delegate = self

        actionCountLabel = NSTextField(labelWithString: "")
        actionCountLabel.translatesAutoresizingMaskIntoConstraints = false
        actionCountLabel.textColor = .secondaryLabelColor
        actionCountLabel.font = .systemFont(ofSize: 11)

        deleteButton = NSButton(title: "삭제",
                                target: self,
                                action: #selector(onDelete(_:)))
        deleteButton.bezelStyle = .roundRect
        deleteButton.hasDestructiveAction = true
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        detailContainer.addSubview(nameLabel)
        detailContainer.addSubview(nameField)
        detailContainer.addSubview(actionCountLabel)
        detailContainer.addSubview(deleteButton)

        let closeBtn = NSButton(title: "완료",
                                target: self,
                                action: #selector(closeEditor(_:)))
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\r"
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(addButton)
        content.addSubview(scroll)
        content.addSubview(detailContainer)
        content.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            // Left column
            addButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            addButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            addButton.widthAnchor.constraint(equalToConstant: 32),

            scroll.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.widthAnchor.constraint(equalToConstant: 240),
            scroll.bottomAnchor.constraint(equalTo: closeBtn.topAnchor, constant: -12),

            // Divider gap → detail pane
            detailContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            detailContainer.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 18),
            detailContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            detailContainer.bottomAnchor.constraint(equalTo: closeBtn.topAnchor, constant: -12),

            nameLabel.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),

            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            nameField.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),

            actionCountLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 12),
            actionCountLabel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),

            deleteButton.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            deleteButton.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            closeBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            closeBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        // React to cross-window mutations (e.g. another runner edits the
        // store while this editor is open).
        NotificationCenter.default.addObserver(
            forName: ScenarioStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true else { return }
            self.reloadPreservingSelection()
        }
    }

    // MARK: - Reload + selection

    private func reload(selecting index: Int) {
        let store = ScenarioStore.shared
        let count = store.scenarios.count
        isReloading = true
        tableView.reloadData()
        isReloading = false

        if count == 0 {
            selectedRow = -1
        } else {
            let safe = max(0, min(index, count - 1))
            selectedRow = safe
            tableView.selectRowIndexes(IndexSet(integer: safe), byExtendingSelection: false)
            tableView.scrollRowToVisible(safe)
        }
        refreshDetailPane()
    }

    /// Reload from the store without changing what the user has selected,
    /// re-resolving by UUID so concurrent inserts/deletes don't slide the
    /// highlight onto a different row.
    private func reloadPreservingSelection() {
        let store = ScenarioStore.shared
        let priorId: UUID?
        if store.scenarios.indices.contains(selectedRow) {
            priorId = store.scenarios[selectedRow].id
        } else {
            priorId = nil
        }
        var target = selectedRow
        if let pid = priorId,
           let idx = store.scenarios.firstIndex(where: { $0.id == pid }) {
            target = idx
        }
        reload(selecting: target)
    }

    private func refreshDetailPane() {
        let store = ScenarioStore.shared
        guard store.scenarios.indices.contains(selectedRow) else {
            nameField.stringValue = ""
            nameField.isEnabled = false
            actionCountLabel.stringValue = ""
            deleteButton.isEnabled = false
            return
        }
        let scenario = store.scenarios[selectedRow]
        nameField.stringValue = scenario.name
        nameField.isEnabled = true
        actionCountLabel.stringValue = "동작 \(scenario.actions.count)개"
        deleteButton.isEnabled = store.scenarios.count > 1
    }

    // MARK: - + button menu

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let empty = NSMenuItem(title: "빈 플로우 생성",
                               action: #selector(addEmpty(_:)),
                               keyEquivalent: "")
        empty.target = self
        menu.addItem(empty)

        let duplicate = NSMenuItem(title: "현재 플로우 복제",
                                   action: #selector(duplicateSelected(_:)),
                                   keyEquivalent: "")
        duplicate.target = self
        duplicate.isEnabled = ScenarioStore.shared.scenarios.indices.contains(selectedRow)
        menu.addItem(duplicate)

        let record = NSMenuItem(title: "시퀀스로 기록",
                                action: #selector(beginRecording(_:)),
                                keyEquivalent: "")
        record.target = self
        menu.addItem(record)

        let origin = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    @objc private func addEmpty(_ sender: Any?) {
        let store = ScenarioStore.shared
        let baseName = store.scenarios.indices.contains(selectedRow)
            ? store.scenarios[selectedRow].name
            : "Flow"
        let newName = "New \(baseName)"
        store.add(Scenario(name: newName, actions: []))
        let newIndex = store.scenarios.count - 1
        reload(selecting: newIndex)
        notifySelectionChanged()
        onMutated?()
        AppLogger.shared.log("➕ 플로우 추가: \(newName)")
    }

    @objc private func duplicateSelected(_ sender: Any?) {
        let store = ScenarioStore.shared
        guard store.scenarios.indices.contains(selectedRow) else { return }
        let source = store.scenarios[selectedRow]
        let newName = uniqueName(basedOn: source.name)
        guard store.duplicate(at: selectedRow, newName: newName) != nil else { return }
        let newIndex = store.scenarios.count - 1
        reload(selecting: newIndex)
        notifySelectionChanged()
        onMutated?()
        AppLogger.shared.log("➕ 플로우 복제: \(source.name) → \(newName)")
    }

    @objc private func beginRecording(_ sender: Any?) {
        // Recording uses the main window's overlay/HUD path — close the
        // editor first so the recorder owns the screen, then hand off.
        let callback = onBeginSequenceRecording
        close()
        callback?()
    }

    private func uniqueName(basedOn base: String) -> String {
        let existing = Set(ScenarioStore.shared.scenarios.map { $0.name })
        let first = "\(base) 복사"
        if !existing.contains(first) { return first }
        var n = 2
        while existing.contains("\(first) \(n)") { n += 1 }
        return "\(first) \(n)"
    }

    // MARK: - Detail edits

    @objc private func commitNameEdit(_ sender: Any?) {
        applyPendingNameEdit()
    }

    private func applyPendingNameEdit() {
        let store = ScenarioStore.shared
        guard store.scenarios.indices.contains(selectedRow) else { return }
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = store.scenarios[selectedRow].name
        guard !trimmed.isEmpty, trimmed != current else {
            // Revert empty input back to the existing name so the field
            // doesn't visibly desync from the row label.
            nameField.stringValue = current
            return
        }
        store.rename(at: selectedRow, to: trimmed)
        isReloading = true
        tableView.reloadData(forRowIndexes: IndexSet(integer: selectedRow),
                             columnIndexes: IndexSet(integer: 0))
        isReloading = false
        notifySelectionChanged()
        onMutated?()
    }

    @objc private func onDelete(_ sender: Any?) {
        let store = ScenarioStore.shared
        guard store.scenarios.count > 1,
              store.scenarios.indices.contains(selectedRow) else {
            AppLogger.shared.log("⚠️ 마지막 플로우는 삭제할 수 없습니다.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "플로우를 삭제하시겠습니까?"
        alert.informativeText = store.scenarios[selectedRow].name
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let removedName = store.scenarios[selectedRow].name
        store.delete(at: selectedRow)
        let newIndex = max(0, selectedRow - 1)
        reload(selecting: newIndex)
        notifySelectionChanged()
        onMutated?()
        AppLogger.shared.log("🗑 플로우 삭제: \(removedName)")
    }

    @objc private func closeEditor(_ sender: Any?) {
        // Make sure a pending text edit isn't dropped on close.
        window?.makeFirstResponder(nil)
        close()
    }

    private func notifySelectionChanged() {
        let store = ScenarioStore.shared
        guard store.scenarios.indices.contains(selectedRow) else { return }
        onScenarioSelected?(store.scenarios[selectedRow].id)
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension ScenarioListEditorWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        ScenarioStore.shared.scenarios.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ScenarioRow")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier,
                                           owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let scenarios = ScenarioStore.shared.scenarios
        if scenarios.indices.contains(row) {
            cell.textField?.stringValue = scenarios[row].name
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if isReloading { return }
        // Flush any in-progress rename so we don't lose the user's edit when
        // they tap a different row.
        applyPendingNameEdit()
        selectedRow = tableView.selectedRow
        refreshDetailPane()
        notifySelectionChanged()
    }

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let items = info.draggingPasteboard.pasteboardItems,
              let item = items.first,
              let str = item.string(forType: Self.dragType),
              let source = Int(str) else { return false }
        // NSTableView's drop row is the index the item should land *before*.
        // After removing the source row, anything past it shifts down by one.
        var dest = row
        if dest > source { dest -= 1 }
        guard dest != source else { return false }

        let store = ScenarioStore.shared
        let movedId = store.scenarios.indices.contains(source)
            ? store.scenarios[source].id : nil
        store.move(at: source, to: dest)
        // Re-resolve the moved scenario's new index so the highlight follows
        // the row the user just dragged.
        if let id = movedId,
           let newIdx = store.scenarios.firstIndex(where: { $0.id == id }) {
            reload(selecting: newIdx)
        } else {
            reload(selecting: dest)
        }
        notifySelectionChanged()
        onMutated?()
        return true
    }
}

// MARK: - NSTextFieldDelegate

extension ScenarioListEditorWindowController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        applyPendingNameEdit()
    }
}
