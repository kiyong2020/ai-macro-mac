import Cocoa

// Floating overlay that highlights the screen that will be OCR-scanned.
// Shown while the user is picking a position for an OCR action.
class ScanPreviewPanel: NSPanel {
    static let shared = ScanPreviewPanel()

    private let previewView = ScanPreviewView()
    private var moveMonitor: Any?
    private var localMoveMonitor: Any?
    /// Logical-point size of the highlighted area. Square for the OCR scan
    /// preview (default = `Constants.ocrCaptureSize`), arbitrary W×H for the
    /// `.openBrowser` window-position picker.
    private var size: CGSize = CGSize(width: Constants.ocrCaptureSize,
                                      height: Constants.ocrCaptureSize)

    private init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true   // clicks pass through to MouseListener's CGEvent tap
        previewView.wantsLayer = true
        previewView.layer?.isOpaque = false
        contentView = previewView
    }

    /// Square preview convenience — used by the OCR position picker.
    func show(size: CGFloat = Constants.ocrCaptureSize) {
        show(rectSize: CGSize(width: size, height: size))
    }

    /// Rectangular preview — used by the `.openBrowser` position picker so the
    /// floating overlay matches the user-entered window size.
    func show(rectSize: CGSize) {
        self.size = CGSize(width: max(20, rectSize.width),
                           height: max(20, rectSize.height))
        orderFrontRegardless()
        updatePosition(NSEvent.mouseLocation)

        // Global: fires when mouse is over another app's window
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async { self?.updatePosition(NSEvent.mouseLocation) }
        }
        // Local: fires when mouse is over this app's own window
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updatePosition(NSEvent.mouseLocation)
            return event
        }
    }

    func hide() {
        if let m = moveMonitor { NSEvent.removeMonitor(m) }
        if let m = localMoveMonitor { NSEvent.removeMonitor(m) }
        moveMonitor = nil
        localMoveMonitor = nil
        orderOut(nil)
    }

    private func updatePosition(_ nsPoint: CGPoint) {
        let halfW = size.width / 2
        let halfH = size.height / 2
        // Center the panel on the cursor in NSScreen coords (Y-up).
        let frame = CGRect(x: nsPoint.x - halfW, y: nsPoint.y - halfH,
                           width: size.width, height: size.height)
        setFrame(frame, display: true)
        previewView.needsDisplay = true
    }
}

private class ScanPreviewView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.clear(bounds)

        // Light tint so the capture area is distinguishable
        ctx.setFillColor(NSColor(white: 1, alpha: 0.08).cgColor)
        ctx.fill([bounds])

        // Yellow border — marks the exact OCR scan boundary. Center marker
        // removed because it overlaps the system mouse cursor anyway.
        ctx.setStrokeColor(NSColor.systemYellow.cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(bounds.insetBy(dx: 1.5, dy: 1.5))
    }
}
