import Foundation
import XCTest

@testable import Overterm

/// Pod files (stage 4): `kubectl cp` out of and into a container — the
/// lines (`-c`, `--context` and `-n` always, quoted for zsh, odd paths
/// included), the process class check per class (a copy in only where the
/// context is writable, both after can-i on pods/exec, both refused where
/// shells are off), the paths kubectl can't be given, and the
/// confirmation's words. Pure: nothing runs kubectl.
final class KubePodFilesTests: XCTestCase {
    private func context(_ name: String, settings: KubeContextSettings = KubeContextSettings(), session: Bool = false) -> KubeContext {
        KubeWritesTests.context(name, settings: settings, session: session)
    }

    private func copy(
        _ direction: KubePodCopy.Direction, remote: String = "/var/log/app.log", local: String = "/Users/me/Downloads/app.log",
        container: String? = "app"
    ) -> KubePodCopy {
        KubePodCopy(direction: direction, pod: "web-7d9", namespace: "shop", container: container, remotePath: remote, localPath: local)
    }

    // MARK: The lines

    func testTheLinesNameTheContainerContextAndNamespaceAlways() {
        XCTAssertEqual(
            copy(.out).line(context: "fake-dev"),
            "kubectl cp web-7d9:/var/log/app.log /Users/me/Downloads/app.log -c app --context fake-dev -n shop")
        XCTAssertEqual(
            copy(.into, remote: "/tmp/app.conf", local: "/Users/me/app.conf").line(context: "fake-dev"),
            "kubectl cp /Users/me/app.conf web-7d9:/tmp/app.conf -c app --context fake-dev -n shop", "the local side first going in")
        XCTAssertEqual(
            copy(.out, container: nil).line(context: "fake-dev"),
            "kubectl cp web-7d9:/var/log/app.log /Users/me/Downloads/app.log --context fake-dev -n shop", "no container: kubectl's choice")
        let arn = "arn:aws:eks:eu-west-1:123456789012:cluster/acme-dev"
        XCTAssertTrue(copy(.out).line(context: arn).hasSuffix(" --context \(arn) -n shop"))
    }

