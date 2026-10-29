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
/// Pure.
struct DockerFilter: Equatable, Sendable {
    struct Term: Equatable, Sendable {
        enum Key: String, Sendable { case text, status, project, service, image, port, session }
        var key: Key
        var value: String
        var negated: Bool
    }

    var terms: [Term]

    var isEmpty: Bool { terms.isEmpty }

    init(_ text: String) {
        terms = text.split(whereSeparator: \.isWhitespace).compactMap { word in
            var word = Substring(word)
            let negated = word.hasPrefix("-") && word.count > 1
            if negated { word = word.dropFirst() }
            if let colon = word.firstIndex(of: ":"), colon != word.startIndex {
                let name = word[..<colon].lowercased()
                let value = String(word[word.index(after: colon)...]).lowercased()
                if let key = Self.key(name) {
                    return value.isEmpty ? nil : Term(key: key, value: value, negated: negated)
                }
            }
            return Term(key: .text, value: word.lowercased(), negated: negated)
        }
    }

    private static func key(_ name: String) -> Term.Key? {
        switch name {
        case "status", "state", "is": .status
        case "project", "p", "stack": .project
        case "service", "s": .service
        case "image", "i": .image
        case "port": .port
        case "session", "tc": .session
        default: nil
        }
    }

    func matches(_ container: ContainerSummary) -> Bool {
        terms.allSatisfy { $0.matches(container) != $0.negated }
    }

    /// A service of a project before it runs: by its compose file's words.
    func matches(_ service: ComposeService) -> Bool {
        terms.allSatisfy { $0.matches(service) != $0.negated }
    }
}

extension DockerFilter.Term {
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
