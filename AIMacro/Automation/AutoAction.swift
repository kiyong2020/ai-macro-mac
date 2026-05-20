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
        /// 디폴트 브라우저로 url 을 열고, 저장된 프레임이 있으면 frontmost 창에
        /// 그대로 적용. action.text 는 "<url>|<frame>" 파이프 구분 포맷
        /// (`OpenBrowserPayload`).
        case openBrowser(url: String)
        /// 드래그: action.point 에서 마우스 down → action.text 의 경로점들
        /// ("x1,y1;x2,y2;...") 을 차례로 부드럽게 이동 → 마지막 점에서 up.
        case drag
        case windowFrame /// 활성 윈도우 프레임을 저장된 사각형으로 맞춤
        /// 선택한 플로우로 이동. 타겟이 비어 있으면 ("이동 안함") 아무
        /// 동작도 하지 않고 다음 액션으로 진행.
        case nextScenario
        /// 캡처한 화면 영역 + 사용자 지시문을 ai-macro-api 의
        /// `/generate-actions` 로 보내, 받은 액션 목록을 그 자리에서
        /// 실행. 생성된 액션은 시나리오에 추가되지 않고 일회성으로 소비됨.
        /// 인코딩: point=영역 중심(Quartz), count=ocr 와 동일한 width*10000+height,
        /// text=사용자 지시문.
        case aiGen
        /// 글자인식 전환: 지정된 영역을 일정 간격으로 스캔하여 등록된
        /// 트리거 텍스트 중 하나가 인식되면 해당 플로우로 이동. 한
        /// 액션에 여러 (텍스트, 대상 플로우, 필수 플로우 모드) 조합을
        /// 저장할 수 있으며 플로우 모드가 비어 있으면 '전체 모드' —
        /// 현재 실행 중인 모드와 무관하게 매칭. 인코딩: point/count 는
        /// `.ocr` 와 동일, text 는 `OCRSwitchPayload` 형식.
        case ocrSwitch
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
    /// OCR-specific click repeat count — how many times to click the
    /// recognised target. Unused by other action types (their repeat count
    /// lives in `count`; OCR's `count` is repurposed for scan-area size).
    let clicks = BehaviorSubject<Int>(value: 1)
    /// When true, the action is shown greyed-out in the list and the
    /// runner skips it during playback. Persisted alongside the other
    /// user-editable fields.
    let disabled = BehaviorSubject<Bool>(value: false)
    /// UI-state: which unit the 초/분 popup next to every delay field
    /// should show when this action is re-selected. The stored `delay`
    /// value itself is always in seconds — this only affects rendering.
    /// Shared by the main delay field and all per-FlowMode delay rows.
    let delayUnitIsMinutes = BehaviorSubject<Bool>(value: false)

    init(type:ActionType, group: String = "", name:String = "", point: CGPoint = .zero, delay: Double = 0, count: Int = 1,
         text:String = "",
         clicks: Int = 1,
         disabled: Bool = false,
         delayUnitIsMinutes: Bool = false,
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
        self.clicks.onNext(clicks)
        self.disabled.onNext(disabled)
        self.delayUnitIsMinutes.onNext(delayUnitIsMinutes)
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
        if let clicks = json["clicks"] as? Int {
            self.clicks.onNext(clicks)
        }
        if let disabled = json["disabled"] as? Bool {
            self.disabled.onNext(disabled)
        }
        if let u = json["delayUnitIsMinutes"] as? Bool {
            self.delayUnitIsMinutes.onNext(u)
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
            "clicks": try! clicks.value(),
            "disabled": try! disabled.value(),
            "delayUnitIsMinutes": try! delayUnitIsMinutes.value(),
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
            clicks: (try? clicks.value()) ?? 1,
            disabled: (try? disabled.value()) ?? false,
            delayUnitIsMinutes: (try? delayUnitIsMinutes.value()) ?? false,
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
        case .openBrowser(let url):   return ["kind": "openBrowser", "url": url]
        case .drag:                   return ["kind": "drag"]
        case .windowFrame:            return ["kind": "windowFrame"]
        case .nextScenario:           return ["kind": "nextScenario"]
        case .aiGen:                  return ["kind": "aiGen"]
        case .ocrSwitch:              return ["kind": "ocrSwitch"]
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
        case "openBrowser": return .openBrowser(url: dict["url"] as? String ?? "")
        case "drag":         return .drag
        case "windowFrame":  return .windowFrame
        case "nextScenario": return .nextScenario
        case "aiGen":        return .aiGen
        case "ocrSwitch":    return .ocrSwitch
        default:            return nil
        }
    }

    private static func waitTypeString(_ wt: WaitType) -> String {
        switch wt {
        case .click: return "click"
        case .enter: return "enter"
        case .time:  return "time"
        }
    }

    private static func waitType(from s: String) -> WaitType? {
        switch s {
        case "click": return .click
        case "enter": return .enter
        case "time":  return .time
        // Legacy "code" payloads (verification-code wait, removed with the
        // socket service) decode to nil so fromFullJSON drops them via the
        // caller's compactMap.
        default:      return nil
        }
    }
}

// MARK: - .openBrowser payload

