//
//  ActionStore.swift
//  AIMacro
//
//  SQLite-backed key/value store for per-AutoAction user-edited values
//  (point/delay/count/text). Replaces the prior UserDefaults storage —
//  primary key is the action's stable UUID `id`.
//

import Foundation
import SQLite

final class ActionStore {
    static let shared = ActionStore()

    private let db: Connection?
    private let actions = Table("actions")
    private let idCol = SQLite.Expression<String>("id")
    private let pointCol = SQLite.Expression<String>("point")
    private let delayCol = SQLite.Expression<Double>("delay")
    private let countCol = SQLite.Expression<Int>("count")
    private let textCol = SQLite.Expression<String>("text")
    private let nameCol = SQLite.Expression<String>("name")
    private let clicksCol = SQLite.Expression<Int>("clicks")
    private let disabledCol = SQLite.Expression<Bool>("disabled")

    private init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("AIMacro")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("actions.sqlite3")

        db = try? Connection(dbURL.path)
        createTableIfNeeded()
    }

    private func createTableIfNeeded() {
        guard let db = db else { return }
        try? db.run(actions.create(ifNotExists: true) { t in
            t.column(idCol, primaryKey: true)
            t.column(pointCol, defaultValue: "0&0")
            t.column(delayCol, defaultValue: 0)
            t.column(countCol, defaultValue: 1)
            t.column(textCol, defaultValue: "")
            t.column(nameCol, defaultValue: "")
            t.column(clicksCol, defaultValue: 1)
            t.column(disabledCol, defaultValue: false)
        })
        // Migration: add the `clicks` column to pre-existing databases.
        // SQLite ignores the duplicate-column error so this is safe to
        // call every launch.
        try? db.run(actions.addColumn(clicksCol, defaultValue: 1))
        try? db.run(actions.addColumn(disabledCol, defaultValue: false))
    }

    // MARK: - Per-action read/write

    /// Persist the action's user-editable values keyed by `id`.
    func save(_ action: AutoAction) {
        guard let db = db else { return }
        let row = actions.filter(idCol == action.id)
        let pointStr: String = {
            let p = (try? action.point.value()) ?? .zero
            return "\(Int(p.x))&\(Int(p.y))"
        }()
        let delayVal = (try? action.delay.value()) ?? 0
        let countVal = (try? action.count.value()) ?? 1
        let textVal = (try? action.text.value()) ?? ""
        let clicksVal = (try? action.clicks.value()) ?? 1
        let disabledVal = (try? action.disabled.value()) ?? false

        let setters: [Setter] = [
            idCol <- action.id,
            pointCol <- pointStr,
            delayCol <- delayVal,
            countCol <- countVal,
            textCol <- textVal,
            nameCol <- action.name,
            clicksCol <- clicksVal,
            disabledCol <- disabledVal,
        ]
        // INSERT OR REPLACE on id.
        do {
            try db.run(row.update(setters))
            // update returns 0 rows when no row matches → fall through to insert
            if try db.scalar(row.count) == 0 {
                try db.run(actions.insert(or: .replace, setters))
            }
        } catch {
            print("ActionStore.save failed: \(error)")
        }
    }

    /// Load values into the given action (point/delay/count/text/name).
    /// Returns true if a row existed; false if no record found.
    @discardableResult
    func restore(into action: AutoAction) -> Bool {
        guard let db = db else { return false }
        do {
            guard let row = try db.pluck(actions.filter(idCol == action.id)) else {
                return false
            }
            let p = row[pointCol].split(separator: "&")
            if p.count == 2,
               let x = Double(p[0]), let y = Double(p[1]) {
                action.point.onNext(CGPoint(x: x, y: y))
            }
            action.delay.onNext(row[delayCol])
            action.count.onNext(row[countCol])
            action.text.onNext(row[textCol])
            // `clicks` column was added later — old rows may not have it.
            // `row[clicksCol]` throws if the column is missing on this row's
            // result set; default to 1 in that case.
            if let v = try? row.get(clicksCol) {
                action.clicks.onNext(v)
            }
            if let v = try? row.get(disabledCol) {
                action.disabled.onNext(v)
            }
            let storedName = row[nameCol]
            if !storedName.isEmpty { action.name = storedName }
            return true
        } catch {
            print("ActionStore.restore failed: \(error)")
            return false
        }
    }

    /// Delete the row for an id (used when an action is removed from a
    /// scenario so SQLite doesn't grow unbounded).
    func delete(id: String) {
        guard let db = db else { return }
        try? db.run(actions.filter(idCol == id).delete())
    }
}
