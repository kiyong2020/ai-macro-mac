import Foundation

class FlowMode {
    var id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    func toJSON() -> [String: Any] {
        [
            "id": id.uuidString,
            "name": name,
        ]
    }

    static func fromJSON(_ json: [String: Any]) -> FlowMode? {
        guard let idStr = json["id"] as? String,
              let id = UUID(uuidString: idStr),
              let name = json["name"] as? String else { return nil }
        return FlowMode(id: id, name: name)
    }
}
