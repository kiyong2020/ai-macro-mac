//
//  ScenarioListEditorWindowController.swift
//  AIMacro
//
//  Modal-style manager window invoked from the 편집 button next to the
//  scenario picker. Lists scenarios as a SourceTree-like hierarchy:
//  top-level groups (collapsible) plus loose scenarios at the root.
//  Drag-and-drop reorders entries within a parent and moves scenarios
//  into / out of groups; groups themselves can only sit at the top level.
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

    /// Fired when the user picks a scenario row so the parent VC can
    /// switch its popup selection. The editor itself drives the right
    /// pane; the parent just needs to keep its picker in sync. Group
    /// selections do not fire this — the main popup only shows scenarios.
    var onScenarioSelected: ((UUID) -> Void)?

    // MARK: - State

    /// Pasteboard type for drag-to-reorder within the editor. Payload is
    /// `"g:<UUID>"` for groups and `"s:<UUID>"` for scenarios so the drop
    /// handler can tell them apart without re-looking-up the tree.
    private static let dragType = NSPasteboard.PasteboardType("com.aimacro.scenarioListRow")

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var addButton: NSButton!
    private var nameField: NSTextField!
    private var actionCountLabel: NSTextField!
    private var deleteButton: NSButton!
    private var detailContainer: NSView!

    /// What the user has selected in the outline. `nil` when nothing is
    /// selected (e.g. the list is empty).
    private enum SelectionKind { case group, scenario }
    private struct Selection {
        let kind: SelectionKind
        let id: UUID
    }
    private var selection: Selection?

    /// ID of the entity whose name is currently in the right-pane field.
    /// Looked up at commit time so a pending edit always lands on the
    /// right entity even if the tree was reordered (drag-to-reorder) or
    /// reloaded out from under us between focus-loss and commit.
    private var editingId: UUID?
    private var editingKind: SelectionKind?

    /// Set true while we're reloading the outline programmatically, so the
    /// selection-changed delegate hook doesn't fire spurious side effects.
    private var isReloading = false

    // MARK: - Construction

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
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

    /// Open the window centered on screen with the given scenario pre-selected
    /// (referenced by flat index, matching the main window's popup).
    func present(selectedScenarioIndex: Int) {
        let flat = ScenarioStore.shared.scenarios
        let preferred: Selection?
        if flat.indices.contains(selectedScenarioIndex) {
            preferred = Selection(kind: .scenario, id: flat[selectedScenarioIndex].id)
        } else if let first = flat.first {
            preferred = Selection(kind: .scenario, id: first.id)
        } else {
            preferred = nil
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

        // Left column: + button on top of a bordered outline.
        addButton = NSButton(title: "＋",
                             target: self,
                             action: #selector(showAddMenu(_:)))
        addButton.bezelStyle = .roundRect
        addButton.controlSize = .regular
        addButton.toolTip = "플로우 / 그룹 추가"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let outline = NSOutlineView()
        outline.headerView = nil
        outline.rowHeight = 22
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .inset
        outline.indentationPerLevel = 14
        outline.indentationMarkerFollowsCell = true
        outline.autosaveExpandedItems = false
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        let col = NSTableColumn(identifier: .init("name"))
        col.title = "Flow"
        col.width = 220
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        self.outlineView = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView = scroll

        // Right column: name editor + (scenario-only) action count + delete + close.
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
            addButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            addButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            addButton.widthAnchor.constraint(equalToConstant: 32),

            scroll.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.widthAnchor.constraint(equalToConstant: 260),
            scroll.bottomAnchor.constraint(equalTo: closeBtn.topAnchor, constant: -12),

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
            self.reload(selecting: self.selection)
        }
    }

    // MARK: - Item id helpers
    //
    // NSOutlineView uses opaque items to identify rows. We use prefixed
    // NSString IDs ("g:<UUID>" / "s:<UUID>") so the same row maintains
    // identity across `reloadData` — important for expand/collapse state.

    private func itemId(for node: ScenarioNode) -> NSString {
        switch node {
        case .group(let g):    return groupItemId(g.id)
        case .scenario(let s): return scenarioItemId(s.id)
        }
    }

    private func groupItemId(_ id: UUID) -> NSString {
        "g:\(id.uuidString)" as NSString
    }

    private func scenarioItemId(_ id: UUID) -> NSString {
        "s:\(id.uuidString)" as NSString
    }

    private func parseItem(_ item: Any?) -> (kind: SelectionKind, id: UUID)? {
        guard let raw = item as? NSString else { return nil }
        return parseToken(raw as String)
    }

    private func parseToken(_ token: String) -> (kind: SelectionKind, id: UUID)? {
        if token.hasPrefix("g:"), let id = UUID(uuidString: String(token.dropFirst(2))) {
            return (.group, id)
        }
        if token.hasPrefix("s:"), let id = UUID(uuidString: String(token.dropFirst(2))) {
            return (.scenario, id)
        }
        return nil
    }

    // MARK: - Reload + selection

    /// Repopulate the outline + restore selection. The expand/collapse
    /// state for each group is re-applied from `ScenarioGroup.isExpanded`.
    private func reload(selecting target: Selection?) {
        isReloading = true
        outlineView.reloadData()
        // Re-apply expand state. We do this after reloadData so the
        // outline has fresh item identities to expand against.
        for node in ScenarioStore.shared.tree {
            if case .group(let g) = node {
                let item = groupItemId(g.id)
                if g.isExpanded {
                    outlineView.expandItem(item)
                } else {
                    outlineView.collapseItem(item)
                }
            }
        }
        isReloading = false

        applySelection(target)
        refreshDetailPane()
    }

    private func applySelection(_ target: Selection?) {
        guard let target = target else {
            selection = nil
            outlineView.deselectAll(nil)
            return
        }
        let item: NSString = (target.kind == .group)
            ? groupItemId(target.id)
            : scenarioItemId(target.id)
        // Expand the parent group if the target is a scenario inside one.
        if target.kind == .scenario,
           let parent = parentGroupId(forScenarioId: target.id) {
            outlineView.expandItem(groupItemId(parent))
        }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else {
            // Fall back to the first scenario if the target vanished.
            if let first = ScenarioStore.shared.scenarios.first {
                applySelection(Selection(kind: .scenario, id: first.id))
            } else {
                selection = nil
                outlineView.deselectAll(nil)
            }
            return
        }
        selection = target
        isReloading = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        isReloading = false
    }

    private func parentGroupId(forScenarioId id: UUID) -> UUID? {
        for node in ScenarioStore.shared.tree {
            if case .group(let g) = node, g.scenarios.contains(where: { $0.id == id }) {
                return g.id
            }
        }
        return nil
    }

    private func refreshDetailPane() {
        let store = ScenarioStore.shared
        guard let sel = selection else {
            nameField.stringValue = ""
            nameField.isEnabled = false
            actionCountLabel.stringValue = ""
            deleteButton.isEnabled = false
            editingId = nil
            editingKind = nil
            return
        }
        switch sel.kind {
        case .scenario:
            guard let s = store.scenario(id: sel.id) else { return }
            nameField.stringValue = s.name
            nameField.isEnabled = true
            actionCountLabel.stringValue = "동작 \(s.actions.count)개"
            // The very last scenario across the whole store can't be
            // deleted — runner needs at least one to play.
            deleteButton.isEnabled = store.scenarios.count > 1
            deleteButton.title = "삭제"
        case .group:
            guard let g = store.group(id: sel.id) else { return }
            nameField.stringValue = g.name
            nameField.isEnabled = true
            actionCountLabel.stringValue = "그룹 · 플로우 \(g.scenarios.count)개"
            deleteButton.isEnabled = true
            deleteButton.title = "그룹 삭제"
        }
        editingId = sel.id
        editingKind = sel.kind
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
        duplicate.isEnabled = (selection?.kind == .scenario)
        menu.addItem(duplicate)

        let record = NSMenuItem(title: "시퀀스로 기록",
                                action: #selector(beginRecording(_:)),
                                keyEquivalent: "")
        record.target = self
        menu.addItem(record)

        menu.addItem(NSMenuItem.separator())

        let addGroup = NSMenuItem(title: "그룹 추가",
                                  action: #selector(addGroup(_:)),
                                  keyEquivalent: "")
        addGroup.target = self
        menu.addItem(addGroup)

        let origin = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    @objc private func addEmpty(_ sender: Any?) {
        let store = ScenarioStore.shared
        let baseName: String
        if let sel = selection, sel.kind == .scenario, let s = store.scenario(id: sel.id) {
            baseName = s.name
        } else if let sel = selection, sel.kind == .group, let g = store.group(id: sel.id) {
            baseName = g.name
        } else {
            baseName = "Flow"
        }
        let newName = uniqueScenarioName(candidate: "New \(baseName)")
        let newScenario = Scenario(name: newName, actions: [])
        store.add(newScenario)
        reload(selecting: Selection(kind: .scenario, id: newScenario.id))
        notifySelectionChanged()
        onMutated?()
        AppLogger.shared.log("➕ 플로우 추가: \(newName)")
    }

    @objc private func duplicateSelected(_ sender: Any?) {
        let store = ScenarioStore.shared
        guard let sel = selection, sel.kind == .scenario,
              let source = store.scenario(id: sel.id),
              let flatIndex = store.scenarios.firstIndex(where: { $0.id == sel.id }) else { return }
        let newName = uniqueScenarioName(basedOn: source.name)
        guard let copy = store.duplicate(at: flatIndex, newName: newName) else { return }
        reload(selecting: Selection(kind: .scenario, id: copy.id))
        notifySelectionChanged()
        onMutated?()
        AppLogger.shared.log("➕ 플로우 복제: \(source.name) → \(newName)")
    }

    @objc private func addGroup(_ sender: Any?) {
        let newName = uniqueGroupName(candidate: "새 그룹")
        let g = ScenarioGroup(name: newName, isExpanded: true)
        ScenarioStore.shared.addGroup(g)
        reload(selecting: Selection(kind: .group, id: g.id))
        onMutated?()
        AppLogger.shared.log("➕ 그룹 추가: \(newName)")
    }

    @objc private func beginRecording(_ sender: Any?) {
        let callback = onBeginSequenceRecording
        close()
        callback?()
    }

    private func uniqueScenarioName(basedOn base: String) -> String {
        uniqueScenarioName(candidate: "\(base) 복사")
    }

    private func uniqueScenarioName(candidate: String) -> String {
        let existing = Set(ScenarioStore.shared.scenarios.map { $0.name })
        if !existing.contains(candidate) { return candidate }
        var n = 2
        while existing.contains("\(candidate) \(n)") { n += 1 }
        return "\(candidate) \(n)"
    }

    private func uniqueGroupName(candidate: String) -> String {
        let existing = Set(ScenarioStore.shared.groups.map { $0.name })
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
        let store = ScenarioStore.shared
        guard let id = editingId, let kind = editingKind else { return }
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .scenario:
            guard let scenario = store.scenario(id: id) else { return }
            guard !trimmed.isEmpty, trimmed != scenario.name else {
                nameField.stringValue = scenario.name
                return
            }
            store.renameScenario(id: id, to: trimmed)
        case .group:
            guard let g = store.group(id: id) else { return }
            guard !trimmed.isEmpty, trimmed != g.name else {
                nameField.stringValue = g.name
                return
            }
            store.renameGroup(id: id, to: trimmed)
        }
        // Refresh just the affected row by reloading the whole outline —
        // cheap enough for the sizes the editor handles, and avoids the
        // bookkeeping of re-resolving a row index.
        isReloading = true
        outlineView.reloadData()
        isReloading = false
        notifySelectionChanged()
        onMutated?()
    }

    @objc private func onDelete(_ sender: Any?) {
        let store = ScenarioStore.shared
        guard let sel = selection else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")

        switch sel.kind {
        case .scenario:
            guard store.scenarios.count > 1, let s = store.scenario(id: sel.id) else {
                AppLogger.shared.log("⚠️ 마지막 플로우는 삭제할 수 없습니다.")
                return
            }
            alert.messageText = "플로우를 삭제하시겠습니까?"
            alert.informativeText = s.name
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store.deleteScenario(id: sel.id)
            AppLogger.shared.log("🗑 플로우 삭제: \(s.name)")
        case .group:
            guard let g = store.group(id: sel.id) else { return }
            alert.messageText = "그룹을 삭제하시겠습니까?"
            alert.informativeText = g.scenarios.isEmpty
                ? "\(g.name) (빈 그룹)"
                : "\(g.name) — 안의 플로우 \(g.scenarios.count)개는 그룹 밖으로 옮겨집니다."
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store.deleteGroup(id: sel.id, promotingScenarios: true)
            AppLogger.shared.log("🗑 그룹 삭제: \(g.name)")
        }

        // Fall back to the first remaining scenario after deletion so the
        // detail pane doesn't sit on a dead reference.
        let fallback: Selection? = store.scenarios.first.map {
            Selection(kind: .scenario, id: $0.id)
        }
        reload(selecting: fallback)
        notifySelectionChanged()
        onMutated?()
    }

    @objc private func closeEditor(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        close()
    }

    private func notifySelectionChanged() {
        guard let sel = selection, sel.kind == .scenario,
              ScenarioStore.shared.scenario(id: sel.id) != nil else { return }
        onScenarioSelected?(sel.id)
    }
}

