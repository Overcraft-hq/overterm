import Foundation

/// A container that couldn't start because its host port is taken — two
/// worktrees' stacks with the same `5432:5432` — and who has the port.
/// Docker says only "port is already allocated"; this says by whom.
struct DockerPortConflict: Equatable, Sendable {
    enum Holder: Equatable, Sendable {
        /// Another container publishes it: a stack of another checkout, often.
        case container(id: String, name: String, project: String?, folder: String?)
        /// A process in one of the window's tabs listens on it.
        case tab(id: UUID, title: String, process: String)
        /// Something else on this Mac does.
        case process(pid: Int32, command: String)
        case unknown
    }

    var port: Int
    var holder: Holder
}

/// Pure.
enum PortConflicts {
    /// The host port a start failed on, from the engine's words:
    /// `Bind for 0.0.0.0:5432 failed: port is already allocated` (another
    /// container), `listen tcp 0.0.0.0:5432: bind: address already in use`
    /// and Docker Desktop's `exposing port TCP 0.0.0.0:5432` (a process).
    static func port(in error: String) -> Int? {
        let patterns = [#"Bind for [^\s]*:(\d+) failed"#, #"listen tcp[46]? [^\s]*:(\d+): bind: address already in use"#, #"exposing port TCP [^\s]*:(\d+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: error, range: NSRange(error.startIndex..., in: error)),
                let range = Range(match.range(at: 1), in: error)
            else { continue }
            return Int(error[range])
        }
        return nil
    }

    /// Who holds a port, in a sentence: a conflict's detail, Up on Free
    /// Ports' question.
    static func holderText(_ holder: DockerPortConflict.Holder) -> String {
        switch holder {
        case .container(_, let name, let project, let folder):
            let whose = project.map { " — compose project \($0)" + (folder.map { " in \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? "") } ?? ""
            return "\(name) publishes it\(whose)."
        case .tab(_, let title, let process): return "\(process) listens on it, in the tab “\(title)”."
        case .process(let pid, let command): return "\(command) (pid \(pid)) listens on it, outside Overterm's tabs."
        case .unknown: return "Something else holds it."
        }
    }

    /// The running container, other than `except`, publishing `port`.
    static func container(holding port: Int, among containers: [ContainerSummary], except id: String) -> ContainerSummary? {
        containers.first { container in
            container.Id != id && container.state.isUp && PublishedPort.of(container.Ports ?? []).contains { $0.hostPort == port }
        }
    }
}
