//
//  Notifications.swift
//  AIMacro
//
//  Central definitions for in-app NotificationCenter messages, so the
//  AutomationRunner can broadcast lifecycle events without depending on every
//  component that wants to react to them.
//

import Foundation

extension Notification.Name {
    /// Posted by AutomationRunner immediately before an action sequence begins
    /// executing. Listeners use this to drop stale per-run state — cached
    /// verification codes, simulated-mouse positions, debug overlays, etc.
    static let actionSequenceWillStart = Notification.Name("actionSequenceWillStart")
}
