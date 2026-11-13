import Foundation

/// A process Overterm may start for a context, as Section 5's table names
/// them (docs/design/kubernetes/analysis.md). They run with the user's own
/// kubeconfig and credentials, never the proxy's socket — so whether one
/// may start on a context is a check in Overterm's code
/// (`KubeProcessCheck`), the socket can't enforce it. Only some are built
/// yet (`KubeCommands`); the rest are here so the rule for each is said,
/// and tested, before its verb exists.
enum KubeProcessVerb: String, CaseIterable, Sendable {
    /// `kubectl logs -f`, in a tab (`t`).
    case followLogs
    /// `kubectl port-forward`, a managed process.
    case portForward
    /// `kubectl exec -it`, in a tab (`e`).
    case shell
    /// `kubectl attach -it`, in a tab (`A`).
    case attach
    /// `kubectl cp POD:PATH LOCAL` and `kubectl cp LOCAL POD:PATH`, in a tab
    /// (stage 4, `KubePodCopy`): tar through exec; a copy in changes the
    /// container's files.
    case copyOut, copyIn
    /// `kubectl debug` (an ephemeral container), `drain`, `rollout undo`.
    case debug, drain, rolloutUndo
    /// `helm rollback`, `upgrade`, `uninstall`.
    case helmRollback, helmUpgrade, helmUninstall
    /// `kubectl debug node/…`.
    case nodeShell
    /// `argocd app sync` (core mode), `flux reconcile … --with-source` (stage 4).
    case argoSync, fluxReconcile
    /// What changes nothing: `auth can-i`, `auth whoami`, `version`, `kustomize`; `helm template`.
    case canI, whoami, version, kustomize, helmTemplate
    /// Terminal in this context: the user's own kubectl, nothing enforced inside it.
    case terminal

    var title: String {
        switch self {
        case .followLogs: "Follow Logs in a Tab"
        case .portForward: "Port-forward"
        case .shell: "Shell"
        case .attach: "Attach"
        case .copyOut: "Copy from Container"
        case .copyIn: "Copy into Container"
        case .debug: "Debug Container"
        case .drain: "Drain"
        case .rolloutUndo: "Roll Back"
        case .helmRollback: "Helm Rollback"
        case .helmUpgrade: "Helm Upgrade"
        case .helmUninstall: "Helm Uninstall"
        case .nodeShell: "Node Shell"
        case .argoSync: "Argo CD Sync"
        case .fluxReconcile: "Flux Reconcile with Source"
        case .canI: "kubectl auth can-i"
        case .whoami: "kubectl auth whoami"
        case .version: "kubectl version"
        case .kustomize: "kubectl kustomize"
        case .helmTemplate: "helm template"
        case .terminal: "Terminal in This Context"
        }
    }

    /// Whether it changes the cluster — its objects, or a container's files: refused on a read-only context.
    var writes: Bool {
        switch self {
        case .debug, .drain, .rolloutUndo, .helmRollback, .helmUpgrade, .helmUninstall, .nodeShell, .argoSync, .fluxReconcile, .copyIn: true
        default: false
        }
    }

    /// What `kubectl auth can-i` is asked before it starts.
    var access: KubeAccess? {
        switch self {
        case .followLogs: .logs
        case .portForward: .portForward
        case .shell, .copyOut, .copyIn: .exec
        case .attach: .attach
        default: nil
        }
    }
}

/// One permission `kubectl auth can-i` is asked about: `create pods/exec`.
struct KubeAccess: Hashable, Sendable, CustomStringConvertible {
    var verb: String
    var resource: String

    static let exec = KubeAccess(verb: "create", resource: "pods/exec")
    static let attach = KubeAccess(verb: "create", resource: "pods/attach")
    static let portForward = KubeAccess(verb: "create", resource: "pods/portforward")
    static let logs = KubeAccess(verb: "get", resource: "pods/log")

    var description: String { "\(verb) \(resource)" }
}

