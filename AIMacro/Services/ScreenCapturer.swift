//
//  ScreenCapture.swift
//  AIMacro
//
//  Created by Kiyong Kim on 7/9/25.
//
import Cocoa
import ScreenCaptureKit
import CoreVideo

class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    var handler: ((NSImage?) -> Void)?

    /// Fraction of physical pixel resolution to capture at.
    /// 1.0 = logical (Retina 2x screen uses 1x pixels → 4× less memory, still fine for OCR)
    /// 2.0 = full physical Retina resolution
    var outputScale: CGFloat = 1.0

    /// Whether captured frames include the system cursor. Set to true for the
    /// live position-picker preview — without it SCStream may stop delivering
    /// frames while the user moves the mouse over a static region.
    var showsCursor: Bool = false

    /// Actual scale used for the current stream (set during start).
    private(set) var bufferScale: CGFloat = 1.0
    /// Actual capture rect after clamping to screen bounds (NSScreen coords, Y-up).
    private(set) var effectiveCaptureRect: CGRect = .zero

    private var stream: SCStream?
    private var targetScreen: NSScreen?
    private var captureRect: CGRect = .zero
    private var isStreaming = false
    /// Tracks the most recent in-flight stop so a subsequent start() can wait
    /// for the OS to fully tear down the previous SCStream before creating a
    /// new one — otherwise rapid stop/start (e.g. user hits Stop mid-OCR and
    /// runs again) leaves the new stream silently non-functional.
    private var pendingStop: Task<Void, Never>?

    func start(rect: CGRect) {
        guard !isStreaming else { return }

        guard CGPreflightScreenCaptureAccess() else {
            AppLogger.shared.log("⚠️ 화면 기록 권한이 없습니다. 시스템 설정에서 허용 후 앱을 재시작해주세요.")
            handler?(nil)
            return
        }

        self.captureRect = rect
        let waitForPriorStop = pendingStop
        Task {
            // Block until the previous stream has fully stopped at the OS
            // level. Without this, SCStream creation can succeed but never
            // deliver frames if the prior stream is still being torn down.
            await waitForPriorStop?.value
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

                guard let nsScreen = NSScreen.screens.first(where: { $0.frame.intersects(captureRect) }),
                      let screenNumber = nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                      let scDisplay = content.displays.first(where: { $0.displayID == screenNumber }) else {
                    let r = self.captureRect
                    let screensDesc = NSScreen.screens.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height))" }.joined(separator: " | ")
                    let msg = "❌ 캡처 영역 (\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))) 에 해당하는 화면이 없습니다. 모니터 구성: [\(screensDesc)]"
                    print(msg)
                    AppLogger.shared.log(msg)
                    handler?(nil)
                    return
                }

                let safeRect = clampedRect(for: rect, in: nsScreen)
                self.captureRect = safeRect
                self.effectiveCaptureRect = safeRect

                self.bufferScale = outputScale
                let config = SCStreamConfiguration()
                config.width = max(1, Int(CGFloat(scDisplay.width) * outputScale))
                config.height = max(1, Int(CGFloat(scDisplay.height) * outputScale))
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = self.showsCursor
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)

                let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

                self.targetScreen = nsScreen
                self.stream = SCStream(filter: filter, configuration: config, delegate: self)
                try self.stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                try await self.stream?.startCapture()

                self.isStreaming = true
                let r = self.effectiveCaptureRect
                AppLogger.shared.log("✅ 화면 캡처 시작 (\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)) on display \(scDisplay.displayID))")
            } catch {
                let msg = "⚠️ Stream error: \(error)"
                print(msg)
                AppLogger.shared.log(msg)
                handler?(nil)
            }
        }
    }

    func stop() {
        guard isStreaming else { return }
        print("🛑 Stopping screen stream.")
        let oldStream = stream
        stream = nil
        isStreaming = false
        targetScreen = nil
        handler = nil
        // Expose the stop completion so a subsequent start() can await it.
        pendingStop = Task {
            guard let oldStream = oldStream else { return }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                oldStream.stopCapture { error in
                    if let error = error {
                        print("❌ Error stopping stream: \(error)")
                    } else {
                        print("✅ Screen stream stopped.")
                    }
                    cont.resume()
                }
            }
        }
    }

    func updateCaptureRect(_ rect: CGRect) {
        self.captureRect = rect
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let screen = targetScreen else { return }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return
        }

        // Convert captureRect (logical points) → buffer pixel coordinates using bufferScale
        let scale = bufferScale
        let localX = (captureRect.origin.x - screen.frame.origin.x) * scale
        let localY = (captureRect.origin.y - screen.frame.origin.y) * scale
        let rectWidth = captureRect.width * scale
        let rectHeight = captureRect.height * scale
        let flippedY = CGFloat(height) - localY - rectHeight

        let rect = CGRect(x: Int(localX),
                          y: Int(flippedY),
                          width: Int(rectWidth),
                          height: Int(rectHeight)).integral

        // Drop frames whose target rect collapsed to zero in either dimension
        // — happens transiently when the cursor crosses a display boundary or
        // when a captureRect is clamped against a screen edge with no overlap.
        // CGContext init returns nil for non-positive width/height; force-
        // unwrapping there used to crash the app.
        guard rect.width > 0, rect.height > 0,
              let context = CGContext(data: nil,
                                      width: Int(rect.width),
                                      height: Int(rect.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: Int(rect.width) * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return
        }

        // Clamp the source read per row. Without this, a rect that extends
        // past the buffer's right edge keeps copying `rect.width * 4` bytes,
        // which silently wraps into the start of the next row — appearing as
        // the left edge of the same screen. Out-of-bounds destination pixels
        // stay zero (CGContext's allocated buffer is zero-initialized).
        let bufW = Int(width), bufH = Int(height)
        let rectX = Int(rect.origin.x), rectY = Int(rect.origin.y)
        let rectW = Int(rect.width), rectH = Int(rect.height)
        for row in 0..<rectH {
            let srcY = rectY + row
            if srcY < 0 || srcY >= bufH { continue }
            let srcXStart = max(0, rectX)
            let srcXEnd = min(bufW, rectX + rectW)
            if srcXEnd <= srcXStart { continue }
            let copyWidth = srcXEnd - srcXStart
            let dstXOffset = srcXStart - rectX
            let src = base.advanced(by: srcY * bytesPerRow + srcXStart * 4)
            let dst = context.data!.advanced(by: row * rectW * 4 + dstXOffset * 4)
            memcpy(dst, src, copyWidth * 4)
        }

        if let image = context.makeImage() {
            let nsImage = NSImage(cgImage: image, size: NSSize(width: rect.width, height: rect.height))
            handler?(nsImage)
        }

        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }
}

