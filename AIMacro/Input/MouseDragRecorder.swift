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
    /// Fired on the first `.leftMouseDown` after `start()`.
    var onStart: ((CGPoint) -> Void)?
    /// Fired on each `.leftMouseDragged` whose distance from the last
    /// sampled point exceeds `sampleDistance` — i.e., the intermediate
    /// waypoints that should be replayed during playback.
    var onSample: ((CGPoint) -> Void)?
    /// Fired on the `.leftMouseUp` that ends the gesture. The recorder
    /// auto-stops after this fires.
    var onEnd: ((CGPoint) -> Void)?

    /// Minimum pixel distance between consecutive samples. Larger ⇒ fewer
    /// waypoints. 40 pt gives ~5–25 samples for typical drags.
    var sampleDistance: CGFloat = 40

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastSamplePoint: CGPoint?
    private var didReceiveDown = false

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
        self.didReceiveDown = false
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
        didReceiveDown = false
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
            // First click of the gesture — record start, prep the sample
            // distance check. Any earlier residual mouseDown (from clicking
            // our own "녹화" button) is filtered by the fact that `start()`
            // runs after that button's mouseUp.
            didReceiveDown = true
            lastSamplePoint = point
            onStart?(point)
        case .leftMouseDragged:
            guard didReceiveDown, let last = lastSamplePoint else { return }
            let dx = point.x - last.x
            let dy = point.y - last.y
            if (dx * dx + dy * dy) >= sampleDistance * sampleDistance {
                lastSamplePoint = point
                onSample?(point)
            }
        case .leftMouseUp:
            guard didReceiveDown else { return }
            // End point — last waypoint is always the release location, so
            // the runner knows where to issue mouseUp.
            let endPoint = point
            stop()
            onEnd?(endPoint)
        default: break
        }
    }
}

/// CGEventTap C callback — unpacks the recorder pointer from the userInfo
/// and forwards the event. Returns nil to swallow the event so the user's
/// drag doesn't perturb apps under the cursor.
private func dragRecorderCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
    let recorder = Unmanaged<MouseDragRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    recorder.handle(type: type, at: event.location)
    return nil
}
