//
//  KeyUtil.swift
//  AIMacro
//
//  Created by Kiyong Kim on 7/12/25.
//
import Foundation
import AppKit
import ScreenCaptureKit
import Vision
import CoreGraphics

func mouseLocation() -> CGPoint {
    return NSEvent.mouseLocation
}

func click(at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) async {
    await performClick(at: point,
                       button: .left,
                       downType: .leftMouseDown,
                       upType: .leftMouseUp,
                       modifiers: modifiers)
}

func rightClick(at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) async {
    await performClick(at: point,
                       button: .right,
                       downType: .rightMouseDown,
                       upType: .rightMouseUp,
                       modifiers: modifiers)
}

/// Synthesises a mouse click with optional Cmd / Shift / Ctrl / Opt held
/// across the down/up pair. Attaches the modifier mask to the CGEvent
/// `.flags` *and* presses the actual modifier keys around the click, so
/// both event-flag readers (browsers) and keyboard-state readers (some
/// AppKit controls) see the chord.
private func performClick(at point: CGPoint,
                          button: CGMouseButton,
                          downType: CGEventType,
                          upType: CGEventType,
                          modifiers: NSEvent.ModifierFlags) async {
    await simulateMouseMove(to: point)
    let source = CGEventSource(stateID: .hidSystemState)
    let flags = cgEventFlags(from: modifiers)

    // Hold the modifier keys around the click for apps that inspect actual
    // key state instead of (or in addition to) event flags.
    let modKeys = modifierKeyCodes(for: modifiers)
    for code in modKeys {
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
    }

    let mouseDown = CGEvent(mouseEventSource: source, mouseType: downType,
                            mouseCursorPosition: point, mouseButton: button)
    let mouseUp   = CGEvent(mouseEventSource: source, mouseType: upType,
                            mouseCursorPosition: point, mouseButton: button)
    // Mark the down/up pair as a single click — required for apps that
    // distinguish a real click from a stray mouseDown/mouseUp, including
    // Chrome's native JavaScript confirm dialog (otherwise the synthetic
    // click reaches the right coordinates but the button never activates).
    mouseDown?.setIntegerValueField(.mouseEventClickState, value: 1)
    mouseUp?.setIntegerValueField(.mouseEventClickState, value: 1)
    mouseDown?.flags = flags
    mouseUp?.flags = flags
    mouseDown?.post(tap: .cghidEventTap)
    // Right-skewed click hold: most clicks ~15-25 ms, occasional longer.
    // pow(u, 2) biases toward 0; adds 0-33 ms on top of 12 ms baseline.
    let holdMs = 12 + Int(pow(Double.random(in: 0...1), 2.0) * 33)
    try? await Task.sleep(for: .milliseconds(holdMs))
    mouseUp?.post(tap: .cghidEventTap)

    // Release modifier keys in reverse order.
    for code in modKeys.reversed() {
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        up?.post(tap: .cghidEventTap)
    }
}

/// Virtual key codes for the modifier keys present in `m`. Order is fixed
/// so press / release happens deterministically.
private func modifierKeyCodes(for m: NSEvent.ModifierFlags) -> [CGKeyCode] {
    var codes: [CGKeyCode] = []
    if m.contains(.command) { codes.append(0x37) }   // Left Command
    if m.contains(.shift)   { codes.append(0x38) }   // Left Shift
    if m.contains(.option)  { codes.append(0x3A) }   // Left Option
    if m.contains(.control) { codes.append(0x3B) }   // Left Control
    return codes
}

/// Last simulated cursor position in Quartz coords. Tracked across calls so each move
/// continues smoothly from where the previous one ended (instead of jumping based on
/// the system cursor position, which may have been changed by the user or other code).
private var lastSimulatedPosition: CGPoint?

/// Listens for the action-sequence-will-start broadcast and resets the cached
/// position so a new run starts from the actual cursor location instead of
/// where the previous run happened to leave the simulated cursor. Held in a
/// static of a small wrapper class (Swift file-level lazy lets aren't eagerly
/// initialized) and forced-touched from `setupGlobalObservers()`.
private final class _MouseMoveCacheObserver {
    static let shared = _MouseMoveCacheObserver()
    private init() {
        NotificationCenter.default.addObserver(
            forName: .actionSequenceWillStart,
            object: nil,
            queue: .main
        ) { _ in
            lastSimulatedPosition = nil
        }
    }
}

/// Call once at app startup so module-level observers (like the mouse-move
/// cache reset) get registered.
func setupGlobalObservers() {
    _ = _MouseMoveCacheObserver.shared
}

