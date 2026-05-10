import Cocoa
import Quartz

class MouseListener {

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRunning = false

    var onMouseDown: ((CGPoint, CGEventType) -> Void)?

    /// When true, both left- and right-mouse-down events are consumed
    /// (return nil from the tap callback) instead of being delivered to the
    /// app underneath. The position pickers turn this on so the click that
    /// confirms a coordinate doesn't also activate whatever the cursor is
    /// hovering (a button, a link, a context menu, etc.).
    var consumesAllClicks: Bool = false

    // MARK: - Start listening
    func start() {
        guard !isRunning else { return }

        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                                 (1 << CGEventType.rightMouseDown.rawValue)

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mouseEventCallback,
            userInfo: selfPointer
        )

        guard let eventTap = eventTap else {
            print("Failed to create event tap. Check Accessibility permissions.")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        isRunning = true
        print("Mouse listener started.")
    }

    // MARK: - Stop listening
    func stop() {
        guard isRunning else { return }

        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if let eventTap = eventTap {
            CFMachPortInvalidate(eventTap)
        }

        self.runLoopSource = nil
        self.eventTap = nil
        isRunning = false
        print("Mouse listener stopped.")
    }

    deinit {
        stop()
    }
}

// MARK: - Global Callback

private func mouseEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }
    let listener = Unmanaged<MouseListener>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .leftMouseDown || type == .rightMouseDown {
        listener.onMouseDown?(event.location, type)
    }
    if (type == .leftMouseDown || type == .rightMouseDown) && listener.consumesAllClicks {
        return nil   // swallow the click while picking a position
    }
    return Unmanaged.passRetained(event)
}
