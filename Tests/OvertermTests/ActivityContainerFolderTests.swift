import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes

/// A compose project's folder in its checkout's spelling: the checkout
/// scope compares paths as strings (6.5).
final class ActivityContainerFolderTests: XCTestCase {
    func testAProjectsFolderTakesItsCheckoutsSpelling() {
        let real: (String) -> String = { $0.hasPrefix("/var/") ? "/private" + $0 : $0 }
        let checkouts = ["/var/folders/fake/acme-shop", "/Users/fake/src/globex"]
        XCTAssertEqual(
            ActivityFolderSpelling.folder("/private/var/folders/fake/acme-shop", checkouts: checkouts, real: real),
            "/var/folders/fake/acme-shop", "the same folder by its real path")
        XCTAssertEqual(ActivityFolderSpelling.folder("/Users/fake/src/globex", checkouts: checkouts, real: real), "/Users/fake/src/globex")
        XCTAssertEqual(
            ActivityFolderSpelling.folder("/Users/fake/src/initech", checkouts: checkouts, real: real), "/Users/fake/src/initech",
            "no checkout's: as it is")
        var asked = 0
        _ = ActivityFolderSpelling.folder("/Users/fake/src/globex", checkouts: checkouts) {
            asked += 1; return $0
        }
        XCTAssertEqual(asked, 0, "a checkout's own spelling reads nothing")
    }

    /// The containers' folders, each read once a make, never on the main
    /// thread's say: the page hands them over as Compose wrote them.
    func testTheContainersAreSpelledOncePerFolder() {
        var asked: [String] = []
        let real: (String) -> String = { path in
            asked.append(path)
            return path.hasPrefix("/var/") ? "/private" + path : path
        }
        let containers = [
            ActivityContainer(id: "a", name: "acme-web", project: "acme", folder: "/private/var/folders/fake/acme-shop"),
            ActivityContainer(id: "b", name: "acme-db", project: "acme", folder: "/private/var/folders/fake/acme-shop"),
            ActivityContainer(id: "c", name: "loose", project: nil, folder: nil),
        ]
        let spelled = ActivityFolderSpelling.spelled(containers, checkouts: ["/var/folders/fake/acme-shop"], real: real)
        XCTAssertEqual(spelled.map(\.folder), ["/var/folders/fake/acme-shop", "/var/folders/fake/acme-shop", nil])
        XCTAssertEqual(asked.count, 2, "the folder and the checkout, once for both containers")
    }
}
