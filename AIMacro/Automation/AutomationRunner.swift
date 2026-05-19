//
//  AutomationRunner.swift
//  AIMacro
//
//  Owns the per-action execution logic and the resources used during a run
//  (mouse listener, keyboard listener, screen capturer). The view controller
//  drives this class via run(_:) / stop() / signalWaitDone().
//

import Cocoa
import IOKit.pwr_mgt
import RxSwift

final class AutomationRunner {
    let mouseListener: MouseListener
    let keyboardListener: GlobalKeyListener
    let screenCapturer = ScreenCapturer()

    /// IOPMAssertion ID held while a run is in flight to keep the display
    /// awake. Without this, a long `wait(.time)` lets the display idle-sleep
    /// and the next OCR action sees only black frames (Vision returns no
    /// text, the action times out with an empty scan).
    private var displaySleepAssertion: IOPMAssertionID = 0

    // MARK: - Public state for the UI

    /// Index of the currently-running action, or nil when idle.
    /// Emits before each action begins; emits nil when the run completes.
    let currentIndex = BehaviorSubject<Int?>(value: nil)

    /// Total number of actions in the current run (or 0 when idle).
    let totalCount = BehaviorSubject<Int>(value: 0)

    /// Name of the action currently executing.
    let currentName = BehaviorSubject<String>(value: "")

    /// Last error message, set when an action fails. UI uses this for a status banner.
    let lastError = BehaviorSubject<String?>(value: nil)

    /// Flag used to break out of in-action wait loops (.wait(.enter)).
    /// Settable externally via `signalWaitDone()` so the view controller can flip it
    /// from its keyboard subscription on the Enter key.
    private var waitDone = false

    /// Populated when a `.nextScenario` action with a specific target
    /// runs. The run loop checks it after each action and breaks early;
    /// the view controller reads this property when `run(_:)` returns to
    /// decide which scenario to move to. An empty target means "이동
    /// 안함" — the runner leaves this nil and continues with subsequent
    /// actions.
    private(set) var nextScenarioRequest: NextScenarioRequest?

    /// UUID of the scenario whose actions are currently being executed.
    /// Set by the view controller before each call to `run(_:)` so the
    /// `.aiGen` handler can tell the server which flow it's inside (and
    /// the server can keep the AI from branching to itself).
    var currentScenarioId: String?

    /// Display name of the scenario currently being executed. Set by the
    /// view controller before each `run(_:)` so the runner can emit
    /// 시작/종료 markers in the on-screen log.
    var currentScenarioName: String?

    /// UUID of the FlowMode active for this run. Used by `.nextScenario`
    /// to pick a per-mode target — unset / unknown values fall back to
    /// the default (first) FlowMode's target, then to the legacy value,
    /// then to "이동 안함". Set by the view controller before each call
    /// to `run(_:)`.
    var currentFlowModeId: String?

    enum NextScenarioRequest {
        case specific(id: String)
    }

    init(mouseListener: MouseListener, keyboardListener: GlobalKeyListener) {
        self.mouseListener = mouseListener
        self.keyboardListener = keyboardListener
    }

    /// External signal — typically called from the keyboard subscription on Enter.
    func signalWaitDone() { waitDone = true }

    /// Stop screen capture and any active input listeners. Called when the user
    /// clicks Stop — must clean up everything `runOCR` / `waitFor*` would have
    /// torn down on a normal exit, since their cleanup is skipped when their
    /// awaiting `Task.sleep` throws `CancellationError`.
    func stop() {
        screenCapturer.stop()
        mouseListener.stop()
        keyboardListener.stop()
        OCRDebugWindow.shared.hide()
        releaseDisplaySleepAssertion()
    }