    func testOddPathsAreQuotedForZsh() {
        XCTAssertEqual(
            copy(.out, remote: "/data/my file's $HOME.txt", local: "/Users/me/Down loads/it's *.txt").line(context: "fake-dev"),
            #"kubectl cp 'web-7d9:/data/my file'\''s $HOME.txt' '/Users/me/Down loads/it'\''s *.txt' -c app --context fake-dev -n shop"#)
        XCTAssertEqual(
            copy(.into, remote: "~/!x;rm -rf /", local: "/tmp/a`b`").line(context: "it's prod"),
            #"kubectl cp '/tmp/a`b`' 'web-7d9:~/!x;rm -rf /' -c app --context 'it'\''s prod' -n shop"#, "nothing in a path runs")
        XCTAssertEqual(
            KubePodCopy(direction: .out, pod: "-rf", namespace: "$NS", container: "a b", remotePath: "relative/dir", localPath: "/tmp/dir")
                .line(context: "c"),
            "kubectl cp '-rf:relative/dir' /tmp/dir -c 'a b' --context c -n '$NS'")
        XCTAssertEqual(
            copy(.out, remote: "/etc/a:b", local: "/tmp/x").line(context: "c"),
            "kubectl cp web-7d9:/etc/a:b /tmp/x -c app --context c -n shop", "a colon in the container's path is kubectl's: after the first")
    }

    func testPathsKubectlCantBeGivenAreRefused() {
        XCTAssertNil(KubePodCopy.problem(remote: "/var/log", local: "/tmp/log"))
        XCTAssertNotNil(KubePodCopy.problem(remote: "  ", local: "/tmp/log"), "a container path")
        XCTAssertNotNil(KubePodCopy.problem(remote: "/var/log", local: ""), "a local path")
        XCTAssertNotNil(KubePodCopy.problem(remote: "/var/log", local: "relative/log"), "absolute on this Mac")
        XCTAssertNotNil(KubePodCopy.problem(remote: "/var/log", local: "/tmp/a:b"), "kubectl would read a pod's name")
        XCTAssertNotNil(KubePodCopy.problem(remote: "/var/log\nrm -rf ~", local: "/tmp/log"), "a newline would run in the tab")
        XCTAssertNotNil(KubePodCopy.problem(remote: "/var/log", local: "/tmp/\tlog"))
        XCTAssertNotNil(KubePodCopy.problem(remote: "/var/\u{1B}[2Jlog", local: "/tmp/log"), "an escape")
        XCTAssertEqual(copy(.out, local: "/tmp/a:b").refused, KubePodCopy.problem(remote: "/var/log/app.log", local: "/tmp/a:b"))
        XCTAssertThrowsError(try KubeCommands.command(copy(.out, local: "/tmp/a:b"), in: context("fake-dev")), "never built")
    }

    func testTheContainersWholeRootIsNotCopiedOut() {
        for root in ["/", "//", "/.", "/./", "/..", " / "] {
            XCTAssertNotNil(copy(.out, remote: root, local: "/tmp/copy").refused, "copy out of \(root)")
            XCTAssertNotNil(KubePodCopy.outProblem(remote: root), root)
        }
        XCTAssertNil(copy(.out, remote: "/var", local: "/tmp/var").refused)
        XCTAssertNil(copy(.out, remote: "relative", local: "/tmp/r").refused)
        XCTAssertNil(copy(.into, remote: "/", local: "/tmp/app.conf").refused, "a copy in names the folder it lands in")
        XCTAssertThrowsError(try KubeCommands.command(copy(.out, remote: "/", local: "/tmp/copy"), in: context("fake-dev")), "never built")
    }

    func testTheSuggestedNames() {
        XCTAssertEqual(KubePodCopy.suggestedName(for: "/var/log/app.log"), "app.log")
        XCTAssertEqual(KubePodCopy.suggestedName(for: "/var/log/"), "log")
        XCTAssertEqual(KubePodCopy.suggestedName(for: "/"), "copy")
        XCTAssertEqual(KubePodCopy.suggestedName(for: "data/.."), "data")
        XCTAssertEqual(KubePodCopy.suggestedName(for: "/var/log/a:b.log"), "a-b.log", "a colon would be refused on this Mac")
        XCTAssertEqual(KubePodCopy.suggestedName(for: "/var/log/app-2026-11-07T10:00:00.log"), "app-2026-11-07T10-00-00.log")
        let name = KubePodCopy.suggestedName(for: "/var/log/a:b.log")
        XCTAssertNil(KubePodCopy.problem(remote: "/var/log/a:b.log", local: "/tmp/" + name), "the name suggested is one taken")
        XCTAssertEqual(KubePodCopy.suggestedRemote(for: "/Users/me/app.conf"), "/tmp/app.conf")
        XCTAssertEqual(
            KubePodCopy.workingDirectories([
                "spec": ["containers": [["name": "app", "workingDir": "/srv/app"], ["name": "side"], ["name": "rel", "workingDir": "x"]]]
            ]), ["app": "/srv/app/"])
    }

    // MARK: The process class check

    func testEveryClassForBothDirections() {
        let settings = KubeContextSettings()
        for kind in KubeContextClass.allCases {
            for writable in [false, true] {
                let out = KubeProcessCheck.rule(.copyOut, class: kind, writable: writable, settings: settings)
                XCTAssertEqual(out, KubeProcessRule(access: .exec, confirm: true), "\(kind) \(writable): reads, after can-i, asked")
                let into = KubeProcessCheck.rule(.copyIn, class: kind, writable: writable, settings: settings)
                if writable {
                    XCTAssertEqual(into, KubeProcessRule(access: .exec, confirm: true), "\(kind)")
                } else {
                    XCTAssertEqual(into.refused, KubeProcessCheck.readOnly(kind), "\(kind): read-only")
                }
            }
        }
        XCTAssertEqual(KubeProcessVerb.copyOut.access, .exec)
        XCTAssertEqual(KubeProcessVerb.copyIn.access, .exec)
        XCTAssertTrue(KubeProcessVerb.copyIn.writes)
        XCTAssertFalse(KubeProcessVerb.copyOut.writes)
    }

    func testShellsOffRefusesBoth() {
        let off = KubeContextSettings(shells: false)
        for kind in KubeContextClass.allCases {
            XCTAssertEqual(KubeProcessCheck.rule(.copyOut, class: kind, writable: true, settings: off).refused, KubeProcessCheck.copiesOff)
            XCTAssertEqual(KubeProcessCheck.rule(.copyIn, class: kind, writable: true, settings: off).refused, KubeProcessCheck.copiesOff)
        }
    }

    func testTheContextsOfThisMacTakeNoCopyIn() throws {
        for name in [
            "arn:aws:eks:eu-west-1:123456789012:cluster/acme-dev", "arn:aws:eks:eu-west-1:123456789012:cluster/acme-prod", "globex-eu-west-1-dev",
            "globex-eu-west-1-prod", "kubernetes-admin@k8s-cluster", "fake-dev", "fake-prod",
        ] {
            let read = context(name)
            XCTAssertThrowsError(try KubeCommands.command(copy(.into), in: read), name)
            XCTAssertEqual(try KubeCommands.command(copy(.out), in: read), copy(.out).line(context: name), "\(name): out, after can-i and asked")
        }
        XCTAssertNoThrow(try KubeCommands.command(copy(.into), in: context("kind-fake")), "local: writable")
        XCTAssertNoThrow(try KubeCommands.command(copy(.into), in: context("fake-prod", session: true)), "production with its switch on")
        XCTAssertNoThrow(try KubeCommands.command(copy(.into), in: context("fake-dev", settings: KubeContextSettings(writable: true))))
    }

    // MARK: The confirmation

    func testTheConfirmationNamesEverything() {
        let prod = context("fake-prod", session: true)
        let rule = KubeProcessCheck.rule(.copyOut, for: prod)
        let out = copy(.out).confirmation(context: prod, rule: rule)
        XCTAssertEqual(out.title, "Copy /var/log/app.log out of pod shop/web-7d9?")
        XCTAssertEqual(out.scope, "PRODUCTION · fake-prod · namespace shop")
        XCTAssertTrue(out.production)
        XCTAssertNil(out.typedName, "not in rule 4's list")
        XCTAssertTrue(out.detail.contains("pod shop/web-7d9, container app: /var/log/app.log"), out.detail)
        XCTAssertTrue(out.detail.contains("/Users/me/Downloads/app.log"), out.detail)
        XCTAssertTrue(out.detail.contains(copy(.out).line(context: "fake-prod")), out.detail)
        XCTAssertEqual(out.kubectl, copy(.out).line(context: "fake-prod"))

        let dev = context("kind-fake")
        let into = copy(.into, remote: "/tmp/app.conf", local: "/Users/me/app.conf").confirmation(
            context: dev, rule: KubeProcessCheck.rule(.copyIn, for: dev))
        XCTAssertEqual(into.title, "Copy app.conf into pod shop/web-7d9?")
        XCTAssertEqual(into.scope, "kind-fake · namespace shop")
        XCTAssertFalse(into.production)
        XCTAssertTrue(into.detail.contains("pod shop/web-7d9, container app: /tmp/app.conf"), into.detail)
        XCTAssertTrue(into.detail.contains("overwritten"), into.detail)
        XCTAssertEqual(into.button, "Copy In in a Tab")
        XCTAssertEqual(copy(.out).opened(context: "fake-dev"), "Copying /var/log/app.log out of pod shop/web-7d9 in a new tab, in fake-dev.")
    }

    func testACopyIsNamedAPodsInATab() {
        let line = copy(.out).line(context: "fake-dev")
        XCTAssertEqual(TabKind.of(agent: nil, title: line, hasPort: false, pinned: true), .kubernetes, "a pinned tab's own: one command, no stdin")
    }
}
