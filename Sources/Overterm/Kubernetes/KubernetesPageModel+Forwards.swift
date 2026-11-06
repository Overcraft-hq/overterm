import Foundation

// MARK: Port-forwards (stage 1d; docs/design/kubernetes/analysis.md, 2.7 and 3.8)

extension KubernetesPageModel {
    /// What `f` and `o` mean: the detail's object while it shows a pod, a
    /// Service or a Deployment, else the list's one selected row of them.
    var forwardRef: KubeObjectRef? {
        if let detail { return KubeForwardTarget.of(kind: detail.ref.kind, name: detail.ref.name) != nil ? detail.ref : nil }
        guard selection.count == 1, let row = rows.first(where: { selection.contains($0.id) }), let ref = ref(for: row.id) else { return nil }
        return KubeForwardTarget.of(kind: ref.kind, name: ref.name) != nil ? ref : nil
    }

    /// The forwards an object has, those not stopped.
    func forwards(of ref: KubeObjectRef) -> [KubeForward] {
        guard let target = KubeForwardTarget.of(kind: ref.kind, name: ref.name) else { return [] }
        return forwards.forwards.filter {
            !$0.state.isStopped && $0.spec.context == ref.context && $0.spec.namespace == ref.namespace && $0.spec.target == target
        }
    }

    /// A detail's buttons: Ask Why, a pod's tab verbs, then its forwards', then
    /// what opens through one (a database pod's Database client), and an
    /// Ingress's Open.
    func detailVerbs(for ref: KubeObjectRef) -> [ResourceVerb] {
        [askWhyVerb(for: ref)].compactMap { $0 } + podVerbs(for: ref) + forwardVerbs(for: ref) + [editVerb(for: ref), compareVerb(for: ref)] + writeVerbs(for: ref)
            + tabWriteVerbs(for: ref)
            + [databaseVerb(for: ref), ingressVerb(for: ref)].compactMap { $0 }
    }

    /// The one row picked: its forward verbs, and what opens through one.
    func forwardVerbs(for picked: [KubeRow]) -> [ResourceVerb] {
        guard picked.count == 1, let row = picked.first, let ref = ref(for: row.id.description) else { return [] }
        return forwardVerbs(for: ref) + [databaseVerb(for: ref), ingressVerb(for: ref)].compactMap { $0 }
    }

    /// Port-forward… (`f`) and Quick Forward on a pod, a Service or a
    /// Deployment — greyed with why until `kubectl auth can-i create
    /// pods/portforward` says yes (a read-only context's too: a forward
    /// changes no object) — and Open Forward (`o`) while it has one.
    func forwardVerbs(for ref: KubeObjectRef) -> [ResourceVerb] {
        guard KubeForwardTarget.of(kind: ref.kind, name: ref.name) != nil, let context = model.contexts.context(named: ref.context),
            let namespace = ref.namespace
        else { return [] }
        let why = unavailable(.portForward, context, namespace)
        var verbs = [
            ResourceVerb(
                title: "Port-forward…", label: "Forward", symbol: "arrow.left.arrow.right", place: .button, key: KubernetesKey.portForward.key,
                unavailable: why, group: 5
            ) { [weak self] in self?.portForward(ref) },
            ResourceVerb(title: "Quick Forward", symbol: "bolt.horizontal", unavailable: why, group: 5) { [weak self] in self?.quickForward(ref) },
        ]
        if let running = forwards(of: ref).first {
            verbs.append(
                ResourceVerb(title: "Open Forward", label: "Open", symbol: "safari", place: .button, key: KubernetesKey.openForward.key, group: 5) {
                    [weak self] in self?.openForward(running.id)
                })
        }
        return verbs
    }

    // MARK: The sheet

    /// `f`: the sheet on `forwardRef`; false when there is none.
    @discardableResult
    func portForward() -> Bool {
        guard let ref = forwardRef else { return false }
        portForward(ref)
        return true
    }

