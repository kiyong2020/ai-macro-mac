//
//  AutomationRunner.swift
//  AIMacro
//
//  Owns the per-action execution logic and the resources used during a run
//  (mouse listener, keyboard listener, screen capturer). The view controller
//  drives this class via run(_:) / stop() / signalWaitDone().
//

import Cocoa
import RxSwift

final class AutomationRunner {
    let mouseListener: MouseListener
    let keyboardListener: GlobalKeyListener
    let screenCapturer = ScreenCapturer()

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
    }

    /// Run the full action list sequentially. Per-action errors are surfaced via
    /// `lastError` but don't abort the sequence — matches the previous behaviour.
    func run(_ actions: [AutoAction]) async throws {
        // Gate the bottom on-screen log to this run only. defer ensures the
        // session ends on early return / cancellation / thrown error so idle
        // logs stay console-only.
        AppLogger.shared.startSession()
        defer { AppLogger.shared.endSession() }

        // Broadcast first so any listener (KeyUtil cache, etc.) can wipe stale
        // per-run state before the first action fires.
        NotificationCenter.default.post(name: .actionSequenceWillStart, object: self)

        keyboardListener.stop()
        totalCount.onNext(actions.count)
        lastError.onNext(nil)
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
        if baseMs + extraMs > 0 {
            try await Task.sleep(for: .milliseconds(baseMs + extraMs))
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

    private func runDrag(_ action: AutoAction) async throws {
        let count = try! action.count.value()
        let start = try! action.point.value()
        let waypoints = action.dragWaypoints
        for i in 0 ..< count {
            await dragMove(start: start, waypoints: waypoints)
            if i < count - 1 {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func runScroll(_ action: AutoAction) async throws {
        let count = try! action.count.value()
        let direction = action.scrollDirection
        for i in 0 ..< count {
            scrollWheel(direction: direction)
            if i < count - 1 {
                try await Task.sleep(for: .milliseconds(100))
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
        // Per-action scan size — repurposes the unused `count` field for OCR.
        // 0 means "default" (Constants.ocrCaptureSize, 200pt).
        let storedSize = (try? action.count.value()) ?? 0
        let captureSize: CGFloat = storedSize > 0
            ? CGFloat(storedSize)
            : Constants.ocrCaptureSize
        let half = captureSize / 2

        // Capture rect centered on action.point, in NSScreen coords (Y-up)
        let captureRectNS = CGRect(
            x: center.x - half,
            y: (primaryH - center.y) - half,
            width: captureSize,
            height: captureSize
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
