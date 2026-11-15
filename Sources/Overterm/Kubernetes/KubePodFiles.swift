import Foundation

/// A file or folder copied out of a pod's container, or into it (stage 4;
/// decision 10: pod files are rare, so `kubectl cp` in a tab, no file
/// browser): `kubectl cp POD:PATH LOCAL` or `kubectl cp LOCAL POD:PATH`,
/// `-c`, `--context` and `-n` always, every word quoted for zsh. kubectl
/// runs `tar` in the container through exec, so both ask `kubectl auth
/// can-i create pods/exec` first and a context's `shells` turned off
/// refuses both; a copy in changes the container's files, so it is a
/// writing process — refused on a read-only context (`KubeProcessCheck`).
/// Each is confirmed in the window naming the context, namespace, pod,
/// container and both paths, then typed into a tab pinned to the context
/// (`KubernetesPageModel.copyFiles`). Pure.
struct KubePodCopy: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        /// Out of the container, onto this Mac.
        case out
        /// From this Mac, into the container.
        case into
    }

    var direction: Direction
    var pod: String
    var namespace: String
    /// Nil: kubectl's own choice (a pod read without a spec).
    var container: String?
    /// In the container: absolute, or kubectl's relative to its working directory.
    var remotePath: String
    /// On this Mac: absolute, as a save or open panel gives it.
    var localPath: String

    /// The verbs, as the pod's menu orders them.
    static let verbs: [KubeProcessVerb] = [.copyOut, .copyIn]

    static func direction(of verb: KubeProcessVerb) -> Direction? {
        switch verb {
        case .copyOut: .out
        case .copyIn: .into
        default: nil
        }
    }

    static func title(_ verb: KubeProcessVerb) -> String {
        verb == .copyIn ? "Copy into Container in a Tab…" : "Copy from Container in a Tab…"
    }

    static func label(_ verb: KubeProcessVerb) -> String {
        verb == .copyIn ? "Copy In" : "Copy Out"
    }

    static func symbol(_ verb: KubeProcessVerb) -> String {
        verb == .copyIn ? "square.and.arrow.down.on.square" : "square.and.arrow.up.on.square"
    }

    /// `pod/container:path`, as the confirmation says the container's side.
    var remoteSpoken: String {
        "pod \(namespace)/\(pod)" + (container.map { ", container \($0)," } ?? "") + " " + remotePath
    }

    /// kubectl's word for the container's side: `POD:PATH`, the namespace
    /// left to `-n` (kubectl reads a `NS/POD:` prefix too, never needed).
    var remoteWord: String { pod + ":" + remotePath }

    /// The last part of a container's path, for a save panel's name: `app.log`
    /// for `/var/log/app.log`, `log` for `/var/log/`, `copy` for `/`. A colon
    /// becomes `-` (`app-10-00.log` for `app-10:00.log`): a local path with one
    /// is refused (`problem`), so the name suggested must never have one.
    static func suggestedName(for remote: String) -> String {
        let parts = remote.split(separator: "/").filter { $0 != "." && $0 != ".." }
        let name = parts.last.map { $0.replacingOccurrences(of: ":", with: "-") } ?? ""
        return name.isEmpty ? "copy" : name
    }

    /// Where a local file goes in the container unless the user says
    /// otherwise: `/tmp/<its name>`.
    static func suggestedRemote(for local: String) -> String {
        "/tmp/" + ((local as NSString).lastPathComponent.isEmpty ? "copy" : (local as NSString).lastPathComponent)
    }

    /// Why these paths can't be given to kubectl, whatever the context; nil
    /// when they can. A control character would break the line typed into
    /// the tab; kubectl reads the first `:` of an argument as the end of a
    /// pod's name, so a local path with one would be taken for a pod.
    static func problem(remote: String, local: String) -> String? {
        if remote.trimmingCharacters(in: .whitespaces).isEmpty { return "A path in the container, please." }
        if hasControl(remote) { return "The container's path has a control character (a newline, a tab): kubectl cp can't be given it." }
        if local.isEmpty { return "A place on this Mac, please." }
        if hasControl(local) { return "The path on this Mac has a control character (a newline, a tab): kubectl cp can't be given it." }
        if !local.hasPrefix("/") { return "The path on this Mac must be absolute." }
        if local.contains(":") {
            return "The path on this Mac has a colon, which kubectl cp reads as a pod's name: pick a place without one."
        }
        return nil
    }

    /// Why a copy out of this path is refused, beyond `problem`: the container's
    /// whole root (`/`, `/.`, `//`, `/..`) would be tarred over exec onto this
    /// Mac — `/proc` and `/sys` with it —, never what was meant.
    static func outProblem(remote: String) -> String? {
        let path = remote.trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/").filter { $0 != "." && $0 != ".." }
        return parts.isEmpty ? "That is the container's whole filesystem (/proc and /sys too): name a file or folder in it." : nil
    }

    private static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "\u{7F}" }
    }
}

