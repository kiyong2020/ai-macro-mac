//
//  Preferences.swift
//  AIMacro
//
//  Lightweight persisted user preferences. UserDefaults-backed.
//

import Foundation

enum Preferences {
    /// Maximum extra random delay (seconds) added on top of each action's
    /// configured delay. The actual extra is uniformly sampled in [0, max].
    /// Set to 0 to disable the randomization entirely.
    static var maxRandomDelay: Double {
        get { UserDefaults.standard.double(forKey: "maxRandomDelay") }
        set { UserDefaults.standard.set(max(0, newValue), forKey: "maxRandomDelay") }
    }

    /// Global base delay (seconds) added before every action runs, on top
    /// of the action's own configured delay. Lets the user globally slow
    /// down (or pad) a macro without editing each action individually.
    /// Set to 0 to disable.
    static var defaultActionDelay: Double {
        get { UserDefaults.standard.double(forKey: "defaultActionDelay") }
        set { UserDefaults.standard.set(max(0, newValue), forKey: "defaultActionDelay") }
    }

    /// UUID string of the scenario the user had selected when the app last
    /// quit. Used to restore the popup selection on launch (we use id rather
    /// than index so renames/reorders don't break the restore).
    static var lastScenarioId: String? {
        get { UserDefaults.standard.string(forKey: "lastScenarioId") }
        set { UserDefaults.standard.set(newValue, forKey: "lastScenarioId") }
    }

    /// Whether the bottom log view is expanded. Persisted so the user's
    /// preferred layout survives relaunches. Default: closed — log only
    /// shows what's happening during a run, so most of the time it's
    /// empty and the table view benefits from the extra vertical space.
    static var isLogOpen: Bool {
        get { (UserDefaults.standard.object(forKey: "isLogOpen") as? Bool) ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "isLogOpen") }
    }
}
