//
//  util.swift
//  AIMacro
//
//  Created by Kiyong Kim on 7/2/25.
//
import Foundation
import AppKit
import ScreenCaptureKit
import Vision
import CoreGraphics

func keyCodeToNumber(_ keyCode: Int) -> String? {
    let keyMap: [Int: String] = [
        18: "1",
        19: "2",
        20: "3",
        21: "4",
        23: "5",
        22: "6",
        26: "7",
        28: "8",
        25: "9",
        29: "0"
    ]
    return keyMap[keyCode]
}

func runAppleScript(_ script: String) {
    let command = "osascript -e \"\(script.replacingOccurrences(of: "\"", with: "\\\""))\""
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-c", command]
    try? task.run()
}

func setChromeURL(_ url: String) {
    let appleScript = """
    tell application "Google Chrome"
        if not (exists window 1) then
            make new window
        end if
        set URL of front window's active tab to "\(url)"
        activate
    end tell
    """
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", appleScript]
    try? task.run()
}

func openNewChromeWindow(_ url: String) {
    // Always creates a new window (vs. setChromeURL which only creates one if
    // none exists). If url is empty the window opens at the new-tab page.
    let urlClause = url.isEmpty
        ? ""
        : "set URL of active tab of front window to \"\(url)\""
    let appleScript = """
    tell application "Google Chrome"
        activate
        make new window
        \(urlClause)
    end tell
    """
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", appleScript]
    try? task.run()
}

func runJavaScriptInChromeBase64(_ jsCode: String) {
    // Base64 인코딩
    let base64 = Data(jsCode.utf8).base64EncodedString()
    let payload = "eval(atob(\"\(base64)\"))"

    let escapedPayload = payload
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")

    let appleScript = """
    tell application "Google Chrome"
        if not (exists window 1) then return
        execute front window's active tab javascript \"\(escapedPayload)\"
    end tell
    """

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", appleScript]
    try? task.run()
}

func printAllScreenSizes() {
    for (index, screen) in NSScreen.screens.enumerated() {
        let frame = screen.frame
        print("Screen \(index): origin = \(frame.origin), size = \(frame.size)")
    }
}

func convertToQuartzCoords(_ point: CGPoint) -> CGPoint {
    for (_, screen) in NSScreen.screens.enumerated() {
        let frame = screen.frame
        if frame.contains(point) {
            return CGPoint(x: point.x, y: frame.height - point.y)
        }
    }
    return point
}


/// Wall-clock-anchored one-shot scheduler. Replacement for the previous
/// DispatchSource-based timer, which used `.now()` (mach uptime) and so
/// effectively paused during system sleep — a job scheduled for 9:00 AM
/// across an overnight sleep would fire (sleep duration) late after wake.
///
/// This implementation:
///   * uses `Timer.scheduledTimer(withTimeInterval:repeats:)`, which is
///     wall-clock based,
///   * additionally re-anchors itself on `NSWorkspace.didWakeNotification`,
///     so if the deadline passed during sleep we fire immediately on wake,
///   * fires at most once and is cancellable via `cancel()`.
final class WallClockScheduler {
    private let target: Date
    private var action: (() -> Void)?
    private var timer: Timer?
    private var wakeObserver: Any?

    init(at target: Date, action: @escaping () -> Void) {
        self.target = target
        self.action = action
        scheduleTimer()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleTimer()
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = target.timeIntervalSinceNow
        if interval <= 0 {
            fire()
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fire()
        }
    }

    private func fire() {
        guard let action = action else { return }
        self.action = nil   // single-shot
        cancelObservers()
        action()
    }

    func cancel() {
        action = nil
        cancelObservers()
    }

    private func cancelObservers() {
        timer?.invalidate()
        timer = nil
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
    }

    deinit { cancelObservers() }
}

func scheduleTask(at targetDate: Date, action: @escaping () -> Void) -> WallClockScheduler? {
    let interval = targetDate.timeIntervalSinceNow
    guard interval > 0 else {
        print("Target time is in the past!")
        action()
        return nil
    }
    return WallClockScheduler(at: targetDate, action: action)
}

func convertToScreenLocalCoords(_ point: CGPoint) -> (screen: NSScreen, localPoint: CGPoint)? {
    for screen in NSScreen.screens {
        let frame = screen.frame
        if frame.contains(point) {
            let localX = point.x - frame.origin.x
            let localY = point.y - frame.origin.y
            return (screen, CGPoint(x: localX, y: localY))
        }
    }
    return nil // Point is outside all known screens
}


