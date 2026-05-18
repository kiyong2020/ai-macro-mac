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

/// Open `url` in whichever browser the user has set as the system default.
/// Behaviour mirrors clicking a hyperlink: the browser is launched if it's
/// not running, an existing window receives a new tab otherwise.
///
/// Auto-prepends `https://` when the input has no scheme — `URL(string:)`
/// accepts schemeless strings as relative URLs, which then resolve to nothing
/// and surface as "해당 응용 프로그램을 열 수 없습니다 -50" via Finder.
func openInDefaultBrowser(_ url: String) {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        AppLogger.shared.log("⚠️ URL 이 비어있습니다")
        return
    }

    let normalized: String
    if trimmed.range(of: "^[a-zA-Z][a-zA-Z0-9+.\\-]*://", options: .regularExpression) != nil {
        normalized = trimmed
    } else {
        normalized = "https://" + trimmed
    }

    guard let parsed = URL(string: normalized),
          let scheme = parsed.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
        AppLogger.shared.log("⚠️ 잘못된 URL: \(url)")
        return
    }
    NSWorkspace.shared.open(parsed)
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
    recognizeTextDetailed(from: cgImage, customWords: customWords, topN: 1) { observations in
        completion(observations.map { ($0.candidates.first, $0.box) })
    }
}

/// Single OCR observation with multiple candidate readings (in confidence
/// order). Use the richer form when you need fallbacks for fuzzy matching —
/// Vision's second/third guess often hits where the first one misreads a
/// single jamo.
struct OCRObservation {
    let candidates: [String]
    let box: CGRect
}

