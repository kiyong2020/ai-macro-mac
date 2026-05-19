//
//  ActionGenService.swift
//  AIMacro
//
//  HTTP client for ai-macro-api's `/generate-actions` endpoint. Sends a
//  base64-encoded PNG of a captured screen region plus a natural-language
//  instruction; receives a list of macOS AutoActions to run in-place.
//
//  The returned actions are consumed once by `.aiGen` execution and are
//  NOT persisted into the scenario list.
//

import AppKit
import Alamofire

final class ActionGenService {
    static let shared = ActionGenService()

    private let session: Session

    private init() {
        let cfg = URLSessionConfiguration.default
        // Claude calls can take several seconds; raise the per-request
        // timeout well above the AF default (60s) so a slow generation
        // doesn't abort the in-progress run.
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 120
        self.session = Session(configuration: cfg)
    }

    /// One generated action, in `AutoAction.toFullJSON()` shape. The
    /// raw dictionary is fed straight to `AutoAction.fromFullJSON(_:)`.
    typealias GeneratedActionJSON = [String: Any]

    /// One turn of the `.aiGen` loop: a batch of actions plus the model's
    /// signal of whether the user goal has been fully achieved. The runner
    /// keeps calling `/generate-actions` (with a fresh screenshot each
    /// turn) until `finish` is true.
    ///
    /// `toolUseInput` is the raw `generate_actions` payload the model
    /// emitted this turn. Opaque from the client's perspective — the
    /// runner stores it and replays it as `conversation_history` on the
    /// next call so Claude sees its own prior decisions. `nil` when the
    /// server didn't include it (older API revision or empty plan).
    struct GenerateResult {
        let actions: [GeneratedActionJSON]
        let finish: Bool
        let toolUseInput: [String: Any]?
    }

    struct GenerateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Minimal scenario info the AI needs to branch via `nextScenario`.
    /// Pass an empty array to disable branching.
    struct ScenarioInfo {
        let id: String
        let name: String
    }

    /// Action kinds the server may emit for one `.aiGen` call. Raw values
    /// are the wire-format strings the API expects in the `allowed_kinds`
    /// request field — keep them in lockstep with `GeneratedKind` on the
    /// server (`ai-macro-api/src/claude/claude.service.ts`).
    /// Granular action options the user can toggle in the `.aiGen`
    /// editor. Scroll and drag are split per-direction so the user can,
    /// for example, allow drag-down only while forbidding drag-up.
    ///
    /// Wire values are sent in `allowed_kinds`. The server splits them
    /// into base kinds (for the `kind` JSON-schema enum), scroll
    /// directions (constrained via the `direction` enum), and drag
    /// directions (communicated via the system prompt — drag direction
    /// is implicit in the waypoints, so it's a prompt-level rule).
    enum AllowedKind: String, CaseIterable {
        case click
        case key
        case scrollUp    = "scroll:up"
        case scrollDown  = "scroll:down"
        case dragUp      = "drag:up"
        case dragDown    = "drag:down"
        case dragLeft    = "drag:left"
        case dragRight   = "drag:right"
        case wait
        /// Branch to another flow. Wire value matches the server's
        /// `nextScenario` kind. Only honoured when the request also
        /// includes a non-empty `scenarios` list.
        case flowMove    = "nextScenario"

        /// User-facing Korean label shown in the action editor.
        var displayName: String {
            switch self {
            case .click:      return "클릭"
            case .key:        return "키 입력"
            case .scrollUp:   return "스크롤 위"
            case .scrollDown: return "스크롤 아래"
            case .dragUp:     return "드래그 위"
            case .dragDown:   return "드래그 아래"
            case .dragLeft:   return "드래그 왼쪽"
            case .dragRight:  return "드래그 오른쪽"
            case .wait:       return "시간 대기"
            case .flowMove:   return "플로우 이동"
            }
        }

        /// Effective default applied to any `.aiGen` action that hasn't
        /// been explicitly customised. Intentionally conservative — the
        /// model is restricted to clicks only until the user opts into
        /// more powerful kinds.
        static let defaults: Set<AllowedKind> = [.click]
    }

