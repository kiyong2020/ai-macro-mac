//
//  ScenarioStore.swift
//  AIMacro
//
//  Persistent store for user-editable scenarios. Loads/saves a JSON file in
//  Application Support, and seeds a single empty default flow ("My Flow")
//  on first launch.
//

import Foundation

final class ScenarioStore {
    static let shared = ScenarioStore()

    private(set) var scenarios: [Scenario] = []

    /// Posted whenever the scenario list changes (add/rename/delete) so UI
    /// can refresh. The body of a single scenario (its actions' values) is
    /// not covered — that uses the existing per-action UserDefaults flow.
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
        if scenarios.isEmpty {
            seedDefaults()
        }
        // Persist unconditionally on launch — ensures freshly-generated
        // action ids (from legacy scenario data missing an "id" field) are
        // written back to disk so they stay stable across launches.
        save()
    }

    // MARK: - File I/O

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        scenarios = arr.compactMap { Scenario.fromJSON($0) }
    }

    func save() {
        let arr = scenarios.map { $0.toJSON() }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: storeURL, options: .atomic)
        NotificationCenter.default.post(name: ScenarioStore.didChangeNotification, object: self)
    }

    // MARK: - Mutations

    /// Replace the entire scenario list in one shot. Used by undo/redo to
    /// restore a captured snapshot; per-action SQLite + OCR cleanup is the
    /// caller's responsibility (it has more context about what changed).
    func replaceAll(with scenarios: [Scenario]) {
        self.scenarios = scenarios
        save()
    }

    func add(_ scenario: Scenario) {
        scenarios.append(scenario)
        save()
    }

    @discardableResult
    func duplicate(at index: Int, newName: String) -> Scenario? {
        guard scenarios.indices.contains(index) else { return nil }
        let src = scenarios[index]
        // Deep-clone actions so per-action edits in the copy don't bleed
        // back into the source scenario.
        let cloned = src.actions.map { $0.clone() }
        let copy = Scenario(name: newName, actions: cloned)
        scenarios.append(copy)
        save()
        return copy
    }

    func delete(at index: Int) {
        guard scenarios.indices.contains(index) else { return }
        // Clean up per-action SQLite rows + OCR snapshots.
        for action in scenarios[index].actions {
            ActionStore.shared.delete(id: action.id)
            OCRSnapshotStore.shared.delete(actionId: action.id)
        }
        scenarios.remove(at: index)
        save()
    }

    func rename(at index: Int, to newName: String) {
        guard scenarios.indices.contains(index) else { return }
        scenarios[index].name = newName
        save()
    }

    // MARK: - Action mutations

    func insertAction(_ action: AutoAction,
                      inScenarioAt scenarioIndex: Int,
                      atActionIndex actionIndex: Int) {
        guard scenarios.indices.contains(scenarioIndex) else { return }
        let safeIndex = max(0, min(actionIndex, scenarios[scenarioIndex].actions.count))
        scenarios[scenarioIndex].actions.insert(action, at: safeIndex)
        save()
    }

    func deleteAction(inScenarioAt scenarioIndex: Int, atActionIndex actionIndex: Int) {
        guard scenarios.indices.contains(scenarioIndex),
              scenarios[scenarioIndex].actions.indices.contains(actionIndex) else { return }
        let removed = scenarios[scenarioIndex].actions.remove(at: actionIndex)
        ActionStore.shared.delete(id: removed.id)
        OCRSnapshotStore.shared.delete(actionId: removed.id)
        save()
    }

    func moveAction(inScenarioAt scenarioIndex: Int, from sourceIndex: Int, to destIndex: Int) {
        guard scenarios.indices.contains(scenarioIndex),
              scenarios[scenarioIndex].actions.indices.contains(sourceIndex) else { return }
        let action = scenarios[scenarioIndex].actions.remove(at: sourceIndex)
        let safeDest = max(0, min(destIndex, scenarios[scenarioIndex].actions.count))
        scenarios[scenarioIndex].actions.insert(action, at: safeDest)
        save()
    }

    // MARK: - First-run seeding

    private func seedDefaults() {
        scenarios = [
            Scenario(name: L("My Flow"), actions: [])
        ]
    }
}
