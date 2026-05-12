//
//  AppLogger.swift
//  AIMacro
//

import Foundation
import RxSwift

class AppLogger {
    static let shared = AppLogger()

    let logText = BehaviorSubject<String>(value: "")
    private var lines: [String] = []
    private let maxLines = 500
    /// When true, `log(_:)` appends to the on-screen buffer in addition to
    /// printing to the Xcode console. Toggled around an action sequence by
    /// `AutomationRunner` via `startSession` / `endSession` so the bottom
    /// log view only shows what's happening during a run; idle-state logs
    /// (action edits, permission requests, app launch) stay console-only.
    private var capturingForUI = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private init() {}

    /// Begin capturing for the on-screen log. Clears any prior contents so
    /// the visible log focuses on the current run.
    func startSession() {
        capturingForUI = true
        lines.removeAll()
        DispatchQueue.main.async {
            self.logText.onNext("")
        }
    }

    /// Stop appending to the on-screen log. Leaves the existing contents
    /// visible (frozen at the last run's state) until the next session.
    func endSession() {
        capturingForUI = false
    }

    func log(_ message: String) {
        let ts = Self.formatter.string(from: Date())
        let line = "[\(ts)] \(message)"
        print(line)
        guard capturingForUI else { return }
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        let text = lines.joined(separator: "\n")
        DispatchQueue.main.async {
            self.logText.onNext(text)
        }
    }
}
