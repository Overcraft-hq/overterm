import Foundation

/// What a bound release's upgrade asks of its window.
@MainActor
protocol KubeHelmUpgradeHost: AnyObject {
    /// The write's confirmation (`WriteConfirmation`): what was typed when
    /// the button was pressed, nil for Cancel.
    func askHelmUpgrade(_ confirmation: KubeWriteConfirmation) async -> String?
    /// Asked first, with this button (a production release's values read for its diff).
    func askHelmUpgrade(_ title: String, _ detail: String, _ button: String) async -> Bool
    /// The diff, in the right-hand pane.
    func showHelmDiff(_ session: KubeHelmUpgradeSession)
    /// `helm upgrade` typed into a tab pinned to the context (recorded in a scenario).
    func runHelmUpgrade(_ command: String, in context: KubeContext, namespace: String)
}

/// A bound checkout's release against its chart (stage 3a, `KubeHelmUpgrade`):
/// Diff Chart with Release reads the release's newest record — on
/// production asked first, once a context and session, as Show is —
/// renders the checkout's chart with its values (`helm template`, no
/// cluster), and shows what would change, masked, in the changes pane;
/// Upgrade… is a step of its own through the writes' guard path: the
/// class check (writable contexts only; production with its switch for
/// the session), a fresh diff, the access review, the confirmation naming
/// the context and namespace (the name typed on production), the context
/// checked again at the button, then `helm upgrade` in a pinned tab.
@MainActor
final class KubeHelmUpgradeSession: ObservableObject, Identifiable {
    typealias State = KubeManifestSession.State

    /// One diff made: against what, and what would change.
    struct Diffed: Equatable {
        var context: String
        var production: Bool
        var release: String
        var namespace: String
        var storage: KubeHelmStorage
        var revision: Int
        var chart: URL
        var chartSaid: String?
        var diff: KubeHelmDiff
        /// What the server serves (the page's, else read for the diff): the
        /// render's `--api-versions`, and the kinds its access review asks about.
        var discovery: KubeDiscovery?
    }

    let id = UUID()
    let binding: KubeBinding
    let checkout: URL
    let model: KubernetesModel
    @Published private(set) var state: State = .idle
    @Published private(set) var result: Diffed?
    /// Each object's diff, made for the pane once.
    @Published private(set) var fileDiffs: [String: DiffModel.FileDiff] = [:]
    weak var host: KubeHelmUpgradeHost?

    /// What a read goes through: the context's proxy in a background slot, or a test's connection.
    var client: (KubeContext) -> KubeClient
    /// The checkout's chart for the release (a bounded walk, off the main thread).
    var findChart: (URL, String) async -> URL?
    /// The chart rendered with the release's values and the cluster's
    /// version and groups (`KubeHelmTemplate`); a test's stands in.
    var render: (URL, String, String, Data, KubeContext, KubeHelmCapabilities) async throws -> String
    /// What the session is told when its tab opens (the scenario).
    var onUpgrade: ((String) -> Void)?

    init(binding: KubeBinding, checkout: URL, model: KubernetesModel) {
        self.binding = binding
        self.checkout = checkout
        self.model = model
        client = { context in model.panelClient(for: context) }
        findChart = { root, release in
            await KubeBlocking.run { KubeHelmUpgrade.chart(in: KubeCheckoutScan.files(in: root), release: release, root: root) }
        }
        render = { chart, release, namespace, values, context, capabilities in
            try await KubeHelmTemplate.render(
                chart: chart, release: release, namespace: namespace, values: values, context: context, configured: Settings.shared.kubernetesHelmPath,
                capabilities: capabilities)
        }
    }

    var release: String? { binding.release }

    /// `Helm release shop/web`.
    var title: String { "Helm release \(binding.namespace)/\(binding.release ?? "?")" }

    // MARK: Diff Chart with Release

    func diff() { Task { _ = await runDiff() } }

    @discardableResult
    func runDiff(show: Bool = true) async -> Diffed? {
        guard let release = binding.release else {
            state = .failed("The binding names no Helm release.")
            return nil
        }
        state = .working("Rendering the checkout's chart for \(title)…")
        guard let context = await contextNow() else { return nil }
        guard let chart = await findChart(checkout, release) else {
            fail("No chart for \(release) in the checkout: a Chart.yaml named \(release), or a single one.")
            return nil
        }
        if model.secretConsent.needsAsking(context.name, production: context.isProduction) {
            let yes =
                await host?.askHelmUpgrade(
                    "Read this release's values to diff its chart?",
                    "PRODUCTION · \(context.name)\nHelm keeps them in a Secret: they are read once, given to helm template on its stdin, compared masked, and dropped — never written or kept. Asked once a session.",
                    "Read and Compare") ?? false
            guard yes else {
                fail("Nothing was read: the diff reads the release's values, and that wasn't allowed.")
                return nil
            }
            model.secretConsent.grant(context.name)
        }
        do {
            let client = self.client(context)
            let found = try await Self.release(release, namespace: binding.namespace, client: client)
            let body = try await client.get(found.storage.kind.path(namespace: found.namespace, name: found.latest.object)).body
            let storage = found.storage
            let inputs = try await KubeBlocking.run { Swift.Result { try KubeHelm.upgradeInputs(body, storage: storage) } }.get()
            // The cluster as helm upgrade will see it: its version and what
            // it serves (GETs; the page's discovery when it has one).
            let version = try? await client.version()
            var discovery = model.knownDiscovery(of: context)
            if discovery == nil { discovery = try? await client.discover() }
            let capabilities = KubeHelmCapabilities(version: version, discovery: discovery)
            let rendered = try await render(chart, release, binding.namespace, inputs.values, context, capabilities)
            let current = inputs.manifest
            let namespace = binding.namespace
            let revision = inputs.revision
            let diff = await KubeBlocking.run { KubeHelmUpgrade.diff(current: current, rendered: rendered, namespace: namespace, revision: revision) }
            let chartText = (try? String(contentsOf: chart.appendingPathComponent("Chart.yaml"), encoding: .utf8)) ?? ""
            let result = Diffed(
                context: context.name, production: context.isProduction, release: release, namespace: namespace, storage: storage,
                revision: revision, chart: chart, chartSaid: KubeHelmUpgrade.chartInfo(chartText).said, diff: diff, discovery: discovery)
            self.result = result
            fileDiffs = Dictionary(uniqueKeysWithValues: diff.items.filter { !$0.diff.isEmpty }.map { ($0.id, DiffModel.FileDiff(parsing: $0.diff, path: $0.file)) })
            state = .done(diff.said)
            if show { host?.showHelmDiff(self) }
            return result
        } catch {
            fail(Self.said(error))
            return nil
        }
    }