/// Whether a process may start on a context, and what comes first. Pure.
struct KubeProcessRule: Equatable, Sendable {
    /// Why it may not start here; nil when it may.
    var refused: String?
    /// Asked of `kubectl auth can-i` first; a no greys the verb with why.
    var access: KubeAccess?
    /// Confirmed first, naming the context (a shell or attach on
    /// production: once per pod and session, rule 5; a log followed in a
    /// tab on production: once per context and session).
    var confirm = false
    /// The object's name typed to confirm (rule 4).
    var typedName = false

    var allowed: Bool { refused == nil }
}

/// The process class check (Section 5's table, rule 1): every process verb
/// against the context's class and settings. `KubeCommands` builds nothing
/// this refuses. Pure, and tested verb by verb, class by class.
enum KubeProcessCheck {
    static func rule(_ verb: KubeProcessVerb, for context: KubeContext) -> KubeProcessRule {
        rule(verb, class: context.contextClass, writable: context.isWritable, settings: context.settings)
    }

    /// Why a shell, an attach or a debug shell is refused where `shells` is off.
    static let shellsOff = "Shells and attach are off for this context (its shells setting)."
    /// Why a copy is refused there: kubectl cp is exec in the pod.
    static let copiesOff = "Copying files is exec in the pod, and shells and exec are off for this context (its shells setting)."

    static func rule(_ verb: KubeProcessVerb, class kind: KubeContextClass, writable: Bool, settings: KubeContextSettings) -> KubeProcessRule {
        let production = kind == .production
        switch verb {
        case .followLogs:
            // Its tab is pinned to the context, and once the follow ends (or
            // Ctrl-C) it is a plain shell there: on production, asked as
            // Terminal in this context is.
            return KubeProcessRule(access: verb.access, confirm: production)
        case .portForward:
            return KubeProcessRule(access: verb.access)
        case .shell, .attach:
            if settings.shells == false { return KubeProcessRule(refused: shellsOff) }
            return KubeProcessRule(access: verb.access, confirm: production)
        case .copyOut, .copyIn:
            // Writing the container's files: on a writable context only.
            if verb == .copyIn, !writable { return KubeProcessRule(refused: readOnly(kind)) }
            if settings.shells == false { return KubeProcessRule(refused: copiesOff) }
            // Each copy is asked in the window, naming both paths, on every class.
            return KubeProcessRule(access: verb.access, confirm: true)
        case .debug, .drain, .rolloutUndo, .helmRollback, .helmUpgrade, .helmUninstall, .argoSync, .fluxReconcile:
            guard writable else { return KubeProcessRule(refused: readOnly(kind)) }
            // A debug container is attached to: an interactive shell in the
            // pod, which a context's shells setting turned off promises not to open.
            if verb == .debug, settings.shells == false { return KubeProcessRule(refused: shellsOff) }
            let typed: Bool =
                switch verb {
                case .helmUninstall: true
                // Rule 4; a debug container too, which stays in the pod's spec.
                // An upgrade from the checkout's chart too (stage 3a): it changes what the release runs.
                case .drain, .rolloutUndo, .debug, .helmRollback, .helmUpgrade: production
                // A sync applies what Git says now, pruning what it says to: as an upgrade does.
                case .argoSync: production
                default: false
                }
            return KubeProcessRule(confirm: true, typedName: typed)
        case .nodeShell:
            guard writable else { return KubeProcessRule(refused: readOnly(kind)) }
            if settings.shells == false { return KubeProcessRule(refused: shellsOff) }
            guard settings.nodeShell == true else {
                return KubeProcessRule(refused: "Node shells are off until the context's nodeShell setting is on.")
            }
            // Decision 20: its name typed on every class.
            return KubeProcessRule(confirm: true, typedName: true)
        case .canI, .whoami, .version, .kustomize, .helmTemplate:
            return KubeProcessRule()
        case .terminal:
            return KubeProcessRule(confirm: production)
        }
    }

    static func readOnly(_ kind: KubeContextClass) -> String {
        "This context is read-only: Overterm changes nothing here (its writable setting)."
    }
}

