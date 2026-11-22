import Darwin
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
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents

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
        detached: Bool = false, isApp: Bool = false, isZombie: Bool = false, stopped: ActivityStopper? = nil
    ) -> ActivityTarget {
        ActivityTarget(
            kind, pid: 4242, effectiveUID: user, isZombie: isZombie, inForeground: inForeground, groupHoldsAgent: groupHoldsAgent,
            terraformWrite: terraformWrite, releaseWrite: releaseWrite, detached: detached, isApp: isApp, stopped: stopped)
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
                    default: XCTFail("\(kind) \(facts): a pill's Free is ⌃C, a signal or the close — \(action)")
                    }
                    if target.terraformWrite != nil { XCTAssertNotEqual(action, .signal(.term), "\(kind) \(facts): a write is interrupted only") }
                }
            }
        }
        XCTAssertGreaterThan(allowed, 0)
        XCTAssertEqual(routes, [.closePane, .stopContainer, .stopForward, .disconnect, .restartLanguageServer, .stopTerraformRun], "every route seen")
    }

    // MARK: The page's verbs, every one over every class (stage 2)

    private func rule(_ verb: ActivityVerb, _ target: ActivityTarget, parent: ActivityTarget? = nil) -> ActivityRule {
        ActivitySignalCheck.rule(verb, for: target, parent: parent, user: user)
    }

    /// Every class of 6.10's table, with the facts that make a row of it.
    private var everyClass: [(String, ActivityTarget)] {
        var rows: [(String, ActivityTarget)] = [
            ("job", own(.paneJob)), ("foreground job", own(.paneJob, inForeground: true)), ("agent", own(.agent, inForeground: true, groupHoldsAgent: true)),
            ("agent's child", own(.agentChild, groupHoldsAgent: true)), ("left its terminal", own(.leftTerminal)), ("left behind", own(.leftBehind)),
            ("elsewhere", own(.elsewhere)), ("terraform", own(.paneJob, inForeground: true, terraformWrite: "terraform apply")),
            ("helm", own(.elsewhere, releaseWrite: "helm upgrade")), ("detached", own(.paneJob, detached: true)), ("app", own(.elsewhere, isApp: true)),
            ("another Overterm", own(.anotherOverterm)), ("Overterm", own(.overterm)), ("engine", own(.engine)), ("macOS", own(.macOS)),
            ("pane's shell", own(.paneSession, inForeground: true)), ("login", ActivityTarget(.paneSession, pid: 4100, effectiveUID: 0, realUID: user)),
            ("container", ActivityTarget(.container, pid: 0, effectiveUID: user)), ("launchd", ActivityTarget(.macOS, pid: 1, effectiveUID: 0)),
            ("root's", ActivityTarget(.elsewhere, pid: 4301, effectiveUID: 0)), ("setuid", ActivityTarget(.paneJob, pid: 4300, effectiveUID: 0, realUID: user)),
            ("zombie", own(.paneJob, isZombie: true)),
        ]
        rows += ActivityHelper.allCases.map { ("helper \($0)", own(.helper($0))) }
        return rows
    }

    /// Whatever ends a process asks: every verb but Suspend, Resume and the
    /// background for one plain process — and Send a Signal always.
    func testEveryVerbThatEndsAProcessAsks() {
        for verb in ActivityVerb.allCases where verb != .stopParent {
            for (name, target) in everyClass {
                let decided = rule(verb, target)
                switch decided {
                case .refused: continue
                case .route(let route, let confirm):
                    if case .send = verb { XCTAssertTrue(confirm, "\(verb) \(name)") }
                    if route == .closePane || route == .stopContainer { XCTAssertTrue(confirm, "\(verb) \(name): the close asks") }
                case .allowed(let action, let confirm, let critical):
                    switch action {
                    case .suspend, .resume, .background, .normalPriority:
                        if case .send = verb { XCTAssertTrue(confirm, "\(verb) \(name): Send a Signal asks") }
                    default:
                        XCTAssertTrue(confirm, "\(verb) \(name): \(action) asks")
                    }
                    if action == .signal(.kill) || action == .forceQuitApp { XCTAssertTrue(critical, "\(verb) \(name): Force Quit is critical") }
                }
            }
        }
    }

    /// The never-list, for every verb: launchd and the kernel, what doesn't
    /// run as the user alone, Overterm, another Overterm, the engine,
    /// macOS's daemons, a zombie — refused; the pane's shell only its
    /// close (and Suspend Tab's) route.
    func testTheNeverListForEveryVerb() {
        let never: [(String, ActivityTarget)] = everyClass.filter {
            ["launchd", "root's", "setuid", "zombie", "Overterm", "another Overterm", "macOS"].contains($0.0)
        }
        for verb in ActivityVerb.allCases where verb != .stopParent && verb != .free {
            for (name, target) in never {
                XCTAssertNotNil(rule(verb, target).refusal, "\(verb) \(name)")
            }
            for helper in ActivityHelper.allCases {
                if case .route = rule(verb, own(.helper(helper))) {
                    XCTAssertTrue([ActivityVerb.stop, .interrupt, .freePort].contains(verb), "\(verb): a helper's only routes are its own Stop")
                }
                if case .allowed = rule(verb, own(.helper(helper))) { XCTFail("\(verb) helper \(helper): never signalled") }
            }
            switch rule(verb, own(.paneSession)) {
            case .allowed(let action, _, _): XCTFail("\(verb): the pane's shell is never sent \(action)")
            case .route(let route, _): XCTAssertTrue([.closePane, .suspendTab, .resumeTab].contains(route), "\(verb) \(route)")
            case .refused: break
            }
            if case .allowed = rule(verb, own(.engine)) { XCTFail("\(verb): the engine is never signalled") }
        }
    }

    /// k on each: Stop, or Interrupt on the pane's foreground job, Stop
    /// Agent (critical) on the agent; an app's Quit.
    func testStopByClass() {
        XCTAssertEqual(rule(.stop, own(.paneJob)), stop)
        XCTAssertEqual(rule(.stop, own(.leftTerminal)), stop)
        XCTAssertEqual(rule(.stop, own(.elsewhere, detached: true)), stop, "picked alone: asked, one at a time")
        XCTAssertEqual(rule(.stop, own(.agent)), stopAgent)
        XCTAssertEqual(rule(.stop, own(.elsewhere, releaseWrite: "pulumi up")), .allowed(.signal(.term), confirm: true, critical: true))
        XCTAssertEqual(rule(.stop, own(.elsewhere, isApp: true)), .allowed(.quitApp, confirm: true, critical: false))
        XCTAssertEqual(rule(.stop, own(.paneSession)), .route(.closePane, confirm: true))
        XCTAssertEqual(rule(.stop, ActivityTarget(.container, pid: 0, effectiveUID: user)), .route(.stopContainer, confirm: true))
        XCTAssertEqual(rule(.stop, own(.engine)).refusal, ActivitySignalCheck.engine)
        XCTAssertEqual(rule(.stop, own(.macOS)).refusal, ActivitySignalCheck.daemon)
        XCTAssertEqual(rule(.stop, own(.anotherOverterm)).refusal, ActivitySignalCheck.anotherOverterm)
    }

    /// Interrupt: ⌃C typed for the pane's foreground job alone — never
    /// where its group holds an agent, never under an agent, never what
    /// runs in no pane.
    func testInterruptIsThePanesForegroundJobOnly() {
        XCTAssertEqual(rule(.interrupt, own(.paneJob, inForeground: true)), interrupt)
        XCTAssertEqual(rule(.interrupt, own(.paneJob)).refusal, ActivitySignalCheck.notForeground)
        XCTAssertEqual(rule(.interrupt, own(.paneJob, inForeground: true, groupHoldsAgent: true)).refusal, ActivitySignalCheck.groupHoldsAgentWords)
        XCTAssertEqual(rule(.interrupt, own(.agentChild, inForeground: true)).refusal, ActivitySignalCheck.underAgent)
        for kind in [ActivityClass.leftTerminal, .leftBehind, .elsewhere] {
            XCTAssertEqual(rule(.interrupt, own(kind, inForeground: true)).refusal, ActivitySignalCheck.noPane, "\(kind)")
        }
        XCTAssertEqual(rule(.interrupt, own(.elsewhere, isApp: true)).refusal, ActivitySignalCheck.appInterrupt)
        XCTAssertEqual(rule(.interrupt, own(.paneJob, inForeground: true, releaseWrite: "helm upgrade")), .allowed(.interruptPane, confirm: true, critical: true))
    }

    /// The agent: Interrupt Turn (⌃C, plain) while it is the pane's
    /// foreground job; Stop Agent critical; neither for anything else.
    func testTheAgentsTwoVerbs() {
        XCTAssertEqual(rule(.interruptTurn, own(.agent, inForeground: true, groupHoldsAgent: true)), interrupt)
        XCTAssertEqual(rule(.interrupt, own(.agent, inForeground: true, groupHoldsAgent: true)), interrupt, "its Interrupt is the turn's")
        XCTAssertEqual(rule(.interruptTurn, own(.agent)).refusal, ActivitySignalCheck.agentNotForeground)
        XCTAssertEqual(rule(.stopAgent, own(.agent)), stopAgent)
        for kind in [ActivityClass.paneJob, .agentChild, .elsewhere] {
            XCTAssertEqual(rule(.interruptTurn, own(kind, inForeground: true)).refusal, ActivitySignalCheck.notAnAgent, "\(kind)")
            XCTAssertEqual(rule(.stopAgent, own(kind)).refusal, ActivitySignalCheck.notAnAgent, "\(kind)")
        }
    }

    /// Force Quit: SIGKILL to the process alone, critical; an app's
    /// `forceTerminate`; never a terraform write's.
    func testForceQuit() {
        let kill = ActivityRule.allowed(.signal(.kill), confirm: true, critical: true)
        for kind in [ActivityClass.paneJob, .agent, .agentChild, .leftTerminal, .leftBehind, .elsewhere] {
            XCTAssertEqual(rule(.forceQuit, own(kind)), kill, "\(kind)")
        }
        XCTAssertEqual(rule(.forceQuit, own(.elsewhere, isApp: true)), .allowed(.forceQuitApp, confirm: true, critical: true))
        XCTAssertEqual(rule(.forceQuit, own(.paneJob, terraformWrite: "terraform apply")).refusal, ActivitySignalCheck.terraformKill)
        XCTAssertEqual(rule(.forceQuit, own(.paneSession)), .route(.closePane, confirm: true), "the shell: its close")
    }

    /// A terraform write, wherever it runs: Interrupt only — ⌃C where it is
    /// the pane's job, SIGINT to terraform alone anywhere else — and in no
    /// bulk, no suspend, no priority.
    func testATerraformWriteIsInterruptOnly() {
        let pane = own(.paneJob, inForeground: true, terraformWrite: "terraform apply")
        let elsewhere = own(.elsewhere, terraformWrite: "tofu destroy")
        let underAgent = own(.agentChild, inForeground: true, groupHoldsAgent: true, terraformWrite: "terraform apply")
        for verb in [ActivityVerb.stop, .interrupt, .freePort, .send(.int)] {
            XCTAssertEqual(rule(verb, pane), interrupt, "\(verb)")
            XCTAssertEqual(rule(verb, elsewhere), interruptAlone, "\(verb)")
            XCTAssertEqual(rule(verb, underAgent), interruptAlone, "\(verb): never the agent's group")
        }
        for signal in ActivitySignal.allCases where signal != .int {
            XCTAssertNotNil(rule(.send(signal), pane).refusal, "\(signal)")
        }
        for verb in [ActivityVerb.forceQuit, .stopTree, .stopGroup, .suspend, .background, .lowerPriority] {
            XCTAssertNotNil(rule(verb, elsewhere).refusal, "\(verb)")
        }
    }

    /// Send a Signal ▸: each under the verb it equals, always asked; USR1
    /// and the rest plain signals, asked.
    func testSendASignalMapsToItsVerb() {
        let job = own(.paneJob, inForeground: true)
        XCTAssertEqual(rule(.send(.kill), job), rule(.forceQuit, job))
        XCTAssertEqual(rule(.send(.term), job), stop, "TERM is Stop, not Interrupt")
        XCTAssertEqual(rule(.send(.int), job), interrupt, "INT to the pane's job is Interrupt")
        XCTAssertEqual(rule(.send(.int), own(.elsewhere)), interruptAlone, "else a plain SIGINT")
        XCTAssertEqual(rule(.send(.int), own(.agent, inForeground: true)), interrupt, "an agent's: its turn")
        XCTAssertEqual(rule(.send(.term), own(.agent)), stopAgent)
        XCTAssertEqual(rule(.send(.stop), own(.elsewhere)), .allowed(.suspend, confirm: true, critical: false), "STOP is Suspend, asked")
        XCTAssertEqual(rule(.send(.stop), job), .route(.suspendPane, confirm: true))
        var stopped = own(.elsewhere)
        stopped.stopped = .activity
        XCTAssertEqual(rule(.send(.cont), stopped), .allowed(.resume, confirm: true, critical: false), "CONT is Resume, asked")
        stopped.stopped = .jobControl
        XCTAssertEqual(rule(.send(.cont), stopped).refusal, ActivitySignalCheck.jobControl)
        for signal in [ActivitySignal.hup, .quit, .usr1, .usr2] {
            XCTAssertEqual(rule(.send(signal), own(.elsewhere)), .allowed(.signal(signal), confirm: true, critical: false), "\(signal)")
            XCTAssertEqual(rule(.send(signal), own(.paneSession)), .route(.closePane, confirm: true), "\(signal) to the shell: its close")
        }
        XCTAssertEqual(rule(.send(.stop), own(.paneSession)), .route(.suspendTab, confirm: true))
        XCTAssertEqual(rule(.send(.hup), own(.helper(.forward))).refusal, ActivitySignalCheck.helper, "never a signal to a helper")
    }

    /// Stop Its Tree: asked, the agent's critical; never a terraform write's
    /// or an app's. What a bulk leaves out, member by member.
    func testStopItsTreeAndWhatItLeavesOut() {
        XCTAssertEqual(rule(.stopTree, own(.paneJob)), .allowed(.signalTree(.term), confirm: true, critical: false))
        XCTAssertEqual(rule(.stopTree, own(.agent)), .allowed(.signalTree(.term), confirm: true, critical: true))
        XCTAssertEqual(rule(.stopTree, own(.paneJob, terraformWrite: "terraform apply")).refusal, ActivitySignalCheck.terraformBulk)
        XCTAssertEqual(rule(.stopTree, own(.elsewhere, isApp: true)).refusal, ActivitySignalCheck.appBulk)
        XCTAssertNil(ActivitySignalCheck.bulkRefusal(own(.paneJob), user: user))
        XCTAssertNil(ActivitySignalCheck.bulkRefusal(own(.agentChild), user: user))
        for (member, why) in [
            (own(.paneJob, terraformWrite: "terraform apply"), "terraform"), (own(.paneJob, detached: true), "outlive"), (own(.elsewhere, isApp: true), "app"),
            (ActivityTarget(.elsewhere, pid: 9, effectiveUID: 0, realUID: user), "not yours"), (own(.agent), "agent"), (own(.paneSession), "shell"),
            (own(.helper(.other)), "Overterm"),
        ] {
            XCTAssertTrue(ActivitySignalCheck.bulkRefusal(member, user: user)?.contains(why) == true, why)
        }
    }

    /// Stop Its Group: only where it leads a group that says more than its
    /// tree and holds nothing no group Stop may reach.
    func testStopItsGroup() {
        var leader = own(.paneJob)
        XCTAssertEqual(rule(.stopGroup, leader).refusal, ActivitySignalCheck.notLeader)
        leader.leadsGroup = true
        XCTAssertEqual(rule(.stopGroup, leader).refusal, ActivitySignalCheck.groupIsTree)
        leader.groupBeyondTree = true
        XCTAssertEqual(rule(.stopGroup, leader), .allowed(.signalGroup(.term), confirm: true, critical: false))
        leader.groupHolds = "the pane's shell"
        XCTAssertTrue(rule(.stopGroup, leader).refusal?.contains("the pane's shell") == true)
        XCTAssertEqual(ActivitySignalCheck.groupBlocker(own(.agent), user: user), "an agent")
        XCTAssertEqual(ActivitySignalCheck.groupBlocker(own(.paneSession), user: user), "the pane's shell")
        XCTAssertNil(ActivitySignalCheck.groupBlocker(own(.paneJob), user: user))
    }

    /// What `killpg` would reach and no bulk may (never-list 12): each one
    /// in a group refuses the whole group Stop, as it is left out of a tree.
    func testAGroupHoldingWhatNoBulkReachesIsRefusedWhole() {
        var inside = own(.elsewhere)
        inside.insideApp = true
        let members: [(ActivityTarget, String)] = [
            (own(.paneJob, detached: true), "a process that chose to outlive its terminal"), (own(.elsewhere, isApp: true), "an app"), (inside, "an app"),
            (own(.engine), "Docker's engine"), (own(.macOS), "part of macOS"), (own(.anotherOverterm), "Overterm's own"),
            (ActivityTarget(.elsewhere, pid: 1, effectiveUID: user), "part of macOS"), (own(.helper(.other)), "Overterm's own"),
            (own(.paneJob, terraformWrite: "terraform apply"), "a terraform write"),
            (ActivityTarget(.paneJob, pid: 9, effectiveUID: 0, realUID: user), "another user's process"),
        ]
        for (member, words) in members {
            XCTAssertEqual(ActivitySignalCheck.groupBlocker(member, user: user), words, words)
            XCTAssertNotNil(ActivitySignalCheck.bulkRefusal(member, user: user), "a tree leaves it out too: \(words)")
            var leader = own(.paneJob)
            leader.leadsGroup = true
            leader.groupBeyondTree = true
            leader.groupHolds = ActivitySignalCheck.groupBlocker(member, user: user)
            XCTAssertEqual(rule(.stopGroup, leader).refusal, "Its process group holds \(words): no group Stop reaches it.", words)
        }
        XCTAssertNil(ActivitySignalCheck.groupBlocker(own(.leftTerminal), user: user))
        XCTAssertNil(ActivitySignalCheck.groupBlocker(own(.agentChild), user: user))
    }

    /// A terraform write that isn't the pane's foreground job: SIGINT to
    /// its group when it leads one holding nothing no group send reaches
    /// (`TerraformCloseGuard.interruptTarget`'s rule), else to it alone.
    func testATerraformWritesInterruptGoesToTheGroupItLeads() {
        var leader = own(.elsewhere, terraformWrite: "terraform apply")
        leader.leadsGroup = true
        let toGroup = ActivityRule.allowed(.signalGroup(.int), confirm: true, critical: false)
        for verb in [ActivityVerb.stop, .interrupt, .send(.int)] { XCTAssertEqual(rule(verb, leader), toGroup, "\(verb)") }
        leader.groupHolds = "an agent"
        XCTAssertEqual(rule(.interrupt, leader), interruptAlone, "a group holding an agent: terraform alone")
        var pane = own(.paneJob, inForeground: true, terraformWrite: "terraform apply")
        pane.leadsGroup = true
        XCTAssertEqual(rule(.interrupt, pane), interrupt, "the pane's foreground job: ⌃C typed")
    }

    /// Stop Its Parent: the parent's own class decides.
    func testStopItsParent() {
        let zombie = own(.paneJob, isZombie: true)
        XCTAssertEqual(rule(.stopParent, zombie).refusal, ActivitySignalCheck.parentUnknown)
        XCTAssertEqual(rule(.stopParent, zombie, parent: own(.paneSession)), .route(.closePane, confirm: true), "a shell: its pane's close")
        XCTAssertEqual(rule(.stopParent, zombie, parent: own(.agent)), stopAgent, "an agent: Stop Agent, critical")
        XCTAssertEqual(rule(.stopParent, zombie, parent: own(.paneJob)), stop)
        XCTAssertEqual(rule(.stopParent, zombie, parent: own(.overterm)).refusal, ActivitySignalCheck.parentOverterm)
        XCTAssertEqual(rule(.stopParent, zombie, parent: ActivityTarget(.macOS, pid: 1, effectiveUID: 0)).refusal, ActivitySignalCheck.parentLaunchd)
        XCTAssertEqual(rule(.stopParent, zombie, parent: own(.paneJob, stopped: .jobControl)).refusal, ActivitySignalCheck.parentStopped)
        XCTAssertNotNil(rule(.stopParent, zombie, parent: ActivityTarget(.elsewhere, pid: 50, effectiveUID: 0)).refusal, "root's parent")
        XCTAssertEqual(rule(.stop, zombie).refusal, ActivitySignalCheck.ended, "the zombie itself: nothing to signal")
    }

    /// Suspend and Resume: a pane's job with its pane; an app asked; Resume
    /// only for what Activity stopped.
    func testSuspendAndResume() {
        XCTAssertEqual(rule(.suspend, own(.paneJob)), .route(.suspendPane, confirm: false))
        XCTAssertEqual(rule(.suspend, own(.agentChild)), .allowed(.suspend, confirm: false, critical: false))
        XCTAssertEqual(rule(.suspend, own(.elsewhere, isApp: true)), .allowed(.suspend, confirm: true, critical: false))
        XCTAssertEqual(rule(.suspend, own(.paneSession)), .route(.suspendTab, confirm: false))
        XCTAssertEqual(rule(.suspend, own(.elsewhere, stopped: .activity)).refusal, ActivitySignalCheck.alreadyStopped)
        XCTAssertEqual(rule(.resume, own(.elsewhere)).refusal, ActivitySignalCheck.notStopped)
        XCTAssertEqual(rule(.resume, own(.elsewhere, stopped: .activity)), .allowed(.resume, confirm: false, critical: false))
        XCTAssertEqual(rule(.resume, own(.elsewhere, stopped: .suspendTab)), .route(.resumeTab, confirm: false))
        XCTAssertEqual(rule(.resume, own(.elsewhere, stopped: .jobControl)).refusal, ActivitySignalCheck.jobControl)
        XCTAssertEqual(rule(.resume, own(.elsewhere, stopped: .traced)).refusal, ActivitySignalCheck.traced)
        XCTAssertEqual(rule(.resume, own(.elsewhere, stopped: .unknown)).refusal, ActivitySignalCheck.notStoppedHere)
    }

    /// Priority: Background unasked, Normally only for what Activity put
    /// there, Lower asked.
    func testPriority() {
        XCTAssertEqual(rule(.background, own(.paneJob)), .allowed(.background, confirm: false, critical: false))
        XCTAssertEqual(rule(.runNormally, own(.paneJob)).refusal, ActivitySignalCheck.notBackgrounded)
        var put = own(.paneJob)
        put.backgroundedHere = true
        XCTAssertEqual(rule(.runNormally, put), .allowed(.normalPriority, confirm: false, critical: false))
        XCTAssertEqual(rule(.lowerPriority, own(.paneJob)), .allowed(.lowerPriority, confirm: true, critical: false))
    }

    /// Free :N from the page for the user's own holder: what its pill's
    /// would be, but apps and what chose to outlive its terminal asked here.
    func testFreeFromThePage() {
        XCTAssertEqual(rule(.freePort, own(.paneJob, inForeground: true)), interrupt)
        XCTAssertEqual(rule(.freePort, own(.paneJob)), stop)
        XCTAssertEqual(rule(.freePort, own(.paneJob, detached: true)), stop)
        XCTAssertEqual(rule(.freePort, own(.elsewhere, isApp: true)), .allowed(.quitApp, confirm: true, critical: false))
        XCTAssertEqual(rule(.freePort, own(.agent)), stopAgent)
        XCTAssertEqual(rule(.freePort, own(.engine)), .route(.stopContainer, confirm: true))
    }
}
