//
//  FlowModeListEditorWindowController.swift
//  AIMacro
//
//  Modal-style manager window for FlowModes, invoked from the flow-mode
//  button in the main window. Mirrors ScenarioListEditorWindowController
//  but uses a flat table view (no groups): each row is a FlowMode that
//  can be added, renamed, deleted, or reordered.
//
//  The first row (index 0) is the implicit default mode and is locked:
//  it cannot be renamed, deleted, or moved. ViewController and a few
//  callers index into `FlowModeStore.shared.flowModes.first` to read the
//  default mode's id, so keeping it pinned in slot 0 preserves that
//  invariant.
//

import Cocoa

final class FlowModeListEditorWindowController: NSWindowController {

    // MARK: - Public surface

    /// Fired after any mutation so the main VC can refresh its button
    /// title and any downstream state (e.g. `.nextScenario` rows whose
    /// per-mode delays are keyed by FlowMode id).
    var onMutated: (() -> Void)?

    /// Fired when the user picks a row so the main VC can update the
    /// flow-mode button title + currentFlowModeIndex.
    var onFlowModeSelected: ((UUID) -> Void)?

    // MARK: - State

    private static let dragType = NSPasteboard.PasteboardType("com.aimacro.flowModeRow")

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var addButton: NSButton!
    private var nameField: NSTextField!
    private var deleteButton: NSButton!
    private var detailContainer: NSView!
    private var noteLabel: NSTextField!

    private var editingId: UUID?
    private var isReloading = false

    private var selectedIds: [UUID] {
        let store = FlowModeStore.shared
        return tableView.selectedRowIndexes
            .compactMap { store.flowModes.indices.contains($0) ? store.flowModes[$0].id : nil }
    }

    private var primarySelectedId: UUID? { selectedIds.first }

    // MARK: - Construction