/// Pipe-delimited "<url>|<frame>" packed into a single `action.text`. The
/// frame half uses the same string format as `.windowFrame` actions
/// (`WindowFrameUtil.encode`). Either half may be empty.
enum OpenBrowserPayload {
    static func parse(_ s: String) -> (url: String, frame: String) {
        if let pipe = s.firstIndex(of: "|") {
            return (String(s[..<pipe]), String(s[s.index(after: pipe)...]))
        }
        return (s, "")
    }

    static func encode(url: String, frame: String) -> String {
        return frame.isEmpty ? url : "\(url)|\(frame)"
    }
}

// MARK: - Frame slot accessor (.windowFrame + .openBrowser)

/// Lets the window-frame picker UI (`makeWindowFrameRow`, `pickWindow`,
/// `restoreWindow`) read/write the frame for both `.windowFrame` (frame is
/// the entire `text`) and `.openBrowser` (frame is the second pipe-half).
extension AutoAction {
    /// Encoded frame string ("x,y,w,h" via `WindowFrameUtil.encode`), or
    /// empty when no frame has been set.
    var encodedFrame: String {
        let raw = (try? text.value()) ?? ""
        switch type {
        case .openBrowser: return OpenBrowserPayload.parse(raw).frame
        default:           return raw
        }
    }

    func setEncodedFrame(_ encoded: String) {
        switch type {
        case .openBrowser:
            let cur = OpenBrowserPayload.parse((try? text.value()) ?? "")
            text.onNext(OpenBrowserPayload.encode(url: cur.url, frame: encoded))
        default:
            text.onNext(encoded)
        }
    }

    /// Decoded frame for `.openBrowser` (`.zero` if unset). Only meaningful
    /// for that action type.
    var browserFrame: CGRect {
        WindowFrameUtil.decode(encodedFrame) ?? .zero
    }

    func setBrowserFrame(_ frame: CGRect) {
        setEncodedFrame(WindowFrameUtil.encode(frame))
    }
}

// MARK: - .ocr scan area size

/// OCR scan-area size (width × height in pixels) packed into the otherwise-
/// unused `count` field for `.ocr` actions:
/// - `0`            → default (`Constants.ocrCaptureSize` × …, square)
/// - `1...9999`     → legacy square (`width == height == count`)
/// - `≥ 10000`      → `width = count / 10000`, `height = count % 10000`
///
/// New writes always use the packed form so width and height can be edited
/// independently; legacy square values are still decoded correctly on read.
extension AutoAction {
    var ocrScanSize: CGSize {
        let raw = (try? count.value()) ?? 0
        if raw <= 0 {
            return CGSize(width: Constants.ocrCaptureSize,
                          height: Constants.ocrCaptureSize)
        }
        if raw < 10000 {
            return CGSize(width: raw, height: raw)
        }
        return CGSize(width: raw / 10000, height: raw % 10000)
    }

    func setOCRScanSize(width: Int, height: Int) {
        let w = max(1, min(9999, width))
        let h = max(1, min(9999, height))
        count.onNext(w * 10000 + h)
    }
}

// MARK: - .aiGen payload (instruction + loop interval + end condition)

/// `.aiGen` packs three things into `action.text`:
/// - the natural-language instruction (free-form user text),
/// - an optional inter-iteration interval (seconds) for the multi-turn loop,
/// - an optional end condition (single-line) — when present, the runner
///   keeps calling `/generate-actions` until the model reports the
///   condition is satisfied; when empty, the runner makes exactly one call,
/// - an optional `allowedKinds` subset that restricts which action kinds
///   the server may emit.
///
/// Encoded as zero-or-more `@key=value` header lines at the top followed
/// by the instruction body:
/// ```
/// @interval=2.0
/// @end=로그인 화면이 보이면 종료
/// @allowed=click,drag,scroll,nextScenario
/// 로그인 버튼을 클릭
/// ```
/// Headers may appear in any order. Lines that don't match `@key=value`
/// terminate the header section, so legacy `.aiGen` actions (no header at
/// all) still decode cleanly with the body as `instruction`.
struct AIGenPayload {
    static let defaultInterval: Double = 1.0
    static let intervalRange: ClosedRange<Double> = 0.1 ... 60.0

    var instruction: String = ""
    /// `nil` ⇒ no header was present (legacy / never edited).
    var interval: Double?
    /// Empty ⇒ one-shot mode (runner stops after a single API call).
    var endCondition: String = ""
    /// `nil` ⇒ no `@allowed` header — server uses its default kind set.
    /// Non-nil (possibly empty) ⇒ user explicitly restricted the kinds.
    var allowedKinds: Set<ActionGenService.AllowedKind>?

