import Foundation

/// The Activity page's keys (docs/design/activity/analysis.md, 6.3), only
/// while its list has the keyboard. Letters are case-sensitive, as Docker's
/// `d` and `D` are. ← and → aren't here: `ResourceTable` folds and unfolds
/// with them itself. The verbs' keys (`k`, `K`, `x`, `p`, `b`, `n`, `f`,
/// `a`) come with the verbs (stage 2) — `f` frees a port through its
/// owner's own verb now (`ActivityPortHolder`); Terminal in Its Folder (`e`) and
/// Open Files (`l`) with the folder and descriptor reads they need. ⌥o is
/// `ActivityPageModel.pressOption`'s. Pure.
enum ActivityKey: String, ResourceKey {
    case processes, listening
    case goTo, detail, filter, help
    case open, reveal, tabInfo, sample
    case tree, group, narrower, wider
    case follow, pause, mine, connections, free
    case sortCPU, sortMemory, sortTime, sortPID, invert

    var section: ActivityPageModel.Section? {
        switch self {
        case .processes: .processes
        case .listening: .listening
        default: nil
        }
    }

    var key: String {
        switch self {
        case .processes: "1"
        case .listening: "2"
        case .goTo: "↩"
        case .detail: "Space"
        case .filter: "/"
        case .help: "?"
        case .open: "o"
        case .reveal: "r"
        case .tabInfo: "i"
        case .sample: "s"
        case .tree: "t"
        case .group: "G"
        case .narrower: "["
        case .wider: "]"
        case .follow: "F"
        case .pause: "Z"
        case .mine: "u"
        case .connections: "c"
        case .free: "f"
        case .sortCPU: "P"
        case .sortMemory: "M"
        case .sortTime: "T"
        case .sortPID: "N"
        case .invert: "I"
        }
    }

    var title: String {
        switch self {
        case .processes: "Processes"
        case .listening: "Listening"
        case .goTo: "Go to its tab and pane — a port: its process's row"
        case .detail: "Show or hide the detail"
        case .filter: "Filter — name:node|bun cpu:>50 mem:>1g age:<5m port:3000 is:agent -user:root"
        case .help: "These keys"
        case .open: "Open its port in its tab's browser column — ⌥o the default browser"
        case .reveal: "Reveal its executable in Finder"
        case .tabInfo: "Tab Info for its tab"
        case .sample: "Sample it in a new tab: sample <pid> 5"
        case .tree: "Tree or flat"
        case .group: "Group by checkout, tab, agent, app, user or none"
        case .narrower: "Narrower: all tabs, the checkout, the tab"
        case .wider: "Wider, back to the whole Mac"
        case .follow: "Follow the selection as it moves"
        case .pause: "Pause updates"
        case .mine: "Yours only, or everyone's"
        case .connections: "Listening: your established connections too, paired end to end"
        case .free: "Listening: free the port through its owner — Stop Container, Stop Forward, Disconnect, Stop the Service, AirPlay's switch"
        case .sortCPU: "Sort by CPU"
        case .sortMemory: "Sort by memory"
        case .sortTime: "Sort by CPU time"
        case .sortPID: "Sort by PID"
        case .invert: "Invert the sort"
        }
    }

    /// ← and →, which `ResourceTable` reads: listed by `?`, never typed here.
    static let foldHelp = "← → fold or unfold the row"
}