/// The `kubectl` commands Overterm types into a terminal tab — a shell, an
/// attach, a log followed — rather than running itself: they ask for input
/// or print as they go, and the user sees them and can run them again
/// (Docker's `DockerCommands`). Each names its context and namespace
/// (`--context`, `-n`) whatever the tab's pin or kubectl's current context
/// says (rule 7), and every word that isn't ours is quoted for zsh as Copy
/// as kubectl quotes it (`KubectlLine.quoted`). Nothing the process check
/// refuses is built. Pure.
enum KubeCommands {
    /// bash where the image has it, else sh.
    static let shellScript = "command -v bash >/dev/null && exec bash || exec sh"
    /// How many lines a followed log starts with.
    static let tail = 200

    struct Refused: Error, Equatable, CustomStringConvertible {
        var reason: String
        var description: String { reason }
    }

    /// The command for `verb` on a pod, checked against the context first.
    static func command(_ verb: KubeProcessVerb, in context: KubeContext, namespace: String, pod: String, container: String?) throws -> String {
        let rule = KubeProcessCheck.rule(verb, for: context)
        if let refused = rule.refused { throw Refused(reason: refused) }
        guard let line = line(verb, context: context.name, namespace: namespace, pod: pod, container: container) else {
            throw Refused(reason: "\(verb.title) isn't a command Overterm types for a pod.")
        }
        return line
    }

    /// The words alone, unchecked: nil for a verb that isn't a pod's tab.
    ///
    /// - shell: `kubectl exec -it POD -c C --context CTX -n NS -- sh -c '…'`
    /// - attach: `kubectl attach -it POD -c C --context CTX -n NS`
    /// - followLogs: `kubectl logs -f --tail=200 POD -c C --context CTX -n NS`
    static func line(_ verb: KubeProcessVerb, context: String, namespace: String, pod: String, container: String?) -> String? {
        var words: [String]
        switch verb {
        case .shell: words = ["kubectl", "exec", "-it", quoted(pod)]
        case .attach: words = ["kubectl", "attach", "-it", quoted(pod)]
        case .followLogs: words = ["kubectl", "logs", "-f", "--tail=\(tail)", quoted(pod)]
        default: return nil
        }
        if let container, !container.isEmpty { words += ["-c", quoted(container)] }
        words += ["--context", quoted(context), "-n", quoted(namespace)]
        if verb == .shell { words += ["--", "sh", "-c", quoted(shellScript)] }
        return words.joined(separator: " ")
    }

    static func quoted(_ word: String) -> String { KubectlLine.quoted(word) }
}

/// Which of a pod's containers a tab's command goes to, as its Logs tab
/// picks: the one `kubectl.kubernetes.io/default-container` names, else
/// the first (`KubePodContainers.defaultContainer`). A shell or attach is
/// offered the pod's containers; a log its init and ephemeral ones too.
/// Several: a picker, the default first. Pure.
enum KubeContainerPick: Equatable {
    case one(String)
    /// The default first.
    case several([String], default: String)
    /// No container at all (an object without a spec): kubectl's own choice.
    case none

    static func of(_ pod: [String: Any], for verb: KubeProcessVerb) -> KubeContainerPick {
        let all = KubePodContainers.of(pod)
        let offered = all.filter { verb == .followLogs || $0.role == .container }.map(\.name)
        guard let first = offered.first else { return .none }
        guard offered.count > 1 else { return .one(first) }
        let chosen = KubePodContainers.defaultContainer(pod).flatMap { offered.contains($0) ? $0 : nil } ?? first
        return .several([chosen] + offered.filter { $0 != chosen }, default: chosen)
    }
}

/// The shells and attaches on production confirmed this session: once per
/// pod, context and verb (rule 5) — a log followed in a tab once per
/// context (`pod` empty) — in memory only, asked again after a relaunch.
@MainActor
final class KubeShellConsent {
    private var granted: Set<String> = []

    private static func key(_ verb: KubeProcessVerb, _ context: String, _ namespace: String, _ pod: String) -> String {
        [verb.rawValue, context, namespace, pod].joined(separator: "\u{1F}")
    }

    func isGranted(_ verb: KubeProcessVerb, context: String, namespace: String, pod: String) -> Bool {
        granted.contains(Self.key(verb, context, namespace, pod))
    }

    func grant(_ verb: KubeProcessVerb, context: String, namespace: String, pod: String) {
        granted.insert(Self.key(verb, context, namespace, pod))
    }
}
