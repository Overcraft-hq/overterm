import Combine
import Darwin
import Foundation

/// What a pill, Tab Info and the palette say of a forward (`ListeningPort.forward`).
package struct KubeForwardPill: Hashable, Sendable {
    package var id: UUID
    package var context: String
    package var namespace: String
    /// `svc/web`.
    package var target: String
    /// The pod it is pinned to.
    package var pod: String?
    package var https: Bool
    package var forwarding: Bool
    package var production: Bool
    package var state: String

    package init(id: UUID, context: String, namespace: String, target: String, pod: String? = nil, https: Bool, forwarding: Bool, production: Bool, state: String) {
        self.id = id
        self.context = context
        self.namespace = namespace
        self.target = target
        self.pod = pod
        self.https = https
        self.forwarding = forwarding
        self.production = production
        self.state = state
    }
}