extension ScreenCapturer {
    /// One-shot off-main screenshot of a global-Quartz rect via
    /// `SCScreenshotManager`. Returns nil on missing display, denied
    /// permission, or any SC error. Safe to call from any thread —
    /// internally awaits on the SC cooperative pool, so callers on the
    /// main thread won't block (use the completion overload below to
    /// receive the result back on main).
    static func captureOnce(_ rect: CGRect) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(center) })
                              ?? content.displays.first else { return nil }
            let cfg = SCStreamConfiguration()
            cfg.width = max(1, Int(rect.width))
            cfg.height = max(1, Int(rect.height))
            cfg.sourceRect = CGRect(x: rect.minX - display.frame.minX,
                                    y: rect.minY - display.frame.minY,
                                    width: rect.width, height: rect.height)
            cfg.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg)
        } catch {
            return nil
        }
    }

    /// Same as `captureOnce(_:)` but delivers the result on the main
    /// thread. Use from main-thread (RunLoop) call sites that need to
    /// touch UI state with the captured image.
    static func captureOnce(_ rect: CGRect,
                            completion: @escaping (CGImage?) -> Void) {
        Task.detached(priority: .userInitiated) {
            let img = await captureOnce(rect)
            await MainActor.run { completion(img) }
        }
    }
}

func clampedRect(for rect: CGRect, in screen: NSScreen) -> CGRect {
    let screenFrame = screen.frame

    let x = max(rect.origin.x, screenFrame.origin.x)
    let y = max(rect.origin.y, screenFrame.origin.y)

    let maxX = min(rect.maxX, screenFrame.maxX)
    let maxY = min(rect.maxY, screenFrame.maxY)

    let width = max(0, maxX - x)
    let height = max(0, maxY - y)

    return CGRect(x: x, y: y, width: width, height: height)
}
