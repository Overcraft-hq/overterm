import Foundation

// MARK: Pod files (stage 4 — docs/design/kubernetes/analysis.md, decision 10 and Section 5)

/// A file or folder copied out of a pod's container or into it, as
/// `kubectl cp` in a tab (`KubePodCopy`). One path, as a shell's and the
/// tab writes' are:
/// 1. the process class check (`KubeProcessCheck`): a copy in only on a
///    writable context; either refused where the context's `shells` is off;
/// 2. `kubectl auth can-i create pods/exec` (kubectl cp is tar through exec);
/// 3. the pod read for its containers, one picked when several (the
///    default first, as a shell's);
/// 4. the paths: out, the container's path asked, then where on this Mac
///    (a save panel); in, the file or folder (an open panel), then where
///    in the container;
/// 5. the confirmation in the window naming the context, namespace, pod,
///    container and both paths, and the command (`confirmTabCommand`: the
///    class check again against the context as it is then);
/// 6. the command typed into a new tab pinned to the context — in a
///    scenario, recorded instead (`kubernetesCommandRecorder`).
extension KubernetesPageModel {
    /// A pod's Copy Out and Copy In — its detail's More and its right-click
    /// menu: each greyed with why where the class check refuses it, or
    /// until `kubectl auth can-i create pods/exec` says yes.
    func podFileVerbs(for ref: KubeObjectRef) -> [ResourceVerb] {
        guard ref.isPod, let context = model.contexts.context(named: ref.context), let namespace = ref.namespace else { return [] }
        return KubePodCopy.verbs.map { verb in
            ResourceVerb(
                title: KubePodCopy.title(verb), label: KubePodCopy.label(verb), symbol: KubePodCopy.symbol(verb), place: .more,
                unavailable: unavailable(verb, context, namespace), group: 4
            ) { [weak self] in self?.copyFiles(verb, on: ref) }
        }
    }

    /// The one pod picked in the pod list: its copies.
    func podFileVerbs(for picked: [KubeRow]) -> [ResourceVerb] {
        guard isPods, picked.count == 1, let row = picked.first, let ref = ref(for: row.id.description) else { return [] }
        return podFileVerbs(for: ref)
    }

    /// `verb` (`.copyOut`, `.copyIn`) on the pod, by the path above.
    func copyFiles(_ verb: KubeProcessVerb, on ref: KubeObjectRef) {
        guard writeChecking == nil else { return }
        writeStatus = nil
        guard let direction = KubePodCopy.direction(of: verb), ref.isPod, let namespace = ref.namespace else {
            writeStatus = .failed("\(verb.title) is a pod's.")
            return
        }
        guard let context = model.contexts.context(named: ref.context) else {
            writeStatus = .failed("No context called \(ref.context).")
            return
        }
        let rule = KubeProcessCheck.rule(verb, for: context)
        if let refused = rule.refused {
            writeStatus = .failed(refused)
            return
        }
        guard let client = model.client(for: ref.context) else {
            writeStatus = .failed("Kubernetes is off, or the context is gone.")
            return
        }
        writeChecks += 1
        let token = writeChecks
        writeChecking = token
        writeStatus = .working("Checking… pod \(namespace)/\(ref.name)")
        Task { [weak self] in
            defer { self?.endChecking(token) }
            if let access = rule.access {
                let answer = await self?.model.access.answer(context, namespace: namespace, access) ?? .failed("")
                guard let self else { return }
                if let why = KubeAccessState.answered(answer).unavailable(access, namespace: namespace) {
                    self.writeStatus = .failed(why)
                    return
                }
            }
            let pick: KubeContainerPick
            let directories: [String: String]
            do {
                let pod = try await client.object(ref.kind, namespace: namespace, name: ref.name).json
                pick = KubeContainerPick.of(pod, for: .shell)
                directories = KubePodCopy.workingDirectories(pod)
            } catch {
                self?.writeStatus = .failed("Couldn't read pod \(namespace)/\(ref.name): \(KubernetesModel.said(error))")
                return
            }
            guard let self else { return }
            self.endChecking(token)
            self.writeStatus = nil
            self.choose(pick, verb, context: context, namespace: namespace, pod: ref.name) { [weak self] container in
                self?.askCopyPaths(
                    direction, pod: ref.name, namespace: namespace, container: container, directory: container.flatMap { directories[$0] }, in: context)
            }
        }
    }

    private func askCopyPaths(
        _ direction: KubePodCopy.Direction, pod: String, namespace: String, container: String?, directory: String?, in context: KubeContext
    ) {
        let target = "pod \(namespace)/\(pod)" + (container.map { ", container \($0)" } ?? "") + " in \(context.displayName)"
        let finish = { [weak self] (remote: String, local: String) in
            let copy = KubePodCopy(direction: direction, pod: pod, namespace: namespace, container: container, remotePath: remote, localPath: local)
            if let problem = copy.refused {
                self?.writeStatus = .failed(problem)
                return
            }
            self?.confirmTabCommand(copy, reviewed: context, pin: namespace)
        }
        switch direction {
        case .out:
            actions?.askText(
                "Copy what out of the container?",
                "A file or folder in \(target): absolute, or relative to its working directory. Where it goes on this Mac is asked next.",
                directory ?? ""
            ) { [weak self] remote in
                self?.actions?.pickSave(KubePodCopy.suggestedName(for: remote)) { url in finish(remote, url.path) }
            }
        case .into:
            actions?.pickOpen("Copy a file or folder into \(target).") { [weak self] url in
                self?.actions?.askText(
                    "Copy \(url.lastPathComponent) where in the container?",
                    "A path in \(target): what is there is overwritten.",
                    KubePodCopy.suggestedRemote(for: url.path)
                ) { remote in finish(remote, url.path) }
            }
        }
    }
}

extension KubePodCopy {
    /// Each container's `workingDir`, where one is set: a copy out's path starts there.
    static func workingDirectories(_ pod: [String: Any]) -> [String: String] {
        var found: [String: String] = [:]
        for container in KubeAgentText.list(KubeAgentText.map(pod["spec"])["containers"]) {
            if let name = container["name"] as? String, let directory = container["workingDir"] as? String, directory.hasPrefix("/") {
                found[name] = directory.hasSuffix("/") ? directory : directory + "/"
            }
        }
        return found
    }
}
