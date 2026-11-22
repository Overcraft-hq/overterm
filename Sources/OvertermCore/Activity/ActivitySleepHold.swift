import Foundation
import IOKit.pwr_mgt

/// What a process's power assertions keep awake (docs/design/activity/
/// analysis.md, 6.5's Preventing Sleep, 3.8): `IOPMCopyAssertionsByProcess`,
/// every user's, about 0.25 ms a read. Only the assertions' types are kept —
/// never their names, which are whatever the process wrote (a file, a URL).
package struct ActivitySleepHold: OptionSet, Hashable, Sendable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }

    /// The Mac: `PreventUserIdleSystemSleep`, `PreventSystemSleep`,
    /// `NoIdleSleepAssertion`.
    package static let system = ActivitySleepHold(rawValue: 1)
    /// The display: `PreventUserIdleDisplaySleep`, `NoDisplaySleepAssertion`.
    package static let display = ActivitySleepHold(rawValue: 2)

    /// An assertion type's part; nil for one that keeps nothing awake for
    /// long (`UserIsActive`, a declared activity) or isn't known.
    package static func of(type: String) -> ActivitySleepHold? {
        switch type {
        case "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion": .system
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": .display
        default: nil
        }
    }

    /// The column's words: "System, Display", "System", "Display".
    package var text: String {
        var words: [String] = []
        if contains(.system) { words.append("System") }
        if contains(.display) { words.append("Display") }
        return words.joined(separator: ", ")
    }

    /// The assertions by pid, their types read: pure, for the tests.
    package static func holds(_ assertions: [pid_t: [String]]) -> [pid_t: ActivitySleepHold] {
        var found: [pid_t: ActivitySleepHold] = [:]
        for (pid, types) in assertions {
            let hold = types.reduce(into: ActivitySleepHold()) { $0.formUnion(of(type: $1) ?? []) }
            if !hold.isEmpty { found[pid] = hold }
        }
        return found
    }

    /// The system's answer now; nil when refused.
    package static func read() -> [pid_t: ActivitySleepHold]? {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess, let dictionary = raw?.takeRetainedValue() as NSDictionary? else { return nil }
        var assertions: [pid_t: [String]] = [:]
        for (key, value) in dictionary {
            guard let pid = (key as? NSNumber)?.int32Value, let list = value as? [NSDictionary] else { continue }
            assertions[pid] = list.compactMap { $0[kIOPMAssertionTypeKey as String] as? String }
        }
        return holds(assertions)
    }
}
