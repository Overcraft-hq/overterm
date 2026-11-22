import Darwin

/// What a person asks of a process (docs/design/activity/analysis.md,
/// 6.10): the pane pill's Free…, and the page's verbs — one per row of
/// 6.10's verb table that changes a process. `ActivitySignalCheck` decides
/// each for each class.
package enum ActivityVerb: Hashable, Sendable {
    /// The pill's Free :N…: whatever ends the port's holder the way its
    /// class asks (6.12) — each asked.
    case free
    /// Stop… (`k`): SIGTERM — an app's Quit, an agent's Stop Agent, a
    /// terraform write's Interrupt.
    case stop
    /// Interrupt… (`k` on a pane's foreground job): ⌃C typed into the pane.
    case interrupt
    /// Interrupt Turn… on an agent's row: the same ⌃C into the agent's pane.
    case interruptTurn
    /// Stop Agent… (`k` on an agent's row): SIGTERM to the agent, critical.
    case stopAgent
    /// Force Quit… (`K`): SIGKILL to the process alone.
    case forceQuit
    /// Send a Signal ▸ (`x`): that signal, under the rule of the verb it equals.
    case send(ActivitySignal)
    /// Stop Its Tree…: SIGTERM to the subtree, parents first.
    case stopTree
    /// Stop Its Group…: `killpg` after the member check.
    case stopGroup
    /// Stop Its Parent…: the parent's own class decides.
    case stopParent
    /// Suspend / Resume (`p`).
    case suspend
    case resume
    /// Run in Background / Normally (`b`).
    case background
    case runNormally
    /// Lower Priority ▸ (`n`): upward only.
    case lowerPriority
    /// Free :N from the page, for the user's own holder (6.8): what ends
    /// it as its class asks, apps and detached processes included — there
    /// they are picked alone.
    case freePort

    /// Every verb, each signal of Send a Signal one.
    package static var allCases: [ActivityVerb] {
        [.free, .stop, .interrupt, .interruptTurn, .stopAgent, .forceQuit] + ActivitySignal.allCases.map { .send($0) }
            + [.stopTree, .stopGroup, .stopParent, .suspend, .resume, .background, .runNormally, .lowerPriority, .freePort]
    }
}

/// A process's class to the policy: 6.10's rows. A pane's port pill names
/// the pane's own processes, Overterm's helpers, a container (6.12); the
/// page any of them. Whose it is — root's, another user's, a setuid
/// program's —, a zombie, a stopped process, an app, a terraform or a helm
/// write, what chose to outlive its terminal are the target's facts.
package enum ActivityClass: Hashable, Sendable {
    /// A job in a pane: the user's, under its `login`.
    case paneJob
    /// The pane's agent: any `Agent`.
    case agent
    /// What runs under an agent: an MCP server, a tool shell, a server one
    /// of them started.
    case agentChild
    /// It carries the pane's tag outside its tree: it left its terminal
    /// (disowned, its shell gone), and is in the pane's set.
    case leftTerminal
    /// The pane's `login`, or its shell: the pane itself.
    case paneSession
    /// One of Overterm's own children, or under one (6.5 rule 2).
    case helper(ActivityHelper)
    /// A running container's published port, which the engine holds.
    case container
    /// Overterm itself.
    case overterm
    /// What outlived its tab, its agent or an earlier Overterm (6.9).
    case leftBehind
    /// The user's, outside every tab: another terminal's, another
    /// Overterm's tabs', a `/usr/bin` tool someone ran.
    case elsewhere
    /// Another Overterm, the app itself.
    case anotherOverterm
    /// Docker's engine or its VM, OrbStack's, Colima's, Lima's (6.5 rule 6).
    case engine
    /// macOS's own daemons and agents outside the tabs (6.5 rule 14).
    case macOS
}

/// Who stopped a stopped process (6.10's last row): only what Activity
/// stopped is resumed here.
package enum ActivityStopper: Hashable, Sendable {
    /// Activity's Suspend, kept by identity.
    case activity
    /// Suspend Tab: Resume Tab resumes it.
    case suspendTab
    /// Its shell's job control (⌃Z): `fg` in its tab.
    case jobControl
    /// A debugger (`P_TRACED`): SIGCONT would interfere.
    case traced
    /// Nobody Overterm knows.
    case unknown
}