    static func parse(_ raw: String) -> AIGenPayload {
        var payload = AIGenPayload()
        let lines = raw.components(separatedBy: "\n")
        var headerCount = 0
        for line in lines {
            guard line.hasPrefix("@"),
                  let eq = line.firstIndex(of: "="),
                  eq > line.startIndex else { break }
            let key = String(line[line.index(after: line.startIndex) ..< eq])
            let value = String(line[line.index(after: eq)...])
            switch key {
            case "interval":
                if let n = Double(value) {
                    payload.interval = max(intervalRange.lowerBound,
                                           min(intervalRange.upperBound, n))
                }
            case "end":
                payload.endCondition = value
            case "allowed":
                payload.allowedKinds = Set(
                    value.split(separator: ",").compactMap {
                        ActionGenService.AllowedKind(rawValue: String($0).trimmingCharacters(in: .whitespaces))
                    }
                )
            default:
                // Unknown header — stop parsing and treat as body so we
                // don't silently swallow content the user typed.
                return finalize(payload: payload, body: lines.dropFirst(headerCount).joined(separator: "\n"))
            }
            headerCount += 1
        }
        return finalize(payload: payload,
                        body: lines.dropFirst(headerCount).joined(separator: "\n"))
    }

    private static func finalize(payload: AIGenPayload, body: String) -> AIGenPayload {
        var p = payload
        p.instruction = body
        return p
    }

    func encode() -> String {
        var lines: [String] = []
        if let interval = interval {
            lines.append("@interval=\(formatInterval(interval))")
        }
        if !endCondition.isEmpty {
            lines.append("@end=\(sanitizeSingleLine(endCondition))")
        }
        if let allowedKinds = allowedKinds {
            // Stable order so re-encoding doesn't churn the file.
            let values = ActionGenService.AllowedKind.allCases
                .filter { allowedKinds.contains($0) }
                .map { $0.rawValue }
                .joined(separator: ",")
            lines.append("@allowed=\(values)")
        }
        lines.append(instruction)
        return lines.joined(separator: "\n")
    }

    /// Trim trailing zeros so 2.0 → "2", 1.5 → "1.5". Keeps the encoded
    /// text stable so re-saving an unchanged action doesn't churn the file.
    private func formatInterval(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(v))
        }
        return String(format: "%g", v)
    }

    private func sanitizeSingleLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
    }
}

extension AutoAction {
    /// Free-form instruction for `.aiGen`, with any encoded header
    /// stripped. Use this instead of reading `action.text` directly.
    var aiGenInstruction: String {
        AIGenPayload.parse((try? text.value()) ?? "").instruction
    }

    /// Inter-iteration delay (seconds) the runner waits between successive
    /// `/generate-actions` calls. Falls back to
    /// `AIGenPayload.defaultInterval` when the user hasn't set a value.
    var aiGenInterval: Double {
        AIGenPayload.parse((try? text.value()) ?? "").interval
            ?? AIGenPayload.defaultInterval
    }

    /// Optional end condition. Empty ⇒ runner makes exactly one API call.
    var aiGenEndCondition: String {
        AIGenPayload.parse((try? text.value()) ?? "").endCondition
    }

    func setAIGenInstruction(_ instruction: String) {
        var p = AIGenPayload.parse((try? text.value()) ?? "")
        p.instruction = instruction
        text.onNext(p.encode())
    }

    func setAIGenInterval(_ seconds: Double) {
        var p = AIGenPayload.parse((try? text.value()) ?? "")
        p.interval = max(AIGenPayload.intervalRange.lowerBound,
                         min(AIGenPayload.intervalRange.upperBound, seconds))
        text.onNext(p.encode())
    }

    func setAIGenEndCondition(_ condition: String) {
        var p = AIGenPayload.parse((try? text.value()) ?? "")
        p.endCondition = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        text.onNext(p.encode())
    }

    /// User-restricted action kinds for the server. `nil` ⇒ no restriction
    /// (server defaults). Non-nil ⇒ subset (possibly empty) explicitly
    /// chosen in the editor.
    var aiGenAllowedKinds: Set<ActionGenService.AllowedKind>? {
        AIGenPayload.parse((try? text.value()) ?? "").allowedKinds
    }

    func setAIGenAllowedKinds(_ kinds: Set<ActionGenService.AllowedKind>?) {
        var p = AIGenPayload.parse((try? text.value()) ?? "")
        p.allowedKinds = kinds
        text.onNext(p.encode())
    }
}

// MARK: - .click button + modifier flags

/// Mouse button selection for `.click` actions.
enum ClickButton: String {
    case left
    case right

    static func parse(_ raw: String) -> ClickButton {
        return ClickButton(rawValue: raw.lowercased()) ?? .left
    }
}

/// Full `.click` config — button + held modifier flags. Persisted into
/// `action.text` as `"<button>|<modifiers>"`:
///
/// - `""`                → left click, no modifiers (legacy default)
/// - `"right"`           → right click, no modifiers (legacy)
/// - `"left|cmd"`        → ⌘-click
/// - `"right|cmd,shift"` → ⇧⌘-right-click
struct ClickConfig {
    var button: ClickButton = .left
    var modifiers: NSEvent.ModifierFlags = []

    static func parse(_ raw: String) -> ClickConfig {
        var cfg = ClickConfig()
        let parts = raw.split(separator: "|", maxSplits: 1,
                              omittingEmptySubsequences: false).map(String.init)
        if !parts.isEmpty {
            cfg.button = ClickButton.parse(parts[0])
        }
        if parts.count >= 2 {
            for tok in parts[1].split(separator: ",") {
                switch tok.lowercased() {
                case "cmd", "command":       cfg.modifiers.insert(.command)
                case "shift":                cfg.modifiers.insert(.shift)
                case "ctrl", "control":      cfg.modifiers.insert(.control)
                case "opt", "option", "alt": cfg.modifiers.insert(.option)
                default: break
                }
            }
        }
        return cfg
    }

