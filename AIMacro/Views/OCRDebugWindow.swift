//
//  OCRDebugWindow.swift
//  AIMacro
//
//  Floating debug window that displays the live OCR capture frame and the
//  text it recognised. Used while developing/tuning OCR actions.
//

import Cocoa

final class OCRDebugWindow {
    static let shared = OCRDebugWindow()

    private lazy var window: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 360, height: 420),
                         styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                         backing: .buffered,
                         defer: false)
        w.title = L("Text Recognition Debug")
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.contentView = buildContent()
        return w
    }()

    private let targetLabel = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let resultsView = NSTextView()

    private init() {}

    private func buildContent() -> NSView {
        let content = NSView()

        targetLabel.translatesAutoresizingMaskIntoConstraints = false
        targetLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        targetLabel.lineBreakMode = .byTruncatingTail

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.borderColor = NSColor.systemYellow.withAlphaComponent(0.5).cgColor
        imageView.layer?.borderWidth = 1

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        resultsView.isEditable = false
        resultsView.isSelectable = true
        resultsView.font = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        resultsView.backgroundColor = .textBackgroundColor
        resultsView.textColor = .labelColor
        resultsView.textContainerInset = NSSize(width: 4, height: 4)
        resultsView.autoresizingMask = [.width]
        resultsView.isVerticallyResizable = true
        resultsView.isHorizontallyResizable = false
        resultsView.textContainer?.widthTracksTextView = true
        scrollView.documentView = resultsView

        content.addSubview(targetLabel)
        content.addSubview(imageView)
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            targetLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            targetLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            targetLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),

            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            imageView.topAnchor.constraint(equalTo: targetLabel.bottomAnchor, constant: 8),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        return content
    }

    // MARK: - Public API

    /// Show the window with the search target highlighted.
    func show(target: String) {
        guard Constants.showOCRDebugWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.targetLabel.stringValue = "찾는 글자: \"\(target)\""
            self.imageView.image = nil
            self.resultsView.string = ""
            self.window.orderFrontRegardless()
        }
    }

    /// Update the captured frame and recognised-text list.
    func update(image: NSImage, results: [(String?, CGRect)], target: String) {
        guard Constants.showOCRDebugWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.imageView.image = image
            let lines = results.map { (text, rect) -> String in
                let marker = (text == target) ? "✓" : " "
                let t = text ?? "?"
                return "\(marker) \(t)  [\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))]"
            }
            self.resultsView.string = lines.isEmpty ? "(인식된 글자 없음)" : lines.joined(separator: "\n")
        }
    }

    /// Scored variant used by the OCR matcher: each entry already carries its
    /// similarity score against the target, plus a flag indicating whether
    /// it's the chosen one. Sorted by score descending in the display.
    struct ScoredResult {
        let text: String
        let box: CGRect
        let score: Double
        let isMatch: Bool
        let merged: Bool
    }

    func updateScored(image: NSImage, results: [ScoredResult], target: String) {
        guard Constants.showOCRDebugWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.imageView.image = image
            let sorted = results.sorted { $0.score > $1.score }
            let lines = sorted.map { r -> String in
                let marker = r.isMatch ? "✓" : (r.merged ? "+" : " ")
                let pct = String(format: "%.2f", r.score)
                return "\(marker) [\(pct)] \(r.text)  [\(Int(r.box.minX)),\(Int(r.box.minY)) \(Int(r.box.width))×\(Int(r.box.height))]"
            }
            self.resultsView.string = lines.isEmpty ? "(인식된 글자 없음)" : lines.joined(separator: "\n")
        }
    }

    /// Show an error message in place of the recognised-text list. Used when
    /// the screen capture fails (e.g. point recorded on a screen no longer
    /// connected, or permission missing).
    func showError(_ message: String) {
        guard Constants.showOCRDebugWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.imageView.image = nil
            self.resultsView.string = "⚠️ \(message)"
        }
    }

    /// Always safe to call; idempotent if the window was never shown.
    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.window.orderOut(nil)
        }
    }
}
