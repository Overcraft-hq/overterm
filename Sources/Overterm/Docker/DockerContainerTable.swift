import AppKit
import SwiftUI

/// A row of the containers list: a group's own row (a compose project, a
/// test run, the rest), one of its containers, or a service of a project
/// that hasn't run.
enum DockerTableRow: ResourceTableRow {
    case group(DockerListGroup)
    case container(ContainerSummary, group: DockerListGroup)
    case service(ComposeService, group: DockerListGroup)

    /// The selection's tag, as the page's model keeps it.
    var id: String {
        switch self {
        case .group(let group): group.id
        case .container(let container, _): container.Id
        case .service(let service, _): DockerPageModel.serviceTag(service)
        }
    }

    var height: CGFloat {
        switch self {
        case .group: 28
        case .container, .service: 30
        }
    }

    var spansColumns: Bool {
        if case .group = self { return true }
        return false
    }

    /// The list's rows: each group's row, then — unless it is folded — its
    /// containers and its services not yet created. Pure.
    static func rows(_ groups: [DockerListGroup], collapsed: Set<String>) -> [DockerTableRow] {
        ResourceGrouping.rows(
            groups, collapsed: collapsed, id: \.id, header: { .group($0) },
            members: { group in group.containers.map { .container($0, group: group) } + group.services.map { .service($0, group: group) } })
    }
}

/// The containers list: a resource table of one column, each row drawing
/// its own cells under the page's SwiftUI header (`DockerListColumns`).
typealias DockerContainerTable = ResourceTable<DockerTableRow>