/// Moves the cursor from its last simulated position to `target` along a slightly curved
/// path with randomized step timing, mimicking natural human mouse movement.
private func simulateMouseMove(to target: CGPoint) async {
    let start: CGPoint
    if let last = lastSimulatedPosition {
        start = last
    } else {
        // First call: seed from the actual cursor position (NSScreen Y-up → Quartz Y-down)
        let startNS = NSEvent.mouseLocation
        let primaryH = NSScreen.main?.frame.height ?? 0
        start = CGPoint(x: startNS.x, y: primaryH - startNS.y)
    }

    let steps = 9
    // Random control point offset for a subtle bezier curve
    let cpOffset = CGPoint(
        x: CGFloat.random(in: -60...60),
        y: CGFloat.random(in: -60...60)
    )
    let control = CGPoint(
        x: (start.x + target.x) / 2 + cpOffset.x,
        y: (start.y + target.y) / 2 + cpOffset.y
    )

    for i in 1...steps {
        // Ease-in-out via smoothstep
        let t = CGFloat(i) / CGFloat(steps)
        let s = t * t * (3 - 2 * t)

        // Quadratic bezier
        let x = (1 - s) * (1 - s) * start.x + 2 * (1 - s) * s * control.x + s * s * target.x
        let y = (1 - s) * (1 - s) * start.y + 2 * (1 - s) * s * control.y + s * s * target.y

        // Small random jitter on intermediate steps (not the final one)
        let jx = i < steps ? CGFloat.random(in: -2...2) : 0
        let jy = i < steps ? CGFloat.random(in: -2...2) : 0

        let pos = CGPoint(x: x + jx, y: y + jy)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pos, mouseButton: .left)?
            .post(tap: .cghidEventTap)

        // Slow down as the cursor closes on the target. Inter-step delay
        // grows quadratically with progress (`t`), so the first few steps
        // fly past (~2–5 ms) while the last one or two pause noticeably
        // (~20+ ms) — combined with smoothstep's already-small spatial
        // deltas near t=1, this reads as natural deceleration.
        let baseDelay = 2
        let deceleration = Int(t * t * 18)
        let jitter = Int.random(in: 0...3)
        try? await Task.sleep(for: .milliseconds(baseDelay + deceleration + jitter))
    }

    lastSimulatedPosition = target
}


func scrollDown() {
    sendKeyPress(key: 49)    // 스페이스로 아래로 스크롤
}

func enterKey() {
    sendKeyPress(key: 36)   // 엔터키
}

func tabKey() {
    sendKeyPress(key: 48)   // 탭키
}

func sendKeyPress(key: CGKeyCode) {
    let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
    keyDown?.post(tap: .cghidEventTap)
    usleep(10) // slight delay
    keyUp?.post(tap: .cghidEventTap)
}

// MARK: - Custom key (drives the .key action after the redesign)

/// Encoded key + modifier-flag set, persisted into `AutoAction.text`.
/// Two modes:
///   - **key** (default): single keystroke. Examples → `":space"`, `"cmd:s"`.
///   - **text**: types a string of characters (no virtual keycode mapping).
///     Encoded with a `T:` prefix → `"T::hello"`, `"T:cmd:문자열"`.
/// The `T:` prefix preserves backward compatibility with previously-saved
/// scenarios that didn't have a mode marker.
struct CustomKey {
    var modifiers: NSEvent.ModifierFlags = []
    var key: String = ""
    var isText: Bool = false

    static func decode(_ s: String) -> CustomKey {
        var c = CustomKey()
        var rest = s
        if rest.hasPrefix("T:") {
            c.isText = true
            rest.removeFirst(2)
        }
        let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            for raw in parts[0].split(separator: ",") {
                switch raw.lowercased() {
                case "cmd", "command":   c.modifiers.insert(.command)
                case "shift":            c.modifiers.insert(.shift)
                case "ctrl", "control":  c.modifiers.insert(.control)
                case "opt", "option", "alt": c.modifiers.insert(.option)
                default: break
                }
            }
            c.key = String(parts[1])
        } else {
            c.key = rest
        }
        return c
    }

    func encode() -> String {
        var mods: [String] = []
        if modifiers.contains(.command) { mods.append("cmd") }
        if modifiers.contains(.shift)   { mods.append("shift") }
        if modifiers.contains(.control) { mods.append("ctrl") }
        if modifiers.contains(.option)  { mods.append("opt") }
        let body = mods.joined(separator: ",") + ":" + key
        return isText ? "T:" + body : body
    }
}

/// Map common named keys to virtual key codes. Anything not in this list is
/// sent as Unicode text via `keyboardSetUnicodeString`.
private func virtualKeyCode(for key: String) -> CGKeyCode? {
    switch key.lowercased() {
    case "space":               return 49
    case "tab":                 return 48
    case "return", "enter":     return 36
    case "esc", "escape":       return 53
    case "delete", "backspace": return 51
    case "left":                return 123
    case "right":               return 124
    case "up":                  return 126
    case "down":                return 125
    default:                    return nil
    }
}

