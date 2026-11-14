import Darwin

/// What a person asks of a process (docs/design/activity/analysis.md,
/// 6.10). Stage 0 has the pane pill's one; the page's — Stop, Interrupt,
/// Stop Agent, Force Quit, Send a Signal, Suspend… — come with the whole
/// class table in stage 2.
enum ActivityVerb: String, CaseIterable, Sendable {
    /// The pill's Free :N…: whatever ends the port's holder the way its
    /// class asks (6.12) — each asked.
    case free
}

/// A process's class to the policy: 6.10's rows, as far as a pane's port
/// pill can name one (6.12) — the pane's own processes, Overterm's
/// helpers, a container. Stage 2 adds the page's: Left Behind, yours
/// elsewhere, another Overterm, the engine and its VM, macOS's daemons.
enum ActivityClass: Hashable, Sendable {
    /// A job in a pane: the user's, under its `login`.
    case paneJob
    /// The pane's agent: claude or codex.
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
}

/// Which of Overterm's helpers, for its own verb (6.10's helpers row).
enum ActivityHelper: Hashable, Sendable, CaseIterable {
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
struct ActivityTarget: Hashable, Sendable {
    var kind: ActivityClass
    /// Its pid; 0 for a container's port, which none of the user's holds.
    var pid: pid_t
    /// Its effective uid, read fresh: whose it is to the kernel's reads. A
    /// setuid program the user started — every terminal's `login` — is
    /// root's here.
    var effectiveUID: uid_t
    /// Its real uid: the user's for a setuid program the user started,
    /// which `kill(2)` would let through (3.2).
    var realUID: uid_t
    /// Its saved uid: root's for a setuid-root program that set its
    /// effective uid to the user's for a while, and can take root back.
    var savedUID: uid_t
    var isZombie = false
    /// Its process group is its pane's foreground group (`e_tpgid`): what
    /// ⌃C typed into the pane reaches.
    var inForeground = false
    /// Its process group holds an agent: a ⌃C or a SIGINT to the group
    /// reaches the agent too (Codex's children keep its group).
    var groupHoldsAgent = false
    /// A terraform, tofu or terragrunt write — apply, destroy, import,
    /// `state …` — by its name and its masked argv's operation
    /// (`TerraformCommandLine.parse(arguments:)`, `isWrite`), wherever it
    /// runs: its words for the sheet, "terraform apply".
    var terraformWrite: String?
    /// A helm or pulumi write — `helm upgrade`, `install` or `rollback`,
    /// `pulumi up` or `destroy` — by its name and its masked argv's
    /// operation (`releaseWrite(name:arguments:)`), wherever it runs, or
    /// what runs under one (pulumi's plugins hold its ports on 127.0.0.1):
    /// its words for the sheet, "helm upgrade". A release stopped
    /// mid-upgrade stays pending-upgrade (6.10).
    var releaseWrite: String?
    /// It ignores SIGHUP (`p_sigignore`) or was detached on purpose (tmux,
    /// screen, ssh-agent, 6.5 rule 5): it chose to outlive its terminal.
    var detached = false
    /// A GUI app, anything inside an `.app`, or an app started from a pane.
    var isApp = false

    init(
        _ kind: ActivityClass, pid: pid_t, effectiveUID: uid_t, realUID: uid_t? = nil, savedUID: uid_t? = nil, isZombie: Bool = false,
        inForeground: Bool = false, groupHoldsAgent: Bool = false, terraformWrite: String? = nil, releaseWrite: String? = nil, detached: Bool = false,
        isApp: Bool = false
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
    }

    /// Whether it runs as `user` and as nobody else — its effective, real
    /// and saved uids all `user`'s —, as `ProcessSignals` asks
    /// (`ActivityProcess.isWhollyOwn`).
    func isWhollyOwn(by user: uid_t) -> Bool { effectiveUID == user && realUID == user && savedUID == user }

    /// The tools whose writes `releaseWrite` names, and those writes.
    static let releaseWrites: [String: Set<String>] = [
        "helm": ["upgrade", "install", "rollback"],
        // `update` is `up`'s other name, `down` `destroy`'s.
        "pulumi": ["up", "update", "destroy", "down"],
    ]

    /// Their global flags that take a value as the next word: what stands
    /// between the tool and its operation (`helm --kube-context acme-prod
    /// -n acme upgrade`, `pulumi -C infra up`).
    static let releaseValueFlags: [String: Set<String>] = [
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
    static func releaseWrite(name: String, arguments: [String]) -> String? {
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
enum ActivityRule: Hashable, Sendable {
    /// Not offered: greyed, with why.
    case refused(String)
    /// Done as `action`, asked first when `confirm`, in a critical sheet
    /// when `critical`.
    case allowed(ActivityAction, confirm: Bool, critical: Bool)
    /// The owner's own verb, asked by Activity first when `confirm`.
    case route(ActivityRoute, confirm: Bool)

    var refusal: String? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}

/// What an allowed verb does.
enum ActivityAction: Hashable, Sendable {
    /// ⌃C typed into the pane — a key event to its surface, never a SIGINT
    /// to its group: a full-screen program reads ⌃C as a byte. At the
    /// button the surface's foreground group must still be the target's.
    case interruptPane
    /// A signal, through `ProcessSignals`.
    case signal(ActivitySignal)
}

/// An owner's own verb, where the owner, not a signal, ends it (6.10, 6.8).
/// Whether Activity asks first is the rule's (`ActivityRule.route`): a
/// container's and a forward's Stop act at once when called, the apply
/// view's first Stop sends its SIGINT unasked.
enum ActivityRoute: Hashable, Sendable {
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
}

/// The policy (6.10): what each verb does to each class of process. Pure,
/// and tested class by class, as `KubeProcessCheck` is. Stage 0's is the
/// class table restricted to what a pane's port pill can name (6.12);
/// stage 2's is the whole table. `ProcessSignals` makes its own refusals
/// under it, whatever it says.
enum ActivitySignalCheck {
    static func rule(_ verb: ActivityVerb, for target: ActivityTarget, user: uid_t = getuid()) -> ActivityRule {
        switch verb {
        case .free: free(target, user: user)
        }
    }

    static let macOS = ActivitySignalRefusal.system.reason
    static let overterm = ActivitySignalRefusal.overterm.reason
    static let ended = "It has ended: its parent hasn't collected it yet."
    static let detached =
        "It chose to outlive its terminal — it ignores hangups, or was detached on purpose: stop it from Activity, where it is picked alone."
    static let app = "An app: quit it from its menu, or from Activity."
    static let kubectlProxy = "A kubectl proxy of Overterm's: it closes when idle, and at quit."
    static let helper = ActivitySignalRefusal.helper.reason

    /// Why one that doesn't run as the user alone is refused: root's, a
    /// setuid program the user started — as root or another user, or as
    /// the user for now —, another user's, or root's running as the user
    /// for now.
    static func notYours(_ target: ActivityTarget, user: uid_t) -> String {
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
        case .paneJob, .agent, .agentChild, .leftTerminal: break
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
