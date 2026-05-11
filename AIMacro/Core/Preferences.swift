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

    /// UUID string of the scenario the user had selected when the app last
    /// quit. Used to restore the popup selection on launch (we use id rather
    /// than index so renames/reorders don't break the restore).
    static var lastScenarioId: String? {
        get { UserDefaults.standard.string(forKey: "lastScenarioId") }
        set { UserDefaults.standard.set(newValue, forKey: "lastScenarioId") }
    }
}