private func cgEventFlags(from m: NSEvent.ModifierFlags) -> CGEventFlags {
    var f: CGEventFlags = []
    if m.contains(.command) { f.insert(.maskCommand) }
    if m.contains(.shift)   { f.insert(.maskShift) }
    if m.contains(.control) { f.insert(.maskControl) }
    if m.contains(.option)  { f.insert(.maskAlternate) }
    return f
}

/// Send a key event for `key` with the given modifier flags. Honors the
/// `isText` flag — in text mode the entire string is typed character-by-
/// character (modifiers ignored), in key mode a single keystroke is sent.
func sendCustomKey(_ raw: CustomKey) {
    guard !raw.key.isEmpty else { return }

    if raw.isText {
        // Text mode: type the value as if the user typed it. typeString()
        // already inserts realistic per-character timing.
        typeString(raw.key)
        return
    }

    let source = CGEventSource(stateID: .hidSystemState)
    let flags = cgEventFlags(from: raw.modifiers)

    // Key mode: in addition to named keys ("space", "tab", …) accept the
    // literal character form (" ", "\t", "\n") so users can type the actual
    // whitespace character into the UI field.
    let normalized: String
    switch raw.key {
    case " ":           normalized = "space"
    case "\t":          normalized = "tab"
    case "\n", "\r":    normalized = "return"
    default:            normalized = raw.key
    }

    if let code = virtualKeyCode(for: normalized) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(10)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    } else {
        let chars = Array(normalized.utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.flags = flags
        down?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        down?.post(tap: .cghidEventTap)
        usleep(10)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.flags = flags
        up?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        up?.post(tap: .cghidEventTap)
    }
}

// Types a string by injecting each character as a CGEvent unicode keystroke.
// Does not touch the pasteboard, so the user's clipboard is preserved.
//
// Timing approximates human keystroke distribution:
//  - dwell (keyDown→keyUp): right-skewed ~40–130 ms, median ~70 ms
//  - gap (keyUp→next keyDown): longer for digits/punctuation (cognitive pause),
//    occasional 200–600 ms "thinking" pause every few characters
func typeString(_ string: String) {
    let src = CGEventSource(stateID: .combinedSessionState)
    let digitsAndPunct = CharacterSet.decimalDigits.union(.punctuationCharacters)

    for scalar in string.unicodeScalars {
        var ch = UniChar(scalar.value & 0xFFFF)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
        up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)

        down?.post(tap: .cghidEventTap)

        // Key dwell — right-skewed log-normal-ish
        let dwellMs = 40 + Int(pow(Double.random(in: 0...1), 2.0) * 90)
        usleep(useconds_t(dwellMs * 1000))

        up?.post(tap: .cghidEventTap)

        // Inter-key gap — longer for digits/punctuation (slower cognitive load)
        let slow = digitsAndPunct.contains(scalar)
        let baseGap = slow ? 130 : 90
        let gapMs = baseGap + Int(pow(Double.random(in: 0...1), 1.8) * 160)
        usleep(useconds_t(gapMs * 1000))

        // ~12% chance of a longer "thinking" pause (look back at phone, etc.)
        if Double.random(in: 0...1) < 0.12 {
            usleep(useconds_t(Int.random(in: 220_000...550_000)))
        }
    }
}

/// Sends Cmd+A to select all text in the focused field. Used before paste to ensure
/// the paste replaces existing text rather than appending to it (e.g. when retrying
/// verification code entry after a previous paste left the field non-empty).
func selectAllKey() {
    let src = CGEventSource(stateID: .combinedSessionState)
    let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
    let aDown   = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: true)
    let aUp     = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: false)
    let cmdUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)

    cmdDown?.flags = .maskCommand
    aDown?.flags   = .maskCommand
    aUp?.flags     = .maskCommand
    cmdUp?.flags   = []

    cmdDown?.post(tap: .cghidEventTap)
    aDown?.post(tap: .cghidEventTap)
    aUp?.post(tap: .cghidEventTap)
    cmdUp?.post(tap: .cghidEventTap)
}

func pasteKey() {
    let src = CGEventSource(stateID: .combinedSessionState)
    let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
    let vDown   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
    let vUp     = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
    let cmdUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)

    cmdDown?.flags = .maskCommand   // Cmd held
    vDown?.flags   = .maskCommand   // V pressed while Cmd held
    vUp?.flags     = .maskCommand   // V released while Cmd still held
    cmdUp?.flags   = []             // Cmd released — no modifiers active

    cmdDown?.post(tap: .cghidEventTap)
    vDown?.post(tap: .cghidEventTap)
    vUp?.post(tap: .cghidEventTap)
    cmdUp?.post(tap: .cghidEventTap)
}