/// Which of Overterm's helpers, for its own verb (6.10's helpers row).
package enum ActivityHelper: Hashable, Sendable, CaseIterable {
    /// A Kubernetes port-forward's kubectl (`KubeForwards`).
    case forward
    /// A database tunnel's ssh (`SSHTunnel`).
    case tunnel
    /// One of the editor's language servers.
    case languageServer
    /// A terraform Overterm runs: a plan, an init, a detached apply.
    case terraformRun
    /// A context's `kubectl proxy` (`KubeProxy`).
    case kubectlProxy
    /// Anything else it started: git, gh, docker, the shell-environment read.
    case other
}

/// A process as the policy sees it: its class, and the facts read fresh
/// when the sheet opens (6.10 step 3).
package struct ActivityTarget: Hashable, Sendable {
    package var kind: ActivityClass
    /// Its pid; 0 for a container's port, which none of the user's holds.
    package var pid: pid_t
    /// Its effective uid, read fresh: whose it is to the kernel's reads. A
    /// setuid program the user started — every terminal's `login` — is
    /// root's here.
    package var effectiveUID: uid_t
    /// Its real uid: the user's for a setuid program the user started,
    /// which `kill(2)` would let through (3.2).
    package var realUID: uid_t
    /// Its saved uid: root's for a setuid-root program that set its
    /// effective uid to the user's for a while, and can take root back.
    package var savedUID: uid_t
    package var isZombie = false
    /// Its process group is its pane's foreground group (`e_tpgid`): what
    /// ⌃C typed into the pane reaches.
    package var inForeground = false
    /// Its process group holds an agent: a ⌃C or a SIGINT to the group
    /// reaches the agent too (Codex's children keep its group).
    package var groupHoldsAgent = false
    /// A terraform, tofu or terragrunt write — apply, destroy, import,
    /// `state …` — by its name and its masked argv's operation
    /// (`TerraformCommandLine.parse(arguments:)`, `isWrite`), wherever it
    /// runs: its words for the sheet, "terraform apply".
    package var terraformWrite: String?
    /// A helm or pulumi write — `helm upgrade`, `install` or `rollback`,
    /// `pulumi up` or `destroy` — by its name and its masked argv's
    /// operation (`releaseWrite(name:arguments:)`), wherever it runs, or
    /// what runs under one (pulumi's plugins hold its ports on 127.0.0.1):
    /// its words for the sheet, "helm upgrade". A release stopped
    /// mid-upgrade stays pending-upgrade (6.10).
    package var releaseWrite: String?
    /// It ignores SIGHUP (`p_sigignore`) or was detached on purpose (tmux,
    /// screen, ssh-agent, 6.5 rule 5): it chose to outlive its terminal.
    package var detached = false
    /// A GUI app, anything inside an `.app`, or an app started from a pane.
    package var isApp = false
    /// Inside an `.app` without being the app (a helper): Stop warns, a
    /// Suspend asks — a stopped helper can freeze its app.
    package var insideApp = false
    /// Stopped (T), and by whom; nil while it runs.
    package var stopped: ActivityStopper?
    /// Activity put it in the background (3.9: nothing else can say so).
    package var backgroundedHere = false
    /// It leads its process group (`pgid == pid`).
    package var leadsGroup = false
    /// Its group holds a process outside its subtree: Stop Its Group says
    /// more than Stop Its Tree.
    package var groupBeyondTree = false
    /// What its group holds that no group Stop may reach — "a shell", "an
    /// agent", "a terraform write", "Overterm's own" —; nil when nothing.
    package var groupHolds: String?

    package init(
        _ kind: ActivityClass, pid: pid_t, effectiveUID: uid_t, realUID: uid_t? = nil, savedUID: uid_t? = nil, isZombie: Bool = false,
        inForeground: Bool = false, groupHoldsAgent: Bool = false, terraformWrite: String? = nil, releaseWrite: String? = nil, detached: Bool = false,
        isApp: Bool = false, insideApp: Bool = false, stopped: ActivityStopper? = nil
    ) {
        self.kind = kind
        self.pid = pid
        self.effectiveUID = effectiveUID
        self.realUID = realUID ?? effectiveUID
        self.savedUID = savedUID ?? effectiveUID
        self.isZombie = isZombie
        self.inForeground = inForeground
        self.groupHoldsAgent = groupHoldsAgent
        self.terraformWrite = terraformWrite
        self.releaseWrite = releaseWrite
        self.detached = detached
        self.isApp = isApp
        self.insideApp = insideApp
        self.stopped = stopped
    }

    /// Whether it runs as `user` and as nobody else — its effective, real
    /// and saved uids all `user`'s —, as `ProcessSignals` asks
    /// (`ActivityProcess.isWhollyOwn`).
    package func isWhollyOwn(by user: uid_t) -> Bool { effectiveUID == user && realUID == user && savedUID == user }

    /// The tools whose writes `releaseWrite` names, and those writes.
    package static let releaseWrites: [String: Set<String>] = [
        "helm": ["upgrade", "install", "rollback"],
        // `update` is `up`'s other name, `down` `destroy`'s.
        "pulumi": ["up", "update", "destroy", "down"],
    ]

    /// Their global flags that take a value as the next word: what stands
    /// between the tool and its operation (`helm --kube-context acme-prod
    /// -n acme upgrade`, `pulumi -C infra up`).
    package static let releaseValueFlags: [String: Set<String>] = [
        "helm": [
            "--burst-limit", "--content-cache", "--kube-apiserver", "--kube-as-group", "--kube-as-user", "--kube-ca-file", "--kube-context",
            "--kube-tls-server-name", "--kube-token", "--kubeconfig", "-n", "--namespace", "--qps", "--registry-config", "--repository-cache",
            "--repository-config",
        ],
        "pulumi": ["-C", "--color", "--cwd", "--memprofilerate", "--otel-traces", "--profiling", "--tracing", "--tracing-header", "-v", "--verbose"],
    ]

    /// A helm or pulumi write by a process's name — its executable's, never
    /// argv[0], which a process sets itself — and its argv's words, masked
    /// as the census keeps them: "helm upgrade", "pulumi up"; nil for
    /// anything else (`helm list`, `pulumi preview`, `helm template … --set
    /// mode=upgrade`). Its operation is the first word that is neither a
    /// flag nor a global flag's value. Pure.
    package static func releaseWrite(name: String, arguments: [String]) -> String? {
        guard let writes = releaseWrites[name] else { return nil }
        let valued = releaseValueFlags[name] ?? []
        var words = arguments.dropFirst()
        while let word = words.popFirst() {
            if word == "--" { return nil }
            if word.hasPrefix("-") {
                if !word.contains("="), valued.contains(word) { _ = words.popFirst() }
                continue
            }
            return writes.contains(word) ? "\(name) \(word)" : nil
        }
        return nil
    }
}

