import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermTerraform

/// P15: the Terraform flow's links — the var files a root can be planned
/// with, a run's end in Overterm's words, the changes pane's summary.
final class TerraformLinksTests: XCTestCase {
    func testOnlyTheRootsOwnVarFilesAreChoosable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tfvars-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested.tfvars"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["dev.tfvars", "secrets.tfvars.json", "terraform.tfvars", "net.auto.tfvars", "main.tf"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data())
        }
        XCTAssertEqual(
            TerraformRootStore.choosable(in: root), ["dev.tfvars", "secrets.tfvars.json"],
            "the ones every run loads, a folder and other files left out")
    }

    func testARunsEndIsSaidInOvertermsWordsOnly() {
        XCTAssertEqual(
            TerraformRunEnd.plan(.planned, root: "envs/dev", workspace: "default", kind: .plan, refreshOnly: false, counts: "+1 ~0 -0"),
            TerraformRunEnd(text: "Plan of envs/dev @default: +1 ~0 -0", failed: false))
        XCTAssertEqual(
            TerraformRunEnd.plan(.failed("Error: invalid token sk-live-123"), root: "envs/dev", workspace: "default", kind: .plan, refreshOnly: false, counts: nil),
            TerraformRunEnd(text: "Plan of envs/dev @default failed", failed: true), "terraform's own words never")
        XCTAssertEqual(
            TerraformRunEnd.plan(.noChanges, root: "envs/dev", workspace: "prod", kind: .plan, refreshOnly: true, counts: nil)?.text,
            "Drift check of envs/dev @prod: no drift")
        XCTAssertNil(TerraformRunEnd.plan(.running, root: "a", workspace: "b", kind: .plan, refreshOnly: false, counts: nil))
        XCTAssertNil(TerraformRunEnd.plan(.stopped, root: "a", workspace: "b", kind: .plan, refreshOnly: false, counts: nil), "the person stopped it")
        XCTAssertEqual(TerraformRunEnd.apply(.failed("x"), root: "envs/prod", workspace: "default")?.failed, true)
        XCTAssertEqual(TerraformRunEnd.apply(.applied("x"), root: "envs/prod", workspace: "default")?.text, "Apply of envs/prod @default done")
        XCTAssertNil(TerraformRunEnd.apply(.running, root: "a", workspace: "b"))
        XCTAssertEqual(TerraformRunEnd.test(.failed("x"), root: "envs/dev"), TerraformRunEnd(text: "Tests of envs/dev failed", failed: true))
    }

    func testTheTabIsMarkedOnceAndNeverOverAHigherMark() {
        var activity = TabActivity()
        XCTAssertFalse(activity.terraformRunEnded("Plan of a done", failed: false, visible: true), "looked at: nothing")
        XCTAssertTrue(activity.terraformRunEnded("Plan of a done", failed: false, visible: false))
        XCTAssertEqual(activity.mark, .done)
        XCTAssertFalse(activity.terraformRunEnded("Plan of a done", failed: false, visible: false), "the same words again")
        XCTAssertTrue(activity.terraformRunEnded("Apply of a failed", failed: true, visible: false))
        XCTAssertEqual(activity.mark, .failed)
        activity.handle(.bell, visible: false)
        XCTAssertFalse(activity.terraformRunEnded("Plan of b done", failed: false, visible: false), "under a waiting mark it stays")
        XCTAssertEqual(activity.mark, .waiting)
    }

    func testTheChangesLineNamesEachRootAndItsModule() {
        let roots = [
            TerraformReview.Root(path: "envs/prod", name: "envs/prod", rootClass: .production, why: "through modules/network", present: true),
            TerraformReview.Root(path: "envs/dev", name: "envs/dev", rootClass: .local, why: "envs/dev/main.tf", present: true),
        ]
        XCTAssertEqual(TerraformChangesLine.summary(roots), "envs/prod (via modules/network), envs/dev")
    }
}
