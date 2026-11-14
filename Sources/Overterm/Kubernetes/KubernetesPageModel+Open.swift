import Foundation

// MARK: What opens through a forward (stage 1d; docs/design/kubernetes/analysis.md, 3.8)

extension KubernetesPageModel {
    // MARK: An Ingress: `o`, in the default browser

    /// The Ingress `o` opens: the detail's while it shows one, else the
    /// list's one selected row.
    var ingressRef: KubeObjectRef? {
        if let detail { return detail.ref.isIngress ? detail.ref : nil }
        guard selection.count == 1, let row = rows.first(where: { selection.contains($0.id) }), let ref = ref(for: row.id), ref.isIngress else {
            return nil
        }
        return ref
    }

    func ingressVerb(for ref: KubeObjectRef) -> ResourceVerb? {
        guard ref.isIngress else { return nil }
        return ResourceVerb(title: "Open in Browser", label: "Open", symbol: "safari", place: .button, key: KubernetesKey.openForward.key, group: 5) {
            [weak self] in self?.openIngress(ref)
        }
    }

    /// Where the Ingress is reached — its hosts, https where its TLS names
    /// them, else its address — in the default browser: the detail's
    /// object, else one GET. Several hosts: which one is asked.
    func openIngress(_ ref: KubeObjectRef) {
        commandProblem = nil
        if let detail, detail.ref == ref, let json = detail.object?.json { return openIngress(ref, KubeIngressLinks.urls(of: json)) }
        guard let client = model.client(for: ref.context) else {
            commandProblem = "Kubernetes is off, or \(ref.context) is no longer in the kubeconfig."
            return
        }
        Task { [weak self] in
            let urls: [URL]
            do {
                urls = KubeIngressLinks.urls(of: try await client.object(ref.kind, namespace: ref.namespace, name: ref.name).json)
            } catch {
                self?.commandProblem = "Couldn't read ing/\(ref.name): \(KubernetesModel.said(error))"
                return
            }
            self?.openIngress(ref, urls)
        }
    }

    private func openIngress(_ ref: KubeObjectRef, _ urls: [URL]) {
        guard let first = urls.first else {
            commandProblem = "ing/\(ref.name) has no host or address yet."
            return
        }
        guard urls.count > 1 else {
            actions?.openExternal(first)
            return
        }
        let shown = Array(urls.prefix(8))
        actions?.choose(
            "Open which host of ing/\(ref.name)?", "In your browser: the cluster's own front door, not a forward.", shown.map(\.absoluteString)
        ) { [weak self] index in
            guard shown.indices.contains(index) else { return }
            self?.actions?.openExternal(shown[index])
        }
    }

    // MARK: A database pod: `d`, in the Database client

    /// The pod `d` acts on: the detail's while it shows a pod, else the
    /// list's one selected pod.
    var databaseRef: KubeObjectRef? {
        if let detail { return detail.ref.isPod ? detail.ref : nil }
        guard isPods, selection.count == 1, let row = rows.first(where: { selection.contains($0.id) }), let ref = ref(for: row.id), ref.isPod else {
            return nil
        }
        return ref
    }

    /// Open in Database Client, on a pod whose detail read it runs a
    /// database the client speaks — greyed with why while a forward can't
    /// start (`kubectl auth can-i create pods/portforward`).
    func databaseVerb(for ref: KubeObjectRef) -> ResourceVerb? {
        guard ref.isPod, let detail, detail.ref == ref, let json = detail.object?.json, let target = KubeDatabase.detect(json),
            let context = model.contexts.context(named: ref.context), let namespace = ref.namespace
        else { return nil }
        return ResourceVerb(
            title: "Open in Database Client", label: target.kind.title, symbol: "cylinder.split.1x2", place: .button, key: KubernetesKey.database.key,
            unavailable: unavailable(.portForward, context, namespace), group: 5
        ) { [weak self] in self?.openInDatabase(ref) }
    }

    /// `d`: on `databaseRef`; false when there is none.
    @discardableResult
    func openInDatabase() -> Bool {
        guard let ref = databaseRef else { return false }
        openInDatabase(ref)
        return true
    }

