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

    /// Send the captured region + instruction to the server. Coordinates
    /// in the response are in the image's local pixel space (top-left
    /// origin); callers translate to screen-space by adding the capture
    /// region's origin before running the actions.
    ///
    /// - Parameters:
    ///   - scenarios: Flows the AI may branch to. Empty disables branching.
    ///   - currentScenarioId: UUID of the flow `.aiGen` is running inside.
    ///     The AI is told not to branch to itself.
    func generate(image: NSImage,
                  instruction: String,
                  defaultDelay: Double,
                  scenarios: [ScenarioInfo] = [],
                  currentScenarioId: String? = nil) async throws -> [GeneratedActionJSON] {
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
        if !scenarios.isEmpty {
            body["scenarios"] = scenarios.map { ["id": $0.id, "name": $0.name] }
        }
        if let cur = currentScenarioId, !cur.isEmpty {
            body["current_scenario_id"] = cur
        }

        let response = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            session.request(url,
                            method: .post,
                            parameters: body,
                            encoding: JSONEncoding.default,
                            headers: ["Content-Type": "application/json"])
                .validate()
                .responseData { resp in
                    switch resp.result {
                    case .success(let data):
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
        if let conf = response["confidence"] as? Double {
            AppLogger.shared.log("🤖 액션 생성 \(rawActions.count)개 (confidence=\(String(format: "%.2f", conf)))")
        }
        if let reason = response["reasoning"] as? String, !reason.isEmpty {
            AppLogger.shared.log("🤖 \(reason)")
        }
        return rawActions
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
