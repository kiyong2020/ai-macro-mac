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

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private init() {}

    func log(_ message: String) {
        let ts = Self.formatter.string(from: Date())
        let line = "[\(ts)] \(message)"
        print(line)
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
