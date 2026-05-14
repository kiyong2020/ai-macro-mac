//
//  SequenceRecorder.swift
//  Macroony
//
//  Continuous capture of the user's mouse + scroll input, classified into
//  `.click` / `.drag` / `.scroll` AutoActions. Lives at the session-level
//  CGEventTap. Pass-through model — the user's events still reach the focused
//  app so they can demonstrate a flow by actually using it — except for the
//  terminating ESC keyDown, which is swallowed so it doesn't bleed into the
//  app under the cursor.
//
//  Gesture classification:
//      mouseDown → ... → mouseUp at ~same point   →  .click
//      mouseDown → drag past `dragThreshold` → up →  .drag
//      scrollWheel bursts grouped by `scrollIdleMs` →  .scroll
//
//  Delay assignment: each emitted action's `delay` is the wall-clock gap
//  since the previous emission (clamped to [0.1, 5.0]s) so playback roughly
//  mirrors recording pacing.
//
//  Lifecycle:
//      let rec = SequenceRecorder()
//      rec.onAction = { action in … append to scenario … }
//      rec.onEnd    = {           … tear down HUD,    persist        }
//      rec.start()
//      // user interacts; presses ESC; onEnd fires; tap is torn down
//

import Cocoa
import CoreGraphics

final class SequenceRecorder {
    /// Fired on the main thread each time a complete gesture is captured.
    var onAction: ((AutoAction) -> Void)?
    /// Fired on the main thread once the user presses ESC. The recorder
    /// stops itself before this fires.
    var onEnd: (() -> Void)?

    /// Minimum movement (points) between mouseDown and mouseUp for the
    /// gesture to be classified as a drag rather than a click.
    var dragThreshold: CGFloat = 5
    /// Spacing between intermediate drag waypoints. Matches MouseDragRecorder
    /// so playback feels consistent regardless of which recorder produced
    /// the action. 5 pt preserves enough detail for the literal drag replay
    /// (in `dragMove`) to reproduce the user's speed and curve faithfully.
    var dragSampleDistance: CGFloat = 5
    /// Inactivity that closes a scroll group and emits the `.scroll` action.
    var scrollIdleMs: Int = 400

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Mouse gesture state
    private var isMouseDown = false
    private var downPoint: CGPoint = .zero
    private var downModifiers: NSEvent.ModifierFlags = []
    private var downButton: ClickButton = .left
    private var lastSamplePoint: CGPoint?
    private var dragWaypoints: [DragWaypoint] = []
    private var dragStartTime: Date?
    private var didCrossDragThreshold = false

    // Scroll grouping state
    private var scrollSumDy: CGFloat = 0
    private var scrollSumDx: CGFloat = 0
    private var scrollAnchorPoint: CGPoint = .zero
    private var scrollIdleTimer: Timer?

