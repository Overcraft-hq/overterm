import Foundation

/// Activity's hooks into the shell under it (`FeatureHooks`): its agents'
/// `port_` and `proc_` reads, offered last.
package enum ActivityFeature {
    package static func install() {
        BrowserMCP.featuresStorage.append(
            BrowserMCP.Provider(
                handles: { ActivityMCP.handles($0) }, enabled: { $0.activityAgentAccess },
                unavailable: "Processes and ports aren't available to agents — Settings ▸ Activity.",
                tools: { ActivityMCP.tools }, instructions: { _ in ActivityMCP.instructions },
                call: { name, arguments, context in try await ActivityMCP.call(name, arguments, pane: context.pane) },
                said: { ActivityMCP.scrubbed($0.localizedDescription) }))
    }
}