    /// The sheet for `ref`, at once; its ports once the object is read (one
    /// GET), the first picked and the same local port where it is free, and
    /// `kubectl auth can-i` asked. `port`: the one picked (a container port
    /// in a pod's Overview), the same local port where it is free.
    func portForward(_ ref: KubeObjectRef, port: Int? = nil) {
        commandProblem = nil
        forwardProblem = nil
        guard let (context, namespace, target) = forwardable(ref) else { return }
        forwardDraft = KubeForwardDraft(
            context: context.name, namespace: namespace, target: target, offered: [], remote: port.map(String.init) ?? "", local: "",
            unavailable: unavailable(.portForward, context, namespace))
        guard let client = model.client(for: ref.context, role: .page) else {
            // Nothing will fill it: said, not left on Checking….
            let why = "Kubernetes is off, or \(ref.context) is no longer in the kubeconfig."
            forwardDraft?.unavailable = why
            forwardProblem = why
            return
        }
        Task { [weak self] in
            var said: String?
            var object: [String: Any]?
            do {
                object = try await client.object(ref.kind, namespace: namespace, name: ref.name).json
            } catch {
                said = KubernetesModel.said(error)
            }
            guard let self, self.forwardDraft?.target == target, self.forwardDraft?.editing == nil else { return }
            let offered = object.map { KubeForwardPortOption.offered(by: $0, target: target) } ?? []
            self.forwardDraft?.offered = offered
            if self.forwardDraft?.remote.isEmpty == true, let first = offered.first {
                self.forwardDraft?.remote = "\(first.port)"
            }
            if self.forwardDraft?.local.isEmpty == true {
                self.forwardDraft?.local = self.freeLocalPort(preferring: Int(self.forwardDraft?.remote ?? "")).map(String.init) ?? ""
            }
            if let said { self.forwardProblem = "Couldn't read \(target): \(said)" }
            let answer = await self.model.access.answer(context, namespace: namespace, .portForward)
            guard self.forwardDraft?.target == target else { return }
            self.forwardDraft?.unavailable = KubeAccessState.answered(answer).unavailable(.portForward, namespace: namespace)
        }
    }

    /// The sheet's Edit: the forward's local port, address and https; its
    /// target and remote port stay.
    func editForward(_ id: UUID) {
        guard let forward = forwards.forward(id) else { return }
        let spec = forward.spec
        forwardProblem = nil
        forwardDraft = KubeForwardDraft(
            context: spec.context, namespace: spec.namespace, target: spec.target,
            offered: [KubeForwardPortOption(port: spec.remotePort)], remote: "\(spec.remotePort)", local: "\(spec.localPort)", address: spec.address,
            https: spec.https, editing: id)
    }

    /// The sheet's Random: a free local port.
    func randomLocalPort() {
        forwardDraft?.local = freeLocalPort(preferring: nil).map(String.init) ?? ""
    }

    func closeForwardSheet() {
        forwardDraft = nil
        forwardProblem = nil
        giveListTheKeyboard()
    }

    /// The sheet's Forward (or Save): started, or the edited one started
    /// again — or why not, under its fields.
    @discardableResult
    func confirmForward() -> UUID? {
        guard let draft = forwardDraft else { return nil }
        if let why = draft.unavailable {
            forwardProblem = why
            return nil
        }
        guard let context = model.contexts.context(named: draft.context) else {
            forwardProblem = "No context called \(draft.context)."
            return nil
        }
        // An edited forward's own port is its kubectl's, not taken.
        let own = draft.editing.flatMap { forwards.forward($0)?.spec.localPort }
        var taken = forwards.takenPorts
        if let own { taken.remove(own) }
        let bound = isPortBound
        switch draft.spec(taken: taken, isBound: { $0 != own && bound($0) }, tab: actions?.currentTab()) {
        case .failure(let failure):
            forwardProblem = failure.description
            return nil
        case .success(let spec):
            if draft.editing != nil {
                forwards.edit(spec)
            } else {
                forwards.start(spec, in: context)
            }
            forwardDraft = nil
            forwardProblem = nil
            giveListTheKeyboard()
            return spec.id
        }
    }

