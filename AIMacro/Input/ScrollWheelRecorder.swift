//
//  ScrollWheelRecorder.swift
//  Macroony
//
//  Records a scroll gesture (mouse wheel, Magic Mouse top swipe, trackpad
//  two-finger scroll — all share the same `.scrollWheel` event stream) by
//  tapping the session-level event stream. Sums the per-event line/pixel
//  deltas, then reports the totals via `onEnd`.
//
//  Termination model:
//      1. Recorder starts.
//      2. Any number of clicks the user does before scrolling are passed
//         through normally — useful for navigating to / focusing the
//         scrollable area without ending the gesture.
//      3. The user scrolls — accumulates deltas.
//      4. The next click *after a scroll has been seen* ends the recording.
//         That terminating click is swallowed so it doesn't accidentally
//         activate whatever's under the cursor.
//
//  Lifecycle:
//      let rec = ScrollWheelRecorder()
//      rec.onDelta = { dy, dx in … }    // optional live feedback
//      rec.onEnd = { dy, dx in … }
//      rec.start()
//

import Cocoa
import CoreGraphics

final class ScrollWheelRecorder {
    /// Fired on every `.scrollWheel` event. Use for a live preview if needed
    /// — totals are also reported in `onEnd`.
    var onDelta: ((CGFloat, CGFloat) -> Void)?
    /// Fired once when the user clicks after scrolling. Arguments are the
    /// running totals (line units) on the vertical and horizontal axes,
    /// signed per the system's natural-scrolling setting. The recorder
    /// auto-stops before this fires.
    var onEnd: ((CGFloat, CGFloat) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var sumDy: CGFloat = 0
    private var sumDx: CGFloat = 0
    /// True once at least one scroll event has been captured. Used to
    /// gate the click-to-end behaviour: clicks while this is false (i.e.
    /// before any scrolling) pass through and are ignored; the first
    /// click after this flips to true ends the recording.
    private var hasScrolled = false

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

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
        self.hasScrolled = false
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
    }

    /// Aborts the session without firing `onEnd`. Caller is responsible for
    /// resetting any UI it armed.
    func cancel() {
        stop()
    }

    /// Per-event handler called from the C callback. Returns a tuple
    /// describing how the underlying event should be routed:
    ///   - `consume == true`: the callback swallows the event (return nil)
    ///   - `consume == false`: the event passes through unchanged
    fileprivate func handle(scrollDeltaY dy: CGFloat, deltaX dx: CGFloat) {
        hasScrolled = true
        sumDy += dy
        sumDx += dx
        onDelta?(dy, dx)
    }

    /// Returns true when the click should be swallowed (it's the
    /// terminating click after a scroll). When the recorder hasn't seen a
    /// scroll yet, the click is passed through so the user can position
    /// the cursor.
    fileprivate func handleClick() -> Bool {
        guard hasScrolled else { return false }
        finalize()
        return true
    }

    private func finalize() {
        let dy = sumDy
        let dx = sumDx
        stop()
        onEnd?(dy, dx)
    }

    deinit {
        // Belt-and-braces: tear the tap down on dealloc so the C callback
        // can't dereference our dangling unretained pointer.
        stop()
    }
}

/// CGEventTap C callback. Scroll events update the running totals and pass
/// through; mouse-down events either pass through (first click, used for
/// positioning) or get swallowed and end the recording (any click after a
/// scroll).
private func scrollRecorderCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
    let recorder = Unmanaged<ScrollWheelRecorder>.fromOpaque(userInfo).takeUnretainedValue()

    switch type {
    case .scrollWheel:
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
        recorder.handle(scrollDeltaY: dy, deltaX: dx)
        return Unmanaged.passRetained(event)

    case .leftMouseDown, .rightMouseDown:
        if recorder.handleClick() {
            return nil   // swallow the terminating click
        }
        return Unmanaged.passRetained(event)

    default:
        return Unmanaged.passRetained(event)
    }
}
