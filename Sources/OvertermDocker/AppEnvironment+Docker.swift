import Foundation

/// Kept with the feature it is for; AppEnvironment holds the shell's.
extension AppEnvironment {
    /// Docker's engine: OVERTERM_DOCKER_HOST's (a scenario's fake engine),
    /// else the one the user's `docker` reaches (or `docker.endpoint`'s, the
    /// setting, when not empty). An isolated run without the variable
    /// reaches none: a scenario must never list the user's containers, let
    /// alone stop one.
    package static func dockerEndpoint(setting: String = "", context: String = "") -> DockerEndpoint? {
        if let host = env["OVERTERM_DOCKER_HOST"], !host.isEmpty {
            return DockerEndpoint(address: DockerEndpoint.address(of: host), context: nil, source: "OVERTERM_DOCKER_HOST")
        }
        if isIsolated { return nil }
        if !setting.isEmpty { return DockerEndpoint(address: DockerEndpoint.address(of: setting), context: nil, source: "docker.endpoint") }
        if !context.isEmpty, let chosen = DockerEndpoint.chosen(context: context) { return chosen }
        return DockerEndpoint.current()
    }
}