/// What a verb does to a target (6.10): refused, with why; done — asked
/// first, and how; or the owner's own verb, asked as the rule says. The
/// class table is the only source of who is asked: each rule carries it.
package enum ActivityRule: Hashable, Sendable {
    /// Not offered: greyed, with why.
    case refused(String)
    /// Done as `action`, asked first when `confirm`, in a critical sheet
    /// when `critical`.
    case allowed(ActivityAction, confirm: Bool, critical: Bool)
    /// The owner's own verb, asked by Activity first when `confirm`.
    case route(ActivityRoute, confirm: Bool)

    package var refusal: String? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}

/// What an allowed verb does.
package enum ActivityAction: Hashable, Sendable {
    /// ⌃C typed into the pane — a key event to its surface, never a SIGINT
    /// to its group: a full-screen program reads ⌃C as a byte. At the
    /// button the surface's foreground group must still be the target's.
    case interruptPane
    /// A signal, through `ProcessSignals`.
    case signal(ActivitySignal)
    /// The signal to its subtree as the sheet lists it, each member by its
    /// own token, parents first (CONT children first).
    case signalTree(ActivitySignal)
    /// The signal to its process group, every member checked first.
    case signalGroup(ActivitySignal)
    /// SIGSTOP and SIGCONT, kept by identity.
    case suspend
    case resume
    /// `PRIO_DARWIN_BG`, and back.
    case background
    case normalPriority
    /// nice raised: can't be lowered back without an administrator.
    case lowerPriority
    /// An app asked to quit (`NSRunningApplication.terminate`), or ended
    /// without asking (`forceTerminate`).
    case quitApp
    case forceQuitApp
}