// MARK: - NSOutlineViewDataSource

extension ScenarioListEditorWindowController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let store = ScenarioStore.shared
        if item == nil {
            return store.tree.count
        }
        if let parsed = parseItem(item), parsed.kind == .group {
            return store.group(id: parsed.id)?.scenarios.count ?? 0
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let store = ScenarioStore.shared
        if item == nil {
            guard store.tree.indices.contains(index) else {
                return scenarioItemId(UUID())
            }
            return itemId(for: store.tree[index])
        }
        if let parsed = parseItem(item), parsed.kind == .group,
           let g = store.group(id: parsed.id),
           g.scenarios.indices.contains(index) {
            return scenarioItemId(g.scenarios[index].id)
        }
        return scenarioItemId(UUID())
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let parsed = parseItem(item), parsed.kind == .group else { return false }
        return true
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView,
                     pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let parsed = parseItem(item) else { return nil }
        let token: String
        switch parsed.kind {
        case .group:    token = "g:\(parsed.id.uuidString)"
        case .scenario: token = "s:\(parsed.id.uuidString)"
        }
        let pb = NSPasteboardItem()
        pb.setString(token, forType: Self.dragType)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let token = info.draggingPasteboard.pasteboardItems?
                .first?.string(forType: Self.dragType),
              let dragged = parseToken(token) else { return [] }

        if dragged.kind == .group {
            // Groups stay at the root and cannot nest.
            if item == nil && index >= 0 { return .move }
            return []
        }

        // Scenario: can land at root or inside a group, but not ON a
        // scenario (NSOutlineView passes childIndex == -1 for "drop on item").
        if let parsed = parseItem(item), parsed.kind == .scenario {
            return []
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        guard let token = info.draggingPasteboard.pasteboardItems?
                .first?.string(forType: Self.dragType),
              let dragged = parseToken(token) else { return false }

        let store = ScenarioStore.shared

        if dragged.kind == .group {
            // Top-level reorder among other top-level nodes. NSOutlineView
            // gives us the pre-removal target index; adjust for the
            // extraction so the group lands where the user intended.
            guard let from = store.tree.firstIndex(where: {
                if case .group(let g) = $0 { return g.id == dragged.id }
                return false
            }) else { return false }
            var dest = (index < 0) ? store.tree.count : index
            if dest > from { dest -= 1 }
            if dest == from { return false }
            store.moveGroup(id: dragged.id, toTopIndex: dest)
            reload(selecting: Selection(kind: .group, id: dragged.id))
            onMutated?()
            return true
        }

        // Scenario drop. Resolve source path so we can adjust the dest
        // index for same-container moves.
        let sourcePath = findScenarioSourcePath(scenarioId: dragged.id)
        let targetGroupId: UUID? = {
            if let parsed = parseItem(item), parsed.kind == .group { return parsed.id }
            return nil
        }()

        // Effective child-count of the destination container.
        let destContainerCount: Int = {
            if let gid = targetGroupId {
                return store.group(id: gid)?.scenarios.count ?? 0
            }
            return store.tree.count
        }()

        // Normalise -1 ("drop on group") to "end of group's children".
        var dest = (index < 0) ? destContainerCount : index

        // Same container → user-visible drop index is pre-removal, so
        // shift down once we extract the source.
        if let sp = sourcePath {
            let sameContainer = (sp.parentGroupId == targetGroupId)
            if sameContainer {
                if dest > sp.indexWithinParent { dest -= 1 }
                if dest == sp.indexWithinParent { return false }
            }
        }

        store.moveScenario(id: dragged.id, intoGroup: targetGroupId, at: dest)
        reload(selecting: Selection(kind: .scenario, id: dragged.id))
        notifySelectionChanged()
        onMutated?()
        return true
    }

    /// Where the dragged scenario lives right now: which group (nil for
    /// loose top-level) and which slot inside it.
    private func findScenarioSourcePath(scenarioId id: UUID)
        -> (parentGroupId: UUID?, indexWithinParent: Int)? {
        let store = ScenarioStore.shared
        for (i, node) in store.tree.enumerated() {
            switch node {
            case .scenario(let s) where s.id == id:
                return (nil, i)
            case .group(let g):
                if let j = g.scenarios.firstIndex(where: { $0.id == id }) {
                    return (g.id, j)
                }
            default: continue
            }
        }
        return nil
    }
}