    // MARK: Quick, open, stop

    /// Quick Forward: the object's first port, a free local port at random,
    /// no sheet — opened in the browser column once it forwards.
    func quickForward(_ ref: KubeObjectRef) {
        commandProblem = nil
        guard let (context, namespace, target) = forwardable(ref), let client = model.client(for: ref.context, role: .page) else { return }
        Task { [weak self] in
            let object: [String: Any]
            do {
                object = try await client.object(ref.kind, namespace: namespace, name: ref.name).json
            } catch {
                self?.commandProblem = "Couldn't read \(target): \(KubernetesModel.said(error))"
                return
            }
            guard let self else { return }
            guard let port = KubeForwardPortOption.offered(by: object, target: target).first?.port else {
                self.commandProblem = "\(target) declares no TCP port: Port-forward… (\(KubernetesKey.portForward.key)) takes one typed."
                return
            }
            let answer = await self.model.access.answer(context, namespace: namespace, .portForward)
            if let why = KubeAccessState.answered(answer).unavailable(.portForward, namespace: namespace) {
                self.commandProblem = why
                return
            }
            guard let local = self.freeLocalPort(preferring: nil) else {
                self.commandProblem = "No free local port came up."
                return
            }
            let spec = KubeForwardSpec(
                context: context.name, namespace: namespace, target: target, remotePort: port, localPort: local, tab: self.actions?.currentTab())
            let id = self.forwards.start(spec, in: context)
            for _ in 0..<300 {
                guard let forward = self.forwards.forward(id), !forward.state.isStopped else { return }
                if forward.isForwarding {
                    self.openForward(id)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// `o`: in Forwards the one picked (else the first forwarding), else the
    /// forward of the object `f` would act on — or, on an Ingress, where
    /// it is reached, in the default browser.
    @discardableResult
    func openForward() -> Bool {
        let forward: KubeForward?
        if section == .forwards {
            let live = forwards.forwards.filter { !$0.state.isStopped }
            forward = forwardSelection.flatMap { id in live.first { $0.id == id } } ?? live.first { $0.isForwarding } ?? live.first
        } else {
            forward = forwardRef.flatMap { forwards(of: $0).first }
        }
        guard let forward else {
            guard section != .forwards, let ingress = ingressRef else { return false }
            openIngress(ingress)
            return true
        }
        openForward(forward.id)
        return true
    }

    /// Its URL in the browser column (or the default browser, as links open).
    func openForward(_ id: UUID) {
        guard let url = forwards.forward(id)?.spec.url else { return }
        actions?.openURL(url)
    }

    func stopForward(_ id: UUID) {
        forwards.stop(id)
        if forwardSelection == id { forwardSelection = nil }
    }

    /// The Forwards section, on the page.
    func showForwards() {
        showSection(.forwards)
    }

    // MARK: Helpers

    /// A free local port: `preferring` it when free, else one at random.
    func freeLocalPort(preferring port: Int?) -> Int? {
        KubeForwardPortChoice.free(preferred: port, taken: forwards.takenPorts, isBound: isPortBound)
    }

    /// The context, namespace and target `ref` is, or why not (the page's
    /// `commandProblem`): the process check first.
    func forwardable(_ ref: KubeObjectRef) -> (KubeContext, String, KubeForwardTarget)? {
        guard let target = KubeForwardTarget.of(kind: ref.kind, name: ref.name) else { return nil }
        guard let context = model.contexts.context(named: ref.context), let namespace = ref.namespace else {
            commandProblem = "No context called \(ref.context)."
            return nil
        }
        if let refused = KubeProcessCheck.rule(.portForward, for: context).refused {
            commandProblem = refused
            return nil
        }
        return (context, namespace, target)
    }
}
