//
//  KeyboardListener.swift
//  AIMacro
//
//  Created by Kiyong Kim on 7/1/25.
//

import Foundation
import ApplicationServices
import RxSwift

class GlobalKeyListener {
    let keyRelay = BehaviorSubject<(Int, Bool)>(value: (0, false))

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        let eventMask = (1 << CGEventType.keyDown.rawValue)

        let pointerToSelf = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: GlobalKeyListener.eventCallback,
            userInfo: pointerToSelf
        ) else {
            print("event tap 생성 실패!")
            return
        }

        self.eventTap = eventTap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        print("키 감지 시작됨")
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }

        print("키 감지 중지됨")
    }

    // ⬇️ 여기가 핵심! 외부 변수 캡처 없이 static C-compatible 함수로 작성
    static let eventCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
        let mySelf = Unmanaged<GlobalKeyListener>.fromOpaque(userInfo).takeUnretainedValue()

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let shiftPressed = flags.contains(.maskShift)

        mySelf.keyRelay.onNext((Int(keyCode), shiftPressed))

        return Unmanaged.passUnretained(event)
    }
}