func recognizeText(from cgImage: CGImage,
                   customWords: [String] = [],
                   completion: @escaping ([(String?, CGRect)]) -> Void) {
    let request = VNRecognizeTextRequest { request, error in
        guard let results = request.results as? [VNRecognizedTextObservation], error == nil else {
            completion([])  // 실패 시 빈 배열 반환
            return
        }

        let texts: [(String?, CGRect)] = results.compactMap { observation in
            (observation.topCandidates(1).first?.string, convertBoundingBox(observation.boundingBox, imageSize: .init(width: cgImage.width, height: cgImage.height)))
        }
        completion(texts)
    }

    // 🔸 한국어 + 영어 인식 설정
    request.recognitionLanguages = ["ko-KR", "en-US"]
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    // OCR 액션의 타겟 텍스트를 customWords 로 등록하면 Vision 이 비슷한
    // 글자(예: 약/악) 사이에서 등록된 단어를 우선 인식.
    if !customWords.isEmpty {
        request.customWords = customWords
    }
    
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try handler.perform([request])
        } catch {
            print("Text recognition failed: \(error)")
            completion([])
        }
    }
}

func convertBoundingBox(_ box: CGRect, imageSize: CGSize) -> CGRect {
    return CGRect(
        x: box.origin.x * imageSize.width,
        y: (1 - box.origin.y - box.height) * imageSize.height, // y축 반전
        width: box.width * imageSize.width,
        height: box.height * imageSize.height
    )
}

func setPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

extension NSImage {
    func toCGImage() -> CGImage? {

        // bitmapRep을 얻기 위해 NSImage에서 TIFF 데이터 추출
        guard let tiffData = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.cgImage
    }
}

extension CGRect {
    func center() -> CGPoint {
        return CGPoint(x: midX, y: midY)
    }
}

// MARK: - Hangul-aware fuzzy substring match
//
// Used by the OCR matcher: returns true if `target` appears in `candidate`
// with at most ONE Hangul syllable that differs by at most ONE jamo
// (초/중/종성). Non-Hangul characters must match exactly. No insertions or
// deletions — lengths must align.

/// Decompose a Hangul syllable scalar into its (초성, 중성, 종성) jamo
/// indices. Returns nil for non-syllable codepoints.
private func decomposeHangulSyllable(_ scalar: Unicode.Scalar) -> (Int, Int, Int)? {
    let v = Int(scalar.value)
    guard v >= 0xAC00 && v <= 0xD7A3 else { return nil }
    let i = v - 0xAC00
    return (i / (21 * 28),     // 초성  (0..18)
            (i / 28) % 21,     // 중성  (0..20)
            i % 28)            // 종성  (0..27, 0=종성 없음)
}

/// True if `t` and `c` differ by exactly one jamo and both are Hangul
/// syllables. Used to allow a single 초/중/종성 typo (e.g. 약/악, 예/얘).
private func differsByOneJamo(_ t: Character, _ c: Character) -> Bool {
    guard let ts = t.unicodeScalars.first, let cs = c.unicodeScalars.first,
          let td = decomposeHangulSyllable(ts),
          let cd = decomposeHangulSyllable(cs) else { return false }
    let diff = (td.0 != cd.0 ? 1 : 0)
             + (td.1 != cd.1 ? 1 : 0)
             + (td.2 != cd.2 ? 1 : 0)
    return diff == 1
}

/// True if `target` is contained in `candidate` allowing at most ONE
/// character to differ — and if it does, that single character must be a
/// Hangul syllable that differs from the target's by exactly one jamo.
func fuzzyHangulContains(_ candidate: String, target: String) -> Bool {
    let cChars = Array(candidate)
    let tChars = Array(target)
    guard !tChars.isEmpty else { return true }
    guard tChars.count <= cChars.count else { return false }

    let lastStart = cChars.count - tChars.count
    for start in 0...lastStart {
        var allowance = 1
        var matched = true
        for j in 0..<tChars.count {
            let c = cChars[start + j]
            let t = tChars[j]
            if c == t { continue }
            if allowance > 0 && differsByOneJamo(t, c) {
                allowance -= 1
                continue
            }
            matched = false
            break
        }
        if matched { return true }
    }
    return false
}