    func encode() -> String {
        var mods: [String] = []
        if modifiers.contains(.command) { mods.append("cmd") }
        if modifiers.contains(.shift)   { mods.append("shift") }
        if modifiers.contains(.control) { mods.append("ctrl") }
        if modifiers.contains(.option)  { mods.append("opt") }
        if mods.isEmpty {
            // Keep legacy form: empty string for default left click, plain
            // "right" for right click.
            return button == .left ? "" : button.rawValue
        }
        return "\(button.rawValue)|\(mods.joined(separator: ","))"
    }
}

extension AutoAction {
    /// Full click config (button + modifiers) for `.click` actions.
    var clickConfig: ClickConfig {
        ClickConfig.parse((try? text.value()) ?? "")
    }

    func setClickConfig(_ cfg: ClickConfig) {
        text.onNext(cfg.encode())
    }

    /// Mouse button for `.click` actions. Defaults to `.left` for legacy
    /// rows where `text` is empty. Preserves the modifier slot.
    var clickButton: ClickButton {
        clickConfig.button
    }

    func setClickButton(_ button: ClickButton) {
        var cfg = clickConfig
        cfg.button = button
        setClickConfig(cfg)
    }

    /// Toggle a single modifier flag without disturbing the button or other
    /// modifier bits.
    func setClickModifier(_ flag: NSEvent.ModifierFlags, on: Bool) {
        var cfg = clickConfig
        if on {
            cfg.modifiers.insert(flag)
        } else {
            cfg.modifiers.remove(flag)
        }
        setClickConfig(cfg)
    }
}

// MARK: - .scroll direction + options

/// Encoded as `action.text`:
/// - `""`                    → down, no flags (legacy default)
/// - `"up"`                  → up, no flags (legacy)
/// - `"down|slow"`           → down, slower inter-tick delay (avoids the
///                             receiving app — e.g. Android Emulator/Qt —
///                             turning a rapid burst into a kinetic flick).
/// - `"down|slow,delay=500"` → down + slow, with a user-tuned step delay
///                             in ms. Absent `delay=` means the legacy
///                             default (`ScrollConfig.defaultSlowDelayMs`).
struct ScrollConfig {
    static let defaultSlowDelayMs = 300
    static let slowDelayRange = 50 ... 5000

    var direction: ScrollDirection = .down
    /// When true, the runner spaces ticks further apart so flick-detecting
    /// receivers don't add their own deceleration.
    var slow: Bool = false
    /// Inter-tick delay (ms) applied only when `slow == true`. Persisted
    /// so toggling `slow` off and back on keeps the user's chosen value.
    var slowDelayMs: Int = defaultSlowDelayMs

    static func parse(_ raw: String) -> ScrollConfig {
        var cfg = ScrollConfig()
        let parts = raw.split(separator: "|", maxSplits: 1,
                              omittingEmptySubsequences: false).map(String.init)
        if !parts.isEmpty {
            cfg.direction = ScrollDirection.parse(parts[0])
        }
        if parts.count >= 2 {
            for tok in parts[1].split(separator: ",") {
                let s = String(tok).lowercased()
                if s == "slow" {
                    cfg.slow = true
                } else if s.hasPrefix("delay=") {
                    if let v = Int(s.dropFirst("delay=".count)) {
                        cfg.slowDelayMs = max(slowDelayRange.lowerBound,
                                              min(slowDelayRange.upperBound, v))
                    }
                }
            }
        }
        return cfg
    }

    func encode() -> String {
        var flags: [String] = []
        if slow {
            flags.append("slow")
            // Only emit the delay when non-default so existing rows that
            // used the legacy 300ms don't churn on first save.
            if slowDelayMs != Self.defaultSlowDelayMs {
                flags.append("delay=\(slowDelayMs)")
            }
        }
        if flags.isEmpty {
            // Preserve legacy form so existing saves don't get rewritten on
            // first load.
            return direction.rawValue
        }
        return "\(direction.rawValue)|\(flags.joined(separator: ","))"
    }
}

extension AutoAction {
    var scrollConfig: ScrollConfig {
        ScrollConfig.parse((try? text.value()) ?? "")
    }

    func setScrollConfig(_ cfg: ScrollConfig) {
        text.onNext(cfg.encode())
    }

    /// Direction for `.scroll` actions, decoded from `action.text`.
    /// Defaults to `.down` for legacy rows where `text` is empty.
    var scrollDirection: ScrollDirection {
        scrollConfig.direction
    }

    func setScrollDirection(_ direction: ScrollDirection) {
        var cfg = scrollConfig
        cfg.direction = direction
        setScrollConfig(cfg)
    }

    func setScrollSlow(_ slow: Bool) {
        var cfg = scrollConfig
        cfg.slow = slow
        setScrollConfig(cfg)
    }