    // Timing
    private var lastEmissionTime: Date?

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: sequenceRecorderCallback,
            userInfo: userInfo
        ) else {
            AppLogger.shared.log("⚠️ 시퀀스 녹화: 이벤트 탭 생성 실패 — 손쉬운 사용 권한 확인")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source
        self.lastEmissionTime = Date()
    }

    func stop() {
        scrollIdleTimer?.invalidate()
        scrollIdleTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Aborts without firing onEnd. Caller takes responsibility for any UI
    /// it armed.
    func cancel() { stop() }

    /// Per-event handler. Returns `true` when the event should be swallowed
    /// (currently only the terminating ESC keyDown).
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .scrollWheel:
            handleScroll(event: event)
        case .leftMouseDown:
            flushPendingScroll()
            beginMouseDown(at: event.location, button: .left, modifiers: event.flags)
        case .leftMouseDragged:
            handleMouseDragged(at: event.location)
        case .leftMouseUp:
            endMouseDown(at: event.location)
        case .rightMouseDown:
            flushPendingScroll()
            beginMouseDown(at: event.location, button: .right, modifiers: event.flags)
        case .rightMouseDragged:
            handleMouseDragged(at: event.location)
        case .rightMouseUp:
            endMouseDown(at: event.location)
        case .keyDown:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if code == 53 {   // kVK_Escape
                flushPendingScroll()
                stop()
                let cb = onEnd
                DispatchQueue.main.async { cb?() }
                return true
            }
        default:
            break
        }
        return false
    }

    // MARK: - Mouse gesture

    private func beginMouseDown(at point: CGPoint,
                                button: ClickButton,
                                modifiers: CGEventFlags) {
        isMouseDown = true
        downPoint = point
        downButton = button
        downModifiers = nsEventFlags(from: modifiers)
        lastSamplePoint = point
        dragWaypoints = []
        dragStartTime = nil
        didCrossDragThreshold = false
    }

    private func handleMouseDragged(at point: CGPoint) {
        guard isMouseDown else { return }
        if !didCrossDragThreshold {
            let dx0 = point.x - downPoint.x
            let dy0 = point.y - downPoint.y
            if (dx0 * dx0 + dy0 * dy0) >= dragThreshold * dragThreshold {
                didCrossDragThreshold = true
                // Anchor drag timing on the first dragged event past the
                // threshold so subsequent waypoints' tMs measure actual
                // motion, matching `MouseDragRecorder`.
                dragStartTime = Date()
            }
        }
        guard didCrossDragThreshold else { return }
        if let last = lastSamplePoint {
            let dx = point.x - last.x
            let dy = point.y - last.y
            if (dx * dx + dy * dy) >= dragSampleDistance * dragSampleDistance {
                dragWaypoints.append(DragWaypoint(point: point, tMs: dragElapsedMs()))
                lastSamplePoint = point
            }
        } else {
            lastSamplePoint = point
        }
    }

    private func endMouseDown(at point: CGPoint) {
        guard isMouseDown else { return }
        isMouseDown = false
        if didCrossDragThreshold {
            // Drag — guarantee the final waypoint is the release point so
            // the runner knows where to lift the button.
            if dragWaypoints.last?.point != point {
                dragWaypoints.append(DragWaypoint(point: point, tMs: dragElapsedMs()))
            }
            emitDrag(start: downPoint, waypoints: dragWaypoints)
        } else {
            emitClick(at: point, button: downButton, modifiers: downModifiers)
        }
        lastSamplePoint = nil
        dragWaypoints = []
        dragStartTime = nil
        didCrossDragThreshold = false
    }

    private func dragElapsedMs() -> Int {
        guard let t0 = dragStartTime else { return 0 }
        return max(0, Int(Date().timeIntervalSince(t0) * 1000))
    }

    // MARK: - Scroll grouping

    private func handleScroll(event: CGEvent) {
        let lineDy = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let lineDx = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let dy: CGFloat
        let dx: CGFloat
        if lineDy != 0 || lineDx != 0 {
            dy = lineDy
            dx = lineDx
        } else {
            // Continuous (Magic Mouse / trackpad) — convert px → line (1 line ≈ 10 px).
            let pdy = CGFloat(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let pdx = CGFloat(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            dy = pdy / 10
            dx = pdx / 10
        }
        if scrollSumDy == 0 && scrollSumDx == 0 {
            scrollAnchorPoint = event.location
        }
        scrollSumDy += dy
        scrollSumDx += dx
        scrollIdleTimer?.invalidate()
        scrollIdleTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(scrollIdleMs) / 1000.0,
            repeats: false
        ) { [weak self] _ in
            self?.flushPendingScroll()
        }
    }

    private func flushPendingScroll() {
        scrollIdleTimer?.invalidate()
        scrollIdleTimer = nil
        let dy = scrollSumDy
        let dx = scrollSumDx
        scrollSumDy = 0
        scrollSumDx = 0
        guard dy != 0 || dx != 0 else { return }
        emitScroll(dy: dy, dx: dx, at: scrollAnchorPoint)
    }

    // MARK: - Emission

    private func nextDelay() -> Double {
        let now = Date()
        let gap = now.timeIntervalSince(lastEmissionTime ?? now)
        lastEmissionTime = now
        return max(0.1, min(5.0, gap))
    }

    private func emitClick(at point: CGPoint,
                           button: ClickButton,
                           modifiers: NSEvent.ModifierFlags) {
        let action = AutoAction(type: .click,
                                name: "New 클릭",
                                point: point,
                                delay: nextDelay(),
                                count: 1,
                                text: "")
        var cfg = ClickConfig(button: button, modifiers: [])
        if modifiers.contains(.command)  { cfg.modifiers.insert(.command) }
        if modifiers.contains(.shift)    { cfg.modifiers.insert(.shift) }
        if modifiers.contains(.control)  { cfg.modifiers.insert(.control) }
        if modifiers.contains(.option)   { cfg.modifiers.insert(.option) }
        action.setClickConfig(cfg)
        AppLogger.shared.log("⏺ 녹화 → 클릭 \(button == .right ? "(우)" : "") @ \(Int(point.x)),\(Int(point.y))")
        let cb = onAction
        DispatchQueue.main.async { cb?(action) }
    }

    private func emitDrag(start: CGPoint, waypoints: [DragWaypoint]) {
        let action = AutoAction(type: .drag,
                                name: "New 드래그",
                                point: start,
                                delay: nextDelay(),
                                count: 1,
                                text: "")
        action.setDragWaypointsTimed(waypoints)
        let totalMs = waypoints.last?.tMs ?? 0
        AppLogger.shared.log("⏺ 녹화 → 드래그 \(waypoints.count)포인트, \(totalMs)ms")
        let cb = onAction
        DispatchQueue.main.async { cb?(action) }
    }

    private func emitScroll(dy: CGFloat, dx: CGFloat, at point: CGPoint) {
        let absY = abs(dy)
        let absX = abs(dx)
        let direction: ScrollDirection
        let magnitude: CGFloat
        // Sign convention matches scrollWheel(direction:lines:):
        // negative wheel1 ⇒ .down, positive ⇒ .up;
        // negative wheel2 ⇒ .right, positive ⇒ .left.
        if absY >= absX {
            direction = dy < 0 ? .down : .up
            magnitude = absY
        } else {
            direction = dx < 0 ? .right : .left
            magnitude = absX
        }
        let ticks = max(1, Int(ceil(magnitude / 3)))
        let action = AutoAction(type: .scroll,
                                name: "New 스크롤",
                                point: point,
                                delay: nextDelay(),
                                count: ticks,
                                text: direction.rawValue)
        AppLogger.shared.log("⏺ 녹화 → 스크롤 \(direction.rawValue) \(ticks)틱")
        let cb = onAction
        DispatchQueue.main.async { cb?(action) }
    }

    /// Translate the CG-level event flags into the AppKit ones our
    /// `ClickConfig` uses.
    private func nsEventFlags(from cg: CGEventFlags) -> NSEvent.ModifierFlags {
        var out: NSEvent.ModifierFlags = []
        if cg.contains(.maskCommand)   { out.insert(.command) }
        if cg.contains(.maskShift)     { out.insert(.shift) }
        if cg.contains(.maskControl)   { out.insert(.control) }
        if cg.contains(.maskAlternate) { out.insert(.option) }
        return out
    }

    deinit { stop() }
}

/// CGEventTap C callback — unpacks the recorder pointer from userInfo and
/// dispatches to the handler. Returns nil only when the recorder asks to
/// swallow the event (terminating ESC).
private func sequenceRecorderCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
    let recorder = Unmanaged<SequenceRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    if recorder.handle(type: type, event: event) {
        return nil
    }
    return Unmanaged.passRetained(event)
}
