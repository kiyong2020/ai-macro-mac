//
//  MouseAction.swift
//  AIMacro
//
//  Created by Kiyong Kim on 6/30/25.
//
import Cocoa
import RxSwift

class AutoAction {
    enum WaitType {
        case click
        case enter
        case code
        case time
    }
    
    /// Legacy enum used only when migrating older serialised payloads
    /// (`{"kind":"key","keyType":"enter|tab|scroll"}`) into the new free-form
    /// custom-key representation. New code should not reference this.
    enum LegacyKeyType: String {
        case enter, tab, scroll
    }

    enum ActionType {
        case click  /// 클릭
        case scroll /// 스크롤 (스페이스바)
        case key    /// 사용자 정의 키 입력 — 키 + 모디파이어는 action.text 에 CustomKey 인코딩
        case wait(type: WaitType) /// 키 대기
        case ocr  /// OCR 클릭
        case script(code: String)  /// script
        case setURL(url: String) /// chrome 브라우저의 url 설정
        case openChrome(url: String) /// 새 chrome 창을 열고 url 로드
        case windowFrame /// 활성 윈도우 프레임을 저장된 사각형으로 맞춤
    }

    var disposeBag: DisposeBag = .init()
    /// Stable per-action identifier — used as the UserDefaults key for
    /// `save()` / `restore()`. Persisted in the scenario JSON via
    /// `toFullJSON()` so it survives across app launches.
    let id: String
    var group = ""
    var type: ActionType
    var name = ""
    var runsDisablePopup = false
    let point = BehaviorSubject<CGPoint>(value: .zero)
    let delay = BehaviorSubject<Double>(value: 0.1)
    let count = BehaviorSubject<Int>(value: 1)
    let text = BehaviorSubject<String>(value: "")

    init(type:ActionType, group: String = "", name:String = "", point: CGPoint = .zero, delay: Double = 0, count: Int = 1,
         text:String = "",
         runsDisablePopup: Bool = false,
         id: String = UUID().uuidString) {
        self.id = id
        self.name = name
        self.type = type
        self.runsDisablePopup = runsDisablePopup
        self.point.onNext(point)
        self.delay.onNext(delay)
        self.count.onNext(count)
        self.text.onNext(text)
    }
    
    func set(json: [String: Any]) throws {
//        self.type = json["type"] as? String == "click" ? .click : .scroll
        self.name = json["name"] as? String ?? ""
        if let pointStr = json["point"] as? String {
            let points = pointStr.split(separator: "&")
            self.point.onNext(.init(x: Double(points[0]) ?? 0, y: Double(points[1]) ?? 0))
        }

        if let delay = json["delay"] as? Double {
            self.delay.onNext(delay)
        }
        
        if let count = json["count"] as? Int {
            self.count.onNext(count)
        }
        if let text = json["text"] as? String {
            self.text.onNext(text)
        }
    }
    
    func toJSON() -> [String: Any] {
        let point = try! point.value()
        return [
            "name": name,
            "point": "\(Int(point.x))&\(Int(point.y))",
            "delay": try! delay.value(),
            "count": try! count.value(),
            "text": try! text.value(),
            ]
    }
    
    func save() {
        ActionStore.shared.save(self)
    }

    func restore() {
        // Primary read: SQLite (keyed by id).
        if ActionStore.shared.restore(into: self) { return }

        // Legacy fallback: prior versions stored a JSON blob in UserDefaults
        // under either the id or `group+name`. Copy across to SQLite once
        // and the next launch hits the fast path.
        let candidates = [id, group + name].filter { !$0.isEmpty }
        for key in candidates {
            guard let data = UserDefaults.standard.data(forKey: key) else { continue }
            applyJSONData(data)
            save()  // migrate to SQLite
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
    }

    private func applyJSONData(_ data: Data) {
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
            try self.set(json: json)
        } catch {
            print(error)
        }
    }
}

// MARK: - Full type-aware serialization
//
// `toJSON` / `set(json:)` above only round-trip the user-editable fields
// (point/delay/count/text). When we persist a whole Scenario we also need
// to capture the action's *type* (including its associated values) so we
// can rebuild the action from disk. The helpers below handle that and are
// used exclusively by Scenario / ScenarioStore.

