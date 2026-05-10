import Cocoa

// Floating overlay that highlights the screen that will be OCR-scanned.
// Shown while the user is picking a position for an OCR action.
class ScanPreviewPanel: NSPanel {
    static let shared = ScanPreviewPanel()

    private let previewView = ScanPreviewView()
    private var moveMonitor: Any?
    private var localMoveMonitor: Any?
    /// Side length (logical points) of the highlighted capture square.
    /// Defaults to `Constants.ocrCaptureSize` but can be overridden per-show.
    private var size: CGFloat = Constants.ocrCaptureSize

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

    func show(size: CGFloat = Constants.ocrCaptureSize) {
        self.size = max(20, size)
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
        let half = size / 2
        // Center the window on the cursor in NSScreen coords (Y-up)
        let frame = CGRect(x: nsPoint.x - half, y: nsPoint.y - half,
                           width: size, height: size)
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

        // Yellow border — marks the exact OCR scan boundary
        ctx.setStrokeColor(NSColor.systemYellow.cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(bounds.insetBy(dx: 1.5, dy: 1.5))

        // Crosshair at center (cursor is always centered inside this window)
        let cx = bounds.midX, cy = bounds.midY
        let len: CGFloat = 12
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: cx - len, y: cy)); ctx.addLine(to: CGPoint(x: cx + len, y: cy))
        ctx.move(to: CGPoint(x: cx, y: cy - len)); ctx.addLine(to: CGPoint(x: cx, y: cy + len))
        ctx.strokePath()
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: cx - 8, y: cy - 8, width: 16, height: 16))

        // Label at top of the box
        let label = "클릭하여 저장"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let strSize = str.size()
        let padding: CGFloat = 6
        let bgRect = CGRect(x: bounds.midX - strSize.width / 2 - padding,
                            y: bounds.maxY - strSize.height - padding * 2,
                            width: strSize.width + padding * 2,
                            height: strSize.height + padding)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.65).cgColor)
        ctx.fill([bgRect])
        str.draw(at: CGPoint(x: bgRect.origin.x + padding, y: bgRect.origin.y + padding / 2))
    }
}