    /// The pod read (the detail's object, else one GET) and its database
    /// found by its image (`DockerClient`'s table). What its env takes from
    /// a Secret is asked about first — Cancel, and nothing starts. Then a
    /// forward to that port — one already running reused, else one
    /// started, after `kubectl auth can-i create pods/portforward` — and,
    /// once it forwards, the Secret read if the user said so (one GET of
    /// it, only the keys named kept, handed to the form, the rest dropped
    /// at once) and the Database client's form filled in: 127.0.0.1 and the
    /// forward's local port, the user and database its env writes. A
    /// password written in the spec, or one not read, is left to type.
    /// Nothing is saved or connected here: the form does that, and keeps a
    /// password in the keychain only.
    func openInDatabase(_ ref: KubeObjectRef) {
        commandProblem = nil
        guard let (context, namespace, _) = forwardable(ref) else { return }
        guard let client = model.client(for: ref.context) else {
            commandProblem = "Kubernetes is off, or \(ref.context) is no longer in the kubeconfig."
            return
        }
        let known = detail?.ref == ref ? detail?.object?.json : nil
        Task { [weak self] in
            let pod: [String: Any]
            if let known {
                pod = known
            } else {
                do {
                    pod = try await client.object(ref.kind, namespace: namespace, name: ref.name).json
                } catch {
                    self?.commandProblem = "Couldn't read pod \(namespace)/\(ref.name): \(KubernetesModel.said(error))"
                    return
                }
            }
            guard let self else { return }
            guard let target = KubeDatabase.detect(pod) else {
                self.commandProblem =
                    KubeDatabase.otherClient(pod).map {
                        "pod \(ref.name) runs \($0.rawValue), which the Database client doesn't speak (\(KubeDatabase.spoken)) — "
                            + "\(KubernetesKey.shell.key) opens a shell in it, where \($0.program) runs."
                    } ?? "pod \(ref.name) runs no database the Database client speaks (\(KubeDatabase.spoken))."
                return
            }
            let answer = await self.model.access.answer(context, namespace: namespace, .portForward)
            if let why = KubeAccessState.answered(answer).unavailable(.portForward, namespace: namespace) {
                self.commandProblem = why
                return
            }
            // Asked before anything starts: a Cancel leaves no forward behind.
            self.askForSecrets(target, context: context, namespace: namespace, pod: ref.name) { [weak self] reads in
                Task { [weak self] in
                    guard let self, let local = await self.databaseForward(ref.name, target, context: context, namespace: namespace) else { return }
                    let read = reads ? await self.readSecrets(target, namespace: namespace, client: client) : KubeSecretValues()
                    self.actions?.openDatabase(
                        KubeDatabase.connection(target, pod: ref.name, context: context.name, namespace: namespace, localPort: local, read: read))
                }
            }
        }
    }

    /// A forward to the pod's database port that forwards — one already
    /// running, else one started on a free local port (the database's own
    /// where it is free), marked the Database client's so its server is
    /// never probed for an API — its local port; nil, said, when it
    /// doesn't come up.
    private func databaseForward(_ pod: String, _ database: KubeDatabaseTarget, context: KubeContext, namespace: String) async -> Int? {
        let target = KubeForwardTarget.pod(pod)
        let id: UUID
        if let running = forwards.forwards.first(where: {
            !$0.state.isStopped && $0.spec.context == context.name && $0.spec.namespace == namespace && $0.spec.target == target
                && $0.spec.remotePort == database.port
        }) {
            id = running.id
        } else {
            guard let local = freeLocalPort(preferring: database.port) else {
                commandProblem = "No free local port came up."
                return nil
            }
            id = forwards.start(
                KubeForwardSpec(
                    context: context.name, namespace: namespace, target: target, remotePort: database.port, localPort: local, forDatabase: true,
                    tab: actions?.currentTab()),
                in: context)
        }
        for _ in 0..<300 {
            guard let forward = forwards.forward(id) else {
                commandProblem = "The forward to pod/\(pod):\(database.port) was stopped."
                return nil
            }
            if case .stopped(let why) = forward.state {
                commandProblem = "The forward to pod/\(pod):\(database.port) stopped — \(why)"
                return nil
            }
            if forward.isForwarding { return forward.spec.localPort }
            try? await Task.sleep(for: .milliseconds(100))
        }
        commandProblem = "The forward to pod/\(pod):\(database.port) didn't come up in 30 seconds."
        return nil
    }

