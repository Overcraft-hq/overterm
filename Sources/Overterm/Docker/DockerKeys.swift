import Foundation

/// The Docker lists' keys: single letters, only while a list has the
/// keyboard — the terminal never sees them, and a list is where a
/// keystroke can't be text. `?` shows this table. Pure.
enum DockerKey: String, CaseIterable, Sendable {
    case details, toggleDetail, startStop, restart, pause, logs, followLogs, shell, debugShell, inspect, open, database, remove, composeUp,
        composeDown, run, filter, cleanUp, containers, images, volumes, networks, builds, models, help

    /// The section a digit goes to.
    var section: DockerPageModel.Section? {
        switch self {
        case .containers: .containers
        case .images: .images
        case .volumes: .volumes
        case .networks: .networks
        case .builds: .builds
        case .models: .models
        default: nil
        }
    }

    /// What is pressed: one character, or a key's name.
    var key: String {
        switch self {
        case .details: "↩"
        case .toggleDetail: "Space"
        case .startStop: "s"
        case .restart: "r"
        case .pause: "p"
        case .logs: "l"
        case .followLogs: "t"
        case .shell: "e"
        case .debugShell: "E"
        case .inspect: "i"
        case .open: "o"
        case .database: "d"
        case .run: "n"
        case .remove: "⌫"
        case .composeUp: "u"
        case .composeDown: "D"
        case .filter: "/"
        case .cleanUp: "c"
        case .containers: "1"
        case .images: "2"
        case .volumes: "3"
        case .networks: "4"
        case .builds: "5"
        case .models: "6"
        case .help: "?"
        }
    }

    var title: String {
        switch self {
        case .details: "Logs of the selected container"
        case .toggleDetail: "Show or hide the detail"
        case .startStop: "Start or stop"
        case .restart: "Restart"
        case .pause: "Pause or unpause"
        case .logs: "Logs"
        case .followLogs: "Follow its logs in a terminal tab"
        case .shell: "A shell in it, in a terminal tab"
        case .debugShell: "A debug shell beside it — tools for an image with none"
        case .inspect: "Inspect"
        case .open: "Open its first port in the browser"
        case .database: "Open a database container in the Database panel"
        case .run: "Run an image — the selected one — in a new container; a model, in a chat in a tab"
        case .remove: "Remove (asks first)"
        case .composeUp: "Compose up, in a terminal tab"
        case .composeDown: "Compose down, in a terminal tab (asks first)"
        case .filter: "Filter — status:running project:api port:5432"
        case .cleanUp: "Clean Up… — what is unused, listed before it goes"
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .builds: "Builds"
        case .models: "Models — Docker Model Runner's"
        case .help: "These keys"
        }
    }

    /// The key a typed character is, if any. Case matters: `D` is compose
    /// down, `d` the Database panel.
    static func of(_ characters: String) -> DockerKey? {
        switch characters {
        case "\r": .details
        case " ": .toggleDetail
        case "\u{7F}", "\u{08}": .remove
        default: allCases.first { $0.key.count == 1 && $0.key == characters }
        }
    }
}
