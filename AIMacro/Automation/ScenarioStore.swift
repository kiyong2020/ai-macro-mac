//
//  ScenarioStore.swift
//  AIMacro
//
//  Persistent store for user-editable scenarios. Internally backed by an
//  ordered tree of `ScenarioNode`s (groups + loose scenarios). External
//  callers that don't care about the tree see a flat preorder view via
//  the `scenarios` computed property, so legacy index-based APIs keep
//  working unchanged.
//

import Foundation

final class ScenarioStore {
    static let shared = ScenarioStore()

    /// Source of truth — ordered mix of groups (each containing scenarios)
    /// and loose top-level scenarios. Mutations go through the helper
    /// methods below so `save()` fires exactly once per change.
    private(set) var tree: [ScenarioNode] = []

    /// Flat preorder traversal of every scenario in the tree. This is the
    /// view consumed by everything that doesn't care about grouping
    /// (main-window popup, runner, action generation, undo snapshots).
    var scenarios: [Scenario] {
        tree.flatMap { node -> [Scenario] in
            switch node {
            case .group(let g):    return g.scenarios
            case .scenario(let s): return [s]
            }
        }
    }

    /// Posted whenever the scenario list changes (add/rename/delete/move,
    /// group create/rename/delete) so UI can refresh. The body of a
    /// single scenario (its actions' values) is not covered — that uses
    /// the existing per-action SQLite flow.
    static let didChangeNotification = Notification.Name("ScenarioStoreDidChange")

    private var storeURL: URL = {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("AIMacro")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scenarios.json")
    }()

    private init() {
        load()
        if tree.isEmpty {
            seedDefaults()
        }
        // Persist unconditionally on launch — ensures freshly-generated
        // action ids (from legacy scenario data missing an "id" field) are
        // written back to disk so they stay stable across launches, and
        // promotes the legacy `[Scenario]` JSON layout to the new
        // `[ScenarioNode]` tree layout.
        save()
    }

