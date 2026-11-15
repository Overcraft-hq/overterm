import Foundation

// MARK: The Docker page (stage 4 — docs/design/kubernetes/analysis.md, 3.12)

/// A pod's or a workload's container, on this Mac's Docker: Run Locally
/// fills in the Docker page's Run window (`KubeRunLocally.plan`), Scan
/// opens its image on the Images section's Vulnerabilities tab and scans
/// it there (`DockerPageModel.scanImage`). Both are reads of the cluster —
/// one GET of the object, never a Secret's or a ConfigMap's — so they are
/// offered on every class; nothing runs and nothing is scanned until the
/// user presses Run in a Tab, or Scan (an image the engine hasn't is
/// asked before it is pulled).
extension KubernetesPageModel {
    static let runLocallyTitle = "Run Locally on Docker…"
    static let scanImageTitle = "Scan Image on Docker"

    /// Run Locally and Scan on a pod or a workload: greyed with why while
    /// Docker is off.
    func dockerVerbs(for ref: KubeObjectRef) -> [ResourceVerb] {
        guard ref.namespace != nil, KubeRunLocally.offers(ref.kind) else { return [] }
        let off = dockerEnabled() ? nil : "Docker is off — Settings ▸ Docker"
        return [
            ResourceVerb(title: Self.runLocallyTitle, label: "Run Locally", symbol: "shippingbox", place: .more, unavailable: off, group: 4) {
                [weak self] in self?.toDocker(.run, ref)
            },
            ResourceVerb(title: Self.scanImageTitle, label: "Scan", symbol: "shield.lefthalf.filled", place: .more, unavailable: off, group: 4) {
                [weak self] in self?.toDocker(.scan, ref)
            },
        ]
    }

    /// The one row picked: its Docker verbs.
    func dockerVerbs(for picked: [KubeRow]) -> [ResourceVerb] {
        guard picked.count == 1, let row = picked.first, let ref = ref(for: row.id.description) else { return [] }
        return dockerVerbs(for: ref)
    }

    enum DockerHandoff { case run, scan }

    /// The object read once, its container picked (the default first, as a
    /// shell's), then the Docker page.
    func toDocker(_ handoff: DockerHandoff, _ ref: KubeObjectRef) {
        guard writeChecking == nil else {
            writeStatus = .failed("Another check is running: try again once it is done.")
            return
        }
        writeStatus = nil
        guard let namespace = ref.namespace, KubeRunLocally.offers(ref.kind) else {
            writeStatus = .failed("Only a pod or a workload runs a container.")
            return
        }
        guard dockerEnabled() else {
            writeStatus = .failed("Docker is off — Settings ▸ Docker.")
            return
        }
        guard let context = model.contexts.context(named: ref.context), let client = model.client(for: ref.context) else {
            writeStatus = .failed("Kubernetes is off, or the context is gone.")
            return
        }
        let object = KubeWriteOutcome.spoken(ref)
        writeChecks += 1
        let token = writeChecks
        writeChecking = token
        writeStatus = .working("Reading \(object)…")
        Task { [weak self] in
            defer { self?.endChecking(token) }
            let pod: [String: Any]
            do {
                let read = try await client.object(ref.kind, namespace: namespace, name: ref.name).json
                guard let like = KubeRunLocally.podLike(read, kind: ref.kind) else {
                    self?.writeStatus = .failed("\(object) has no pod template.")
                    return
                }
                pod = like
            } catch {
                self?.writeStatus = .failed("Couldn't read \(object): \(KubernetesModel.said(error))")
                return
            }
            guard let self else { return }
            self.endChecking(token)
            self.writeStatus = nil
            let pick = KubeContainerPick.of(pod, for: .shell)
            let title = handoff == .run ? "Run Locally" : "Scan Image"
            self.pickContainer(pick, title: "\(title) — \(object) in \(context.displayName).") { [weak self] container in
                guard let self, let container else {
                    self?.writeStatus = .failed("\(object) has no container.")
                    return
                }
                switch handoff {
                case .run:
                    guard let spec = KubeRunLocally.plan(pod, container: container, context: context.name, namespace: namespace, object: object) else {
                        self.writeStatus = .failed("Container \(container) of \(object) names no image.")
                        return
                    }
                    self.actions?.runLocally(spec)
                case .scan:
                    guard let image = KubeRunLocally.image(pod, container: container) else {
                        self.writeStatus = .failed("Container \(container) of \(object) names no image.")
                        return
                    }
                    self.actions?.scanImage(image, "\(object) (container \(container), in \(context.displayName))")
                }
            }
        }
    }

    private func pickContainer(_ pick: KubeContainerPick, title: String, then: @escaping (String?) -> Void) {
        switch pick {
        case .none: then(nil)
        case .one(let container): then(container)
        case .several(let containers, let chosen):
            actions?.choose("Which container?", title, containers.map { $0 == chosen ? "\($0) (default)" : $0 }) { index in
                guard containers.indices.contains(index) else { return }
                then(containers[index])
            }
        }
    }
}