extension AutoAction {
    /// Serialize everything needed to fully reconstruct this action: the
    /// id, type and its associated values, plus the user-editable values
    /// from `toJSON()`.
    func toFullJSON() -> [String: Any] {
        var json = toJSON()
        json["id"] = id
        json["group"] = group
        json["actionType"] = encodedActionType()
        return json
    }

    /// Inverse of `toFullJSON` — builds a fresh AutoAction from the
    /// serialized payload, or returns nil if the payload is malformed.
    /// Missing `id` (legacy data) is replaced with a freshly generated UUID
    /// — `ScenarioStore` writes the file back on next save, persisting it.
    static func fromFullJSON(_ json: [String: Any]) -> AutoAction? {
        guard let type = decodedActionType(json["actionType"]) else { return nil }
        let action = AutoAction(
            type: type,
            group: json["group"] as? String ?? "",
            name: json["name"] as? String ?? "",
            id: (json["id"] as? String) ?? UUID().uuidString
        )
        try? action.set(json: json)

        // Legacy migration: old `.key(type: .enter|.tab|.scroll)` payloads
        // need their keyType folded into action.text as a CustomKey. Only
        // applies when text is empty so user-edited values aren't clobbered.
        if case .key = type,
           let typeJSON = json["actionType"] as? [String: Any],
           let oldKey = typeJSON["keyType"] as? String,
           ((try? action.text.value())?.isEmpty ?? true) {
            switch oldKey {
            case "enter":  action.text.onNext(":enter")
            case "tab":    action.text.onNext(":tab")
            case "scroll": action.text.onNext(":space")
            default: break
            }
        }
        return action
    }

    /// Produce a deep copy with a fresh BehaviorSubject set so edits to one
    /// instance don't affect the other. Used when duplicating scenarios.
    func clone() -> AutoAction {
        let copy = AutoAction(
            type: type,
            group: group,
            name: name,
            point: (try? point.value()) ?? .zero,
            delay: (try? delay.value()) ?? 0,
            count: (try? count.value()) ?? 1,
            text: (try? text.value()) ?? "",
            runsDisablePopup: runsDisablePopup
        )
        return copy
    }

    // MARK: ActionType encoding

    private func encodedActionType() -> [String: Any] {
        switch type {
        case .click:                  return ["kind": "click"]
        case .scroll:                 return ["kind": "scroll"]
        case .key:                    return ["kind": "key"]
        case .wait(let wt):           return ["kind": "wait", "waitType": Self.waitTypeString(wt)]
        case .ocr:                    return ["kind": "ocr"]
        case .script(let code):       return ["kind": "script", "code": code]
        case .setURL(let url):        return ["kind": "setURL", "url": url]
        case .openChrome(let url):    return ["kind": "openChrome", "url": url]
        case .windowFrame:            return ["kind": "windowFrame"]
        }
    }

    private static func decodedActionType(_ raw: Any?) -> ActionType? {
        guard let dict = raw as? [String: Any],
              let kind = dict["kind"] as? String else { return nil }
        switch kind {
        case "click":       return .click
        case "scroll":      return .scroll
        case "key":         return .key   // legacy keyType handled in fromFullJSON migration
        case "wait":
            guard let s = dict["waitType"] as? String, let wt = waitType(from: s) else { return nil }
            return .wait(type: wt)
        case "ocr":         return .ocr
        case "script":      return .script(code: dict["code"] as? String ?? "")
        case "setURL":      return .setURL(url: dict["url"] as? String ?? "")
        case "openChrome":  return .openChrome(url: dict["url"] as? String ?? "")
        case "windowFrame": return .windowFrame
        default:            return nil
        }
    }

    private static func waitTypeString(_ wt: WaitType) -> String {
        switch wt {
        case .click: return "click"
        case .enter: return "enter"
        case .code:  return "code"
        case .time:  return "time"
        }
    }

    private static func waitType(from s: String) -> WaitType? {
        switch s {
        case "click": return .click
        case "enter": return .enter
        case "code":  return .code
        case "time":  return .time
        default:      return nil
        }
    }
}
