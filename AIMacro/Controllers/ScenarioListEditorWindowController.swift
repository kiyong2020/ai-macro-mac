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

    /// What the user has selected in the outline. Multi-select via shift /
    /// cmd is enabled — many actions operate on the whole selection
    /// (delete, drag), while name editing only kicks in when exactly one
    /// item is selected.
    private enum SelectionKind { case group, scenario }
    private struct Selection: Equatable {
        let kind: SelectionKind
        let id: UUID
    }

    /// Live selection derived from `outlineView.selectedRowIndexes`. Kept
    /// as a computed property so we don't have to keep a parallel `var`
    /// in sync with NSOutlineView's own selection state.
    private var selections: [Selection] {
        var out: [Selection] = []
        for row in outlineView.selectedRowIndexes.sorted() {
            if let item = outlineView.item(atRow: row),
               let parsed = parseItem(item) {
                out.append(Selection(kind: parsed.kind, id: parsed.id))
            }
        }
        return out
    }

    private var primarySelection: Selection? { selections.first }

    /// ID of the entity whose name is currently in the right-pane field.
    /// Looked up at commit time so a pending edit always lands on the
    /// right entity even if the tree was reordered (drag-to-reorder) or
    /// reloaded out from under us between focus-loss and commit. Only
    /// non-nil while exactly one item is selected.
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
        let preferred: [Selection]
        if flat.indices.contains(selectedScenarioIndex) {
            preferred = [Selection(kind: .scenario, id: flat[selectedScenarioIndex].id)]
        } else if let first = flat.first {
            preferred = [Selection(kind: .scenario, id: first.id)]
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
        outline.allowsMultipleSelection = true
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
            self.reload(selecting: self.selections)
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
    private func reload(selecting targets: [Selection]) {
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

        applySelections(targets)
        refreshDetailPane()
    }

    private func applySelections(_ targets: [Selection]) {
        guard !targets.isEmpty else {
            isReloading = true
            outlineView.deselectAll(nil)
            isReloading = false
            return
        }
        // Expand parent groups so child rows are addressable.
        for target in targets where target.kind == .scenario {
            if let parent = parentGroupId(forScenarioId: target.id) {
                outlineView.expandItem(groupItemId(parent))
            }
        }
        var rows = IndexSet()
        for target in targets {
            let item: NSString = (target.kind == .group)
                ? groupItemId(target.id)
                : scenarioItemId(target.id)
            let row = outlineView.row(forItem: item)
            if row >= 0 { rows.insert(row) }
        }
        if rows.isEmpty {
            // All targets vanished — fall back to the first scenario.
            if let first = ScenarioStore.shared.scenarios.first {
                applySelections([Selection(kind: .scenario, id: first.id)])
            } else {
                isReloading = true
                outlineView.deselectAll(nil)
                isReloading = false
            }
            return
        }
        isReloading = true
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first {
            outlineView.scrollRowToVisible(first)
        }
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
        let sels = selections
        // Nothing selected → empty state.
        guard let first = sels.first else {
            nameField.stringValue = ""
            nameField.isEnabled = false
            actionCountLabel.stringValue = ""
            deleteButton.isEnabled = false
            editingId = nil
            editingKind = nil
            return
        }
        // Multi-select → show summary; rename is disabled (only one item
        // at a time can be renamed) but delete operates on the whole set.
        if sels.count > 1 {
            let groupCount = sels.filter { $0.kind == .group }.count
            let scenarioCount = sels.count - groupCount
            var parts: [String] = []
            if groupCount > 0    { parts.append("그룹 \(groupCount)개") }
            if scenarioCount > 0 { parts.append("플로우 \(scenarioCount)개") }
            actionCountLabel.stringValue = parts.joined(separator: " · ") + " 선택됨"
            nameField.stringValue = ""
            nameField.placeholderString = "여러 항목 — 이름 변경 불가"
            nameField.isEnabled = false
            deleteButton.title = "선택 항목 삭제"
            // Block "선택 항목 삭제" when it would wipe out the last
            // scenario (runner needs at least one).
            let scenarioSelectionIds = Set(sels.filter { $0.kind == .scenario }.map { $0.id })
            let scenariosLostIfGroupsDeleted = sels.filter { $0.kind == .group }
                .compactMap { store.group(id: $0.id) }
                .flatMap { $0.scenarios.map { $0.id } }
            let removedScenarioIds = scenarioSelectionIds.union(scenariosLostIfGroupsDeleted)
            let surviving = store.scenarios.filter { !removedScenarioIds.contains($0.id) }.count
            deleteButton.isEnabled = surviving > 0
            editingId = nil
            editingKind = nil
            return
        }
        // Exactly one selected.
        nameField.placeholderString = ""
        switch first.kind {
        case .scenario:
            guard let s = store.scenario(id: first.id) else { return }
            nameField.stringValue = s.name
            nameField.isEnabled = true
            actionCountLabel.stringValue = "동작 \(s.actions.count)개"
            // The very last scenario across the whole store can't be
            // deleted — runner needs at least one to play.
            deleteButton.isEnabled = store.scenarios.count > 1
            deleteButton.title = "삭제"
        case .group:
            guard let g = store.group(id: first.id) else { return }
            nameField.stringValue = g.name
            nameField.isEnabled = true
            actionCountLabel.stringValue = "그룹 · 플로우 \(g.scenarios.count)개"
            deleteButton.isEnabled = true
            deleteButton.title = "그룹 삭제"
        }
        editingId = first.id
        editingKind = first.kind
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

        // "복제" only makes sense for exactly one scenario.
        let dupOnly = (selections.count == 1 && primarySelection?.kind == .scenario)
        let duplicate = NSMenuItem(title: "현재 플로우 복제",
                                   action: #selector(duplicateSelected(_:)),
                                   keyEquivalent: "")
        duplicate.target = self
        duplicate.isEnabled = dupOnly
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
        if let sel = primarySelection, sel.kind == .scenario, let s = store.scenario(id: sel.id) {
            baseName = s.name
        } else if let sel = primarySelection, sel.kind == .group, let g = store.group(id: sel.id) {
            baseName = g.name
        } else {
            baseName = "Flow"
        }
        let newName = uniqueScenarioName(candidate: "New \(baseName)")
        let newScenario = Scenario(name: newName, actions: [])
        store.add(newScenario)
        reload(selecting: [Selection(kind: .scenario, id: newScenario.id)])
        notifySelectionChanged()
        onMutated?()
        AppLogger.shared.log("➕ 플로우 추가: \(newName)")
    }

    @objc private func duplicateSelected(_ sender: Any?) {
        let store = ScenarioStore.shared
        guard let sel = primarySelection, sel.kind == .scenario,
              selections.count == 1,
              let source = store.scenario(id: sel.id),
              let flatIndex = store.scenarios.firstIndex(where: { $0.id == sel.id }) else { return }
        let newName = uniqueScenarioName(basedOn: source.name)
        guard let copy = store.duplicate(at: flatIndex, newName: newName) else { return }
        reload(selecting: [Selection(kind: .scenario, id: copy.id)])
        notifySelectionChanged()
        onMutated?()
        AppLogger.shared.log("➕ 플로우 복제: \(source.name) → \(newName)")
    }

    @objc private func addGroup(_ sender: Any?) {
        let newName = uniqueGroupName(candidate: "새 그룹")
        let g = ScenarioGroup(name: newName, isExpanded: true)
        ScenarioStore.shared.addGroup(g)
        reload(selecting: [Selection(kind: .group, id: g.id)])
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
        // Rename only fires when exactly one item is selected — multi-
        // select disables the field, so editingId is nil there.
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
        isReloading = true
        outlineView.reloadData()
        isReloading = false
        notifySelectionChanged()
        onMutated?()
    }

    @objc private func onDelete(_ sender: Any?) {
        let store = ScenarioStore.shared
        let sels = selections
        guard !sels.isEmpty else { return }

        // Single-selection: keep the per-kind confirmation copy the user
        // already knows.
        if sels.count == 1, let only = sels.first {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.addButton(withTitle: "삭제")
            alert.addButton(withTitle: "취소")
            switch only.kind {
            case .scenario:
                guard store.scenarios.count > 1, let s = store.scenario(id: only.id) else {
                    AppLogger.shared.log("⚠️ 마지막 플로우는 삭제할 수 없습니다.")
                    return
                }
                alert.messageText = "플로우를 삭제하시겠습니까?"
                alert.informativeText = s.name
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                store.deleteScenario(id: only.id)
                AppLogger.shared.log("🗑 플로우 삭제: \(s.name)")
            case .group:
                guard let g = store.group(id: only.id) else { return }
                alert.messageText = "그룹을 삭제하시겠습니까?"
                alert.informativeText = g.scenarios.isEmpty
                    ? "\(g.name) (빈 그룹)"
                    : "\(g.name) — 안의 플로우 \(g.scenarios.count)개는 그룹 밖으로 옮겨집니다."
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                store.deleteGroup(id: only.id, promotingScenarios: true)
                AppLogger.shared.log("🗑 그룹 삭제: \(g.name)")
            }
            reload(selecting: store.scenarios.first.map {
                [Selection(kind: .scenario, id: $0.id)]
            } ?? [])
            notifySelectionChanged()
            onMutated?()
            return
        }

        // Multi-selection. We pre-validate that at least one scenario
        // would remain, otherwise the runner has nothing to play.
        let scenarioIdsDirect = Set(sels.filter { $0.kind == .scenario }.map { $0.id })
        let groupScenarioIds = sels.filter { $0.kind == .group }
            .compactMap { store.group(id: $0.id) }
            .flatMap { $0.scenarios.map { $0.id } }
        // When a group is selected we promote its scenarios (not delete
        // them), so they don't count as "removed".
        let removed = scenarioIdsDirect
        let surviving = store.scenarios.filter { !removed.contains($0.id) }.count
        if surviving < 1 {
            AppLogger.shared.log("⚠️ 모든 플로우를 한 번에 삭제할 수 없습니다.")
            return
        }

        let groupCount = sels.filter { $0.kind == .group }.count
        let scenarioCount = sels.count - groupCount
        var parts: [String] = []
        if groupCount > 0    { parts.append("그룹 \(groupCount)개") }
        if scenarioCount > 0 { parts.append("플로우 \(scenarioCount)개") }
        let summary = parts.joined(separator: " · ")
        var detail = "\(summary) 를 삭제합니다."
        if !groupScenarioIds.isEmpty {
            detail += " 그룹 안의 플로우 \(groupScenarioIds.count)개는 그룹 밖으로 옮겨집니다."
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "선택 항목을 삭제하시겠습니까?"
        alert.informativeText = detail
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Order matters when deleting groups + scenarios in the same pass:
        // promote group children first (so their UUIDs stay alive in the
        // tree), then drop the standalone scenarios.
        for sel in sels where sel.kind == .group {
            store.deleteGroup(id: sel.id, promotingScenarios: true)
        }
        for sel in sels where sel.kind == .scenario {
            store.deleteScenario(id: sel.id)
        }
        AppLogger.shared.log("🗑 선택 항목 삭제: \(summary)")

        reload(selecting: store.scenarios.first.map {
            [Selection(kind: .scenario, id: $0.id)]
        } ?? [])
        notifySelectionChanged()
        onMutated?()
    }

    @objc private func closeEditor(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        close()
    }

    private func notifySelectionChanged() {
        // Main popup only tracks a single scenario; if the user has a
        // group or multi-selection we leave the popup as-is.
        guard let sel = primarySelection, sel.kind == .scenario,
              selections.count == 1,
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
        let dragged = parsedDraggedItems(info)
        guard !dragged.isEmpty else { return [] }

        // Mixed-kind drag (group + scenario in the same selection) is
        // rejected — the destinations have different rules and asking the
        // user to disambiguate at drop time is worse than just disabling.
        let hasGroup    = dragged.contains { $0.kind == .group }
        let hasScenario = dragged.contains { $0.kind == .scenario }
        if hasGroup && hasScenario { return [] }

        if hasGroup {
            // Groups stay at the root and cannot nest.
            if item == nil && index >= 0 { return .move }
            return []
        }

        // Scenarios: not ON a scenario row (NSOutlineView passes
        // childIndex == -1 for "drop on item").
        if let parsed = parseItem(item), parsed.kind == .scenario {
            return []
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        let dragged = parsedDraggedItems(info)
        guard !dragged.isEmpty else { return false }
        let store = ScenarioStore.shared

        // Validated to be homogeneous in validateDrop.
        let isGroups = dragged.allSatisfy { $0.kind == .group }

        if isGroups {
            // Top-level reorder. Process in drag order, sliding `dest`
            // forward after each landed group so subsequent items land
            // contiguously to the right.
            var dest = (index < 0) ? store.tree.count : index
            for d in dragged {
                guard let from = store.tree.firstIndex(where: {
                    if case .group(let g) = $0 { return g.id == d.id }
                    return false
                }) else { continue }
                var adjustedDest = dest
                if adjustedDest > from { adjustedDest -= 1 }
                if adjustedDest == from {
                    // Already at the right slot — skip the move but keep
                    // sliding dest forward so the next item lands next to it.
                    dest = from + 1
                    continue
                }
                store.moveGroup(id: d.id, toTopIndex: adjustedDest)
                dest = adjustedDest + 1
            }
            reload(selecting: dragged.map { Selection(kind: .group, id: $0.id) })
            onMutated?()
            return true
        }

        // Scenarios.
        let targetGroupId: UUID? = {
            if let parsed = parseItem(item), parsed.kind == .group { return parsed.id }
            return nil
        }()
        let destContainerCount: Int = {
            if let gid = targetGroupId {
                return store.group(id: gid)?.scenarios.count ?? 0
            }
            return store.tree.count
        }()
        var dest = (index < 0) ? destContainerCount : index

        for d in dragged {
            // Re-resolve each scenario's path between moves — earlier
            // moves may have shifted its index within its parent.
            guard let sp = findScenarioSourcePath(scenarioId: d.id) else { continue }
            var adjustedDest = dest
            let sameContainer = (sp.parentGroupId == targetGroupId)
            if sameContainer && adjustedDest > sp.indexWithinParent {
                adjustedDest -= 1
            }
            if sameContainer && adjustedDest == sp.indexWithinParent {
                // No-op move; slide dest forward to land the next item right after.
                dest = adjustedDest + 1
                continue
            }
            store.moveScenario(id: d.id, intoGroup: targetGroupId, at: adjustedDest)
            dest = adjustedDest + 1
        }
        reload(selecting: dragged.map { Selection(kind: .scenario, id: $0.id) })
        notifySelectionChanged()
        onMutated?()
        return true
    }

    /// Parse every pasteboard entry from a multi-row drag into typed IDs.
    private func parsedDraggedItems(_ info: NSDraggingInfo) -> [(kind: SelectionKind, id: UUID)] {
        guard let items = info.draggingPasteboard.pasteboardItems else { return [] }
        var out: [(kind: SelectionKind, id: UUID)] = []
        for item in items {
            if let s = item.string(forType: Self.dragType),
               let parsed = parseToken(s) {
                out.append(parsed)
            }
        }
        return out
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