    func setScrollSlowDelay(_ ms: Int) {
        var cfg = scrollConfig
        cfg.slowDelayMs = max(ScrollConfig.slowDelayRange.lowerBound,
                              min(ScrollConfig.slowDelayRange.upperBound, ms))
        setScrollConfig(cfg)
    }
}

// MARK: - .drag waypoints

/// One step along a recorded drag path: a position plus the millisecond
/// offset since the drag started (mouseDown), so playback can reproduce
/// the user's actual pace — including pauses, accelerations, and the
/// overall duration. `tMs == -1` is a sentinel meaning "no timing was
/// recorded" (legacy 2-component waypoints from older saved actions);
/// the runner falls back to synthetic interpolation in that case.
struct DragWaypoint {
    let point: CGPoint
    let tMs: Int

    static let legacyTMs: Int = -1
}

extension AutoAction {
    /// Waypoints traversed during a drag, decoded from `action.text`. The
    /// drag starts at `action.point`, animates through every waypoint in
    /// order, and releases at the last one. Empty list ⇒ "no movement";
    /// the runner still presses + releases at the start point, behaving
    /// as a long-press.
    ///
    /// Format:
    /// - New (timed):  `"x,y,tMs;x,y,tMs;…"` — tMs = ms since drag start.
    /// - Legacy:       `"x,y;x,y;…"` — no timing; per-waypoint tMs is set
    ///   to `DragWaypoint.legacyTMs` and the runner falls back to its
    ///   synthetic bezier replay.
    var dragWaypointsTimed: [DragWaypoint] {
        let raw = (try? text.value()) ?? ""
        guard !raw.isEmpty else { return [] }
        return raw.split(separator: ";").compactMap { s -> DragWaypoint? in
            let parts = s.split(separator: ",")
            guard parts.count >= 2,
                  let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
            let t: Int
            if parts.count >= 3, let parsed = Int(parts[2]) {
                t = max(0, parsed)
            } else {
                t = DragWaypoint.legacyTMs
            }
            return DragWaypoint(point: CGPoint(x: x, y: y), tMs: t)
        }
    }

    /// Position-only view of the recorded path. Used by UI summaries and
    /// the legacy bezier playback path that doesn't care about timing.
    var dragWaypoints: [CGPoint] {
        dragWaypointsTimed.map { $0.point }
    }

    /// Persist a position-only path (no timing). Triggers legacy synthetic
    /// playback. Callers that have timing should use `setDragWaypointsTimed`.
    func setDragWaypoints(_ points: [CGPoint]) {
        let encoded = points.map { "\(Int($0.x)),\(Int($0.y))" }
            .joined(separator: ";")
        text.onNext(encoded)
    }

    /// Persist a timed path so playback can reproduce the user's pace.
    /// Each entry's `tMs` is the millisecond offset since drag start.
    func setDragWaypointsTimed(_ waypoints: [DragWaypoint]) {
        let encoded = waypoints.map {
            "\(Int($0.point.x)),\(Int($0.point.y)),\(max(0, $0.tMs))"
        }.joined(separator: ";")
        text.onNext(encoded)
    }
}

// MARK: - .nextScenario per-FlowMode targets

/// Per-FlowMode target + delay encoding stored in `action.text` for
/// `.nextScenario`.
///
/// New format: `|`-separated entries where each entry is one of
/// - `modeId=targetId`            — target only
/// - `modeId=targetId@delay`      — target + per-mode delay override
/// - `modeId@delay`               — delay override only (target falls
///                                  back to the default mode's entry)
///
/// `targetId` is either empty ("next in list") or a Scenario UUID.
/// `delay` is seconds, encoded as a base-10 double. Mode UUIDs and
/// scenario UUIDs never contain `@`, so the separator is unambiguous.
///
/// Legacy format (whole string has no `=` and no `@`): a single
/// scenario UUID — or empty — applying to every mode. Resolved at
/// runtime as the default mode's target so existing actions keep
/// working without migration; the first explicit write through
/// `setNextScenarioTarget` / `setNextScenarioDelay` preserves it as the
/// default mode's entry and then drops it.
struct NextScenarioPayload {
    /// modeId → targetId map. `""` means "next in list" for that mode.
    var targets: [String: String] = [:]
    /// modeId → delay-override (seconds) map. Absence means the mode
    /// inherits `action.delay`.
    var delays: [String: Double] = [:]
    /// Bare legacy value (text contained no `=`). `nil` once the explicit
    /// map is populated.
    var legacyTarget: String?