    init() {
        let initialWidth: CGFloat = 448
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "플로우 모드 관리"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 300)
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Open the window centered with the given flow mode pre-selected.
    func present(selectedIndex: Int) {
        let modes = FlowModeStore.shared.flowModes
        let preferred: [UUID]
        if modes.indices.contains(selectedIndex) {
            preferred = [modes[selectedIndex].id]
        } else if let first = modes.first {
            preferred = [first.id]
        } else {
            preferred = []
        }
        reload(selecting: preferred)
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

        addButton = NSButton(title: "＋",
                             target: self,
                             action: #selector(onAdd(_:)))
        addButton.bezelStyle = .roundRect
        addButton.controlSize = .regular
        addButton.toolTip = "모드 추가"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 22
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let col = NSTableColumn(identifier: .init("name"))
        col.title = "Mode"
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

        // Right column: name editor + delete + (locked-row hint).
        detailContainer = NSView()
        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: "이름")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        nameField = NSTextField()
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.target = self
        nameField.action = #selector(commitNameEdit(_:))
        nameField.delegate = self

        noteLabel = NSTextField(labelWithString: "")
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = .systemFont(ofSize: 11)

        deleteButton = NSButton(title: "삭제",
                                target: self,
                                action: #selector(onDelete(_:)))
        deleteButton.bezelStyle = .roundRect
        deleteButton.hasDestructiveAction = true
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        detailContainer.addSubview(nameLabel)
        detailContainer.addSubview(nameField)
        detailContainer.addSubview(noteLabel)
        detailContainer.addSubview(deleteButton)

        content.addSubview(addButton)
        content.addSubview(scroll)
        content.addSubview(detailContainer)

        NSLayoutConstraint.activate([
            addButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            addButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            addButton.widthAnchor.constraint(equalToConstant: 32),

            scroll.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            detailContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            detailContainer.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 18),
            detailContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            detailContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            scroll.widthAnchor.constraint(equalTo: detailContainer.widthAnchor),

            nameLabel.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),

            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            nameField.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),

            noteLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 12),
            noteLabel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),

            deleteButton.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            deleteButton.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            forName: FlowModeStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true else { return }
            self.reload(selecting: self.selectedIds)
        }
    }

    // MARK: - Reload + selection

    private func reload(selecting targets: [UUID]) {
        isReloading = true
        tableView.reloadData()
        isReloading = false
        applySelections(targets)
        refreshDetailPane()
    }

    private func applySelections(_ targets: [UUID]) {
        guard !targets.isEmpty else {
            isReloading = true
            tableView.deselectAll(nil)
            isReloading = false
            return
        }
        let store = FlowModeStore.shared
        var rows = IndexSet()
        for id in targets {
            if let idx = store.index(of: id) { rows.insert(idx) }
        }
        if rows.isEmpty {
            // Targets vanished — fall back to the first row.
            if !store.flowModes.isEmpty {
                applySelections([store.flowModes[0].id])
            } else {
                isReloading = true
                tableView.deselectAll(nil)
                isReloading = false
            }
            return
        }
        isReloading = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first {
            tableView.scrollRowToVisible(first)
        }
        isReloading = false
    }

    private func refreshDetailPane() {
        let store = FlowModeStore.shared
        let ids = selectedIds

        guard let first = ids.first else {
            nameField.stringValue = ""
            nameField.isEnabled = false
            nameField.placeholderString = ""
            noteLabel.stringValue = ""
            deleteButton.isEnabled = false
            deleteButton.title = "삭제"
            editingId = nil
            return
        }

        // Multi-select.
        if ids.count > 1 {
            nameField.stringValue = ""
            nameField.placeholderString = "여러 항목 — 이름 변경 불가"
            nameField.isEnabled = false
            noteLabel.stringValue = "모드 \(ids.count)개 선택됨"
            // Block deletion of the default (index 0) and don't allow
            // wiping out every mode.
            let withoutDefault = ids.filter { store.flowModes.first?.id != $0 }
            let surviving = store.flowModes.count - withoutDefault.count
            deleteButton.isEnabled = !withoutDefault.isEmpty && surviving > 0
            deleteButton.title = "선택 항목 삭제"
            editingId = nil
            return
        }

        // Exactly one selected.
        guard let mode = store.flowMode(id: first) else { return }
        let isDefault = (store.flowModes.first?.id == first)
        nameField.stringValue = mode.name
        nameField.placeholderString = ""
        nameField.isEnabled = !isDefault
        if isDefault {
            noteLabel.stringValue = "기본 모드 — 이름 변경/삭제 불가"
            deleteButton.isEnabled = false
        } else {
            noteLabel.stringValue = ""
            deleteButton.isEnabled = store.flowModes.count > 1
        }
        deleteButton.title = "삭제"
        editingId = first
    }

    // MARK: - Add

    @objc private func onAdd(_ sender: Any?) {
        let store = FlowModeStore.shared
        let baseName: String
        if let id = primarySelectedId, let m = store.flowMode(id: id) {
            baseName = m.name
        } else {
            baseName = "Mode"
        }
        let newName = uniqueName(candidate: "New \(baseName)")
        let mode = FlowMode(name: newName)
        store.add(mode)
        reload(selecting: [mode.id])
        onFlowModeSelected?(mode.id)
        onMutated?()
        AppLogger.shared.log("➕ 모드 추가: \(newName)")
    }

    private func uniqueName(candidate: String) -> String {
        let existing = Set(FlowModeStore.shared.flowModes.map { $0.name })
        if !existing.contains(candidate) { return candidate }
        var n = 2
        while existing.contains("\(candidate) \(n)") { n += 1 }
        return "\(candidate) \(n)"
    }

    // MARK: - Detail edits

    @objc private func commitNameEdit(_ sender: Any?) {
        applyPendingNameEdit()
    }

    private func applyPendingNameEdit() {
        let store = FlowModeStore.shared
        guard let id = editingId, let idx = store.index(of: id) else { return }
        // Default mode (index 0) is locked — defensive guard.
        if idx == 0 { return }
        guard let mode = store.flowMode(id: id) else { return }
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != mode.name else {
            nameField.stringValue = mode.name
            return
        }
        store.rename(at: idx, to: trimmed)
        isReloading = true
        tableView.reloadData()
        isReloading = false
        onFlowModeSelected?(id)
        onMutated?()
    }

    @objc private func onDelete(_ sender: Any?) {
        let store = FlowModeStore.shared
        let ids = selectedIds
        guard !ids.isEmpty else { return }
        // Exclude the default (index 0) from deletion regardless of selection.
        let defaultId = store.flowModes.first?.id
        let deletable = ids.filter { $0 != defaultId }
        guard !deletable.isEmpty else {
            AppLogger.shared.log("⚠️ 기본 모드는 삭제할 수 없습니다.")
            return
        }
        guard store.flowModes.count - deletable.count >= 1 else {
            AppLogger.shared.log("⚠️ 모든 모드를 한 번에 삭제할 수 없습니다.")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        if deletable.count == 1, let only = deletable.first, let m = store.flowMode(id: only) {
            alert.messageText = "모드를 삭제하시겠습니까?"
            alert.informativeText = m.name
        } else {
            alert.messageText = "선택한 모드를 삭제하시겠습니까?"
            alert.informativeText = "모드 \(deletable.count)개"
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Delete by id (resolve index per item — earlier removals shift indices).
        for id in deletable {
            guard let idx = store.index(of: id), idx > 0 else { continue }
            let name = store.flowModes[idx].name
            store.delete(at: idx)
            AppLogger.shared.log("🗑 모드 삭제: \(name)")
        }

        // Select whatever's left of the original selection, else the default.
        let remaining = selectedIds  // recomputed after store change
        if remaining.isEmpty, let firstId = store.flowModes.first?.id {
            reload(selecting: [firstId])
            onFlowModeSelected?(firstId)
        } else {
            reload(selecting: remaining)
            if let id = remaining.first { onFlowModeSelected?(id) }
        }
        onMutated?()
    }
}

// MARK: - NSTableViewDataSource

extension FlowModeListEditorWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        FlowModeStore.shared.flowModes.count
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        // Lock the default mode (index 0) in place.
        guard row > 0 else { return nil }
        let modes = FlowModeStore.shared.flowModes
        guard modes.indices.contains(row) else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(modes[row].id.uuidString, forType: Self.dragType)
        return pb
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above else { return [] }
        // The default mode occupies slot 0; nothing may land before it.
        if row <= 0 { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let dragged = parsedDraggedIds(info)
        guard !dragged.isEmpty else { return false }
        let store = FlowModeStore.shared

        // Walk drops in order, sliding `dest` forward after each landed item
        // so subsequent items land contiguously to the right.
        var dest = max(1, min(row, store.flowModes.count))
        for id in dragged {
            guard let from = store.index(of: id), from > 0 else { continue }
            var adjustedDest = dest
            if adjustedDest > from { adjustedDest -= 1 }
            if adjustedDest == from {
                dest = from + 1
                continue
            }
            store.move(from: from, to: adjustedDest)
            dest = adjustedDest + 1
        }
        reload(selecting: dragged)
        if let id = dragged.first { onFlowModeSelected?(id) }
        onMutated?()
        return true
    }

    private func parsedDraggedIds(_ info: NSDraggingInfo) -> [UUID] {
        guard let items = info.draggingPasteboard.pasteboardItems else { return [] }
        return items.compactMap {
            guard let s = $0.string(forType: Self.dragType) else { return nil }
            return UUID(uuidString: s)
        }
    }
}

// MARK: - NSTableViewDelegate

extension FlowModeListEditorWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("FlowModeRow")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
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
        let modes = FlowModeStore.shared.flowModes
        if modes.indices.contains(row) {
            cell.textField?.stringValue = modes[row].name
            cell.textField?.textColor = .labelColor
            // Default mode is rendered semibold so it's distinguishable.
            cell.textField?.font = row == 0
                ? .systemFont(ofSize: 13, weight: .semibold)
                : .systemFont(ofSize: 13)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if isReloading { return }
        applyPendingNameEdit()
        refreshDetailPane()
        // Single-row selection drives the main button title; multi-select
        // leaves the main view's selection unchanged.
        if selectedIds.count == 1, let id = selectedIds.first {
            onFlowModeSelected?(id)
        }
    }
}

// MARK: - NSTextFieldDelegate

extension FlowModeListEditorWindowController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        applyPendingNameEdit()
    }
}
