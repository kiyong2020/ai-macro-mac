//
//  Scenario.swift
//  AIMacro
//
//  A named, ordered list of AutoActions. Replaces the hardcoded
//  `Constants.seonam` / `seonamFull` / `yangchun` arrays as the unit the
//  user picks via the top-of-window scenario popup. Persisted to disk by
//  `ScenarioStore`.
//

import Foundation

struct Scenario {
    var id: UUID
    var name: String
    var actions: [AutoAction]

    init(id: UUID = UUID(), name: String, actions: [AutoAction] = []) {
        self.id = id
        self.name = name
        self.actions = actions
    }

    func toJSON() -> [String: Any] {
        [
            "id": id.uuidString,
            "name": name,
            "actions": actions.map { $0.toFullJSON() },
        ]
    }

    static func fromJSON(_ json: [String: Any]) -> Scenario? {
        guard let idStr = json["id"] as? String,
              let id = UUID(uuidString: idStr),
              let name = json["name"] as? String else { return nil }
        let actionsJSON = json["actions"] as? [[String: Any]] ?? []
        let actions = actionsJSON.compactMap { AutoAction.fromFullJSON($0) }
        return Scenario(id: id, name: name, actions: actions)
    }
}