    // MARK: - File I/O

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        tree = arr.compactMap { ScenarioNode.fromJSON($0) }
    }

    func save() {
        let arr = tree.map { $0.toJSON() }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: storeURL, options: .atomic)
        NotificationCenter.default.post(name: ScenarioStore.didChangeNotification, object: self)
    }

    // MARK: - Lookup

    /// All top-level groups, in tree order. Used by the editor's "move
    /// into group" menu and by anything that needs to enumerate groups.
    var groups: [ScenarioGroup] {
        tree.compactMap {
            if case .group(let g) = $0 { return g }
            return nil
        }
    }

    func group(id: UUID) -> ScenarioGroup? {
        for node in tree {
            if case .group(let g) = node, g.id == id { return g }
        }
        return nil
    }

    func scenario(id: UUID) -> Scenario? {
        for node in tree {
            switch node {
            case .scenario(let s) where s.id == id: return s
            case .group(let g):
                if let s = g.scenarios.first(where: { $0.id == id }) { return s }
            default: continue
            }
        }
        return nil
    }

    /// Path to a scenario inside the tree.
    /// - `topIndex` is the index of the top-level node.
    /// - `childIndex` is the scenario's offset inside that group, or nil
    ///   when the scenario itself is a top-level loose node.
    private func findScenarioPath(id: UUID) -> (topIndex: Int, childIndex: Int?)? {
        for (i, node) in tree.enumerated() {
            switch node {
            case .scenario(let s) where s.id == id:
                return (i, nil)
            case .group(let g):
                if let j = g.scenarios.firstIndex(where: { $0.id == id }) {
                    return (i, j)
                }
            default: continue
            }
        }
        return nil
    }

    private func indexOfGroup(id: UUID) -> Int? {
        for (i, node) in tree.enumerated() {
            if case .group(let g) = node, g.id == id { return i }
        }
        return nil
    }

    /// Apply an in-place mutation to a scenario identified by UUID,
    /// regardless of whether it's loose or inside a group.
    @discardableResult
    private func mutateScenario(id: UUID, _ mutate: (inout Scenario) -> Void) -> Bool {
        guard let path = findScenarioPath(id: id) else { return false }
        if let j = path.childIndex {
            guard case .group(var g) = tree[path.topIndex] else { return false }
            mutate(&g.scenarios[j])
            tree[path.topIndex] = .group(g)
        } else {
            guard case .scenario(var s) = tree[path.topIndex] else { return false }
            mutate(&s)
            tree[path.topIndex] = .scenario(s)
        }
        return true
    }

    // MARK: - Tree replacement (undo/redo)

    /// Replace the entire tree in one shot. Used by undo/redo to restore a
    /// captured snapshot; per-action SQLite + OCR cleanup is the caller's
    /// responsibility (it has more context about what changed).
    func replaceAll(tree newTree: [ScenarioNode]) {
        self.tree = newTree
        save()
    }

    /// Legacy variant for undo paths that still operate on the flat list.
    /// Drops any existing group structure and writes the scenarios back
    /// as a flat sequence of loose top-level nodes.
    func replaceAll(with scenarios: [Scenario]) {
        self.tree = scenarios.map { .scenario($0) }
        save()
    }

    // MARK: - Scenario mutations (flat-index entry points)

    func add(_ scenario: Scenario) {
        tree.append(.scenario(scenario))
        save()
    }

    @discardableResult
    func duplicate(at index: Int, newName: String) -> Scenario? {
        let flat = scenarios
        guard flat.indices.contains(index) else { return nil }
        let src = flat[index]
        let cloned = src.actions.map { $0.clone() }
        let copy = Scenario(name: newName, actions: cloned)
        tree.append(.scenario(copy))
        save()
        return copy
    }

    func delete(at index: Int) {
        let flat = scenarios
        guard flat.indices.contains(index) else { return }
        let target = flat[index]
        deleteScenario(id: target.id)
    }

    func deleteScenario(id: UUID) {
        guard let path = findScenarioPath(id: id) else { return }
        let removed: Scenario?
        if let j = path.childIndex,
           case .group(var g) = tree[path.topIndex] {
            removed = g.scenarios.remove(at: j)
            tree[path.topIndex] = .group(g)
        } else if case .scenario(let s) = tree[path.topIndex] {
            removed = s
            tree.remove(at: path.topIndex)
        } else {
            removed = nil
        }
        if let removed = removed {
            for action in removed.actions {
                ActionStore.shared.delete(id: action.id)
                OCRSnapshotStore.shared.delete(actionId: action.id)
            }
        }
        save()
    }

    func rename(at index: Int, to newName: String) {
        let flat = scenarios
        guard flat.indices.contains(index) else { return }
        renameScenario(id: flat[index].id, to: newName)
    }

    func renameScenario(id: UUID, to newName: String) {
        guard mutateScenario(id: id, { $0.name = newName }) else { return }
        save()
    }

    /// Flat-index reorder. Routes through the tree-aware mover, dropping
    /// the scenario at the top level — flat-mode callers don't know
    /// about groups, so the move is purely visual ordering in the flat
    /// view. (The editor uses `moveScenario(id:intoGroup:at:)` directly.)
    func move(at sourceIndex: Int, to destIndex: Int) {
        let flat = scenarios
        guard flat.indices.contains(sourceIndex) else { return }
        let id = flat[sourceIndex].id
        let safeDest = max(0, min(destIndex, flat.count))
        moveScenario(id: id, intoGroup: nil, at: topIndexAtFlatPosition(safeDest))
    }

    /// Compute which top-level slot a flat-index position lands on. Used
    /// only by legacy `move(at:to:)`; the editor uses the tree-aware mover
    /// directly.
    private func topIndexAtFlatPosition(_ flatIndex: Int) -> Int {
        var seen = 0
        for (i, node) in tree.enumerated() {
            let nodeCount: Int = {
                if case .group(let g) = node { return g.scenarios.count }
                return 1
            }()
            if flatIndex <= seen { return i }
            seen += nodeCount
        }
        return tree.count
    }

    // MARK: - Tree-aware mutations (used by the editor)

    func addGroup(_ group: ScenarioGroup) {
        tree.append(.group(group))
        save()
    }

    func renameGroup(id: UUID, to newName: String) {
        guard let i = indexOfGroup(id: id),
              case .group(var g) = tree[i] else { return }
        g.name = newName
        tree[i] = .group(g)
        save()
    }

    func setGroupExpanded(id: UUID, expanded: Bool) {
        guard let i = indexOfGroup(id: id),
              case .group(var g) = tree[i] else { return }
        if g.isExpanded == expanded { return }
        g.isExpanded = expanded
        tree[i] = .group(g)
        save()
    }

    /// Delete a group. Its scenarios are promoted to loose top-level
    /// entries (in their existing order) so the user doesn't lose work.
    func deleteGroup(id: UUID, promotingScenarios: Bool = true) {
        guard let i = indexOfGroup(id: id),
              case .group(let g) = tree[i] else { return }
        if promotingScenarios {
            let promoted = g.scenarios.map { ScenarioNode.scenario($0) }
            tree.replaceSubrange(i...i, with: promoted)
        } else {
            for s in g.scenarios {
                for a in s.actions {
                    ActionStore.shared.delete(id: a.id)
                    OCRSnapshotStore.shared.delete(actionId: a.id)
                }
            }
            tree.remove(at: i)
        }
        save()
    }

    /// Move a scenario to a specific tree position.
    ///
    /// - `targetGroupId == nil`: insert as a loose top-level node at
    ///   `index` among the top-level array.
    /// - `targetGroupId == someGroupId`: insert into that group at the
    ///   given child `index`.
    func moveScenario(id: UUID, intoGroup targetGroupId: UUID?, at index: Int) {
        guard let path = findScenarioPath(id: id),
              let scenario = extractedScenario(at: path) else { return }
        // After extraction the tree has shifted — recompute the destination.
        if let groupId = targetGroupId {
            guard let g = indexOfGroup(id: groupId),
                  case .group(var grp) = tree[g] else {
                // Group vanished; put it back where it was rather than dropping.
                reinsertScenario(scenario, at: path)
                save()
                return
            }
            let safe = max(0, min(index, grp.scenarios.count))
            grp.scenarios.insert(scenario, at: safe)
            tree[g] = .group(grp)
        } else {
            let safe = max(0, min(index, tree.count))
            tree.insert(.scenario(scenario), at: safe)
        }
        save()
    }

    /// Move a top-level group to a new top-level index.
    func moveGroup(id: UUID, toTopIndex index: Int) {
        guard let from = indexOfGroup(id: id) else { return }
        let node = tree.remove(at: from)
        let safe = max(0, min(index, tree.count))
        tree.insert(node, at: safe)
        save()
    }

    /// Move a loose top-level scenario to a new top-level index (without
    /// changing groups). Used when the user drags a top-level scenario
    /// past a group or another top-level scenario.
    func moveLooseScenario(id: UUID, toTopIndex index: Int) {
        guard let path = findScenarioPath(id: id), path.childIndex == nil else {
            // Not a loose scenario — go through the general mover.
            moveScenario(id: id, intoGroup: nil, at: index)
            return
        }
        let node = tree.remove(at: path.topIndex)
        let safe = max(0, min(index, tree.count))
        tree.insert(node, at: safe)
        save()
    }

    // MARK: - Helpers

    private func extractedScenario(at path: (topIndex: Int, childIndex: Int?)) -> Scenario? {
        if let j = path.childIndex {
            guard case .group(var g) = tree[path.topIndex] else { return nil }
            let s = g.scenarios.remove(at: j)
            tree[path.topIndex] = .group(g)
            return s
        } else {
            guard case .scenario(let s) = tree[path.topIndex] else { return nil }
            tree.remove(at: path.topIndex)
            return s
        }
    }

    private func reinsertScenario(_ scenario: Scenario,
                                  at path: (topIndex: Int, childIndex: Int?)) {
        if let j = path.childIndex,
           tree.indices.contains(path.topIndex),
           case .group(var g) = tree[path.topIndex] {
            let safe = max(0, min(j, g.scenarios.count))
            g.scenarios.insert(scenario, at: safe)
            tree[path.topIndex] = .group(g)
        } else {
            let safe = max(0, min(path.topIndex, tree.count))
            tree.insert(.scenario(scenario), at: safe)
        }
    }

    // MARK: - Action mutations

    func insertAction(_ action: AutoAction,
                      inScenarioAt scenarioIndex: Int,
                      atActionIndex actionIndex: Int) {
        let flat = scenarios
        guard flat.indices.contains(scenarioIndex) else { return }
        let id = flat[scenarioIndex].id
        mutateScenario(id: id) { s in
            let safe = max(0, min(actionIndex, s.actions.count))
            s.actions.insert(action, at: safe)
        }
        save()
    }

    func deleteAction(inScenarioAt scenarioIndex: Int, atActionIndex actionIndex: Int) {
        let flat = scenarios
        guard flat.indices.contains(scenarioIndex) else { return }
        let id = flat[scenarioIndex].id
        var removed: AutoAction?
        mutateScenario(id: id) { s in
            guard s.actions.indices.contains(actionIndex) else { return }
            removed = s.actions.remove(at: actionIndex)
        }
        if let removed = removed {
            ActionStore.shared.delete(id: removed.id)
            OCRSnapshotStore.shared.delete(actionId: removed.id)
        }
        save()
    }

    func moveAction(inScenarioAt scenarioIndex: Int, from sourceIndex: Int, to destIndex: Int) {
        let flat = scenarios
        guard flat.indices.contains(scenarioIndex) else { return }
        let id = flat[scenarioIndex].id
        mutateScenario(id: id) { s in
            guard s.actions.indices.contains(sourceIndex) else { return }
            let a = s.actions.remove(at: sourceIndex)
            let safe = max(0, min(destIndex, s.actions.count))
            s.actions.insert(a, at: safe)
        }
        save()
    }

    // MARK: - First-run seeding

    private func seedDefaults() {
        tree = [.scenario(Scenario(name: L("My Flow"), actions: []))]
    }
}
