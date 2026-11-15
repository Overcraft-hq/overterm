import Foundation

/// What the Docker lists' filter field means: words that must all match,
/// some of them `key:value`, any of them negated with a leading `-`.
///
///     api                    a name, image, project or service holding it
///     status:running         running, exited, paused, created, restarting,
///                            dead; `up` and `stopped`; healthy, unhealthy
///     project:shop           the compose project (`p:`)
///     service:db             its service (`s:`)
///     image:postgres         the image (`i:`)
///     port:5432              published or exposed
///     is:test                Testcontainers' (`tc`, `tests`, `testcontainers`)
///     session:3f2a           one Testcontainers run, by its session's start
///                            (`tc:`)
///     -status:exited         not exited
///
/// Pure: `ResourceFilter`'s words, with Docker's keys and their meaning.
typealias DockerFilter = ResourceFilter<DockerFilterKey>

/// The Docker lists' filter keys, and every name they go by.
enum DockerFilterKey: String, ResourceFilterKey {
    case text, status, project, service, image, port, session

    static let names: [String: DockerFilterKey] = [
        "status": .status, "state": .status, "is": .status,
        "project": .project, "p": .project, "stack": .project,
        "service": .service, "s": .service,
        "image": .image, "i": .image,
        "port": .port,
        "session": .session, "tc": .session,
    ]
}

extension ResourceFilter where Key == DockerFilterKey {
    func matches(_ container: ContainerSummary) -> Bool {
        matches(by: { $0.matches(container) })
    }

    /// A service of a project before it runs: by its compose file's words.
    func matches(_ service: ComposeService) -> Bool {
        matches(by: { $0.matches(service) })
    }
}

extension ResourceFilter.Term where Key == DockerFilterKey {
    func matches(_ container: ContainerSummary) -> Bool {
        switch key {
        case .text:
            return [container.name, container.Image, container.composeProject ?? "", container.composeService ?? ""]
                .contains { $0.lowercased().contains(value) } || container.Id.hasPrefix(value)
        case .status:
            switch value {
            case "up": return container.state.isUp
            case "stopped", "down": return !container.state.isUp
            case "healthy", "unhealthy", "starting": return container.health == value
            case "test", "tests", "tc", "testcontainers": return Testcontainers.isMember(container)
            default: return container.State.lowercased() == value
            }
        case .project:
            return container.composeProject?.lowercased().contains(value) == true
        case .service:
            return container.composeService?.lowercased().contains(value) == true
        case .image:
            return container.Image.lowercased().contains(value)
        case .port:
            return (container.Ports ?? []).contains { "\($0.PrivatePort)" == value || $0.PublicPort.map { "\($0)" == value } == true }
        case .session:
            return Testcontainers.session(of: container)?.lowercased().hasPrefix(value) == true
        }
    }

    /// Not created: only `stopped` (`down`) is its status.
    func matches(_ service: ComposeService) -> Bool {
        let image = service.spec?.image ?? ""
        switch key {
        case .text: return [service.name, service.project, image].contains { $0.lowercased().contains(value) }
        case .status: return value == "stopped" || value == "down"
        case .project: return service.project.lowercased().contains(value)
        case .service: return service.name.lowercased().contains(value)
        case .image: return image.lowercased().contains(value)
        case .port: return (service.spec?.ports ?? []).contains { "\($0.target)" == value || $0.published == value }
        case .session: return false
        }
    }
}