    /// Whether what the pod's env takes from Secrets is read: asked every
    /// time, naming the Secrets and keys, on production in its band's
    /// words; `then(true)` to read, `then(false)` to type — and on Cancel,
    /// nothing. Nothing wanted: `then(false)` at once.
    private func askForSecrets(
        _ target: KubeDatabaseTarget, context: KubeContext, namespace: String, pod: String, then: @escaping @MainActor (Bool) -> Void
    ) {
        let wanted = target.secretKeys
        guard !wanted.isEmpty else { return then(false) }
        let named = wanted.map(\.said).joined(separator: ", ")
        let what = target.passwordInSecret ? "Its password" : "Its user or database"
        let detail =
            (context.isProduction ? "PRODUCTION · \(context.name) · namespace \(namespace)\n" : "")
            + "\(what) comes from Secret \(named), as pod \(namespace)/\(pod)'s env says. Reading it is one GET of the Secret, which "
            + "returns every value it holds: only those keys are kept and handed to the connection form — a password saved with the connection "
            + "goes to the keychain, nowhere else. Not read, you type it in the form."
        actions?.choose(
            target.passwordInSecret ? "Read the database's password from its Secret?" : "Read the database's user from its Secret?", detail,
            ["Read from the Secret", "I'll Type It"]
        ) { index in then(index == 0) }
    }

    /// The Secrets the user agreed to read: one GET each, only the keys
    /// named kept (by `secret/key`), never logged or written; one that
    /// can't be read is said, and its keys left to type.
    private func readSecrets(_ target: KubeDatabaseTarget, namespace: String, client: KubeClient) async -> KubeSecretValues {
        var read = KubeSecretValues()
        for want in target.secretKeys {
            do {
                let answer = try await client.secret(.secrets, namespace: namespace, name: want.secret)
                read.read.insert(want.secret)
                for (key, value) in KubeDatabase.take(answer, keys: want.all) { read.values["\(want.secret)/\(key)"] = value }
            } catch {
                commandProblem = "Couldn't read Secret \(namespace)/\(want.secret): \(KubernetesModel.said(error)) — the form is left for you to fill in."
            }
        }
        return read
    }

    // MARK: A forward's API: the API client

    /// A forward's server's OpenAPI document, into the API client — on a press.
    func importForwardAPI(_ id: UUID) {
        guard let source = forwards.openAPI[id] else { return }
        actions?.importAPI(source)
    }

    /// The palette's New Port-forward…: the sheet on the object `f` would
    /// act on; with none, the Services list, saying what to pick.
    func newForward() {
        if portForward() { return }
        if let services = model.catalog.kind(fullName: KubeResourceKind.services.fullName) { showKind(services) }
        commandProblem = "Pick a pod, a Service or a Deployment, then \(KubernetesKey.portForward.key)."
    }

    // MARK: The palette

    /// The palette's forwards: New Port-forward…, then each forward — ↩
    /// opens it as `o` does (the browser column), or shows it on the page
    /// while it doesn't forward — its Stop while it runs, and the API its
    /// server publishes, to import. `show` brings the page up.
    func forwardPaletteItems(show: @escaping @MainActor () -> Void) -> [PaletteItem] {
        var items = [
            PaletteItem(
                id: "a.kubernetes.forward.new", group: .action, title: "Kubernetes: New Port-forward…",
                subtitle: "On the selected pod, Service or Deployment  \(KubernetesKey.portForward.key)", symbol: "plus"
            ) { [weak self] _, _ in
                show()
                self?.newForward()
            }
        ]
        for forward in forwards.forwards {
            let spec = forward.spec
            let summary = "\(spec.hostPort) → \(spec.target)"
            items.append(
                PaletteItem(
                    id: "k.f.\(forward.id)", group: .kubernetes, title: "Forward \(summary)",
                    subtitle: ([forward.pod.map { "pod \($0)" }, spec.context, spec.namespace, forward.state.text].compactMap { $0 }).joined(separator: " · "),
                    symbol: "arrow.left.arrow.right"
                ) { [weak self] _, _ in
                    guard let self else { return }
                    if forward.isForwarding {
                        self.openForward(forward.id)
                    } else {
                        show()
                        self.showForwards()
                    }
                })
            guard !forward.state.isStopped else { continue }
            items.append(
                PaletteItem(
                    id: "k.fs.\(forward.id)", group: .kubernetes, title: "Stop Forward \(summary)",
                    subtitle: "Ends its kubectl port-forward · \(spec.context) · \(spec.namespace)", symbol: "stop.circle"
                ) { [weak self] _, _ in self?.stopForward(forward.id) })
            if let source = forwards.openAPI[forward.id] {
                items.append(
                    PaletteItem(
                        id: "k.fa.\(forward.id)", group: .kubernetes, title: "Import \(source.title) into the API Client",
                        subtitle: "The OpenAPI document \(summary) serves, as a Bruno collection in the checkout",
                        symbol: "antenna.radiowaves.left.and.right"
                    ) { [weak self] _, _ in self?.importForwardAPI(forward.id) })
            }
        }
        return items
    }
}