    static func parse(_ raw: String) -> NextScenarioPayload {
        var p = NextScenarioPayload()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return p }
        if !trimmed.contains("=") && !trimmed.contains("@") {
            p.legacyTarget = trimmed
            return p
        }
        for pair in trimmed.split(separator: "|", omittingEmptySubsequences: false) {
            let s = String(pair)
            if s.contains("=") {
                // target entry (optionally with @delay)
                let eqParts = s.split(separator: "=", maxSplits: 1,
                                      omittingEmptySubsequences: false)
                let modeId = String(eqParts[0])
                guard !modeId.isEmpty else { continue }
                let rhs = eqParts.count >= 2 ? String(eqParts[1]) : ""
                let atParts = rhs.split(separator: "@", maxSplits: 1,
                                        omittingEmptySubsequences: false)
                p.targets[modeId] = String(atParts[0])
                if atParts.count >= 2, let d = Double(atParts[1]) {
                    p.delays[modeId] = d
                }
            } else if s.contains("@") {
                // delay-only entry
                let atParts = s.split(separator: "@", maxSplits: 1,
                                      omittingEmptySubsequences: false)
                let modeId = String(atParts[0])
                guard !modeId.isEmpty, atParts.count >= 2 else { continue }
                if let d = Double(atParts[1]) {
                    p.delays[modeId] = d
                }
            }
        }
        return p
    }

    func encode() -> String {
        if !targets.isEmpty || !delays.isEmpty {
            // Stable key order so re-saving an unchanged action doesn't
            // churn the file.
            let keys = Set(targets.keys).union(delays.keys).sorted()
            return keys.compactMap { key -> String? in
                let hasTarget = targets[key] != nil
                let delaySuffix: String = {
                    guard let d = delays[key] else { return "" }
                    return "@\(String(format: "%g", d))"
                }()
                if hasTarget {
                    return "\(key)=\(targets[key] ?? "")\(delaySuffix)"
                }
                // delay-only entry
                return delaySuffix.isEmpty ? nil : "\(key)\(delaySuffix)"
            }.joined(separator: "|")
        }
        return legacyTarget ?? ""
    }
}

extension AutoAction {
    var nextScenarioPayload: NextScenarioPayload {
        NextScenarioPayload.parse((try? text.value()) ?? "")
    }

    /// Resolve the target scenario id for the running flow mode. Returns
    /// `""` meaning "next in list" when no specific target applies.
    /// Fallback chain: current-mode override → default-mode entry →
    /// legacy bare value → `""`.
    func nextScenarioTarget(forCurrentModeId currentModeId: String?,
                            defaultModeId: String?) -> String {
        let p = nextScenarioPayload
        if let id = currentModeId, let target = p.targets[id] {
            return target
        }
        if let id = defaultModeId, let target = p.targets[id] {
            return target
        }
        return p.legacyTarget ?? ""
    }

    /// Explicit per-mode target, or `nil` when no override is set (caller
    /// should treat as "use default").
    func nextScenarioExplicitTarget(forModeId modeId: String) -> String? {
        nextScenarioPayload.targets[modeId]
    }

    /// Set the target for a specific mode. Pass `nil` to remove the
    /// override so the mode falls back to the default. `defaultModeId`
    /// is used during legacy migration: the legacy bare value becomes
    /// the default mode's explicit entry before being dropped.
    func setNextScenarioTarget(_ target: String?,
                               forModeId modeId: String,
                               defaultModeId: String?) {
        var p = nextScenarioPayload
        // Preserve legacy by promoting it into the default mode's slot
        // before we start writing the explicit map — otherwise a non-
        // default-mode edit would silently lose the legacy fallback.
        if let legacy = p.legacyTarget, p.targets.isEmpty,
           let defId = defaultModeId, modeId != defId {
            p.targets[defId] = legacy
        }
        if let target = target {
            p.targets[modeId] = target
        } else {
            p.targets.removeValue(forKey: modeId)
        }
        if !p.targets.isEmpty || !p.delays.isEmpty { p.legacyTarget = nil }
        text.onNext(p.encode())
    }

    /// Resolve the delay (seconds) override for the running flow mode.
    /// Returns `nil` when no override applies — caller falls back to
    /// `action.delay`. Fallback chain matches `nextScenarioTarget`:
    /// current-mode override → default-mode entry → `nil`.
    func nextScenarioDelay(forCurrentModeId currentModeId: String?,
                           defaultModeId: String?) -> Double? {
        let p = nextScenarioPayload
        if let id = currentModeId, let d = p.delays[id] {
            return d
        }
        if let id = defaultModeId, let d = p.delays[id] {
            return d
        }
        return nil
    }

    /// Explicit per-mode delay override, or `nil` when not set (caller
    /// should treat as "use action.delay").
    func nextScenarioExplicitDelay(forModeId modeId: String) -> Double? {
        nextScenarioPayload.delays[modeId]
    }

    /// Set the delay override for a specific mode. Pass `nil` to remove
    /// the override so the mode inherits `action.delay`.
    func setNextScenarioDelay(_ delay: Double?,
                              forModeId modeId: String,
                              defaultModeId: String?) {
        var p = nextScenarioPayload
        // Same legacy promotion as setNextScenarioTarget: if there is a
        // legacy bare target and the explicit map is empty, write the
        // legacy as the default mode's target before we start mutating.
        if let legacy = p.legacyTarget, p.targets.isEmpty,
           let defId = defaultModeId, modeId != defId {
            p.targets[defId] = legacy
        }
        if let delay = delay {
            p.delays[modeId] = delay
        } else {
            p.delays.removeValue(forKey: modeId)
        }
        if !p.targets.isEmpty || !p.delays.isEmpty { p.legacyTarget = nil }
        text.onNext(p.encode())
    }
}

// MARK: - .ocrSwitch payload (triggers + interval + timeout)

