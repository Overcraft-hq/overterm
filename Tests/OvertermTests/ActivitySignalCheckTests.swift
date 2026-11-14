import Darwin
import XCTest

@testable import Overterm

/// The pane pill's Free… by the class table (docs/design/activity/
/// analysis.md, 6.10, 6.12, 10.1): every class a pill can name, and what
/// decides first — the owners' own verbs, the never-list, a terraform
/// write wherever it runs, the agent, what chose to outlive its terminal,
/// a helm or pulumi write, the pane's foreground job. Every Free that ends
/// something asks, the owners' own verbs too.
final class ActivitySignalCheckTests: XCTestCase {
    private let user: uid_t = 501

    private func free(_ target: ActivityTarget) -> ActivityRule { ActivitySignalCheck.rule(.free, for: target, user: user) }

    /// One of the user's, in a pane.
    private func own(
        _ kind: ActivityClass, inForeground: Bool = false, groupHoldsAgent: Bool = false, terraformWrite: String? = nil, releaseWrite: String? = nil,
        detached: Bool = false, isApp: Bool = false, isZombie: Bool = false
    ) -> ActivityTarget {
        ActivityTarget(
            kind, pid: 4242, effectiveUID: user, isZombie: isZombie, inForeground: inForeground, groupHoldsAgent: groupHoldsAgent,
            terraformWrite: terraformWrite, releaseWrite: releaseWrite, detached: detached, isApp: isApp)
    }

    private let interrupt = ActivityRule.allowed(.interruptPane, confirm: true, critical: false)
    private let stop = ActivityRule.allowed(.signal(.term), confirm: true, critical: false)
    private let stopAgent = ActivityRule.allowed(.signal(.term), confirm: true, critical: true)
    private let interruptAlone = ActivityRule.allowed(.signal(.int), confirm: true, critical: false)

    // MARK: The pane's processes

    /// The pane's foreground job: ⌃C typed into the pane, asked.
    func testAPanesForegroundJobIsInterrupted() {
        XCTAssertEqual(free(own(.paneJob, inForeground: true)), interrupt)
    }

    /// Another job of the pane, one that left its terminal: Stop, asked.
    func testAnotherJobOfThePaneIsStopped() {
        XCTAssertEqual(free(own(.paneJob)), stop)
        XCTAssertEqual(free(own(.leftTerminal)), stop)
        XCTAssertEqual(free(own(.leftTerminal, inForeground: true)), stop, "it left the pane: ⌃C there doesn't reach it")
    }

    /// Never Interrupt while the group holds an agent: a ⌃C typed or a
    /// SIGINT to the group reaches the agent too (Codex's children keep its
    /// group) — the holder is stopped alone, by its token.
    func testWhereTheGroupHoldsAnAgentItIsStoppedNeverInterrupted() {
        XCTAssertEqual(free(own(.paneJob, inForeground: true, groupHoldsAgent: true)), stop)
        for inForeground in [false, true] {
            for groupHoldsAgent in [false, true] {
                XCTAssertEqual(free(own(.agentChild, inForeground: inForeground, groupHoldsAgent: groupHoldsAgent)), stop, "an agent's child")
            }
        }
    }

    /// The agent itself: Stop Agent…, in a critical sheet — it stops mid-task.
    func testTheAgentIsStopAgentCritical() {
        XCTAssertEqual(free(own(.agent, inForeground: true)), stopAgent)
        XCTAssertEqual(free(own(.agent)), stopAgent)
    }

