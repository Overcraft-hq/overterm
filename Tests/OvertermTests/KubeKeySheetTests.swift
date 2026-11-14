import XCTest

@testable import Overterm

/// `?` on the Kubernetes page: the keys grouped, generated from
/// `KubernetesKey` and the window's Kubernetes commands. Pure.
final class KubeKeySheetTests: XCTestCase {
    func testEveryKeyIsListedOnceInItsGroupInOrder() {
        let groups = KubeKeySheet.groups { _ in nil }
        XCTAssertEqual(groups.map(\.group), KubeKeyGroup.allCases, "every group, in order")
        let keys = groups.filter { $0.group != .window }.flatMap(\.rows).map(\.key)
        XCTAssertEqual(keys.sorted(), KubernetesKey.allCases.map(\.key).sorted(), "every key the page answers, each once")
        XCTAssertEqual(Set(keys).count, keys.count)
        for group in groups where group.group != .window {
            XCTAssertEqual(
                group.rows, KubernetesKey.allCases.filter { $0.group == group.group }.map { KubeKeySheet.Row(key: $0.key, title: $0.title) },
                "\(group.group): in KubernetesKey's order, with its own words")
        }
    }

    func testTheGroupsSayWhatTheKeysAre() {
        XCTAssertEqual(KubernetesKey.delete.group, .writes)
        XCTAssertEqual(KubernetesKey.debug.group, .writes)
        XCTAssertEqual(KubernetesKey.scaleTo.group, .writes)
        XCTAssertEqual(KubernetesKey.logs.group, .verbs)
        XCTAssertEqual(KubernetesKey.shell.group, .verbs)
        XCTAssertEqual(KubernetesKey.wide.group, .list)
        XCTAssertEqual(KubernetesKey.command.group, .navigation)
        XCTAssertEqual(KubernetesKey.help.group, .navigation)
        for section in KubeSection.allCases { XCTAssertEqual(KubernetesKey(rawValue: section.rawValue)?.group, .sections) }
        XCTAssertTrue(KubernetesKey.allCases.filter { $0.group == .writes }.allSatisfy { $0.section == nil })
    }

    func testTheWindowsCommandsWithTheirKeysAsBoundNow() {
        let commands = KubeKeySheet.windowCommands.map(\.id)
        XCTAssertTrue(commands.contains("kubernetes.page") && commands.contains("kubernetes.switch"), "\(commands)")
        XCTAssertTrue(commands.allSatisfy { $0.hasPrefix("kubernetes.") })
        let window =
            KubeKeySheet.groups { $0.id == "kubernetes.switch" ? "⌃⌥K" : $0.defaultKey.flatMap(KeyCombo.init)?.display }
            .first { $0.group == .window }?.rows ?? []
        XCTAssertTrue(window.contains(KubeKeySheet.Row(key: "⌥⌘J", title: "Kubernetes")), "\(window)")
        XCTAssertTrue(window.contains(KubeKeySheet.Row(key: "⌃⌥K", title: "Kubernetes Switcher")), "a rebound key, as it is now")
        XCTAssertTrue(window.contains(KubeKeySheet.Row(key: KubeKeySheet.unbound, title: "Terminal in Kubernetes Context…")), "unbound, said so")
    }

    func testWhatClosesItAndWhatGoesOn() {
        XCTAssertTrue(KubeKeySheet.closes("\u{1B}"))
        XCTAssertTrue(KubeKeySheet.closes("?"))
        XCTAssertFalse(KubeKeySheet.closes("x"))
        XCTAssertTrue(KubeKeySheet.passesThrough(":"))
        XCTAssertTrue(KubeKeySheet.passesThrough("/"))
        XCTAssertFalse(KubeKeySheet.passesThrough("⌫"))
    }
}