/// One trigger row inside an `.ocrSwitch` action.
/// - `text`        — the target string Vision OCR should match against the
///                   captured area.
/// - `targetFlowId` — scenario UUID to switch to when this trigger fires.
///                    Empty ⇒ "No Movement" (the trigger matches but the
///                    runner moves on to the next action instead of
///                    branching). Currently unused at runtime since an
///                    empty target would mean the loop has nothing to do
///                    on match; kept for future flexibility.
/// - `flowModeId`  — when non-empty, the trigger only matches while the
///                   run's active FlowMode equals this id. Empty ⇒ '전체
///                   모드' (any mode). The default mode is the first entry
///                   in `FlowModeStore.shared.flowModes`.
struct OCRSwitchTrigger {
    var text: String = ""
    var targetFlowId: String = ""
    /// Empty string represents '전체 모드' (matches any running mode).
    var flowModeId: String = ""
}

/// `.ocrSwitch` packs three things into `action.text`:
/// - inter-scan interval (seconds, default 1.0),
/// - max wait timeout (seconds, default 30; the action gives up and
///   continues with the next action when nothing matches in time),
/// - an ordered list of triggers (text → target flow, optionally
///   restricted to one flow mode).
///
/// Encoded as `@key=value` header lines at the top followed by one
/// trigger per body line:
/// ```
/// @interval=1
/// @timeout=30
/// 구매||
/// 관리|scenario-uuid|
/// 결제|scenario-uuid|flowmode-uuid
/// ```
/// Trigger fields are pipe-separated; any field may be empty. Lines that
/// fail to parse (no pipes) are skipped so legacy malformed payloads don't
/// crash the action.
struct OCRSwitchPayload {
    static let defaultInterval: Double = 1.0
    static let intervalRange: ClosedRange<Double> = 0.1 ... 60.0
    /// Default timeout is 60 minutes (= 3600 seconds). Users typically
    /// want long waits for state-machine-style branching, so the default
    /// is much longer than a single OCR's 15s timeout.
    static let defaultTimeout: Double = 3600.0
    static let timeoutRange: ClosedRange<Double> = 1.0 ... 86400.0

    var interval: Double = defaultInterval
    var timeout: Double = defaultTimeout
    /// UI-state only: whether the interval field renders/parses in minutes.
    /// The stored `interval` value is always in seconds.
    var intervalIsMinutes: Bool = false
    /// UI-state only: whether the timeout field renders/parses in minutes.
    /// The stored `timeout` value is always in seconds. Default is `true`
    /// to match the long (60-minute) default timeout — showing 3600 in
    /// 초 would be more confusing than 60 in 분.
    var timeoutIsMinutes: Bool = true
    var triggers: [OCRSwitchTrigger] = []

    static func parse(_ raw: String) -> OCRSwitchPayload {
        var p = OCRSwitchPayload()
        let lines = raw.components(separatedBy: "\n")
        var bodyStart = lines.count
        headerLoop: for (i, line) in lines.enumerated() {
            guard line.hasPrefix("@"),
                  let eq = line.firstIndex(of: "="),
                  eq > line.startIndex else {
                bodyStart = i
                break headerLoop
            }
            let key = String(line[line.index(after: line.startIndex) ..< eq])
            let value = String(line[line.index(after: eq)...])
            switch key {
            case "interval":
                if let n = Double(value) {
                    p.interval = max(intervalRange.lowerBound,
                                     min(intervalRange.upperBound, n))
                }
            case "timeout":
                if let n = Double(value) {
                    p.timeout = max(timeoutRange.lowerBound,
                                    min(timeoutRange.upperBound, n))
                }
            case "intervalUnit":
                p.intervalIsMinutes = (value == "min")
            case "timeoutUnit":
                p.timeoutIsMinutes = (value == "min")
            default:
                // Unknown header — keep this line as part of the body so
                // users don't silently lose content.
                bodyStart = i
                break headerLoop
            }
            bodyStart = i + 1
        }
        for line in lines.dropFirst(bodyStart) {
            if line.isEmpty { continue }
            // Self-heal: an earlier buggy build wrote `@interval=…` /
            // `@timeout=…` as triggers when their bodyStart calculation
            // was off-by-one. Re-interpret any header-shaped line we see
            // in the body as a header so the action recovers cleanly on
            // the next save.
            if line.hasPrefix("@"),
               let eq = line.firstIndex(of: "="),
               eq > line.startIndex {
                let key = String(line[line.index(after: line.startIndex) ..< eq])
                let after = String(line[line.index(after: eq)...])
                let value = String(after.prefix(while: { $0 != "|" }))
                if key == "interval", let n = Double(value) {
                    p.interval = max(intervalRange.lowerBound,
                                     min(intervalRange.upperBound, n))
                    continue
                }
                if key == "timeout", let n = Double(value) {
                    p.timeout = max(timeoutRange.lowerBound,
                                    min(timeoutRange.upperBound, n))
                    continue
                }
            }
            // Three pipe-separated fields. Use omittingEmptySubsequences:false
            // so trailing empty fields (no flowMode → "...||") survive.
            let parts = line.split(separator: "|",
                                   maxSplits: 2,
                                   omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count >= 1 else { continue }
            var t = OCRSwitchTrigger()
            t.text = parts[0]
            if parts.count >= 2 { t.targetFlowId = parts[1] }
            if parts.count >= 3 { t.flowModeId = parts[2] }
            p.triggers.append(t)
        }
        return p
    }

    func encode() -> String {
        var lines: [String] = []
        lines.append("@interval=\(formatNumber(interval))")
        lines.append("@timeout=\(formatNumber(timeout))")
        // Always emit unit headers so parsing stays unambiguous even
        // when per-field defaults change (e.g. timeout default is 분).
        lines.append("@intervalUnit=\(intervalIsMinutes ? "min" : "sec")")
        lines.append("@timeoutUnit=\(timeoutIsMinutes ? "min" : "sec")")
        for t in triggers {
            // Sanitize embedded pipes/newlines so the line stays parseable.
            let text = sanitize(t.text)
            lines.append("\(text)|\(t.targetFlowId)|\(t.flowModeId)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatNumber(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(v))
        }
        return String(format: "%g", v)
    }

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
         .replacingOccurrences(of: "|", with: " ")
    }
}

extension AutoAction {
    var ocrSwitchPayload: OCRSwitchPayload {
        OCRSwitchPayload.parse((try? text.value()) ?? "")
    }