    private func acquireDisplaySleepAssertion() {
        guard displaySleepAssertion == 0 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Macroony automation in progress" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            displaySleepAssertion = id
        } else {
            AppLogger.shared.log("⚠️ 디스플레이 절전 방지 실패 (err=\(result))")
        }
    }

    private func releaseDisplaySleepAssertion() {
        guard displaySleepAssertion != 0 else { return }
        IOPMAssertionRelease(displaySleepAssertion)
        displaySleepAssertion = 0
    }

    /// Run the full action list sequentially. Per-action errors are surfaced via
    /// `lastError` but don't abort the sequence — matches the previous behaviour.
    func run(_ actions: [AutoAction]) async throws {
        // Gate the bottom on-screen log to this run only. defer ensures the
        // session ends on early return / cancellation / thrown error so idle
        // logs stay console-only.
        AppLogger.shared.startSession()
        let trimmedName = (currentScenarioName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scenarioLabel = trimmedName.isEmpty ? "플로우" : trimmedName
        AppLogger.shared.log("▶️ 시작: \(scenarioLabel)")
        defer {
            AppLogger.shared.log("⏹ 종료: \(scenarioLabel)")
            AppLogger.shared.endSession()
        }

        // Hold a display-sleep assertion for the full run. wait(.time) can
        // sleep for hours; without this the screen idles off and the next
        // OCR action gets black frames from SCStream.
        acquireDisplaySleepAssertion()
        defer { releaseDisplaySleepAssertion() }

        // Broadcast first so any listener (KeyUtil cache, etc.) can wipe stale
        // per-run state before the first action fires.
        NotificationCenter.default.post(name: .actionSequenceWillStart, object: self)

        // Keep the global key tap active for the entire run so the user can
        // press ESC to abort at any time (handled in ViewController). The
        // initial stop() clears any stale tap before we re-arm.
        keyboardListener.stop()
        keyboardListener.start()
        defer { keyboardListener.stop() }
        totalCount.onNext(actions.count)
        lastError.onNext(nil)
        nextScenarioRequest = nil
        try await Task.sleep(for: .milliseconds(100))

        for (i, action) in actions.enumerated() {
            currentIndex.onNext(i)
            currentName.onNext(action.name)
            if (try? action.disabled.value()) == true {
                AppLogger.shared.log("⏭ 건너뜀(비활성): \(action.name)")
                continue
            }
            do {
                try await run(action)
            } catch {
                let msg = "\(action.name) 실패: \(error.localizedDescription)"
                AppLogger.shared.log("⚠️ \(msg)")
                lastError.onNext(msg)
            }
            // Short-circuit: a `.nextScenario` action just ran and asked the
            // view controller to move on. Don't execute remaining actions.
            if nextScenarioRequest != nil { break }
        }

        currentIndex.onNext(nil)
        currentName.onNext("")
        totalCount.onNext(0)
    }

    private func run(_ action: AutoAction) async throws {
        AppLogger.shared.log("→ \(action.name)")
        // Delay is now applied BEFORE the action runs (was AFTER previously).
        // Each action.delay represents the wait time *leading up to* the
        // action's execution.
        //
        // `.nextScenario` uses its own per-FlowMode delay map (current-
        // mode override → default-mode entry → 0). The action's common
        // `delay` is intentionally ignored here so the UI can hide it
        // for this action type.
        let baseSeconds: Double = {
            if case .nextScenario = action.type {
                let defId = FlowModeStore.shared.flowModes.first?.id.uuidString
                return action.nextScenarioDelay(
                    forCurrentModeId: currentFlowModeId,
                    defaultModeId: defId) ?? 0
            }
            return (try? action.delay.value()) ?? 0
        }()
        let baseMs = Int(baseSeconds * 1000)
        // Optional human-like jitter on top of the configured delay.
        let maxExtra = max(0, Preferences.maxRandomDelay)
        let extraMs = maxExtra > 0 ? Int(Double.random(in: 0...maxExtra) * 1000) : 0
        let totalMs = baseMs + extraMs
        if totalMs > 0 {
            try await Task.sleep(for: .milliseconds(totalMs))
        }
        switch action.type {
        case .click:                   try await runClick(action)
        case .scroll:                  try await runScroll(action)
        case .key:                     try await runKey(action)
        case .wait(let type):          try await runWait(action, type: type)
        case .ocr:                     try await runOCR(action)
        case .script(let code):        try await runScript(action, code: code)
        case .setURL(let url):         setChromeURL(effectiveURL(action, default: url))
        case .openChrome(let url):     openNewChromeWindow(effectiveURL(action, default: url))
        case .openBrowser(let url):    try await runOpenBrowser(action, default: url)
        case .drag:                    try await runDrag(action)
        case .windowFrame:             try await runWindowFrame(action)
        case .nextScenario:            runNextScenario(action)
        case .aiGen:                   try await runAIGen(action)
        }
    }

    /// Hard cap on the number of `/generate-actions` round-trips a single
    /// `.aiGen` action will make. Each round-trip is one Claude call plus
    /// a screenshot, so 20 turns is a meaningful upper bound on a single
    /// goal — if the model hasn't said `finish` by then the user
    /// instruction is probably not achievable from the configured region.
    private static let aiGenMaxIterations = 20

    /// `.aiGen`: loop {capture → POST /generate-actions → execute returned
    /// actions} until the server says `finish: true` (or the safety cap
    /// fires). Coordinates from the server are image-local (top-left
    /// origin); we translate them to Quartz screen-space by adding the
    /// capture region's origin before running each action. Generated
    /// actions are consumed each turn and are NOT written back to the
    /// scenario.
    private func runAIGen(_ action: AutoAction) async throws {
        let instruction = action.aiGenInstruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            AppLogger.shared.log("⚠️ AI 액션 — 지시문이 비어있음")
            return
        }
        let center = (try? action.point.value()) ?? .zero
        let size = action.ocrScanSize
        guard size.width > 0, size.height > 0 else {
            AppLogger.shared.log("⚠️ AI 액션 — 캡처 영역 크기 미설정")
            return
        }
        // Quartz coords (Y-down). action.point is the center; convert to
        // a top-left-origin rect for the SC screenshot.
        let captureRect = CGRect(x: center.x - size.width / 2,
                                 y: center.y - size.height / 2,
                                 width: size.width,
                                 height: size.height)

        // The default delay seeded into each generated action. The
        // existing `Preferences.defaultActionDelay` is the closest
        // user-tuned baseline; fall back to 0.1s.
        let baseDelay = max(0.05, Preferences.defaultActionDelay)

        // Branch options: every scenario in the store. The server filters
        // out the current one (we also tag it via `currentScenarioId`).
        let scenarios = ScenarioStore.shared.scenarios.map {
            ActionGenService.ScenarioInfo(id: $0.id.uuidString, name: $0.name)
        }

        let intervalMs = max(0, Int((action.aiGenInterval * 1000.0).rounded()))
        let endCondition = action.aiGenEndCondition
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty end condition ⇒ single-call mode: capture once, execute the
        // returned batch, then stop. The model's `finish` flag is irrelevant
        // in this mode.
        let maxIterations = endCondition.isEmpty ? 1 : Self.aiGenMaxIterations

        if endCondition.isEmpty {
            AppLogger.shared.log("🤖 AI 액션 시작 (지시문: \(instruction.prefix(40))…, 1회 호출)")
        } else {
            AppLogger.shared.log("🤖 AI 액션 시작 (지시문: \(instruction.prefix(40))…, 간격: \(String(format: "%g", action.aiGenInterval))s, 종료조건: \(endCondition.prefix(40)))")
        }

        for iteration in 1 ... maxIterations {
            // Capture a fresh screenshot for each turn — the whole point
            // of the loop is that the model sees the result of the prior
            // turn's actions before deciding what to do next.
            guard let cg = await ScreenCapturer.captureOnce(captureRect) else {
                AppLogger.shared.log("⚠️ AI 액션 — 화면 캡처 실패")
                return
            }
            let img = NSImage(cgImage: cg,
                              size: NSSize(width: cg.width, height: cg.height))

            if endCondition.isEmpty {
                AppLogger.shared.log("🤖 AI 호출 중…")
            } else {
                AppLogger.shared.log("🤖 AI 턴 \(iteration)/\(maxIterations) 호출 중…")
            }

            let result: ActionGenService.GenerateResult
            do {
                result = try await ActionGenService.shared.generate(
                    image: img,
                    instruction: instruction,
                    endCondition: endCondition,
                    defaultDelay: baseDelay,
                    scenarios: scenarios,
                    currentScenarioId: currentScenarioId,
                    allowedKinds: action.aiGenAllowedKinds ?? ActionGenService.AllowedKind.defaults
                )
            } catch {
                AppLogger.shared.log("⚠️ AI 액션 — 서버 호출 실패: \(error.localizedDescription)")
                throw error
            }

            try await executeGeneratedBatch(result.actions, captureRect: captureRect, cg: cg)

            if nextScenarioRequest != nil {
                AppLogger.shared.log("🤖 AI 액션 — 플로우 전환 요청 감지, 루프 종료")
                return
            }
            // One-shot mode: maxIterations == 1, so we always stop here.
            if endCondition.isEmpty {
                AppLogger.shared.log("🤖 AI 액션 완료 (1회 실행)")
                return
            }
            if result.finish {
                AppLogger.shared.log("🤖 AI 액션 완료 (종료 조건 충족)")
                return
            }
            if iteration == maxIterations {
                AppLogger.shared.log("⚠️ AI 액션 — 최대 반복 횟수(\(maxIterations))에 도달, 종료")
                return
            }
            if intervalMs > 0 {
                try await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
    }

    /// Decode one batch of generated actions, translate their coordinates
    /// from image-local pixels to Quartz screen space, and run them in
    /// order. Each action's failure is logged but does not abort the
    /// batch (matching the outer scenario run loop). A generated
    /// `.nextScenario` short-circuits the rest of the batch.
    private func executeGeneratedBatch(_ rawActions: [[String: Any]],
                                       captureRect: CGRect,
                                       cg: CGImage) async throws {
        guard !rawActions.isEmpty else { return }

        // Coordinate translation: server returns image-local pixels with
        // the image's pixelSize matching what we sent (the CGImage). Use
        // the actual CG pixel dimensions vs. our requested rect to derive
        // the per-axis scale (handles Retina backing transparently).
        let pixelW = Double(cg.width)
        let pixelH = Double(cg.height)
        let scaleX = pixelW > 0 ? Double(captureRect.width) / pixelW : 1
        let scaleY = pixelH > 0 ? Double(captureRect.height) / pixelH : 1
        let originX = Double(captureRect.minX)
        let originY = Double(captureRect.minY)

        var generated: [AutoAction] = []
        for raw in rawActions {
            guard let sub = AutoAction.fromFullJSON(raw) else {
                AppLogger.shared.log("⚠️ AI 액션 — 디코딩 실패한 항목 건너뜀")
                continue
            }
            switch sub.type {
            case .key, .scroll:
                break
            default:
                let p = (try? sub.point.value()) ?? .zero
                let translated = CGPoint(
                    x: originX + Double(p.x) * scaleX,
                    y: originY + Double(p.y) * scaleY
                )
                sub.point.onNext(translated)
                if case .drag = sub.type {
                    let waypoints = sub.dragWaypointsTimed.map { wp in
                        DragWaypoint(
                            point: CGPoint(
                                x: originX + Double(wp.point.x) * scaleX,
                                y: originY + Double(wp.point.y) * scaleY
                            ),
                            tMs: wp.tMs
                        )
                    }
                    sub.setDragWaypointsTimed(waypoints)
                }
            }
            generated.append(sub)
        }

        AppLogger.shared.log("🤖 AI 액션 \(generated.count)개 실행")
        for (i, gen) in generated.enumerated() {
            AppLogger.shared.log("   [\(i + 1)/\(generated.count)] \(gen.name)")
            do {
                try await run(gen)
            } catch {
                AppLogger.shared.log("⚠️ AI 생성 액션 '\(gen.name)' 실패: \(error.localizedDescription)")
            }
            if nextScenarioRequest != nil {
                AppLogger.shared.log("🤖 AI 액션 — 플로우 전환 요청 감지, 남은 단계 중단")
                break
            }
        }
    }

    // MARK: - Per-action handlers

    private func runClick(_ action: AutoAction) async throws {
        let count = try! action.count.value()
        let point = try! action.point.value()
        let cfg = action.clickConfig
        for i in 0 ..< count {
            switch cfg.button {
            case .left:  await click(at: point, modifiers: cfg.modifiers)
            case .right: await rightClick(at: point, modifiers: cfg.modifiers)
            }
            if i < count - 1 {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Populates `nextScenarioRequest` so the run loop short-circuits and
    /// the view controller routes the run to the right scenario. The
    /// target is resolved per-FlowMode via `NextScenarioPayload` — empty
    /// means "이동 안함" (no-op: leave `nextScenarioRequest` nil so the
    /// run loop continues with subsequent actions), any non-empty value
    /// is a scenario UUID.
    private func runNextScenario(_ action: AutoAction) {
        let defaultModeId = FlowModeStore.shared.flowModes.first?.id.uuidString
        let raw = action
            .nextScenarioTarget(forCurrentModeId: currentFlowModeId,
                                defaultModeId: defaultModeId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            AppLogger.shared.log("⏭ 플로우 이동 없음")
        } else {
            nextScenarioRequest = .specific(id: raw)
            AppLogger.shared.log("➡️ 플로우 전환 요청: \(raw)")
        }
    }

    private func runDrag(_ action: AutoAction) async throws {
        let count = try! action.count.value()
        let start = try! action.point.value()
        let waypoints = action.dragWaypointsTimed
        for i in 0 ..< count {
            await dragMove(start: start, waypoints: waypoints)
            if i < count - 1 {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func runScroll(_ action: AutoAction) async throws {
        let count = try! action.count.value()
        let cfg = action.scrollConfig
        // "느린 간격" widens the gap between ticks so flick-detecting
        // receivers (Android Emulator's Qt views, etc.) don't synthesise
        // momentum scrolling on top of our discrete ticks. Default is the
        // legacy 100 ms — only opt-in users pay the latency, and they can
        // tune the exact delay via `cfg.slowDelayMs`.
        let interTickMs = cfg.slow ? cfg.slowDelayMs : 100
        for i in 0 ..< count {
            scrollWheel(direction: cfg.direction)
            if i < count - 1 {
                try await Task.sleep(for: .milliseconds(interTickMs))
            }
        }
    }

    private func runKey(_ action: AutoAction) async throws {
        let count = try! action.count.value()
        // Custom key + modifiers live in action.text (CustomKey-encoded).
        let raw = (try? action.text.value()) ?? ""
        let key = CustomKey.decode(raw)
        for i in 0 ..< count {
            sendCustomKey(key)
            if i < count - 1 {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func runWait(_ action: AutoAction, type: AutoAction.WaitType) async throws {
        switch type {
        case .click: try await waitForMouseClick()
        case .enter: try await waitForEnterKey()
        case .time:  try await waitUntilTime(try! action.text.value())
        }
    }

    private func waitForMouseClick() async throws {
        var done = false
        mouseListener.onMouseDown = { [weak self] _, _ in
            self?.mouseListener.stop()
            done = true
        }
        mouseListener.start()
        // defer so cancellation during the wait still tears the tap down.
        defer { mouseListener.stop() }
        while !done {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForEnterKey() async throws {
        // The keyboard listener is already running for the duration of the
        // run (started in `run(_:)`), so we just wait for the Enter signal.
        waitDone = false
        while !waitDone {
            try await Task.sleep(for: .milliseconds(10))
        }
        waitDone = false
    }

    private func waitUntilTime(_ timeStr: String) async throws {
        let formatter = DateFormatter()
        let now = Date()
        var targetDate: Date?
        // Full date+time first; fall back to time-only (anchored on today) so
        // legacy hardcoded actions that omitted the date still work.
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "HH:mm:ss", "HH:mm"] {
            formatter.dateFormat = fmt
            if let parsed = formatter.date(from: timeStr) {
                if fmt.hasPrefix("yyyy") {
                    targetDate = parsed
                } else {
                    var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
                    let t = Calendar.current.dateComponents([.hour, .minute, .second], from: parsed)
                    comps.hour = t.hour; comps.minute = t.minute; comps.second = t.second
                    targetDate = Calendar.current.date(from: comps)
                }
                break
            }
        }
        if let target = targetDate, target > now {
            AppLogger.shared.log("⏱ 시간 대기: \(timeStr)")
            try await Task.sleep(for: .seconds(target.timeIntervalSince(now)))
        } else {
            AppLogger.shared.log("⏱ 시간 대기: \(timeStr) 이미 지남, 건너뜀")
        }
    }

    private func runOCR(_ action: AutoAction) async throws {
        let text = try! action.text.value()
        let center = try! action.point.value()  // Quartz coords (Y-down)
        let primaryH = NSScreen.main?.frame.height ?? 0
        // Per-action scan size (width × height) packed into `count`. See
        // AutoAction.ocrScanSize for the encoding.
        let scanSize = action.ocrScanSize
        let halfW = scanSize.width / 2
        let halfH = scanSize.height / 2

        // Capture rect centered on action.point, in NSScreen coords (Y-up)
        let captureRectNS = CGRect(
            x: center.x - halfW,
            y: (primaryH - center.y) - halfH,
            width: scanSize.width,
            height: scanSize.height
        )

        var done = false
        mouseListener.onMouseDown = { [weak self] _, _ in
            self?.mouseListener.stop()
            done = true
        }
        mouseListener.start()

        // Debug window: shows each scanned frame + every recognised string,
        // scored against the target with the winning entry marked.
        OCRDebugWindow.shared.show(target: text)

        defer {
            mouseListener.stop()
            OCRDebugWindow.shared.hide()
        }

        // 15-second timeout — give up if the target text never appears.
        // Otherwise the macro stalls forever on a single missing OCR target.
        let timeoutMs = 15_000
        let pollIntervalMs = 200
        var elapsedMs = 0

        while !done && elapsedMs < timeoutMs {
            guard let shot = await ScreenCapturer.captureOnce(rect: captureRectNS) else {
                OCRDebugWindow.shared.showError("화면 캡처 실패. 좌표가 현재 모니터 범위를 벗어났을 수 있습니다 — 위치를 다시 지정해보세요.")
                AppLogger.shared.log("⚠️ OCR 캡처 실패 — 액션 건너뜀")
                return
            }
            if done { break }

            let cgImg = shot.image
            let bufScale = shot.bufferScale
            let nsRect = shot.effectiveRect
            let img = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
            let quartzOriginX = nsRect.origin.x
            let quartzOriginY = primaryH - nsRect.maxY

            // Register the target as a custom word so Vision prefers it over
            // visually similar Hangul (e.g. 약 vs 악, 예 vs 얘).
            let observations: [OCRObservation] = await withCheckedContinuation { cont in
                recognizeTextDetailed(from: cgImg, customWords: [text], topN: 3) { cont.resume(returning: $0) }
            }
            if done { break }

            let scanned = observations.compactMap { $0.candidates.first }.joined(separator: " | ")
            AppLogger.shared.log("OCR 스캔: [\(scanned)]")

            // Build the candidate pool: every top-N reading of every
            // observation, plus same-row neighbour pairs/triples concatenated
            // (covers targets that Vision split across boxes).
            let scoredAll = scoreObservations(observations, target: text)
            let chosen = scoredAll.max(by: { $0.score < $1.score })
            let debugResults = scoredAll.map { s in
                OCRDebugWindow.ScoredResult(
                    text: s.text, box: s.box, score: s.score,
                    isMatch: chosen.map { $0.score >= Constants.ocrMatchThreshold && $0.text == s.text && $0.box == s.box } ?? false,
                    merged: s.merged
                )
            }
            OCRDebugWindow.shared.updateScored(image: img, results: debugResults, target: text)

            if let best = chosen, best.score >= Constants.ocrMatchThreshold {
                done = true
                let clickPoint = CGPoint(
                    x: quartzOriginX + best.box.midX / bufScale,
                    y: quartzOriginY + best.box.midY / bufScale
                )
                let clickCount = max(1, (try? action.clicks.value()) ?? 1)
                let scorePct = String(format: "%.2f", best.score)
                AppLogger.shared.log("OCR '\(text)' 찾음 (유사도 \(scorePct), '\(best.text)') → 클릭: \(clickPoint) × \(clickCount)")
                for i in 0 ..< clickCount {
                    await click(at: clickPoint)
                    if i < clickCount - 1 {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                break
            }

            try await Task.sleep(for: .milliseconds(pollIntervalMs))
            elapsedMs += pollIntervalMs
        }

        if !done {
            AppLogger.shared.log("⏱ OCR '\(text)' \(timeoutMs/1000)초 내 미발견 — 액션 건너뜀")
        }
    }

    /// One scored candidate fed to the OCR matcher.
    private struct ScoredOCRCandidate {
        let text: String
        let box: CGRect
        let score: Double
        let merged: Bool
    }

    /// Score every observation (and short same-row runs of adjacent
    /// observations) against `target`. Returns one entry per candidate
    /// reading — caller picks the max.
    private func scoreObservations(_ observations: [OCRObservation],
                                   target: String) -> [ScoredOCRCandidate] {
        var out: [ScoredOCRCandidate] = []

        // Single observations, all top-N candidates.
        for obs in observations {
            for cand in obs.candidates {
                let score = scoreCandidate(cand, target: target)
                out.append(.init(text: cand, box: obs.box, score: score, merged: false))
            }
        }

        // Same-row runs of 2..3 boxes (top candidate only). Sort by row
        // (using mid-Y bucketed by box height) then by X.
        let sorted = observations.sorted { lhs, rhs in
            let rowDiff = lhs.box.midY - rhs.box.midY
            let rowTol = min(lhs.box.height, rhs.box.height) * 0.5
            if abs(rowDiff) > rowTol { return rowDiff < 0 }
            return lhs.box.minX < rhs.box.minX
        }
        for i in 0..<sorted.count {
            guard let first = sorted[i].candidates.first else { continue }
            var text = first
            var box = sorted[i].box
            let endJ = min(i + 3, sorted.count)
            if i + 1 >= endJ { continue }
            for j in (i + 1)..<endJ {
                let next = sorted[j]
                let sameRow = abs(next.box.midY - box.midY) < min(box.height, next.box.height) * 0.7
                let gap = next.box.minX - box.maxX
                if !sameRow || gap > box.height * 2 || gap < -box.width { break }
                text += (next.candidates.first ?? "")
                box = box.union(next.box)
                let score = scoreCandidate(text, target: target)
                out.append(.init(text: text, box: box, score: score, merged: true))
            }
        }
        return out
    }

    private func scoreCandidate(_ candidate: String, target: String) -> Double {
        let stripped = candidate.replacingOccurrences(of: " ", with: "")
        // Fast path: existing strict matcher → treat as perfect.
        if fuzzyHangulContains(stripped, target: target) { return 1.0 }
        return bestSubstringSimilarity(stripped, target: target)
    }

    /// Prefer the user-edited URL in `action.text`; fall back to the enum
    /// payload baked into the action definition when text is empty.
    private func effectiveURL(_ action: AutoAction, default fallback: String) -> String {
        let v = (try? action.text.value()) ?? ""
        return v.isEmpty ? fallback : v
    }

    private func runOpenBrowser(_ action: AutoAction, default fallbackURL: String) async throws {
        let raw = (try? action.text.value()) ?? ""
        let parsed = OpenBrowserPayload.parse(raw)
        let url = parsed.url.isEmpty ? fallbackURL : parsed.url
        guard !url.isEmpty else {
            AppLogger.shared.log("⚠️ 브라우저 열기 — URL 없음")
            return
        }

        DispatchQueue.main.async { openInDefaultBrowser(url) }
        AppLogger.shared.log("🌐 브라우저 열기: \(url)")

        // Wait for the browser window to come up before applying the frame.
        // 600ms covers most cold-launches; warm cases finish well within.
        guard !parsed.frame.isEmpty,
              let frame = WindowFrameUtil.decode(parsed.frame) else { return }
        try await Task.sleep(for: .milliseconds(600))
        DispatchQueue.main.async {
            if WindowFrameUtil.applyToFrontmostWindow(frame) {
                AppLogger.shared.log("🪟 브라우저 창 프레임 적용: \(parsed.frame)")
            } else {
                AppLogger.shared.log("⚠️ 브라우저 창 프레임 적용 실패")
            }
        }
    }

    private func runWindowFrame(_ action: AutoAction) async throws {
        let frameStr = try! action.text.value()
        guard let frame = WindowFrameUtil.decode(frameStr) else {
            AppLogger.shared.log("⚠️ 윈도우 프레임 미설정 — 건너뜀")
            return
        }
        DispatchQueue.main.async {
            if WindowFrameUtil.applyToFrontmostWindow(frame) {
                AppLogger.shared.log("🪟 활성 윈도우 프레임 설정: \(frameStr)")
            } else {
                AppLogger.shared.log("⚠️ 윈도우 프레임 적용 실패 (활성 앱 없음 또는 권한 부족)")
            }
        }

    }

    private func runScript(_ action: AutoAction, code: String) async throws {
        let script = code.replacingOccurrences(of: "${TEXT}", with: try! action.text.value())
        setPasteboard(script)
        try await Task.sleep(for: .milliseconds(100))
        let point = try! action.point.value()
        await click(at: point)
        try await Task.sleep(for: .milliseconds(100))
        pasteKey()
        try await Task.sleep(for: .milliseconds(400))
        enterKey()
        enterKey()
    }
}