// MARK: - NSOutlineViewDelegate

extension ScenarioListEditorWindowController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ScenarioRow")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier,
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
        let store = ScenarioStore.shared
        if let parsed = parseItem(item) {
            switch parsed.kind {
            case .group:
                if let g = store.group(id: parsed.id) {
                    cell.textField?.stringValue = g.name
                    cell.textField?.font = .systemFont(ofSize: 13, weight: .semibold)
                    cell.textField?.textColor = .labelColor
                }
            case .scenario:
                if let s = store.scenario(id: parsed.id) {
                    cell.textField?.stringValue = s.name
                    cell.textField?.font = .systemFont(ofSize: 13)
                    cell.textField?.textColor = .labelColor
                }
            }
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if isReloading { return }
        applyPendingNameEdit()
        let row = outlineView.selectedRow
        if row < 0 {
            selection = nil
            refreshDetailPane()
            return
        }
        let item = outlineView.item(atRow: row)
        if let parsed = parseItem(item) {
            selection = Selection(kind: parsed.kind, id: parsed.id)
        } else {
            selection = nil
        }
        refreshDetailPane()
        notifySelectionChanged()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isReloading,
              let item = notification.userInfo?["NSObject"],
              let parsed = parseItem(item), parsed.kind == .group else { return }
        ScenarioStore.shared.setGroupExpanded(id: parsed.id, expanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isReloading,
              let item = notification.userInfo?["NSObject"],
              let parsed = parseItem(item), parsed.kind == .group else { return }
        ScenarioStore.shared.setGroupExpanded(id: parsed.id, expanded: false)
    }
}

// MARK: - NSTextFieldDelegate

extension ScenarioListEditorWindowController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        applyPendingNameEdit()
    }
}
