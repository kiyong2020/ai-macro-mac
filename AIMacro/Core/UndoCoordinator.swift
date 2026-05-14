//
//  UndoCoordinator.swift
//  AIMacro
//
//  Snapshot-based undo/redo for scenario + action edits. Wraps a Foundation
//  `UndoManager` that ViewController exposes via the NSResponder chain so
//  Edit > Undo / Redo (⌘Z / ⇧⌘Z) just work.
//
//  Coverage:
//   - Scenario add / rename / delete / duplicate
//   - Action add / delete / reorder
//   - Per-action field edits (name, point, delay, count, text) coalesced by
//     the same 500ms throttle that already drives ActionStore persistence
//
//  Strategy: each undoable mutation registers the *inverse* on the undo
//  manager. The inverse re-registers its own inverse when run, which gets
//  pushed to the redo stack automatically (NSUndoManager semantics).
//

import Cocoa

/// Captured app state at a single point in time. JSON-encoded so it doubles
/// as a stable equality check (different bytes = different state).
struct UndoSnapshot: Equatable {
    let scenariosData: Data
    let currentScenarioIndex: Int
    let selectedRow: Int
}

/// Implemented by `ViewController`. Lets the coordinator capture / restore
/// state without knowing the controller's internals.
protocol UndoSnapshotTarget: AnyObject {
    func makeUndoSnapshot() -> UndoSnapshot
    func applyUndoSnapshot(_ snapshot: UndoSnapshot)
}

final class UndoCoordinator {
    let manager = UndoManager()
    weak var target: UndoSnapshotTarget?

    /// The state we last considered "current" — anchors the next inverse
    /// registration. Initialised in `bind(to:)` once the controller can
    /// produce a snapshot.
    private var lastSnapshot: UndoSnapshot?

    /// Set while an undo/redo apply is in flight so re-entrant captures
    /// (the BehaviorSubject `.onNext` calls inside `applyUndoSnapshot`)
    /// don't immediately register another inverse.
    private var isApplying = false

    init() {
        manager.levelsOfUndo = 100
    }

    /// Establish the baseline snapshot. Call from `viewDidLoad` after the
    /// initial scenario has been loaded.
    func bind(to target: UndoSnapshotTarget) {
        self.target = target
        self.lastSnapshot = target.makeUndoSnapshot()
    }

    /// Compare the controller's current state against the last known one.
    /// If they differ, push the inverse onto the undo manager and update
    /// the baseline. Safe to call repeatedly — no-op when nothing changed.
    func captureIfChanged() {
        guard !isApplying, let target = target else { return }
        let current = target.makeUndoSnapshot()
        guard let prev = lastSnapshot else {
            lastSnapshot = current
            return
        }
        guard current != prev else { return }
        registerInverse(undoTo: prev, redoTo: current)
        lastSnapshot = current
    }

    /// Re-anchor the baseline without registering anything. Use after a
    /// non-undoable bulk operation (e.g. loading a different document) so
    /// the next mutation doesn't try to undo across that boundary.
    func resetBaseline() {
        guard let target = target else { return }
        lastSnapshot = target.makeUndoSnapshot()
    }

    /// 500ms throttle on action edits + an extra cushion for any deferred
    /// side effects that fire shortly after `loadCurrentScenario` resubscribes
    /// (e.g. `seedBrowserDefaults` rewriting `action.text` on detail rebuild).
    private static let postApplyQuietMs: Int = 750

    private func registerInverse(undoTo target: UndoSnapshot,
                                 redoTo current: UndoSnapshot) {
        manager.registerUndo(withTarget: self) { [weak self] _ in
            guard let self = self, let vc = self.target else { return }
            self.isApplying = true
            vc.applyUndoSnapshot(target)
            self.lastSnapshot = target
            // Re-register synchronously so this becomes the redo entry —
            // NSUndoManager detects we're inside an undo and pushes the
            // registration to the redo stack. Doing this async would land
            // it on the undo stack instead.
            self.registerInverse(undoTo: current, redoTo: target)
            // Hold `isApplying` past the action-edit throttle window so any
            // deferred mutations (detail-pane seeding, BehaviorSubject
            // re-emissions, etc.) don't trip a fresh `captureIfChanged`
            // that would clobber the redo stack we just registered. When
            // the window closes, re-anchor the baseline against whatever
            // actually settled so the *next* user edit produces a clean
            // diff.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.postApplyQuietMs)) { [weak self] in
                guard let self = self else { return }
                if let target = self.target {
                    self.lastSnapshot = target.makeUndoSnapshot()
                }
                self.isApplying = false
            }
        }
    }
}
