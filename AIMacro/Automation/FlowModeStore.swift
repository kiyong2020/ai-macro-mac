//
//  FlowModeStore.swift
//  AIMacro
//
//  Persistent store for user-editable flowModes. Loads/saves a JSON file in
//  Application Support, and seeds a single empty default flow ("My Flow")
//  on first launch.
//

import Foundation

final class FlowModeStore {
    static let shared = FlowModeStore()

    private(set) var flowModes: [FlowMode] = []

    /// Posted whenever the FlowMode list changes (add/rename/delete) so UI
    /// can refresh. The body of a single FlowMode (its actions' values) is
    /// not covered — that uses the existing per-action UserDefaults flow.
    static let didChangeNotification = Notification.Name("FlowModeStoreDidChange")

    private var storeURL: URL = {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("AIMacro")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("flowModes.json")
    }()

    private init() {
        load()
        if flowModes.isEmpty {
            seedDefaults()
        }
        // Persist unconditionally on launch — ensures freshly-generated
        // action ids (from legacy FlowMode data missing an "id" field) are
        // written back to disk so they stay stable across launches.
        save()
    }

    // MARK: - File I/O

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        flowModes = arr.compactMap { FlowMode.fromJSON($0) }
    }

    func save() {
        let arr = flowModes.map { $0.toJSON() }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: storeURL, options: .atomic)
        NotificationCenter.default.post(name: FlowModeStore.didChangeNotification, object: self)
    }

    // MARK: - Mutations

    /// Replace the entire FlowMode list in one shot. Used by undo/redo to
    /// restore a captured snapshot; per-action SQLite + OCR cleanup is the
    /// caller's responsibility (it has more context about what changed).
    func replaceAll(with flowModes: [FlowMode]) {
        self.flowModes = flowModes
        save()
    }

    func add(_ flowMode: FlowMode) {
        flowModes.append(flowMode)
        save()
    }

    @discardableResult
    func duplicate(at index: Int, newName: String) -> FlowMode? {
        guard flowModes.indices.contains(index) else { return nil }
        let src = flowModes[index]

        let copy = FlowMode(name: newName)
        flowModes.append(copy)
        save()
        return copy
    }

    func delete(at index: Int) {
        guard flowModes.indices.contains(index) else { return }

        flowModes.remove(at: index)
        save()
    }

    func rename(at index: Int, to newName: String) {
        guard flowModes.indices.contains(index) else { return }
        flowModes[index].name = newName
        save()
    }

    /// Move a flow mode from one position to another. The first slot
    /// (index 0) is reserved for the default mode and must not move —
    /// callers are responsible for keeping the source/destination ≥ 1.
    func move(from sourceIndex: Int, to destIndex: Int) {
        guard flowModes.indices.contains(sourceIndex) else { return }
        let clampedDest = max(0, min(destIndex, flowModes.count - 1))
        guard sourceIndex != clampedDest else { return }
        let item = flowModes.remove(at: sourceIndex)
        flowModes.insert(item, at: clampedDest)
        save()
    }

    func flowMode(id: UUID) -> FlowMode? {
        flowModes.first(where: { $0.id == id })
    }

    func index(of id: UUID) -> Int? {
        flowModes.firstIndex(where: { $0.id == id })
    }

    // MARK: - Action mutations

    func insertAction(_ action: AutoAction,
                      inFlowModeAt FlowModeIndex: Int,
                      atActionIndex actionIndex: Int) {
        guard flowModes.indices.contains(FlowModeIndex) else { return }
        save()
    }

    func deleteAction(inFlowModeAt FlowModeIndex: Int, atActionIndex actionIndex: Int) {
        guard flowModes.indices.contains(FlowModeIndex) else { return }

        save()
    }

    func moveAction(inFlowModeAt flowModeIndex: Int, from sourceIndex: Int, to destIndex: Int) {
        guard flowModes.indices.contains(flowModeIndex) else { return }
        save()
    }

    // MARK: - First-run seeding

    private func seedDefaults() {
        flowModes = [
            FlowMode(name: L("Default Mode"))
        ]
    }
}
