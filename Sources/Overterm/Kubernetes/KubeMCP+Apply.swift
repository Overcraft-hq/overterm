import Foundation

/// `k8s_apply` (stage 2b; 3.3, rule 10, decision 30): an agent's manifest
/// applied server-side by the editor's own path (`KubeManifestRun`) —
/// only on a context `kubernetes.agentWrites` names and writable for
/// Overterm, on production only where the context's `applyOnProduction`
/// is on too. No Secret (rule 10: there is no tool for Secrets — its
/// diff would read its values, and its answer say whether a guess is
/// right). The class check, the access review, a
/// server-side dry run whose diff (masked) and fields' other owners the
/// confirmation shows, a value still masked refused, the name typed on production, every check again
/// against the context as it is then, the requests. Never forced: a 409
/// is reported, and the user may force it from the editor.
extension KubeMCP {
    static func apply(_ call: Call, _ target: Target, kubernetes: KubernetesModel, pane: String? = nil) async throws -> String {
        let context = target.context
        if let refused = KubeAgentWrites.refused(context, agentWrites: kubernetes.agentWrites) {
            throw BrowserMCP.ToolError(message: "k8s_apply isn't offered on \(context.name): \(refused) Tell the user what to change instead.")
        }
        if let refused = KubeApplyCheck.refused(context) { throw BrowserMCP.ToolError(message: refused) }
        guard let text = call.arguments["manifest"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrowserMCP.ToolError(message: "k8s_apply needs “manifest”: the objects as YAML or JSON.")
        }
        let objects: [KubeManifestObject]
        do {
            objects = try KubeManifest.parse(text)
        } catch {
            throw BrowserMCP.ToolError(message: KubernetesModel.said(error))
        }
        // Before anything is read: a Secret's diff reads its values, and
        // whether it changes would tell an agent whether a guess is right.
        if let secret = objects.first(where: \.isSecret) {
            throw BrowserMCP.ToolError(
                message: "k8s_apply takes no Secret (\(secret.spoken)): there is no tool for Secrets, and nothing of one was read. "
                    + "The user can apply it from Overterm's editor.")
        }
        // Nor a secret-looking env value in the clear: its dry run's "No
        // change" would confirm a guess of the value the tools mask.
        for object in objects {
            if let name = secretLookingEnv(object.object) {
                throw BrowserMCP.ToolError(
                    message: "k8s_apply takes no secret-looking env value (\(name) in \(object.spoken)): leave it masked as k8s_get shows it, "
                        + "or use valueFrom.secretKeyRef. Nothing was read.")
            }
        }
        let client = target.client
        // Where an object without its own goes: one namespace, never a
        // guess — named, it is the target's one; of several shown (none
        // named), the agent names it as every other tool needing one does.
        let namespace: String?
        if call.string("namespace") != nil || ((target.scope.names?.count ?? 0) > 1 && objects.contains(where: { $0.namespace == nil })) {
            namespace = try target.oneNamespace("k8s_apply")
        } else {
            namespace = target.namespace
        }
        // The access review first: nothing is read or asked before it says yes.
        do {
            let refs = try await KubeManifestRun.refs(objects, context: context, client: client, model: kubernetes, namespace: namespace)
            for ref in refs {
                for access in KubeApplyCheck.accesses(ref, exists: true) {
                    let answer = await client.review(access, namespace: ref.namespace)
                    if let why = KubeAccessState.answered(answer).unavailable(access, namespace: ref.namespace ?? "", review: true) {
                        throw BrowserMCP.ToolError(message: KubeMCPText.scrubbed(why))
                    }
                }
            }
        } catch let error as BrowserMCP.ToolError {
            throw error
        } catch {
            throw BrowserMCP.ToolError(message: KubeMCPText.scrubbed(KubernetesModel.said(error)))
        }
        let result: KubeManifestDiffResult
        do {
            result = try await KubeManifestRun.diff(objects, text: text, context: context, client: client, model: kubernetes, namespace: namespace)
        } catch {
            throw BrowserMCP.ToolError(message: KubeMCPText.scrubbed(KubernetesModel.said(error)))
        }
        guard result.isServerSide else { throw BrowserMCP.ToolError(message: "\(context.name) wouldn't dry-run it, so it isn't applied: \(result.label)") }
        // An env value masked (`••••••`) that the live object couldn't give back: it would be applied as the mask.
        if let item = result.items.first(where: { !$0.masked.isEmpty }) {
            throw BrowserMCP.ToolError(message: KubeApplyCheck.maskedSaid(item.masked, of: item.spoken, owned: item.overterms))
        }
        guard result.changes > 0 else {
            return KubeMCPText.finished(target.header() + "\nNo change: \(context.name) has it as the manifest says. Nothing was applied.")
        }
        for item in result.items where item.isNew {
            let access = KubeAccess(verb: "create", resource: item.ref.kind.fullName)
            let answer = await client.review(access, namespace: item.ref.namespace)
            if let why = KubeAccessState.answered(answer).unavailable(access, namespace: item.ref.namespace ?? "", review: true) {
                throw BrowserMCP.ToolError(message: KubeMCPText.scrubbed(why))
            }
        }
        let namespaces = Set(result.items.compactMap(\.ref.namespace))
        let kubectl = KubeApply.kubectl(file: "-", context: context.name, namespace: namespaces.count == 1 ? namespaces.first : nil)
        let confirmation = KubeApplyConfirmation.make(result, context: context, kubectl: kubectl, agent: true)
        guard let typed = await ask(confirmation, pane: pane) else {
            throw BrowserMCP.ToolError(message: "The user declined the apply: nothing was changed.")
        }
        guard confirmation.accepts(typed) else {
            throw BrowserMCP.ToolError(message: "The name typed wasn't \(confirmation.typedName ?? ""): nothing was changed.")
        }
        // As the context is now: writes turned off, agentWrites or
        // applyOnProduction changed, or the kubeconfig pointing it elsewhere
        // while it asked stop it here.
        guard let list = await kubernetes.contextsForAgents(), let now = list.context(named: context.name), KubernetesModel.sameAccess(context, now),
            KubeAgentWrites.refused(now, agentWrites: kubernetes.agentWrites) == nil, KubeApplyCheck.refused(now) == nil
        else {
            throw BrowserMCP.ToolError(message: "\(context.name) changed while it was asked (its writes, its settings or agents' access): nothing was changed.")
        }
        let outcome = await KubeManifestRun.apply(result.items, client: kubernetes.agentClient(for: now), versions: [:], force: false, replacing: false)
        switch outcome {
        case .applied(let done):
            let refs = Array(done.keys).sorted { $0.description < $1.description }
            return KubeMCPText.finished(target.header() + "\n" + KubeManifestRun.done(refs, context: now.name) + "\n" + result.summary())
        case .conflict(let conflict, let done):
            let before = done.isEmpty ? "Nothing was applied" : "\(done.count) object(s) before it were applied, the rest not"
            throw BrowserMCP.ToolError(
                message: KubeMCPText.scrubbed(
                    "Conflict: \(conflict.said). \(before). An agent never forces an apply: tell the user, who can look at it in Overterm's editor."))
        case .failed(let said, let done):
            throw BrowserMCP.ToolError(message: KubeMCPText.scrubbed(said + (done.isEmpty ? "" : " (\(done.count) object(s) before it were applied)")))
        }
    }
}

extension KubeMCP {
    /// The first env entry anywhere in `value` whose name looks secret
    /// (`Secrets.isSecret`) and whose literal `value` is given and isn't the
    /// mask: its name. Pure.
    static func secretLookingEnv(_ value: Any) -> String? {
        switch value {
        case let map as [String: Any]:
            for (key, inner) in map.sorted(by: { $0.key < $1.key }) {
                if key == "env", let entries = inner as? [Any] {
                    for case let entry as [String: Any] in entries {
                        guard let name = entry["name"] as? String, Secrets.isSecret(name), let text = entry["value"] as? String else { continue }
                        if !text.isEmpty, text != Secrets.mask(text) { return name }
                    }
                } else if let found = secretLookingEnv(inner) {
                    return found
                }
            }
            return nil
        case let list as [Any]:
            for item in list { if let found = secretLookingEnv(item) { return found } }
            return nil
        default:
            return nil
        }
    }
}
