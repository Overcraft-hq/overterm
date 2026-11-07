import AppKit
import XCTest

@testable import Overterm

/// A page's resource table (`ResourceTable`): its grouped rows, its order,
/// what a press selects and what a right-click means — Docker's containers
/// list is one, Kubernetes' lists with the server's columns the next.
final class ResourceTableTests: XCTestCase {
    /// A list that is not Docker's: a basket's row, then its fruit.
    private enum Fruit: ResourceTableRow {
        case basket(String)
        case fruit(String, weight: Int?)

        var id: String {
            switch self {
            case .basket(let name): "basket:" + name
            case .fruit(let name, _): name
            }
        }

        var height: CGFloat { 24 }

        var spansColumns: Bool {
            if case .basket = self { return true }
            return false
        }
    }

    private let baskets = [("a", ["apple", "apricot"]), ("b", ["banana"])]

    private func rows(collapsed: Set<String> = []) -> [Fruit] {
        ResourceGrouping.rows(
            baskets, collapsed: collapsed, id: { "basket:" + $0.0 }, header: { .basket($0.0) },
            members: { $0.1.map { .fruit($0, weight: nil) } })
    }

    func testAGroupsRowComesBeforeWhatItHolds() {
        XCTAssertEqual(rows().map(\.id), ["basket:a", "apple", "apricot", "basket:b", "banana"])
    }

    func testAFoldedGroupKeepsOnlyItsRow() {
        XCTAssertEqual(rows(collapsed: ["basket:a"]).map(\.id), ["basket:a", "basket:b", "banana"])
    }

    func testSortingIsStableAndPutsTheUnknownLast() {
        let items: [Fruit] = [.fruit("c", weight: 2), .fruit("a", weight: nil), .fruit("b", weight: 1), .fruit("d", weight: 2)]
        func weight(_ fruit: Fruit) -> Int? {
            if case .fruit(_, let weight) = fruit { return weight }
            return nil
        }
        XCTAssertEqual(ResourceSort(column: "weight").sorted(items, by: weight).map(\.id), ["b", "c", "d", "a"])
        XCTAssertEqual(ResourceSort(column: "weight", ascending: false).sorted(items, by: weight).map(\.id), ["c", "d", "b", "a"])
    }

    func testAColumnClickedAgainTurnsTheOrder() {
        let byName = ResourceSort(column: "name")
        XCTAssertEqual(byName.clicked("name"), ResourceSort(column: "name", ascending: false))
        XCTAssertEqual(byName.clicked("age"), ResourceSort(column: "age"))
        XCTAssertEqual(byName.clicked("name").clicked("name"), byName)
    }

    @MainActor
    func testAPressSelectsAddsAndExtends() {
        XCTAssertEqual(ResourceTableView.pressed(3, in: [1], anchor: 1, modifiers: []), [3], "a press: that row alone")
        XCTAssertEqual(ResourceTableView.pressed(3, in: [1], anchor: 1, modifiers: .command), [1, 3], "⌘ adds")
        XCTAssertEqual(ResourceTableView.pressed(1, in: [1, 3], anchor: 1, modifiers: .command), [3], "⌘ again takes it away")
        XCTAssertEqual(ResourceTableView.pressed(4, in: [1], anchor: 1, modifiers: .shift), [1, 2, 3, 4], "⇧ extends")
        XCTAssertEqual(ResourceTableView.pressed(4, in: [], anchor: -1, modifiers: .shift), [4], "⇧ with nothing selected: that row")
    }

    func testARightClickMeansTheSelectionOnlyWhenOnIt() {
        typealias Table = ResourceTable<Fruit>
        let ids = rows().map(\.id)
        XCTAssertEqual(Table.Coordinator.menuTargets(clicked: 1, selected: [1, 2], ids: ids), ["apple", "apricot"])
        XCTAssertEqual(Table.Coordinator.menuTargets(clicked: 4, selected: [1, 2], ids: ids), ["banana"])
        XCTAssertEqual(Table.Coordinator.menuTargets(clicked: 9, selected: [], ids: ids), [])
    }

    func testDockersRowsAreGroupedAsBefore() {
        func container(_ name: String, project: String?) -> ContainerSummary {
            var labels: [String: String] = [:]
            if let project {
                labels["com.docker.compose.project"] = project
                labels["com.docker.compose.service"] = name
                labels["com.docker.compose.project.config_files"] = "/w/\(project)/compose.yaml"
                labels["com.docker.compose.project.working_dir"] = "/w/\(project)"
            }
            return ContainerSummary(Id: name + "-id", Names: ["/" + name], Image: "nginx", Created: 1, Labels: labels, State: "running", Status: "Up")
        }
        let (projects, loose) = ComposeProjects.group([container("web", project: "shop"), container("db", project: "shop"), container("redis", project: nil)])
        let groups = DockerPageModel.groups(projects: projects, loose: loose, filter: DockerFilter(""), runningOnly: false)
        let rows = DockerTableRow.rows(groups, collapsed: [])
        XCTAssertEqual(rows.map(\.id), ["project:shop"] + groups[0].containers.map(\.Id) + ["loose", "redis-id"])
        XCTAssertEqual(DockerTableRow.rows(groups, collapsed: ["project:shop"]).map(\.id), ["project:shop", "loose", "redis-id"])
        XCTAssertEqual(rows.map(\.height), [28, 30, 30, 28, 30])
        XCTAssertEqual(rows.map(\.spansColumns), [true, false, false, true, false])
        XCTAssertEqual(rows.map(\.reuseKind), ["group", "container", "container", "group", "container"])
    }

    /// A cell is reused for a row of its kind in its column only: a
    /// project's row and a container's are other SwiftUI views, and so are
    /// two columns' cells.
    @MainActor
    func testACellIsReusedOnlyForItsKindInItsColumn() {
        let container = ResourceHostingCell.identifier(column: nil, kind: "container")
        XCTAssertEqual(container, ResourceHostingCell.identifier(column: nil, kind: "container"))
        XCTAssertNotEqual(container, ResourceHostingCell.identifier(column: nil, kind: "group"))
        XCTAssertNotEqual(ResourceHostingCell.identifier(column: "name", kind: "row"), ResourceHostingCell.identifier(column: "age", kind: "row"))
        XCTAssertEqual(Fruit.basket("a").reuseKind, "row", "a row that says nothing is of the one kind")
    }

    /// A refresh finds each column where the table shows it: after a header
    /// is dragged elsewhere, the model's order is not the table's.
    @MainActor
    func testARefreshFindsAColumnWhereTheUserMovedIt() {
        let columns = ["name", "status", "age"].map { ResourceColumn(id: $0, title: $0) }
        let table = NSTableView()
        for column in columns { table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))) }
        table.moveColumn(2, toColumn: 0)
        let placed = ResourceTable<Fruit>.placed(columns, in: table)
        XCTAssertEqual(placed.map(\.column.id), ["name", "status", "age"])
        XCTAssertEqual(placed.map(\.at), [1, 2, 0])
        for (at, column) in placed { XCTAssertEqual(table.tableColumns[at].identifier.rawValue, column.id) }

        table.removeTableColumn(table.tableColumns[0])
        XCTAssertEqual(ResourceTable<Fruit>.placed(columns, in: table).map(\.column.id), ["name", "status"])
    }
}
