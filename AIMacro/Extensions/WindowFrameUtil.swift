//
//  WindowFrameUtil.swift
//  AIMacro
//
//  Accessibility-API helpers for the `.windowFrame` action: capture the frame
//  of the window under a click point at configuration time, and apply it to
//  the frontmost app's focused window at runtime.
//

import Cocoa
import ApplicationServices

enum WindowFrameUtil {
    /// Look up the window under `point` (Quartz coords, Y-down) and return its
    /// frame in the same coordinate system. Returns nil if AX can't find one.
    static func windowFrame(at point: CGPoint) -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element = element else { return nil }
        let window = containingWindow(of: element) ?? element
        return frame(of: window)
    }

    /// Apply position+size to whichever window currently sits under `point`
    /// (Quartz coords, Y-down). Useful for "restore this frame" — pass the
    /// saved frame's center as the locator.
    @discardableResult
    static func applyFrame(_ frame: CGRect, toWindowAt point: CGPoint) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element = element else { return false }
        guard let window = containingWindow(of: element) else { return false }
        return setFrame(frame, on: window)
    }

    /// Apply position+size to the frontmost app's focused (or main) window.
    /// Returns false if there's no frontmost app or the AX call fails.
    @discardableResult
    static func applyToFrontmostWindow(_ frame: CGRect) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = focusedWindow(of: appElement) ?? mainWindow(of: appElement) else { return false }
        return setFrame(frame, on: window)
    }

    private static func setFrame(_ frame: CGRect, on window: AXUIElement) -> Bool {
        var pos = frame.origin
        var size = frame.size
        guard let posValue = AXValueCreate(.cgPoint, &pos),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        // Size first then position: some apps clamp position to fit the
        // current size, so applying size first avoids a clipped move.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        return true
    }

    static func encode(_ rect: CGRect) -> String {
        "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))"
    }

    static func decode(_ s: String) -> CGRect? {
        let parts = s.split(separator: ",")
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let w = Double(parts[2]),
              let h = Double(parts[3]) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Private helpers

    private static func containingWindow(of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &ref) == .success,
           let ref = ref {
            return (ref as! AXUIElement)
        }
        // Fallback: walk parents until we find a window-role element.
        var current: AXUIElement? = element
        while let cur = current {
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &role) == .success,
               (role as? String) == kAXWindowRole as String {
                return cur
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success,
                  let parent = parent else { break }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref = ref else { return nil }
        return (ref as! AXUIElement)
    }

    private static func mainWindow(of app: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &ref) == .success,
              let ref = ref else { return nil }
        return (ref as! AXUIElement)
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef = posRef, let sizeRef = sizeRef else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
}
