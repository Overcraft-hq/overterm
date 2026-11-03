import XCTest

@testable import Overterm

/// Settings ▸ About ▸ Acknowledgements says what this build ships: the list
/// moves with the pins, or `Scripts/fetch-licenses.sh` is due.
final class AcknowledgementsTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var resources: URL { root.appendingPathComponent("Resources") }
    private var all: [Acknowledgement] { Acknowledgement.load(from: resources) }

    private func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

    func testEveryOneHasItsLicenceText() {
        XCTAssertGreaterThan(all.count, 50)
        for item in all {
            XCTAssertTrue(Acknowledgement.groups.contains(item.group), item.name)
            let text = item.text(in: resources)
            XCTAssertGreaterThan(text.count, 200, "\(item.name)'s licence is missing or a pointer: \(item.file)")
        }
    }

    func testTheSwiftPackagesAreThePinnedOnes() throws {
        struct Resolved: Decodable {
            struct Pin: Decodable {
                struct State: Decodable { var version: String? }
                var identity: String
                var state: State
            }
            var pins: [Pin]
        }
        let resolved = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: root.appendingPathComponent("Package.resolved")))
        let listed = Dictionary(uniqueKeysWithValues: all.filter { $0.group == "Swift packages" }.map { ($0.name, $0.version) })
        for pin in resolved.pins {
            XCTAssertEqual(listed[pin.identity], pin.state.version, "\(pin.identity) moved: run Scripts/fetch-licenses.sh")
        }
        XCTAssertEqual(listed.count, resolved.pins.count, "a package left: run Scripts/fetch-licenses.sh")
    }

    func testGhosttyAndTreeSitterAreThePinnedOnes() throws {
        let ghostty = try XCTUnwrap(try source("Scripts/build-ghosttykit.sh").firstMatch(of: /GHOSTTY_REF="v([^"]+)"/)?.1)
        XCTAssertEqual(all.first { $0.name == "Ghostty" }?.version, String(ghostty), "run Scripts/fetch-licenses.sh")
        let script = try source("Scripts/build-treesitter.sh")
        let treeSitter = try XCTUnwrap(script.firstMatch(of: /TREE_SITTER_REF="v([^"]+)"/)?.1)
        XCTAssertEqual(all.first { $0.name == "tree-sitter" }?.version, String(treeSitter), "run Scripts/fetch-licenses.sh")
        for match in script.matches(of: /"[^|"]+\|https:\/\/[^|]+\/([^|\/]+)\|([0-9a-f]{12})/) {
            XCTAssertEqual(all.first { $0.name == String(match.1) }?.version, String(match.2), "\(match.1) moved: run Scripts/fetch-licenses.sh")
        }
    }
}
