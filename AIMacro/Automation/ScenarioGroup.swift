//
//  ScenarioGroup.swift
//  AIMacro
//
//  Hierarchical grouping for the scenario list shown in the management
//  window. The top level is an ordered mix of groups (which contain
//  scenarios) and loose scenarios. The main window's popup intentionally
//  ignores the tree structure and renders the preorder-flattened list.
//

import Foundation

/// One named, ordered collection of scenarios. Groups never nest — the
/// editor enforces this in validateDrop. `isExpanded` is persisted so the
/// user's collapse/expand state survives across launches.
struct ScenarioGroup {
    var id: UUID
    var name: String
    var isExpanded: Bool
    var scenarios: [Scenario]

    init(id: UUID = UUID(),
         name: String,
         isExpanded: Bool = true,
         scenarios: [Scenario] = []) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
        self.scenarios = scenarios
    }

    func toJSON() -> [String: Any] {
        [
            "kind": "group",
            "id": id.uuidString,
            "name": name,
            "isExpanded": isExpanded,
            "scenarios": scenarios.map { $0.toJSON() },
        ]
    }

    static func fromJSON(_ json: [String: Any]) -> ScenarioGroup? {
        guard let idStr = json["id"] as? String,
              let id = UUID(uuidString: idStr),
              let name = json["name"] as? String else { return nil }
        let isExpanded = json["isExpanded"] as? Bool ?? true
        let scenariosJSON = json["scenarios"] as? [[String: Any]] ?? []
        let scenarios = scenariosJSON.compactMap { Scenario.fromJSON($0) }
        return ScenarioGroup(id: id,
                             name: name,
                             isExpanded: isExpanded,
                             scenarios: scenarios)
    }
}

/// Top-level entry in the scenario tree. Legacy JSON entries (no `kind`
/// field) are treated as `.scenario` so older `scenarios.json` files load
/// without migration steps — the next save rewrites them in the new form.
enum ScenarioNode {
    case group(ScenarioGroup)
    case scenario(Scenario)

    var id: UUID {
        switch self {
        case .group(let g):    return g.id
        case .scenario(let s): return s.id
        }
    }

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }

    func toJSON() -> [String: Any] {
        switch self {
        case .group(let g): return g.toJSON()
        case .scenario(let s):
            var json = s.toJSON()
            json["kind"] = "scenario"
            return json
        }
    }

    static func fromJSON(_ json: [String: Any]) -> ScenarioNode? {
        // Legacy entries lack `kind` and decode straight to a Scenario at
        // the top level. The first save after load promotes them to
        // `{kind:"scenario", ...}` form.
        let kind = json["kind"] as? String ?? "scenario"
        switch kind {
        case "group":
            return ScenarioGroup.fromJSON(json).map { .group($0) }
        case "scenario":
            return Scenario.fromJSON(json).map { .scenario($0) }
        default:
            return nil
        }
    }
}
