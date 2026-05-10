//
//  OCRSnapshotStore.swift
//  AIMacro
//
//  Persists per-action OCR scan-area snapshots as PNG files in
//  Application Support/AIMacro/snapshots/{action-id}.png. Used to
//  show a thumbnail of "what the action will see" at the bottom of the OCR
//  detail editor.
//

import Cocoa

extension Notification.Name {
    /// Posted (with `userInfo["id"] = action.id`) after a snapshot is saved
    /// or removed, so any visible image view can refresh.
    static let ocrSnapshotChanged = Notification.Name("ocrSnapshotChanged")
}

final class OCRSnapshotStore {
    static let shared = OCRSnapshotStore()

    private let directory: URL = {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("AIMacro/snapshots")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    private func url(for actionId: String) -> URL {
        directory.appendingPathComponent("\(actionId).png")
    }

    func save(_ image: NSImage, actionId: String) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let target = url(for: actionId)
        try? png.write(to: target)
        NotificationCenter.default.post(name: .ocrSnapshotChanged,
                                        object: nil,
                                        userInfo: ["id": actionId])
    }

    func load(actionId: String) -> NSImage? {
        let path = url(for: actionId)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return NSImage(contentsOf: path)
    }

    func delete(actionId: String) {
        try? FileManager.default.removeItem(at: url(for: actionId))
        NotificationCenter.default.post(name: .ocrSnapshotChanged,
                                        object: nil,
                                        userInfo: ["id": actionId])
    }
}
