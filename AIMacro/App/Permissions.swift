//
//  Permissions.swift
//  Macroony
//
//  Centralizes the three TCC prompts the app needs to function:
//    1. Accessibility    — for CGEventTap (mouse + keyboard listeners,
//                          synthesised clicks, AX-driven window control)
//    2. Screen Recording — for ScreenCaptureKit (OCR + position-pick
//                          snapshots and one-shot drag/OCR snapshots)
//    3. Apple Events      — for AppleScript-driven Chrome navigation
//
//  Two callers:
//    - `applicationDidFinishLaunching` runs `requestAll()` once at boot.
//      For TCC prompts that have never been answered, this surfaces the
//      native dialog. For everything else it's a silent no-op.
//    - The settings window's "권한 요청" button calls
//      `requestAll(interactive: true)`. macOS only shows each TCC prompt
//      once per install — if the user previously denied or the cached
//      state thinks it's granted, the native prompt won't reappear, so
//      we additionally pop System Settings open at the relevant pane.
//

import Cocoa
import ApplicationServices

enum Permissions {
    static func requestAll(interactive: Bool = false) {
        requestAccessibility(interactive: interactive)
        requestScreenCapture(interactive: interactive)
        requestAppleEvents(interactive: interactive)
    }

    /// Triggers macOS's native "X.app이(가) 손쉬운 사용 기능을…" dialog
    /// when the app isn't yet on the Accessibility allow-list. When
    /// invoked interactively and the app is still untrusted shortly after
    /// the prompt would have appeared, opens System Settings to the
    /// Accessibility pane.
    static func requestAccessibility(interactive: Bool = false) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if interactive {
            openSystemSettingsIfNeeded(
                isGranted: { AXIsProcessTrusted() },
                anchorURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        }
    }

    /// Always calls `CGRequestScreenCaptureAccess()` regardless of the
    /// preflight state — the API itself is the right place for macOS to
    /// decide whether to prompt. When invoked interactively and the
    /// permission is still missing afterwards (e.g. previously denied,
    /// macOS won't re-prompt), opens System Settings to the Screen
    /// Recording pane so the user can flip the toggle manually.
    static func requestScreenCapture(interactive: Bool = false) {
        _ = CGRequestScreenCaptureAccess()
        if interactive {
            openSystemSettingsIfNeeded(
                isGranted: { CGPreflightScreenCaptureAccess() },
                anchorURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        }
    }

    /// Compiles a one-liner that drives "System Events" — that touch is
    /// enough to surface the Apple Events TCC prompt the first time. The
    /// "Automation" pane in System Settings has per-target toggles; there
    /// is no public API to check current grant state, so we open the pane
    /// unconditionally when interactive.
    static func requestAppleEvents(interactive: Bool = false) {
        let script = NSAppleScript(source: "tell application \"System Events\" to return name of processes")
        script?.compileAndReturnError(nil)
        if interactive {
            // No reliable preflight for AppleEvents; open the pane so the
            // user can confirm or fix per-target grants.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Schedules a short delay (so the native TCC dialog has a chance to
    /// appear and be answered) then re-checks the permission. If still
    /// missing, opens System Settings at the supplied pane URL.
    private static func openSystemSettingsIfNeeded(
        isGranted: @escaping () -> Bool,
        anchorURL: String
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard !isGranted() else { return }
            if let url = URL(string: anchorURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
