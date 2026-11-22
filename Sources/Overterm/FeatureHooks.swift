import Foundation
import SwiftUI

/// What the shell asks of a feature it sits under and so can't name — a
/// tab's Kubernetes badge, an editor buffer's Terraform formatting. Each
/// feature module sets its own hooks once, in `OvertermFeatures.install`
/// (OvertermShell, Features.swift), which is looked up by name the first
/// time a hook is read: the app and a unit test (which never runs
/// AppMain) get them alike. Read a hook through its accessor, never its
/// storage; `install` sets only storage, so nothing it does reads one.
package enum FeatureHooks {
    private static let installed: Void = {
        if let features = NSClassFromString("OvertermFeatures") {
            _ = (features as AnyObject).perform(NSSelectorFromString("install"))
        }
    }()

    package static func ensure() { _ = installed }
}

/// The red the Kubernetes page draws production in, wherever the shell
/// says production too (a tab pinned to it).
package enum ProductionColor {
    package static let color = Color(red: 0.86, green: 0.17, blue: 0.17)
    /// A held change's and an edited object's banner (`KubeResourceBanner`).
    package static let warning = Color(red: 0.93, green: 0.6, blue: 0.2)
}