    var ocrSwitchInterval: Double { ocrSwitchPayload.interval }
    var ocrSwitchTimeout: Double { ocrSwitchPayload.timeout }
    var ocrSwitchIntervalIsMinutes: Bool { ocrSwitchPayload.intervalIsMinutes }
    var ocrSwitchTimeoutIsMinutes: Bool { ocrSwitchPayload.timeoutIsMinutes }
    var ocrSwitchTriggers: [OCRSwitchTrigger] { ocrSwitchPayload.triggers }

    func setOCRSwitchInterval(_ seconds: Double) {
        var p = ocrSwitchPayload
        p.interval = max(OCRSwitchPayload.intervalRange.lowerBound,
                         min(OCRSwitchPayload.intervalRange.upperBound, seconds))
        text.onNext(p.encode())
    }

    func setOCRSwitchTimeout(_ seconds: Double) {
        var p = ocrSwitchPayload
        p.timeout = max(OCRSwitchPayload.timeoutRange.lowerBound,
                        min(OCRSwitchPayload.timeoutRange.upperBound, seconds))
        text.onNext(p.encode())
    }

    func setOCRSwitchIntervalIsMinutes(_ isMinutes: Bool) {
        var p = ocrSwitchPayload
        p.intervalIsMinutes = isMinutes
        text.onNext(p.encode())
    }

    func setOCRSwitchTimeoutIsMinutes(_ isMinutes: Bool) {
        var p = ocrSwitchPayload
        p.timeoutIsMinutes = isMinutes
        text.onNext(p.encode())
    }

    func setOCRSwitchTriggers(_ triggers: [OCRSwitchTrigger]) {
        var p = ocrSwitchPayload
        p.triggers = triggers
        text.onNext(p.encode())
    }

    /// Mutate a single trigger field in place. Pads the list if `index`
    /// points past the end so callers can blindly write to a row they
    /// just rendered without first growing the array.
    func updateOCRSwitchTrigger(at index: Int,
                                _ mutate: (inout OCRSwitchTrigger) -> Void) {
        var triggers = ocrSwitchTriggers
        while triggers.count <= index {
            triggers.append(OCRSwitchTrigger())
        }
        mutate(&triggers[index])
        setOCRSwitchTriggers(triggers)
    }

    func appendOCRSwitchTrigger(_ trigger: OCRSwitchTrigger = OCRSwitchTrigger()) {
        var triggers = ocrSwitchTriggers
        triggers.append(trigger)
        setOCRSwitchTriggers(triggers)
    }

    func removeOCRSwitchTrigger(at index: Int) {
        var triggers = ocrSwitchTriggers
        guard triggers.indices.contains(index) else { return }
        triggers.remove(at: index)
        setOCRSwitchTriggers(triggers)
    }

    /// Mode switch helper for the unified 글자인식 action: convert this
    /// action from `.ocrSwitch` to `.ocr`. Preserves the first trigger's
    /// text as the new search text so the user doesn't have to retype.
    /// Empty trigger list ⇒ blank search text. Caller must mutate
    /// `action.type` after calling this (the type is not a BehaviorSubject
    /// so we leave it to the caller to fire whatever UI refresh they need).
    func convertToOCRClickMode() {
        let firstText = ocrSwitchTriggers.first?.text ?? ""
        type = .ocr
        text.onNext(firstText)
    }

    /// Mode switch helper for the unified 글자인식 action: convert this
    /// action from `.ocr` to `.ocrSwitch`. Promotes the current search
    /// text into a single trigger so the user can immediately attach a
    /// target flow. Empty search text ⇒ one empty trigger row (the
    /// detail pane's auto-seed would have added one anyway).
    func convertToOCRSwitchMode() {
        let current = (try? text.value()) ?? ""
        var p = OCRSwitchPayload()
        var trigger = OCRSwitchTrigger()
        trigger.text = current
        p.triggers.append(trigger)
        type = .ocrSwitch
        text.onNext(p.encode())
    }
}