extension KubePodCopy: KubeTabCommand {
    var verb: KubeProcessVerb { direction == .out ? .copyOut : .copyIn }

    var name: String { pod }

    var refused: String? {
        Self.problem(remote: remotePath, local: localPath) ?? (direction == .out ? Self.outProblem(remote: remotePath) : nil)
    }

    /// The words, unchecked (`KubeCommands.command(_:in:)` checks them first):
    /// - out: `kubectl cp POD:PATH LOCAL -c C --context CTX -n NS`
    /// - into: `kubectl cp LOCAL POD:PATH -c C --context CTX -n NS`
    func line(context: String) -> String {
        let q = KubeCommands.quoted
        var words = ["kubectl", "cp"]
        switch direction {
        case .out: words += [q(remoteWord), q(localPath)]
        case .into: words += [q(localPath), q(remoteWord)]
        }
        if let container, !container.isEmpty { words += ["-c", q(container)] }
        words += ["--context", q(context), "-n", q(namespace)]
        return words.joined(separator: " ")
    }

    /// The context and namespace — production in capitals —, the pod, the
    /// container, both paths, and the command the tab runs.
    func confirmation(context: KubeContext, rule: KubeProcessRule) -> KubeWriteConfirmation {
        let command = line(context: context.name)
        let place = (context.isProduction ? KubeWriteConfirmation.productionMark : "") + context.name + " · namespace \(namespace)"
        let local = (localPath as NSString).abbreviatingWithTildeInPath
        let target = "pod \(namespace)/\(pod)" + (container.map { ", container \($0)" } ?? "")
        let title: String
        let what: String
        let button: String
        switch direction {
        case .out:
            title = "Copy \(remotePath) out of pod \(namespace)/\(pod)?"
            what =
                "From \(target): \(remotePath)\nTo this Mac: \(local) — what is there is replaced.\n"
                + "kubectl cp runs tar in the container through exec (the image needs tar) and reads what your credentials may."
            button = "Copy Out in a Tab"
        case .into:
            title = "Copy \((localPath as NSString).lastPathComponent) into pod \(namespace)/\(pod)?"
            what =
                "From this Mac: \(local)\nTo \(target): \(remotePath) — what is there is overwritten.\n"
                + "kubectl cp runs tar in the container through exec (the image needs tar). It changes the container's files, not the pod's spec: "
                + "a restart loses them."
            button = "Copy In in a Tab"
        }
        var lines = [what, "Runs in a new tab pinned to \(context.displayName): \(command)"]
        let typed = rule.typedName ? name : nil
        if let typed { lines.append("Type \(typed) to confirm.") }
        return KubeWriteConfirmation(
            verb: nil, title: title, scope: place, detail: lines.joined(separator: "\n"), button: button, typedName: typed,
            production: context.isProduction, kubectl: command)
    }

    func opened(context: String) -> String {
        switch direction {
        case .out: "Copying \(remotePath) out of pod \(namespace)/\(pod) in a new tab, in \(context)."
        case .into: "Copying \((localPath as NSString).lastPathComponent) into pod \(namespace)/\(pod) in a new tab, in \(context)."
        }
    }
}