/// An owner's own verb, where the owner, not a signal, ends it (6.10, 6.8).
/// Whether Activity asks first is the rule's (`ActivityRule.route`): a
/// container's and a forward's Stop act at once when called, the apply
/// view's first Stop sends its SIGINT unasked.
package enum ActivityRoute: Hashable, Sendable {
    /// Close This Pane… — Close Tab… for a tab of one pane: asked by
    /// Activity, then Terraform's close guard runs.
    case closePane
    /// Stop Container, through the Docker page.
    case stopContainer
    /// Stop Forward (`KubeForwards.stop`).
    case stopForward
    /// Disconnect the tunnel's connection.
    case disconnect
    /// Restart Language Server.
    case restartLanguageServer
    /// The terraform run's own Stop.
    case stopTerraformRun
    /// Suspend Tab / Resume Tab, for the pane's shell and what Suspend Tab
    /// stopped.
    case suspendTab
    case resumeTab
    /// Suspended with its pane: the shell too, or it takes the terminal back.
    case suspendPane
}

/// The policy (6.10): what each verb does to each class of process — the
/// whole class table, the only source of who is asked. Pure, and tested
/// verb by verb and class by class, as `KubeProcessCheck` is.
/// `ProcessSignals` makes its own refusals under it, whatever it says.
package enum ActivitySignalCheck {
    /// What `verb` does to `target`. `parent`: Stop Its Parent's, read
    /// with the same facts — its own class decides.
    package static func rule(_ verb: ActivityVerb, for target: ActivityTarget, parent: ActivityTarget? = nil, user: uid_t = getuid()) -> ActivityRule {
        switch verb {
        case .free: return free(target, user: user)
        case .stopParent: return stopParent(of: target, parent: parent, user: user)
        case .send(let signal): return send(signal, to: target, user: user)
        default: break
        }
        if let owned = owners(verb, target) { return owned }
        if let never = never(target, user: user) { return never }
        switch verb {
        case .stop: return stop(target)
        case .interrupt: return interrupt(target)
        case .interruptTurn: return interruptTurn(target)
        case .stopAgent: return target.kind == .agent ? stopAgentRule : .refused(notAnAgent)
        case .forceQuit: return forceQuit(target)
        case .stopTree: return stopTree(target)
        case .stopGroup: return stopGroup(target)
        case .suspend: return suspend(target)
        case .resume: return resume(target)
        case .background, .lowerPriority:
            if target.terraformWrite != nil { return .refused(terraformPriority) }
            return verb == .background ? .allowed(.background, confirm: false, critical: false) : .allowed(.lowerPriority, confirm: true, critical: false)
        case .runNormally:
            return target.backgroundedHere ? .allowed(.normalPriority, confirm: false, critical: false) : .refused(notBackgrounded)
        case .freePort: return interruptsPane(target) && target.terraformWrite == nil ? .allowed(.interruptPane, confirm: true, critical: target.releaseWrite != nil) : stop(target)
        case .free, .stopParent, .send: return .refused(helper)
        }
    }

    // MARK: Words

    package static let daemon = "Part of macOS; it would start again."
    package static let anotherOverterm = "Another Overterm: quit it there."
    package static let engine = "Docker's engine or its VM: it holds every container's ports, and containers run inside it — stop a container, or quit the app from its menu."
    package static let paneSession = "The pane's own shell: close the pane or the tab instead."
    package static let container = "A container: stop it on the Docker page."
    package static let terraformKill = "SIGKILL can leave the state locked and half written; Interrupt asks terraform to stop safely."
    package static let terraformOnly = "A terraform write: Interrupt only — SIGTERM, SIGKILL or any other signal can leave its state locked and half written."
    package static let terraformSuspend = "A terraform write: stopped, it holds its state's lock — Interrupt it instead."
    package static let terraformPriority = "A terraform write: Overterm changes nothing of it but Interrupt."
    package static let terraformBulk = "A terraform write is in no bulk Stop: Interrupt it alone."
    package static let notAnAgent = "Not an agent: Stop… instead."
    package static let agentNotForeground = "The agent isn't the pane's foreground job now: ⌃C typed into the pane would reach another."
    package static let notForeground = "Not the pane's foreground job: ⌃C typed into the pane would reach another — Stop… instead."
    package static let groupHoldsAgentWords = "Its process group holds the agent: ⌃C would reach the agent too — Stop… instead."
    package static let underAgent = "It runs under an agent: ⌃C would reach the agent — Stop… instead."
    package static let noPane = "It runs in no pane: ⌃C reaches only a pane's foreground job — Send a Signal ▸ INT instead."
    package static let appInterrupt = "An app: Quit… instead."
    package static let appBulk = "An app is never in a bulk Stop: Quit… it alone."
    package static let notLeader = "It doesn't lead its process group: Stop Its Tree… instead."
    package static let groupIsTree = "Its process group is its tree: Stop Its Tree… instead."
    package static let alreadyStopped = "It is stopped already."
    package static let notStopped = "It isn't stopped."
    package static let traced = "A debugger holds it: SIGCONT would interfere with the debugger."
    package static let jobControl = "Stopped by its shell (⌃Z): `fg` in its tab — a bare SIGCONT would run it behind a shell that still thinks it stopped."
    package static let notStoppedHere = "Activity didn't stop it: resume it where it was stopped."
    package static let notBackgrounded = "Activity didn't put it in the background: nothing to put back."
    package static let parentUnknown = "Its parent isn't known now."
    package static let parentLaunchd = "launchd is its parent: it collects it shortly."
    package static let parentOverterm = "Overterm is its parent: Overterm will collect it; report it if it stays."
    package static let parentStopped = "Its parent is stopped: Resume it first, or its zombies wait."

    package static let macOS = ActivitySignalRefusal.system.reason
    package static let overterm = ActivitySignalRefusal.overterm.reason
    package static let ended = "It has ended: its parent hasn't collected it yet."
    package static let detached =
        "It chose to outlive its terminal — it ignores hangups, or was detached on purpose: stop it from Activity, where it is picked alone."
    package static let app = "An app: quit it from its menu, or from Activity."
    package static let kubectlProxy = "A kubectl proxy of Overterm's: it closes when idle, and at quit."
    package static let helper = ActivitySignalRefusal.helper.reason

    /// Why one that doesn't run as the user alone is refused: root's, a
    /// setuid program the user started — as root or another user, or as
    /// the user for now —, another user's, or root's running as the user
    /// for now.
    package static func notYours(_ target: ActivityTarget, user: uid_t) -> String {
        if target.realUID == user, target.effectiveUID != user {
            let runsAs = target.effectiveUID == 0 ? "root" : "another user"
            return "It runs as \(runsAs) — a setuid program you started: Overterm signals only what runs as you."
        }
        if target.effectiveUID == user {
            if target.realUID == user {
                return "A setuid program you started, running as you for now — it can take its owner's rights back: Overterm doesn't signal it."
            }
            let whose = target.realUID == 0 ? "Root's" : "Another user's"
            return "\(whose), running as you for now: Overterm signals only what runs as you alone."
        }
        if target.effectiveUID == 0 { return "Owned by root: Overterm doesn't signal processes running as root." }
        return "Owned by another user: Overterm signals only what runs as you."
    }

    /// The pill's Free… (6.12), first rule first.
    private static func free(_ target: ActivityTarget, user: uid_t) -> ActivityRule {
        // The owners' own verbs, each asked by Activity first: a container
        // (its Stop acts at once), the pane itself (its login runs as
        // root, and ends with the pane), Overterm's helpers.
        switch target.kind {
        case .container: return .route(.stopContainer, confirm: true)
        case .paneSession: return .route(.closePane, confirm: true)
        case .helper(let helper): return route(helper)
        case .overterm: return .refused(overterm)
        case .anotherOverterm: return .refused(anotherOverterm)
        case .engine: return .route(.stopContainer, confirm: true)
        case .macOS: return .refused(target.pid <= 1 ? macOS : daemon)
        case .paneJob, .agent, .agentChild, .leftTerminal, .leftBehind, .elsewhere: break
        }
        if target.pid <= 1 { return .refused(macOS) }
        if !target.isWhollyOwn(by: user) { return .refused(notYours(target, user: user)) }
        if target.isZombie { return .refused(ended) }
        // A terraform write, wherever it runs: Interrupt only, never TERM
        // or KILL — they can leave its state locked and half written. ⌃C
        // typed where it is the pane's own job, else SIGINT to terraform
        // alone, never the agent or shell whose group it shares.
        if target.terraformWrite != nil {
            return .allowed(interruptsPane(target) ? .interruptPane : .signal(.int), confirm: true, critical: false)
        }
        // The agent: it stops mid-task.
        if target.kind == .agent { return .allowed(.signal(.term), confirm: true, critical: true) }
        if target.isApp { return .refused(app) }
        if target.detached { return .refused(detached) }
        // A helm or pulumi write: what its job gets, in a critical sheet —
        // a release stopped mid-upgrade stays pending-upgrade.
        let critical = target.releaseWrite != nil
        // The pane's foreground job, nothing of an agent's in its group.
        if interruptsPane(target) { return .allowed(.interruptPane, confirm: true, critical: critical) }
        // Another job of the pane, one that left its terminal, an agent's
        // child — never interrupted: a ⌃C would reach the agent too.
        return .allowed(.signal(.term), confirm: true, critical: critical)
    }

    // MARK: The class table

    /// The owners' own rows, before whose a process is: a container, the
    /// pane itself, Overterm and its helpers, another Overterm, the engine
    /// and its VM, macOS's daemons.
    private static func owners(_ verb: ActivityVerb, _ target: ActivityTarget) -> ActivityRule? {
        switch target.kind {
        case .container:
            return verb == .stop || verb == .freePort ? .route(.stopContainer, confirm: true) : .refused(container)
        case .overterm: return .refused(overterm)
        case .anotherOverterm: return .refused(anotherOverterm)
        case .helper(let kind):
            return verb == .stop || verb == .interrupt || verb == .freePort ? route(kind) : .refused(kind == .kubectlProxy ? kubectlProxy : helper)
        case .paneSession:
            switch verb {
            case .stop, .interrupt, .forceQuit, .stopTree: return .route(.closePane, confirm: true)
            case .suspend: return .route(.suspendTab, confirm: false)
            case .resume: return target.stopped == nil ? .refused(notStopped) : .route(.resumeTab, confirm: false)
            default: return .refused(paneSession)
            }
        case .engine: return verb == .freePort ? .route(.stopContainer, confirm: true) : .refused(engine)
        case .macOS: return .refused(target.pid <= 1 ? macOS : daemon)
        case .paneJob, .agent, .agentChild, .leftTerminal, .leftBehind, .elsewhere: return nil
        }
    }

    /// The never-list's facts: launchd and the kernel, what doesn't run as
    /// the user alone, a zombie.
    private static func never(_ target: ActivityTarget, user: uid_t) -> ActivityRule? {
        if target.pid <= 1 { return .refused(macOS) }
        if !target.isWhollyOwn(by: user) { return .refused(notYours(target, user: user)) }
        if target.isZombie { return .refused(ended) }
        return nil
    }

    /// Stop…: SIGTERM, asked — an agent's is Stop Agent, an app's Quit, a
    /// terraform write's Interrupt; a helm or pulumi write's critical.
    private static func stop(_ target: ActivityTarget) -> ActivityRule {
        if target.terraformWrite != nil { return interrupt(target) }
        if target.kind == .agent { return stopAgentRule }
        if target.isApp { return .allowed(.quitApp, confirm: true, critical: false) }
        return .allowed(.signal(.term), confirm: true, critical: target.releaseWrite != nil)
    }

    private static let stopAgentRule = ActivityRule.allowed(.signal(.term), confirm: true, critical: true)

    /// Interrupt…: ⌃C typed into the pane, for its foreground job with no
    /// agent in its group; a terraform write's anywhere — typed where it is
    /// the pane's job, else SIGINT as `TerraformCloseGuard.interruptTarget`
    /// sends it: to its group when terraform leads it and the group holds
    /// nothing no group send may reach, else to terraform alone.
    private static func interrupt(_ target: ActivityTarget) -> ActivityRule {
        if target.terraformWrite != nil {
            let action: ActivityAction =
                interruptsPane(target) ? .interruptPane : target.leadsGroup && target.groupHolds == nil ? .signalGroup(.int) : .signal(.int)
            return .allowed(action, confirm: true, critical: false)
        }
        if target.kind == .agent { return interruptTurn(target) }
        if target.isApp { return .refused(appInterrupt) }
        switch target.kind {
        case .paneJob:
            guard target.inForeground else { return .refused(notForeground) }
            if target.groupHoldsAgent { return .refused(groupHoldsAgentWords) }
            return .allowed(.interruptPane, confirm: true, critical: target.releaseWrite != nil)
        case .agentChild: return .refused(underAgent)
        default: return .refused(noPane)
        }
    }

    /// Interrupt Turn…: ⌃C typed into the agent's pane — Claude Code and
    /// Codex cancel the turn. Asked, plainly.
    private static func interruptTurn(_ target: ActivityTarget) -> ActivityRule {
        guard target.kind == .agent else { return .refused(notAnAgent) }
        guard target.inForeground else { return .refused(agentNotForeground) }
        return .allowed(.interruptPane, confirm: true, critical: false)
    }

    /// Force Quit…: SIGKILL to the process alone, critical; never a
    /// terraform write's.
    private static func forceQuit(_ target: ActivityTarget) -> ActivityRule {
        if target.terraformWrite != nil { return .refused(terraformKill) }
        if target.isApp { return .allowed(.forceQuitApp, confirm: true, critical: true) }
        return .allowed(.signal(.kill), confirm: true, critical: true)
    }

    /// Stop Its Tree…: the subtree, parents first, each member by its own
    /// token — the sheet lists each, and what it leaves out
    /// (`treeMemberRefusal`).
    private static func stopTree(_ target: ActivityTarget) -> ActivityRule {
        if target.terraformWrite != nil { return .refused(terraformBulk) }
        if target.isApp { return .refused(appBulk) }
        return .allowed(.signalTree(.term), confirm: true, critical: target.kind == .agent || target.releaseWrite != nil)
    }

    /// Stop Its Group…: offered only where the group says more than the
    /// tree, and holds no shell, `login`, agent, terraform write or
    /// Overterm's own.
    private static func stopGroup(_ target: ActivityTarget) -> ActivityRule {
        if target.terraformWrite != nil { return .refused(terraformBulk) }
        if target.isApp { return .refused(appBulk) }
        if target.kind == .agent { return .refused("Its process group holds the agent: Stop Agent… instead.") }
        guard target.leadsGroup else { return .refused(notLeader) }
        if let holds = target.groupHolds { return .refused("Its process group holds \(holds): no group Stop reaches it.") }
        guard target.groupBeyondTree else { return .refused(groupIsTree) }
        return .allowed(.signalGroup(.term), confirm: true, critical: target.releaseWrite != nil)
    }

    /// Stop Its Parent…: for a zombie, or a supervised child — the
    /// parent's own class decides, checked again here.
    private static func stopParent(of target: ActivityTarget, parent: ActivityTarget?, user: uid_t) -> ActivityRule {
        guard let parent else { return .refused(parentUnknown) }
        if parent.pid <= 1 { return .refused(parentLaunchd) }
        if parent.kind == .overterm { return .refused(parentOverterm) }
        if parent.stopped != nil, parent.isWhollyOwn(by: user) { return .refused(parentStopped) }
        return rule(.stop, for: parent, user: user)
    }

    /// Suspend: SIGSTOP — a pane's job with its pane, no ask; an app's or
    /// anything inside an `.app`'s, or a helm or pulumi write's, asked.
    private static func suspend(_ target: ActivityTarget) -> ActivityRule {
        if target.terraformWrite != nil { return .refused(terraformSuspend) }
        if target.stopped != nil { return .refused(alreadyStopped) }
        if target.kind == .paneJob || target.kind == .agent { return .route(.suspendPane, confirm: false) }
        return .allowed(.suspend, confirm: target.isApp || target.insideApp || target.releaseWrite != nil, critical: false)
    }

    /// Resume: only what Activity stopped; Suspend Tab's through Resume
    /// Tab; never a ⌃Z job's (its shell's `fg`) nor a traced one's.
    private static func resume(_ target: ActivityTarget) -> ActivityRule {
        switch target.stopped {
        case nil: return .refused(notStopped)
        case .traced: return .refused(traced)
        case .jobControl: return .refused(jobControl)
        case .unknown: return .refused(notStoppedHere)
        case .suspendTab: return .route(.resumeTab, confirm: false)
        case .activity: return .allowed(.resume, confirm: target.isApp || target.insideApp, critical: false)
        }
    }

    /// Send a Signal ▸: under the rule of the verb it equals — KILL as
    /// Force Quit, INT to a pane's job as Interrupt, STOP and CONT as
    /// Suspend and Resume, HUP to a pane's shell as its close, TERM as
    /// Stop —, a terraform write's anything but INT refused. Always asked.
    private static func send(_ signal: ActivitySignal, to target: ActivityTarget, user: uid_t) -> ActivityRule {
        if target.kind == .paneSession {
            switch signal {
            case .stop: return asked(.route(.suspendTab, confirm: true))
            case .cont: return asked(rule(.resume, for: target, user: user))
            default: return .route(.closePane, confirm: true)
            }
        }
        if let owned = owners(.send(signal), target) { return owned }
        if let never = never(target, user: user) { return never }
        if target.terraformWrite != nil { return signal == .int ? interrupt(target) : .refused(signal == .kill ? terraformKill : terraformOnly) }
        switch signal {
        case .kill: return forceQuit(target)
        case .term: return stop(target)
        case .stop: return asked(suspend(target))
        case .cont: return asked(resume(target))
        case .int:
            if target.kind == .agent { return interruptTurn(target) }
            if interruptsPane(target) { return interrupt(target) }
            return .allowed(.signal(.int), confirm: true, critical: target.releaseWrite != nil)
        case .hup, .quit, .usr1, .usr2:
            return .allowed(.signal(signal), confirm: true, critical: target.kind == .agent || target.releaseWrite != nil)
        }
    }

    /// `rule`, asked: Send a Signal always asks.
    private static func asked(_ rule: ActivityRule) -> ActivityRule {
        switch rule {
        case .refused: rule
        case .allowed(let action, _, let critical): .allowed(action, confirm: true, critical: critical)
        case .route(let route, _): .route(route, confirm: true)
        }
    }

    /// Why a member of a tree or a group is left out of its bulk Stop (6.10
    /// never-list 12): a terraform write (Interrupt offered for it alone),
    /// what isn't the user's alone, the pane itself, an agent, Overterm's
    /// own, an app, what chose to outlive its terminal. Nil: it is stopped
    /// with the rest.
    package static func bulkRefusal(_ member: ActivityTarget, user: uid_t = getuid()) -> String? {
        if member.terraformWrite != nil { return "a terraform write: Interrupt it alone" }
        if member.pid <= 1 || !member.isWhollyOwn(by: user) { return "not yours alone" }
        if member.isZombie { return "it has ended" }
        switch member.kind {
        case .paneSession: return "the pane's shell"
        case .agent: return "an agent: Stop Agent… alone"
        case .overterm, .anotherOverterm, .helper: return "Overterm's own"
        case .engine: return "Docker's engine"
        case .macOS: return "part of macOS"
        case .container, .paneJob, .agentChild, .leftTerminal, .leftBehind, .elsewhere: break
        }
        if member.isApp || member.insideApp { return "an app: Quit… it alone" }
        if member.detached { return "it chose to outlive its terminal: stop it alone" }
        return nil
    }

    /// What a group member is, when no group Stop may reach it: what
    /// `groupHolds` says.
    /// `killpg` can't leave a member out as a tree's send does, so a group
    /// holding any of never-list 12's is refused whole: a terraform write,
    /// what isn't the user's alone, the pane itself, an agent, Overterm's
    /// own, the engine, macOS's, an app or a helper inside one, what chose
    /// to outlive its terminal.
    package static func groupBlocker(_ member: ActivityTarget, user: uid_t = getuid()) -> String? {
        if member.pid <= 1 { return "part of macOS" }
        if member.terraformWrite != nil { return "a terraform write" }
        if !member.isWhollyOwn(by: user) { return "another user's process" }
        switch member.kind {
        case .paneSession: return "the pane's shell"
        case .agent: return "an agent"
        case .overterm, .anotherOverterm, .helper: return "Overterm's own"
        case .engine: return "Docker's engine"
        case .macOS: return "part of macOS"
        case .container, .paneJob, .agentChild, .leftTerminal, .leftBehind, .elsewhere: break
        }
        if member.isApp || member.insideApp { return "an app" }
        if member.detached { return "a process that chose to outlive its terminal" }
        return nil
    }

    /// ⌃C typed into its pane reaches it as Ctrl-C would, and no agent:
    /// the pane's foreground job.
    private static func interruptsPane(_ target: ActivityTarget) -> Bool {
        target.kind == .paneJob && target.inForeground && !target.groupHoldsAgent
    }

    /// A helper's own verb (6.10's helpers row), asked by Activity first:
    /// each ends what holds the port — a forward's Stop at once, the apply
    /// view's first Stop unasked.
    private static func route(_ kind: ActivityHelper) -> ActivityRule {
        switch kind {
        case .forward: .route(.stopForward, confirm: true)
        case .tunnel: .route(.disconnect, confirm: true)
        case .languageServer: .route(.restartLanguageServer, confirm: true)
        case .terraformRun: .route(.stopTerraformRun, confirm: true)
        case .kubectlProxy: .refused(kubectlProxy)
        case .other: .refused(helper)
        }
    }
}
