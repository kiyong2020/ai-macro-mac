//
//  RunCoordinator.swift
//  AIMacro
//
//  Process-wide serializer for macro runs across multiple windows.
//  Only one window can hold the mouse/keyboard input lock at a time;
//  others enqueue and start when the active runner finishes.
//

import Foundation
import RxSwift

final class RunCoordinator {
    static let shared = RunCoordinator()

    /// One queued/running entry. `proceed` is invoked on the main thread
    /// when this window becomes the active runner — the window then drives
    /// its `AutomationRunner.run(_:)` and calls `finish(token:)` afterwards.
    final class Token {
        let id = UUID()
        let scenarioId: String
        weak var owner: AnyObject?
        let proceed: () -> Void
        init(scenarioId: String, owner: AnyObject?, proceed: @escaping () -> Void) {
            self.scenarioId = scenarioId
            self.owner = owner
            self.proceed = proceed
        }
    }

    /// UUID of the scenario currently being executed (nil = idle).
    /// Windows displaying this scenario disable edits.
    let activeScenarioId = BehaviorSubject<String?>(value: nil)

    /// Snapshot of the queue (excluding the active entry). Each window
    /// uses this to render "대기 중 (N번째)" labels.
    let queueDidChange = PublishSubject<Void>()

    private var active: Token?
    private var queue: [Token] = []
    private let lock = NSLock()

    private init() {}

    /// Ask to run. If no one's running, `proceed` fires immediately on the
    /// main queue and `active` is set. Otherwise the request is appended
    /// and `proceed` will fire later when the active run finishes.
    /// Returns the token so callers can cancel a queued (or active) entry.
    @discardableResult
    func requestRun(scenarioId: String,
                    owner: AnyObject,
                    proceed: @escaping () -> Void) -> Token {
        let token = Token(scenarioId: scenarioId, owner: owner, proceed: proceed)
        lock.lock()
        let startNow = (active == nil)
        if startNow {
            active = token
        } else {
            queue.append(token)
        }
        lock.unlock()

        if startNow {
            activeScenarioId.onNext(scenarioId)
            DispatchQueue.main.async { proceed() }
        } else {
            queueDidChange.onNext(())
        }
        return token
    }

    /// Called by the active window when its run completes (success or stop).
    /// Pops the next token off the queue and starts it. Owners whose window
    /// closed mid-wait are skipped.
    func finish(token: Token) {
        lock.lock()
        guard active?.id == token.id else { lock.unlock(); return }
        active = nil
        var next: Token? = nil
        while let candidate = popNextOwnedLocked() {
            next = candidate
            active = candidate
            break
        }
        lock.unlock()

        if let next = next {
            activeScenarioId.onNext(next.scenarioId)
            queueDidChange.onNext(())
            DispatchQueue.main.async { next.proceed() }
        } else {
            activeScenarioId.onNext(nil)
            queueDidChange.onNext(())
        }
    }

    /// Cancel a token. If it's active, behaves like `finish` (pops the next).
    /// If it's queued, removes it without running.
    func cancel(token: Token) {
        lock.lock()
        if active?.id == token.id {
            lock.unlock()
            finish(token: token)
            return
        }
        let before = queue.count
        queue.removeAll { $0.id == token.id }
        let changed = queue.count != before
        lock.unlock()
        if changed { queueDidChange.onNext(()) }
    }

    /// Cancel every pending (queued) token belonging to a given owner.
    /// Called when a window closes so its queued entries don't linger.
    func cancelAllPending(for owner: AnyObject) {
        lock.lock()
        let before = queue.count
        queue.removeAll { $0.owner === owner || $0.owner == nil }
        let changed = queue.count != before
        lock.unlock()
        if changed { queueDidChange.onNext(()) }
    }

    /// Snapshot of the queue (excluding the active entry) for UI display.
    func pendingTokens() -> [Token] {
        lock.lock(); defer { lock.unlock() }
        return queue
    }

    /// Returns the position (1-based) of `token` in the pending queue,
    /// or nil if it's active or no longer present.
    func queuePosition(of token: Token) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let idx = queue.firstIndex(where: { $0.id == token.id }) else { return nil }
        return idx + 1
    }

    // Pops the next live (still-owned) token, dropping orphaned entries
    // whose owning window has gone away.
    private func popNextOwnedLocked() -> Token? {
        while !queue.isEmpty {
            let head = queue.removeFirst()
            if head.owner != nil { return head }
        }
        return nil
    }
}