    /// A terraform, tofu or terragrunt write, wherever it runs: Interrupt
    /// only — ⌃C typed where it is the pane's own foreground job, else
    /// SIGINT to it alone, never its group's agent or shell. Never TERM,
    /// never KILL, whatever else it is.
    func testATerraformWriteIsInterruptOnlyWhereverItRuns() {
        let write = "terraform apply"
        XCTAssertEqual(free(own(.paneJob, inForeground: true, terraformWrite: write)), interrupt, "a shell's job: as Ctrl-C would")
        XCTAssertEqual(free(own(.paneJob, terraformWrite: write)), interruptAlone, "in the background")
        XCTAssertEqual(free(own(.paneJob, inForeground: true, groupHoldsAgent: true, terraformWrite: write)), interruptAlone, "an agent's group")
        XCTAssertEqual(free(own(.agentChild, terraformWrite: "tofu destroy")), interruptAlone, "an agent's terraform apply -auto-approve")
        XCTAssertEqual(free(own(.leftTerminal, terraformWrite: "terragrunt apply")), interruptAlone, "nohup'd and left")
        XCTAssertEqual(free(own(.paneJob, terraformWrite: write, detached: true)), interruptAlone, "detached: still interrupted, never refused to a kill -9")
        XCTAssertEqual(free(own(.paneJob, terraformWrite: write, isApp: true)), interruptAlone)
    }

    /// A helm or pulumi write, wherever it runs — or what runs under one,
    /// pulumi's plugins on their 127.0.0.1 ports: what its job gets, in a
    /// critical sheet, since a release stopped mid-upgrade stays
    /// pending-upgrade. What chose to outlive its terminal, and an app,
    /// still get no Free from a pill.
    func testAHelmOrPulumiWriteIsAskedCritically() {
        let interruptCritical = ActivityRule.allowed(.interruptPane, confirm: true, critical: true)
        let stopCritical = ActivityRule.allowed(.signal(.term), confirm: true, critical: true)
        XCTAssertEqual(free(own(.paneJob, inForeground: true, releaseWrite: "helm upgrade")), interruptCritical, "the pane's own job: ⌃C typed")
        XCTAssertEqual(free(own(.paneJob, releaseWrite: "pulumi up")), stopCritical, "in the background")
        XCTAssertEqual(free(own(.paneJob, inForeground: true, groupHoldsAgent: true, releaseWrite: "helm install")), stopCritical, "an agent's group")
        XCTAssertEqual(free(own(.agentChild, releaseWrite: "pulumi destroy")), stopCritical, "an agent's pulumi destroy --yes")
        XCTAssertEqual(free(own(.leftTerminal, releaseWrite: "helm rollback")), stopCritical, "nohup'd and left")
        XCTAssertEqual(free(own(.agent, releaseWrite: "helm upgrade")), stopAgent)
        XCTAssertEqual(free(own(.paneJob, releaseWrite: "helm upgrade", detached: true)).refusal, ActivitySignalCheck.detached)
        XCTAssertEqual(free(own(.paneJob, releaseWrite: "pulumi up", isApp: true)).refusal, ActivitySignalCheck.app)
    }

    /// A release write by its name and its masked argv's operation: the
    /// first word that is neither a flag nor a global flag's value; a
    /// read, a dry run, a name that isn't the tool's, nothing.
    func testAReleaseWriteByItsNameAndOperation() {
        func write(_ name: String, _ line: String) -> String? {
            ActivityTarget.releaseWrite(name: name, arguments: line.split(separator: " ").map(String.init))
        }
        XCTAssertEqual(write("helm", "helm upgrade --install acme-api ./chart"), "helm upgrade")
        XCTAssertEqual(write("helm", "/opt/homebrew/bin/helm --kube-context acme-prod -n acme install acme-api ./chart"), "helm install")
        XCTAssertEqual(write("helm", "helm --namespace=acme --debug rollback acme-api 3"), "helm rollback")
        XCTAssertEqual(write("helm", "helm --kube-token •••••• upgrade acme-api ./chart"), "helm upgrade", "a masked value is still one word")
        XCTAssertEqual(write("pulumi", "pulumi up --yes"), "pulumi up")
        XCTAssertEqual(write("pulumi", "pulumi -C infra --non-interactive destroy --yes"), "pulumi destroy")
        XCTAssertEqual(write("pulumi", "pulumi -v=3 update"), "pulumi update")
        XCTAssertEqual(write("pulumi", "pulumi --color never down"), "pulumi down")
        XCTAssertNil(write("helm", "helm list -A"))
        XCTAssertNil(write("helm", "helm template acme-api . --set mode=upgrade"))
        XCTAssertNil(write("helm", "helm -n upgrade list"), "a flag's value, never the operation")
        XCTAssertNil(write("helm", "helm"))
        XCTAssertNil(write("helm", "helm -- upgrade"))
        XCTAssertNil(write("pulumi", "pulumi preview"))
        XCTAssertNil(write("pulumi", "pulumi stack select acme-dev"))
        XCTAssertNil(write("acme-helm", "helm upgrade acme-api ./chart"), "by its executable's name, not argv[0]")
        XCTAssertNil(write("terraform", "terraform apply"))
    }

