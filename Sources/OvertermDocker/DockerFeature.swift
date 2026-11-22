import Foundation

/// Docker's part in the shell under it, set once (`OvertermFeatures`).
package enum DockerFeature {
    package static func install() {
        BrowserMCP.featuresStorage.append(
            BrowserMCP.Provider(
                handles: { $0.hasPrefix("docker_") }, enabled: { $0.dockerAgentAccess },
                unavailable: "Docker isn't available to agents — Settings ▸ Docker.",
                tools: { DockerMCP.tools }, instructions: { _ in DockerMCP.instructions },
                call: { name, arguments, _ in try await DockerMCP.call(name, arguments, docker: DockerModel.shared) }))
    }
}
