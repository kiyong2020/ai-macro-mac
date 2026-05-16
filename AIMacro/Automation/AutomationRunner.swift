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

    /// Populated when a `.nextScenario` action runs. The run loop checks
    /// it after each action and breaks early; the view controller reads
    /// this property when `run(_:)` returns to decide which scenario to
    /// move to.
    ///
    /// - `.next`           — jump to the next scenario in the list
    /// - `.specific(id:)`  — jump to the scenario with the given UUID
    private(set) var nextScenarioRequest: NextScenarioRequest?

    /// UUID of the scenario whose actions are currently being executed.
    /// Set by the view controller before each call to `run(_:)` so the
    /// `.aiGen` handler can tell the server which flow it's inside (and
    /// the server can keep the AI from branching to itself).
    var currentScenarioId: String?

    enum NextScenarioRequest {
        case next
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
        defer { AppLogger.shared.endSession() }

        // Hold a display-sleep assertion for the full run. wait(.time) can
        // sleep for hours; without this the screen idles off and the next
        // OCR action gets black frames from SCStream.
        acquireDisplaySleepAssertion()
        defer { releaseDisplaySleepAssertion() }

        // Broadcast first so any listener (KeyUtil cache, etc.) can wipe stale
        // per-run state before the first action fires.
        NotificationCenter.default.post(name: .actionSequenceWillStart, object: self)

        keyboardListener.stop()
        totalCount.onNext(actions.count)
        lastError.onNext(nil)
        nextScenarioRequest = nil
        try await Task.sleep(for: .milliseconds(100))

        for (i, action) in actions.enumerated() {
            currentIndex.onNext(i)
            currentName.onNext(action.name)
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
        let baseMs = Int(try! action.delay.value() * 1000)
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
        // the top-left origin a CGWindowListCreateImage rect expects.
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

        AppLogger.shared.log("🤖 AI 액션 시작 (지시문: \(instruction.prefix(40))…, 간격: \(String(format: "%g", action.aiGenInterval))s)")

        for iteration in 1 ... Self.aiGenMaxIterations {
            // Capture a fresh screenshot for each turn — the whole point
            // of the loop is that the model sees the result of the prior
            // turn's actions before deciding what to do next.
            guard let cg = CGWindowListCreateImage(captureRect,
                                                   .optionOnScreenOnly,
                                                   kCGNullWindowID,
                                                   .nominalResolution) else {
                AppLogger.shared.log("⚠️ AI 액션 — 화면 캡처 실패")
                return
            }
            let img = NSImage(cgImage: cg,
                              size: NSSize(width: cg.width, height: cg.height))

            AppLogger.shared.log("🤖 AI 턴 \(iteration)/\(Self.aiGenMaxIterations) 호출 중…")

            let result: ActionGenService.GenerateResult
            do {
                result = try await ActionGenService.shared.generate(
                    image: img,
                    instruction: instruction,
                    defaultDelay: baseDelay,
                    scenarios: scenarios,
                    currentScenarioId: currentScenarioId
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
            if result.finish {
                AppLogger.shared.log("🤖 AI 액션 완료 (finish)")
                return
            }
            if iteration == Self.aiGenMaxIterations {
                AppLogger.shared.log("⚠️ AI 액션 — 최대 반복 횟수(\(Self.aiGenMaxIterations))에 도달, 종료")
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
        // the image's pixelSize matching what we sent (the CGImage). Both
        // axes scale identically since CGWindowListCreateImage with
        // `.nominalResolution` gives point-equal pixels on non-Retina
        // sources but a 2× backing on Retina. Use the actual CG pixel
        // dimensions vs. our requested rect to derive the scale.
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
    /// target is encoded in `action.text` — empty for "next in list",
    /// or a scenario UUID for a specific jump.
    private func runNextScenario(_ action: AutoAction) {
        let raw = ((try? action.text.value()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            nextScenarioRequest = .next
            AppLogger.shared.log("➡️ 다음 플로우로 이동 요청 (목록 순서)")
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
        keyboardListener.start()
        defer { keyboardListener.stop() }
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

        // Debug window: shows the live capture frame + every recognised string,
        // marking the matching one with ✓.
        OCRDebugWindow.shared.show(target: text)

        // Use a FRESH ScreenCapturer per OCR action instead of the shared
        // `runner.screenCapturer`. After long waits (wait(.time)) plus prior
        // OCR start/stop cycles the shared instance can hit a state where
        // SCStream creates successfully but never delivers frames. A fresh
        // instance avoids that entirely.
        //
        // showsCursor = true is required: with a hidden cursor and a static
        // capture area, SCStream throttles frame delivery to ~zero, so the
        // OCR handler never fires. Including the cursor keeps the frames
        // flowing even when no other on-screen content changes.
        let capturer = ScreenCapturer()
        capturer.showsCursor = true

        // Tear everything down on any exit — including Task cancellation,
        // where the cleanup below the loop is skipped because Task.sleep
        // throws.
        defer {
            capturer.stop()
            mouseListener.stop()
            OCRDebugWindow.shared.hide()
        }

        capturer.handler = { [weak capturer] img in
            guard !done, let capturer = capturer else { return }
            guard let img = img, let cgImg = img.toCGImage() else {
                // Capture failed (no display, permission denied, etc.). Bail out
                // so the rest of the macro can continue and the user can see why.
                OCRDebugWindow.shared.showError("화면 캡처 실패. 좌표가 현재 모니터 범위를 벗어났을 수 있습니다 — 위치를 다시 지정해보세요.")
                AppLogger.shared.log("⚠️ OCR 캡처 실패 — 액션 건너뜀")
                done = true
                return
            }
            let bufScale = capturer.bufferScale
            let nsRect = capturer.effectiveCaptureRect
            let quartzOriginX = nsRect.origin.x
            let quartzOriginY = primaryH - nsRect.maxY
            // Register the target as a custom word so Vision prefers it over
            // visually similar Hangul (e.g. 약 vs 악, 예 vs 얘).
            recognizeText(from: cgImg, customWords: [text]) { results in
                let scanned = results.compactMap { $0.0 }.joined(separator: " | ")
                AppLogger.shared.log("OCR 스캔: [\(scanned)]")
                OCRDebugWindow.shared.update(image: img, results: results, target: text)
                // recognizeText is async — multiple frames may have queued OCR jobs
                // before the first one completes. Guard against duplicate firings,
                // otherwise several click() tasks run in parallel and fight over
                // simulateMouseMove's shared lastSimulatedPosition.
                guard !done else { return }
                // Hangul-aware fuzzy contains: tolerates one syllable that
                // differs by a single 초/중/종성 — covers OCR misreads like
                // "예약하기" vs "예악하기" without matching unrelated text.
                guard let result = results.first(where: {
                    let scanned = ($0.0 ?? "").replacingOccurrences(of: " ", with: "")
                    return fuzzyHangulContains(scanned, target: text)
                }) else { return }
                done = true
                capturer.stop()
                let clickPoint = CGPoint(
                    x: quartzOriginX + result.1.midX / bufScale,
                    y: quartzOriginY + result.1.midY / bufScale
                )
                Task {
                    AppLogger.shared.log("OCR '\(text)' 찾음 → 클릭: \(clickPoint)")
                    await click(at: clickPoint)
                }
            }
        }
        capturer.start(rect: captureRectNS)

        // 15-second timeout — give up if the target text never appears.
        // Otherwise the macro stalls forever on a single missing OCR target.
        let timeoutMs = 15_000
        var elapsedMs = 0
        while !done && elapsedMs < timeoutMs {
            try await Task.sleep(for: .milliseconds(50))
            elapsedMs += 50
        }
        if !done {
            AppLogger.shared.log("⏱ OCR '\(text)' \(timeoutMs/1000)초 내 미발견 — 액션 건너뜀")
        }
        // Cleanup runs via defer above.
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
