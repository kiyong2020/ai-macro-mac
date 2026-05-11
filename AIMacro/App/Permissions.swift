//
//  Permissions.swift
//  AIMacro
//
//  Centralizes the three TCC prompts the app needs to function:
//    1. Accessibility    — for CGEventTap (mouse + keyboard listeners,
//                          synthesised clicks)
//    2. Screen Recording — for ScreenCaptureKit (OCR + position-pick
//                          snapshots)
//    3. Apple Events      — for AppleScript-driven Chrome navigation
//
//  Called once at launch from `applicationDidFinishLaunching` and re-callable
//  from the settings window's "권한 요청" button. macOS dedups: granted
//  permissions silently no-op, missing ones surface the native system prompt.
//

import Cocoa
import ApplicationServices

enum Permissions {
    static func requestAll() {
        requestAccessibility()
        requestScreenCapture()
        requestAppleEvents()
    }

    /// Triggers macOS's native "사용자가 X.app이(가) 손쉬운 사용 기능을…"
    /// dialog when the app isn't yet on the Accessibility allow-list.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// CGPreflightScreenCaptureAccess() reads the cached TCC state without
    /// prompting; CGRequestScreenCaptureAccess() adds the app to the system
    /// settings list and shows the prompt the first time it's called.
    static func requestScreenCapture() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    /// Compiles a one-liner that drives "System Events" — that touch is
    /// enough to surface the Apple Events TCC prompt the first time, after
    /// which Chrome-driven `.setURL` / `.openChrome` actions can run.
    static func requestAppleEvents() {
        let script = NSAppleScript(source: "tell application \"System Events\" to return name of processes")
        script?.compileAndReturnError(nil)
    }
}
