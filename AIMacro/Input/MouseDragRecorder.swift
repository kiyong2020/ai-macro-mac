//
//  MouseDragRecorder.swift
//  AIMacro
//
//  Records a left-button drag (down → drag → up) by tapping the session-
//  level event stream. Consumes the events so the user's actual mouse
//  motion doesn't trigger drags in the app under the cursor — purely a
//  capture session. Sampled by distance so a long drag yields a small,
//  evenly spaced waypoint list instead of hundreds of pixel-by-pixel
//  points.
//
//  Lifecycle:
//      let rec = MouseDragRecorder()
//      rec.onStart = { … }
//      rec.onSample = { … }
//      rec.onEnd = { … }       // also tears down the tap
//      rec.start()
//

import Cocoa
import CoreGraphics

final class MouseDragRecorder {
    /// Fired on the first `.leftMouseDragged` past `dragThreshold` — i.e.
    /// when the recorder has decided the gesture is a drag, not a click.
    /// The point is the *mouseDown* location, so the runner can replay the
    /// press at the correct origin and then traverse the waypoints. This
    /// also anchors timing — subsequent `tMs` values are measured from
    /// the moment this fires.
    var onStart: ((CGPoint) -> Void)?
    /// Fired on each `.leftMouseDragged` whose distance from the last
    /// sampled point exceeds `sampleDistance` — i.e., the intermediate
    /// waypoints that should be replayed during playback. `tMs` is the
    /// milliseconds elapsed since `onStart` fired, so playback can pace
    /// the gesture to match the user's recorded speed.
    var onSample: ((CGPoint, Int) -> Void)?
    /// Fired on the `.leftMouseUp` that ends the gesture. `tMs` is the
    /// total drag duration in milliseconds. The recorder auto-stops after
    /// this fires.
    var onEnd: ((CGPoint, Int) -> Void)?

    /// Minimum pixel distance between consecutive samples. Larger ⇒ fewer
    /// waypoints. 5 pt is dense enough to preserve subtle curves and lets
    /// the timing series capture pauses/accelerations faithfully.
    var sampleDistance: CGFloat = 5
    /// Minimum movement (points) between mouseDown and the first dragged
    /// event for the gesture to count as a drag. Plain clicks (mouseDown
    /// → mouseUp at ~same point) fall under this and are dropped, so the
    /// user can freely click around — focusing a window, dismissing a
    /// popover — before performing the actual drag they want recorded.
    /// Matches `SequenceRecorder.dragThreshold` so both recorders behave
    /// consistently.
    var dragThreshold: CGFloat = 5

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastSamplePoint: CGPoint?
    private var pendingStart: CGPoint?
    private var didStartDrag = false
    private var dragStartTime: Date?

    func start() {
        // Already running — bail to avoid registering a second tap.
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: dragRecorderCallback,
            userInfo: userInfo
        ) else {
            AppLogger.shared.log("⚠️ 드래그 녹화: 이벤트 탭 생성 실패 — 손쉬운 사용 권한 확인")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source
        self.lastSamplePoint = nil
        self.pendingStart = nil
        self.didStartDrag = false
        self.dragStartTime = nil
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
        lastSamplePoint = nil
        pendingStart = nil
        didStartDrag = false
        dragStartTime = nil
    }

    deinit {
        // Belt-and-braces: if the recorder is released while still armed
        // (e.g. the detail pane rebuilds mid-gesture), tear the tap down
        // so its C callback can't dereference our dangling pointer.
        stop()
    }

    fileprivate func handle(type: CGEventType, at point: CGPoint) {
        switch type {
        case .leftMouseDown:
            // Stash the candidate start point but don't commit it yet — a
            // plain click (no motion before mouseUp) should be ignored so
            // the user can freely click around before performing the real
            // drag. `onStart` fires later, once we see motion past
            // `dragThreshold`. Any earlier residual mouseDown from the
            // "녹화" button is filtered by the fact that `start()` runs
            // after that button's mouseUp.
            pendingStart = point
            lastSamplePoint = point
            didStartDrag = false
        case .leftMouseDragged:
            guard let start = pendingStart else { return }
            if !didStartDrag {
                let dx0 = point.x - start.x
                let dy0 = point.y - start.y
                guard (dx0 * dx0 + dy0 * dy0) >= dragThreshold * dragThreshold else { return }
                didStartDrag = true
                lastSamplePoint = start
                dragStartTime = Date()
                onStart?(start)
            }
            guard let last = lastSamplePoint else { return }
            let dx = point.x - last.x
            let dy = point.y - last.y
            if (dx * dx + dy * dy) >= sampleDistance * sampleDistance {
                lastSamplePoint = point
                let tMs = elapsedMs()
                onSample?(point, tMs)
            }
        case .leftMouseUp:
            if didStartDrag {
                // End point — last waypoint is always the release location,
                // so the runner knows where to issue mouseUp. tMs is the
                // total drag duration so playback can match the user's pace.
                let endPoint = point
                let tMs = elapsedMs()
                stop()
                onEnd?(endPoint, tMs)
            } else {
                // Click without motion — drop it and keep listening for the
                // real drag.
                pendingStart = nil
                lastSamplePoint = nil
            }
        default: break
        }
    }

    private func elapsedMs() -> Int {
        guard let t0 = dragStartTime else { return 0 }
        return max(0, Int(Date().timeIntervalSince(t0) * 1000))
    }
}

/// CGEventTap C callback — unpacks the recorder pointer from the userInfo
/// and forwards the event. The event is passed through unchanged so the
/// app under the cursor actually receives the user's drag (the recording
/// session observes a real interaction instead of a swallowed one).
private func dragRecorderCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<MouseDragRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    recorder.handle(type: type, at: event.location)
    return Unmanaged.passUnretained(event)
}