    /// A failure said, no diff kept beside it.
    private func fail(_ said: String) {
        result = nil
        fileDiffs = [:]
        state = .failed(said)
    }

    static func said(_ error: Error) -> String {
        switch error {
        case let problem as KubeHelmTemplate.Problem: problem.description
        case let problem as KubeHelmProblem: problem.localizedDescription
        default: KubernetesModel.said(error)
        }
    }

    /// The release's records (Secrets, else ConfigMaps), as a release.
    static func release(_ name: String, namespace: String, client: KubeClient) async throws -> KubeHelmRelease {
        for storage in [KubeHelmStorage.secret, .configMap] {
            let records = try await client.helmRecords(storage, in: .namespace(namespace))
            if let found = KubeHelm.releases(records).first(where: { $0.name == name && $0.namespace == namespace }) { return found }
        }
        throw KubeHelmTemplate.Problem("No Helm release \(namespace)/\(name) in the cluster: install it first (helm install, in a tab).")
    }

    /// The binding's context as the kubeconfig and the session's switches say it now.
    private func contextNow() async -> KubeContext? {
        guard let list = await model.contextsForAgents() else {
            fail("Kubernetes is off in Settings ▸ Kubernetes.")
            return nil
        }
        guard let context = list.context(named: binding.context) else {
            fail("The kubeconfig has no context “\(binding.context)”: edit the binding.")
            return nil
        }
        return context
    }

    // MARK: Upgrade…

    /// Why Upgrade… can't be offered now (the class check); nil when it can.
    func upgradeRefusal(_ context: KubeContext?) -> String? {
        guard let context else { return nil }
        return KubeProcessCheck.rule(.helmUpgrade, for: context).refused
    }

    func upgrade() { Task { await runUpgrade() } }

    func runUpgrade() async {
        guard !state.isWorking, let release = binding.release else { return }
        state = .working("Checking… \(title)")
        guard let context = await contextNow() else { return }
        // 1. The class check: writable contexts only, production with its switch on.
        if let refused = KubeProcessCheck.rule(.helmUpgrade, for: context).refused {
            return state = .failed(refused)
        }
        // 2. A fresh diff: the confirmation says what this render changes.
        guard let result = await runDiff(show: true), result.context == context.name else { return }
        // The access review's plan: the records, and what the diff says
        // helm makes, changes and deletes.
        let review = KubeHelmUpgrade.accesses(storage: result.storage, namespace: result.namespace, diff: result.diff, discovery: result.discovery)
        let write = KubeHelmUpgradeWrite(
            release: release, namespace: result.namespace, storage: result.storage, chart: result.chart.path, chartSaid: result.chartSaid,
            from: result.revision, summary: result.diff.said, reviewNote: review.partial)
        if let refused = write.refused { return state = .failed(refused) }
        // 3. The access review (SelfSubjectAccessReview through the context's
        // writable socket): nothing is asked before it says yes.
        state = .working("Checking… \(title)")
        let client = self.client(context)
        for (access, place) in review.accesses {
            let answer = await client.review(access, namespace: place)
            if let why = KubeAccessState.answered(answer).unavailable(access, namespace: place ?? "", review: true) {
                return state = .failed(why)
            }
        }
        // 4. Asked in the window, the name typed where rule 4 says.
        let rule = KubeProcessCheck.rule(.helmUpgrade, for: context)
        let confirmation = write.confirmation(context: context, rule: rule)
        guard let host else { return state = .failed("Nothing was run: there is no window to ask in.") }
        state = .working("Asking… \(title)")
        guard let typed = await host.askHelmUpgrade(confirmation) else { return state = .done("Cancelled: nothing was run.") }
        guard confirmation.accepts(typed) else { return state = .failed("The name typed wasn't \(release): nothing was run.") }
        // 5. The context as it is now: writes turned off, or the name now another cluster or user, stop it here.
        guard let now = await model.contextsForAgents()?.context(named: context.name), KubernetesModel.sameAccess(context, now) else {
            return state = .failed(KubernetesPageModel.contextChanged)
        }
        do {
            let command = try KubeCommands.command(write, in: now)
            let said = write.opened(context: now.name)
            state = .done(said)
            host.runHelmUpgrade(command, in: now, namespace: result.namespace)
            onUpgrade?(command)
        } catch {
            state = .failed("\(error)")
        }
    }
}
