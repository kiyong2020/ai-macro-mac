//
//  ScrollWheelRecorder.swift
//  AIMacro
//
//  Records a scroll gesture (mouse wheel, Magic Mouse top swipe, trackpad
//  two-finger scroll — all share the same `.scrollWheel` event stream) by
//  tapping the session-level event stream and consuming the events. Sums
//  the per-event line/pixel deltas until the user stops scrolling for
//  `idleTimeoutMs`, then reports the totals via `onEnd` so the caller can
//  derive the dominant axis + tick count for the action.
//
//  Lifecycle:
//      let rec = ScrollWheelRecorder()
//      rec.onDelta = { dy, dx in … }    // optional live feedback
//      rec.onEnd = { dy, dx in … }
//      rec.start()
//      // (user scrolls)
//      // rec auto-stops after idleTimeoutMs of silence, then fires onEnd.
//

import Cocoa
import CoreGraphics

final class ScrollWheelRecorder {
    /// Fired on every `.scrollWheel` event. Use for a live preview if needed
    /// — totals are also reported in `onEnd`.
    var onDelta: ((CGFloat, CGFloat) -> Void)?
    /// Fired once after the gesture has been idle for `idleTimeoutMs`. The
    /// arguments are the running totals (line units) on the vertical and
    /// horizontal axes, signed per the system's natural-scrolling setting.
    /// The recorder auto-stops before this fires.
    var onEnd: ((CGFloat, CGFloat) -> Void)?

    /// Time of inactivity that ends the recording session. 600 ms is a
    /// comfortable threshold — longer than a single wheel-click but well
    /// shorter than the user's reaction time to a fresh gesture.
    var idleTimeoutMs: Int = 600

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var idleTimer: Timer?
    private var sumDy: CGFloat = 0
    private var sumDx: CGFloat = 0
    private var didReceiveAny = false

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollRecorderCallback,
            userInfo: userInfo
        ) else {
            AppLogger.shared.log("⚠️ 스크롤 녹화: 이벤트 탭 생성 실패 — 손쉬운 사용 권한 확인")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source
        self.sumDy = 0
        self.sumDx = 0
        self.didReceiveAny = false
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// Aborts the session without firing `onEnd`. Caller is responsible for
    /// resetting any UI it armed.
    func cancel() {
        idleTimer?.invalidate()
        idleTimer = nil
        stop()
    }

    fileprivate func handle(deltaY: CGFloat, deltaX: CGFloat) {
        didReceiveAny = true
        sumDy += deltaY
        sumDx += deltaX
        onDelta?(deltaY, deltaX)

        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(idleTimeoutMs) / 1000.0,
            repeats: false
        ) { [weak self] _ in
            self?.finalize()
        }
    }

    private func finalize() {
        let dy = sumDy
        let dx = sumDx
        stop()
        onEnd?(dy, dx)
    }

    deinit {
        // Match MouseDragRecorder: tear the tap down on dealloc so the
        // C callback can't dereference our dangling unretained pointer.
        stop()
    }
}

/// CGEventTap C callback. Reads line + point deltas (`.scrollWheelEventDelta…`
/// is what physical wheels produce, point delta covers Magic Mouse swipe
/// and trackpad continuous scroll). Passes the event through unchanged so
/// the user gets live scroll feedback in the app under the cursor while
/// the recorder accumulates totals.
private func scrollRecorderCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
    let recorder = Unmanaged<ScrollWheelRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .scrollWheel {
        let lineDy = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let lineDx = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let dy: CGFloat
        let dx: CGFloat
        if lineDy != 0 || lineDx != 0 {
            dy = lineDy
            dx = lineDx
        } else {
            // Continuous (Magic Mouse / trackpad) — fall back to pixel
            // delta and convert to a line-equivalent (1 line ≈ 10 px).
            let pdy = CGFloat(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let pdx = CGFloat(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            dy = pdy / 10
            dx = pdx / 10
        }
        recorder.handle(deltaY: dy, deltaX: dx)
    }
    return Unmanaged.passRetained(event)
}