    /// Send the captured region + instruction to the server. Coordinates
    /// in the response are in the image's local pixel space (top-left
    /// origin); callers translate to screen-space by adding the capture
    /// region's origin before running the actions.
    ///
    /// - Parameters:
    ///   - endCondition: User-provided text describing when the loop
    ///     should stop. Empty string ⇒ caller is in one-shot mode (the
    ///     server's `finish` flag is informational only); non-empty ⇒
    ///     the server should set `finish: true` once the condition is
    ///     visibly satisfied in the screenshot.
    ///   - scenarios: Flows the AI may branch to. Empty disables branching.
    ///   - currentScenarioId: UUID of the flow `.aiGen` is running inside.
    ///     The AI is told not to branch to itself.
    ///   - allowedKinds: Restrict the server to emit only these action
    ///     kinds. `nil` ⇒ no client-side restriction (server uses its
    ///     defaults). Empty Set ⇒ explicitly forbid every kind (the
    ///     server will return an empty action list).
    ///   - conversationHistory: Prior turns of the same `.aiGen` loop,
    ///     oldest first. Each entry is the `toolUseInput` from a previous
    ///     `generate(...)` response. The server replays them as Claude
    ///     conversation history so the model sees its own past
    ///     decisions. Pass an empty array on the first iteration. Server
    ///     caps history at 8 entries — callers should pre-trim to ~3–5
    ///     to keep request payloads small.
    func generate(image: NSImage,
                  instruction: String,
                  endCondition: String = "",
                  defaultDelay: Double,
                  scenarios: [ScenarioInfo] = [],
                  currentScenarioId: String? = nil,
                  allowedKinds: Set<AllowedKind>? = nil,
                  conversationHistory: [[String: Any]] = []) async throws -> GenerateResult {
        guard let pngData = pngData(from: image) else {
            throw GenerateError(message: "이미지 인코딩 실패")
        }
        let base64 = pngData.base64EncodedString()
        let size = image.pixelSize ?? image.size
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else {
            throw GenerateError(message: "캡처 이미지 크기가 0")
        }

        let url = Constants.baseServerURL.trimmingCharacters(in: .init(charactersIn: "/")) + "/generate-actions"
        var body: [String: Any] = [
            "image": base64,
            "image_wh": [width, height],
            "instruction": instruction,
            "default_delay": defaultDelay,
        ]
        let trimmedEnd = endCondition.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEnd.isEmpty {
            body["end_condition"] = trimmedEnd
        }
        if !scenarios.isEmpty {
            body["scenarios"] = scenarios.map { ["id": $0.id, "name": $0.name] }
        }
        if let cur = currentScenarioId, !cur.isEmpty {
            body["current_scenario_id"] = cur
        }
        if let allowedKinds = allowedKinds {
            // Stable order so request bodies are diffable in logs.
            body["allowed_kinds"] = AllowedKind.allCases
                .filter { allowedKinds.contains($0) }
                .map { $0.rawValue }
        }
        if !conversationHistory.isEmpty {
            body["conversation_history"] = conversationHistory.map { ["tool_use_input": $0] }
        }

        logRequest(url: url, body: body, base64Size: pngData.count)

        let response = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            session.request(url,
                            method: .post,
                            parameters: body,
                            encoding: JSONEncoding.default,
                            headers: ["Content-Type": "application/json"])
                .validate()
                .responseData { [weak self] resp in
                    switch resp.result {
                    case .success(let data):
                        self?.logResponseRaw(data: data, statusCode: resp.response?.statusCode)
                        do {
                            let json = try JSONSerialization.jsonObject(with: data)
                            guard let dict = json as? [String: Any] else {
                                cont.resume(throwing: GenerateError(message: "서버 응답 형식 오류"))
                                return
                            }
                            cont.resume(returning: dict)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    case .failure(let err):
                        self?.logResponseFailure(error: err,
                                                 data: resp.data,
                                                 statusCode: resp.response?.statusCode)
                        let detail: String
                        if let data = resp.data, let s = String(data: data, encoding: .utf8), !s.isEmpty {
                            detail = "\(err.localizedDescription) — \(s)"
                        } else {
                            detail = err.localizedDescription
                        }
                        cont.resume(throwing: GenerateError(message: detail))
                    }
                }
        }

        guard let rawActions = response["actions"] as? [[String: Any]] else {
            throw GenerateError(message: "응답에 actions 필드 없음")
        }
        let finish = (response["finish"] as? Bool) ?? false
        let toolUseInput = response["tool_use_input"] as? [String: Any]
        if let conf = response["confidence"] as? Double {
            AppLogger.shared.log("🤖 액션 생성 \(rawActions.count)개 (confidence=\(String(format: "%.2f", conf))\(finish ? ", finish" : ""))")
        }
        if let reason = response["reasoning"] as? String, !reason.isEmpty {
            AppLogger.shared.log("🤖 \(reason)")
        }
        return GenerateResult(actions: rawActions, finish: finish, toolUseInput: toolUseInput)
    }

    // MARK: - Verbose request/response logging
    //
    // The on-screen log view (AppLogger) only shows the brief status lines
    // emitted by AutomationRunner / generate(). Full request/response bodies
    // go to `print` so they land in the Xcode console (Console.app via
    // ASL/OSLog when running outside a debug session) without flooding the
    // UI. The base64 image is redacted to its byte size — keeping it in
    // the log would push ~1–4 MB of text per call.

    private func logRequest(url: String, body: [String: Any], base64Size: Int) {
        var redacted = body
        redacted["image"] = "<png \(base64Size) bytes (base64)>"
        let pretty = prettyJSON(redacted) ?? String(describing: redacted)
        print("[ActionGen] → POST \(url)\n\(pretty)")
    }

    private func logResponseRaw(data: Data, statusCode: Int?) {
        let status = statusCode.map { String($0) } ?? "?"
        if let s = String(data: data, encoding: .utf8) {
            let pretty = (try? JSONSerialization.jsonObject(with: data))
                .flatMap { prettyJSON($0) } ?? s
            print("[ActionGen] ← \(status) (\(data.count) bytes)\n\(pretty)")
        } else {
            print("[ActionGen] ← \(status) (\(data.count) bytes, non-UTF8)")
        }
    }

    private func logResponseFailure(error: Error, data: Data?, statusCode: Int?) {
        let status = statusCode.map { String($0) } ?? "?"
        var msg = "[ActionGen] ← FAILED status=\(status) error=\(error.localizedDescription)"
        if let data = data, let s = String(data: data, encoding: .utf8), !s.isEmpty {
            msg += "\n\(s)"
        }
        print(msg)
    }

    private func prettyJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private extension NSImage {
    /// Actual pixel dimensions of the underlying bitmap rep. `size` is in
    /// points and can differ on Retina displays.
    var pixelSize: CGSize? {
        guard let rep = representations.first as? NSBitmapImageRep else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}