func recognizeTextDetailed(from cgImage: CGImage,
                           customWords: [String] = [],
                           topN: Int = 3,
                           completion: @escaping ([OCRObservation]) -> Void) {
    let request = VNRecognizeTextRequest { request, error in
        guard let results = request.results as? [VNRecognizedTextObservation], error == nil else {
            completion([])
            return
        }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let observations: [OCRObservation] = results.map { obs in
            let strings = obs.topCandidates(topN).map { $0.string }
            return OCRObservation(
                candidates: strings,
                box: convertBoundingBox(obs.boundingBox, imageSize: imageSize)
            )
        }
        completion(observations)
    }

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

// MARK: - Shape-weighted similarity
//
// Score 0…1 of how close two strings are. OCR errors are visual, so each
// substitution is weighted by how alike the two characters *look* — not by
// general edit distance. Visually-similar Hangul jamo (ㅏ↔ㅑ, ㅁ↔ㅂ) and
// confusable Latin/digit pairs (O↔0, l↔I↔1) cost a fraction of an unrelated
// swap. Whitespace is dropped because OCR invents or swallows spaces.
//
// Encoding scheme (set by `decomposeForSimilarity`):
//   0…18     → 초성 (initial) index
//   100…120  → 중성 (medial) index + 100
//   201…227  → 종성 (final) index + 200 (0/no-jongseong is omitted)
//   1000+x   → non-Hangul scalar x

private func decomposeForSimilarity(_ s: String) -> [Int] {
    var out: [Int] = []
    out.reserveCapacity(s.count * 3)
    for ch in s where !ch.isWhitespace {
        if let sc = ch.unicodeScalars.first,
           let d = decomposeHangulSyllable(sc) {
            out.append(d.0)
            out.append(100 + d.1)
            if d.2 != 0 { out.append(200 + d.2) }
        } else {
            for sc in ch.unicodeScalars { out.append(1000 + Int(sc.value)) }
        }
    }
    return out
}

/// Pair of encoded jamo/scalar codes, order-independent.
private struct ShapeConfusionPair: Hashable {
    let lo: Int
    let hi: Int
    init(_ x: Int, _ y: Int) {
        self.lo = min(x, y)
        self.hi = max(x, y)
    }
}

/// Table of visually-confusable pairs → substitution cost (0…1).
/// Lower number = more similar shapes = OCR is more likely to confuse them.
private let shapeConfusionCosts: [ShapeConfusionPair: Double] = [
    // ── 초성 (0…18) ─────────────────────────────────────────────
    .init(6, 7):   0.20,   // ㅁ ↔ ㅂ
    .init(6, 17):  0.25,   // ㅁ ↔ ㅍ
    .init(7, 17):  0.20,   // ㅂ ↔ ㅍ
    .init(0, 15):  0.20,   // ㄱ ↔ ㅋ
    .init(3, 16):  0.20,   // ㄷ ↔ ㅌ
    .init(12, 14): 0.20,   // ㅈ ↔ ㅊ
    .init(2, 5):   0.30,   // ㄴ ↔ ㄹ
    .init(11, 18): 0.30,   // ㅇ ↔ ㅎ
    .init(0, 1):   0.15,   // ㄱ ↔ ㄲ (doubled)
    .init(7, 8):   0.15,   // ㅂ ↔ ㅃ
    .init(9, 10):  0.15,   // ㅅ ↔ ㅆ
    .init(3, 4):   0.15,   // ㄷ ↔ ㄸ
    .init(12, 13): 0.15,   // ㅈ ↔ ㅉ

    // ── 중성 (100…120) ──────────────────────────────────────────
    .init(100, 102): 0.20, // ㅏ ↔ ㅑ
    .init(104, 106): 0.20, // ㅓ ↔ ㅕ
    .init(108, 112): 0.20, // ㅗ ↔ ㅛ
    .init(113, 117): 0.20, // ㅜ ↔ ㅠ
    .init(101, 103): 0.20, // ㅐ ↔ ㅒ
    .init(105, 107): 0.20, // ㅔ ↔ ㅖ
    .init(118, 119): 0.25, // ㅡ ↔ ㅢ
    .init(100, 104): 0.40, // ㅏ ↔ ㅓ (mirrored)
    .init(108, 113): 0.40, // ㅗ ↔ ㅜ (mirrored)
    .init(101, 105): 0.30, // ㅐ ↔ ㅔ
    .init(103, 107): 0.30, // ㅒ ↔ ㅖ
    .init(118, 120): 0.40, // ㅡ ↔ ㅣ (rotated)
    .init(109, 114): 0.40, // ㅘ ↔ ㅝ
    .init(100, 120): 0.45, // ㅏ ↔ ㅣ (vertical stroke + horizontal stub vs bare vertical)

    // ── 종성 (201…227) ──────────────────────────────────────────
    .init(201, 224): 0.20, // 종ㄱ ↔ 종ㅋ
    .init(207, 225): 0.20, // 종ㄷ ↔ 종ㅌ
    .init(217, 226): 0.20, // 종ㅂ ↔ 종ㅍ
    .init(221, 227): 0.30, // 종ㅇ ↔ 종ㅎ
    .init(204, 208): 0.30, // 종ㄴ ↔ 종ㄹ
    .init(216, 217): 0.25, // 종ㅁ ↔ 종ㅂ
    .init(216, 221): 0.30, // 종ㅁ ↔ 종ㅇ
    .init(201, 202): 0.15, // 종ㄱ ↔ 종ㄲ
    .init(219, 220): 0.15, // 종ㅅ ↔ 종ㅆ

    // ── Latin / digit (1000 + scalar) ───────────────────────────
    .init(1000 + 0x4F, 1000 + 0x30): 0.20, // O ↔ 0
    .init(1000 + 0x6F, 1000 + 0x30): 0.25, // o ↔ 0
    .init(1000 + 0x6F, 1000 + 0x4F): 0.10, // o ↔ O (case)
    .init(1000 + 0x6C, 1000 + 0x49): 0.20, // l ↔ I
    .init(1000 + 0x6C, 1000 + 0x31): 0.20, // l ↔ 1
    .init(1000 + 0x49, 1000 + 0x31): 0.20, // I ↔ 1
    .init(1000 + 0x53, 1000 + 0x35): 0.20, // S ↔ 5
    .init(1000 + 0x73, 1000 + 0x35): 0.30, // s ↔ 5
    .init(1000 + 0x42, 1000 + 0x38): 0.20, // B ↔ 8
    .init(1000 + 0x5A, 1000 + 0x32): 0.30, // Z ↔ 2
    .init(1000 + 0x7A, 1000 + 0x32): 0.30, // z ↔ 2
    .init(1000 + 0x47, 1000 + 0x36): 0.30, // G ↔ 6
    .init(1000 + 0x44, 1000 + 0x30): 0.30, // D ↔ 0
    .init(1000 + 0x63, 1000 + 0x65): 0.40, // c ↔ e
    .init(1000 + 0x75, 1000 + 0x76): 0.40, // u ↔ v
    .init(1000 + 0x69, 1000 + 0x6A): 0.40, // i ↔ j
    .init(1000 + 0x6E, 1000 + 0x68): 0.40, // n ↔ h
]

/// Visual substitution cost between two encoded codes. 0 means identical,
/// 1 means visually unrelated.
private func shapeSubstitutionCost(_ a: Int, _ b: Int) -> Double {
    if a == b { return 0 }
    // Cross-category swaps (e.g. 초성 ↔ 중성, jamo ↔ Latin) — always 1.0.
    if (a / 100) != (b / 100) { return 1.0 }
    if let cost = shapeConfusionCosts[ShapeConfusionPair(a, b)] { return cost }
    // ASCII case-insensitive fallback: same letter, different case → tiny cost.
    if a >= 1000 && b >= 1000 {
        let sa = a - 1000, sb = b - 1000
        let la = (sa >= 0x41 && sa <= 0x5A) ? sa + 32 : sa
        let lb = (sb >= 0x41 && sb <= 0x5A) ? sb + 32 : sb
        if la == lb { return 0.10 }
    }
    return 1.0
}

/// Insertion/deletion cost. ㅇ (silent initial / nasal final) is the most
/// frequent OCR drop-or-add, so its indel is discounted.
private func shapeIndelCost(_ x: Int) -> Double {
    if x == 11 { return 0.40 }   // 초성 ㅇ
    if x == 221 { return 0.50 }  // 종성 ㅇ
    return 1.0
}

private func shapeWeightedDistance(_ a: [Int], _ b: [Int]) -> Double {
    if a.isEmpty { return b.reduce(0.0) { $0 + shapeIndelCost($1) } }
    if b.isEmpty { return a.reduce(0.0) { $0 + shapeIndelCost($1) } }
    var prev = [Double](repeating: 0, count: b.count + 1)
    for j in 1...b.count { prev[j] = prev[j - 1] + shapeIndelCost(b[j - 1]) }
    var curr = [Double](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        curr[0] = prev[0] + shapeIndelCost(a[i - 1])
        for j in 1...b.count {
            let sub = prev[j - 1] + shapeSubstitutionCost(a[i - 1], b[j - 1])
            let del = prev[j] + shapeIndelCost(a[i - 1])
            let ins = curr[j - 1] + shapeIndelCost(b[j - 1])
            curr[j] = min(sub, min(del, ins))
        }
        swap(&prev, &curr)
    }
    return prev[b.count]
}

/// Returns 0…1 shape similarity between two strings. Higher = more visually
/// similar at the jamo / glyph level.
func hangulSimilarity(_ candidate: String, target: String) -> Double {
    let c = decomposeForSimilarity(candidate)
    let t = decomposeForSimilarity(target)
    if c.isEmpty && t.isEmpty { return 1.0 }
    if c.isEmpty || t.isEmpty { return 0.0 }
    let dist = shapeWeightedDistance(c, t)
    let maxLen = max(c.count, t.count)
    return 1.0 - dist / Double(maxLen)
}

/// Slides a window over `candidate` looking for the best-matching substring
/// against `target`. Useful when OCR captures the target embedded in extra
/// noise (e.g. "  예약하기 ▶" vs target "예약하기").
func bestSubstringSimilarity(_ candidate: String, target: String) -> Double {
    let cStripped = candidate.replacingOccurrences(of: " ", with: "")
    let tStripped = target.replacingOccurrences(of: " ", with: "")
    if tStripped.isEmpty { return 0.0 }
    if cStripped.count <= tStripped.count {
        return hangulSimilarity(cStripped, target: tStripped)
    }
    // Hard-coded slack: try window lengths within ±1 of the target so a
    // missing/extra char still gets compared as a near-match.
    let cArr = Array(cStripped)
    let tLen = tStripped.count
    let minLen = max(1, tLen - 1)
    let maxLen = min(cArr.count, tLen + 1)
    var best = 0.0
    for winLen in minLen...maxLen {
        let lastStart = cArr.count - winLen
        for start in 0...lastStart {
            let sub = String(cArr[start..<(start + winLen)])
            let score = hangulSimilarity(sub, target: tStripped)
            if score > best {
                best = score
                if best >= 0.999 { return best }
            }
        }
    }
    return best
}