    /// What chose to outlive its terminal — it ignores SIGHUP, or was
    /// detached on purpose — and an app: no Free from a pill; Activity,
    /// where it is picked alone.
    func testWhatOutlivesItsTerminalAndAppsHaveNoFreeFromAPill() {
        for kind in [ActivityClass.paneJob, .agentChild, .leftTerminal] {
            XCTAssertEqual(free(own(kind, detached: true)).refusal, ActivitySignalCheck.detached, "\(kind)")
            XCTAssertEqual(free(own(kind, isApp: true)).refusal, ActivitySignalCheck.app, "\(kind)")
        }
        XCTAssertEqual(free(own(.paneJob, inForeground: true, detached: true)).refusal, ActivitySignalCheck.detached, "not even interrupted")
    }

    /// The pane's `login` (root's, setuid) and its shell: the close route,
    /// asked by Activity — never a signal.
    func testAPanesSessionIsTheCloseRoute() {
        XCTAssertEqual(free(ActivityTarget(.paneSession, pid: 4100, effectiveUID: 0, realUID: user)), .route(.closePane, confirm: true), "the login")
        XCTAssertEqual(free(own(.paneSession, inForeground: true)), .route(.closePane, confirm: true), "the shell")
    }

    // MARK: Owners, and the never-list

    /// A container's port and Overterm's helpers: their owners' own verbs,
    /// each asked by Activity first — a container's and a forward's Stop
    /// act at once when called, the apply view's first Stop unasked.
    func testContainersAndHelpersTheirOwnersVerbs() {
        XCTAssertEqual(free(ActivityTarget(.container, pid: 0, effectiveUID: user)), .route(.stopContainer, confirm: true))
        let routes: [ActivityHelper: ActivityRule] = [
            .forward: .route(.stopForward, confirm: true), .tunnel: .route(.disconnect, confirm: true),
            .languageServer: .route(.restartLanguageServer, confirm: true), .terraformRun: .route(.stopTerraformRun, confirm: true),
            .kubectlProxy: .refused(ActivitySignalCheck.kubectlProxy), .other: .refused(ActivitySignalCheck.helper),
        ]
        for helper in ActivityHelper.allCases {
            XCTAssertEqual(free(own(.helper(helper))), routes[helper], "\(helper)")
            XCTAssertEqual(free(own(.helper(helper), terraformWrite: "terraform apply")), routes[helper], "its own run's Stop: \(helper)")
        }
    }

    /// Overterm, launchd and the kernel, anything that doesn't run as the
    /// user — root's, a setuid program the user started, another user's —,
    /// a zombie: refused, whatever else they are, a terraform write too.
    func testTheNeverList() {
        XCTAssertEqual(free(own(.overterm)).refusal, ActivitySignalCheck.overterm)
        for pid: pid_t in [0, 1] {
            XCTAssertEqual(free(ActivityTarget(.paneJob, pid: pid, effectiveUID: 0)).refusal, ActivitySignalCheck.macOS, "pid \(pid)")
        }
        let setuid = ActivityTarget(.paneJob, pid: 4300, effectiveUID: 0, realUID: user, inForeground: true)
        XCTAssertEqual(free(setuid).refusal, ActivitySignalCheck.notYours(setuid, user: user))
        XCTAssertTrue(free(setuid).refusal?.contains("setuid") == true, "kill(2) would let it through: refused here")
        let root = ActivityTarget(.paneJob, pid: 4301, effectiveUID: 0)
        XCTAssertTrue(free(root).refusal?.hasPrefix("Owned by root") == true)
        let other = ActivityTarget(.agentChild, pid: 4302, effectiveUID: 502)
        XCTAssertTrue(free(other).refusal?.hasPrefix("Owned by another user") == true)
        // Running as the user only for now, which the effective uid alone
        // would pass: a setuid program that dropped to the user, root kept
        // as its saved uid; root's, its real uid root's.
        let dropped = ActivityTarget(.paneJob, pid: 4303, effectiveUID: user, realUID: user, savedUID: 0, inForeground: true)
        XCTAssertEqual(free(dropped).refusal, ActivitySignalCheck.notYours(dropped, user: user))
        XCTAssertTrue(free(dropped).refusal?.contains("setuid program you started, running as you for now") == true)
        for saved: uid_t in [0, user] {
            let rootsForNow = ActivityTarget(.agentChild, pid: 4304, effectiveUID: user, realUID: 0, savedUID: saved)
            XCTAssertTrue(free(rootsForNow).refusal?.hasPrefix("Root's, running as you for now") == true, "saved \(saved)")
        }
        XCTAssertTrue(free(ActivityTarget(.paneJob, pid: 4305, effectiveUID: user, realUID: 502)).refusal?.hasPrefix("Another user's") == true)
        var write = setuid
        write.terraformWrite = "terraform apply"
        XCTAssertNotNil(free(write).refusal, "a write as root: refused, not interrupted")
        var release = dropped
        release.releaseWrite = "helm upgrade"
        XCTAssertNotNil(free(release).refusal, "a release write that can take root back: refused")
        XCTAssertEqual(free(own(.paneJob, inForeground: true, isZombie: true)).refusal, ActivitySignalCheck.ended)
        XCTAssertEqual(free(own(.agent, isZombie: true)).refusal, ActivitySignalCheck.ended)
    }

    /// Over every class a pill can name and every fact that changes a rule:
    /// whatever ends something asks — a signal, ⌃C typed, an owner's own
    /// verb alike —, only the agent's and a helm or pulumi write's sheets
    /// are critical (a terraform write's Interrupt isn't), and nothing is
    /// sent but TERM or INT — never KILL.
    func testEveryFreeAsks() {
        let kinds: [ActivityClass] = [.paneJob, .agent, .agentChild, .leftTerminal, .paneSession, .container, .overterm] + ActivityHelper.allCases.map { .helper($0) }
        var allowed = 0
        var routes: Set<ActivityRoute> = []
        for kind in kinds {
            for facts in 0..<64 {
                let target = own(
                    kind, inForeground: facts & 1 != 0, groupHoldsAgent: facts & 2 != 0, terraformWrite: facts & 4 != 0 ? "terraform apply" : nil,
                    releaseWrite: facts & 32 != 0 ? "helm upgrade" : nil, detached: facts & 8 != 0, isApp: facts & 16 != 0)
                switch free(target) {
                case .refused: continue
                case .route(let route, let confirm):
                    routes.insert(route)
                    XCTAssertTrue(confirm, "\(kind) \(facts): \(route) asked")
                case .allowed(let action, let confirm, let critical):
                    allowed += 1
                    XCTAssertTrue(confirm, "\(kind) \(facts): asked")
                    XCTAssertEqual(critical, (kind == .agent || target.releaseWrite != nil) && target.terraformWrite == nil, "\(kind) \(facts)")
                    switch action {
                    case .interruptPane: XCTAssertTrue(kind == .paneJob && target.inForeground && !target.groupHoldsAgent, "\(kind) \(facts)")
                    case .signal(let signal): XCTAssertTrue(signal == .term || signal == .int, "\(kind) \(facts): \(signal)")
                    }
                    if target.terraformWrite != nil { XCTAssertNotEqual(action, .signal(.term), "\(kind) \(facts): a write is interrupted only") }
                }
            }
        }
        XCTAssertGreaterThan(allowed, 0)
        XCTAssertEqual(routes, [.closePane, .stopContainer, .stopForward, .disconnect, .restartLanguageServer, .stopTerraformRun], "every route seen")
    }
}
