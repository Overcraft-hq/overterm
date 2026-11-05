import Foundation

// MARK: Helm's writes (stage 2f — docs/design/kubernetes/analysis.md, 2.12, Section 5, decision 15)

/// A release rolled back or uninstalled: helm in a terminal tab
/// (`KubeHelmWrite`), by the path drain and `rollout undo` take
/// (`confirmTabWrite`):
/// 1. the process class check (`KubeProcessCheck`): refused on a
///    read-only context — remote by its `writable` setting, production
///    without its switch for the session —; a Helm 2 release refused
///    everywhere;
/// 2. the access review (SelfSubjectAccessReview through the context's
///    writable socket): the release's records, and — when its manifest was
///    read, the release opened — the kinds it names;
/// 3. a rollback's revision, picked from the release's history (or the
///    one its History row named);
/// 4. the confirmation in the window naming the context and namespace and
///    the command; the release's name typed for a rollback on production
///    and an uninstall everywhere, checked here;
/// 5. the class check again, then the command typed into a new tab pinned
///    to the context — in a scenario, recorded instead.
extension KubernetesPageModel {
    static let helmWriteVerbs: [KubeProcessVerb] = [.helmRollback, .helmUninstall]

    /// The context the Helm section's releases are of.
    var helmContext: KubeContext? { model.contexts.context(named: helm.context ?? model.selectedName ?? "") }

    /// A release's writes — its detail's buttons, its row's menu, the
    /// palette's — each greyed with why: a read-only context, Helm 2, no
    /// earlier revision, the access review's no (asked as they are shown).
    func helmWriteVerbs(for release: KubeHelmRelease) -> [ResourceVerb] {
        guard let context = helmContext else { return [] }
        return Self.helmWriteVerbs.map { verb in
            ResourceVerb(
                title: KubeHelmWrite.title(verb), label: KubeHelmWrite.label(verb), symbol: KubeHelmWrite.symbol(verb),
                place: verb == .helmUninstall ? .remove : .button, key: verb == .helmUninstall ? KubernetesKey.delete.key : nil,
                unavailable: helmWriteUnavailable(verb, context, release), group: 6
            ) { [weak self] in self?.runHelmWrite(verb, on: release) }
        }
    }

    /// Why `verb` can't be done on the release now; nil when it can.
    func helmWriteUnavailable(_ verb: KubeProcessVerb, _ context: KubeContext, _ release: KubeHelmRelease) -> String? {
        if let refused = KubeProcessCheck.rule(verb, for: context).refused { return refused }
        if let refused = KubeHelmWrite.refusal(name: release.name, storage: release.storage) { return refused }
        if verb == .helmRollback, KubeHelmWrite.choices(release).isEmpty { return Self.noEarlierRevision(release) }
        for (access, namespace) in KubeHelmWrite.accesses(verb, storage: release.storage, namespace: release.namespace) {
            let place = namespace ?? ""
            let state = model.writeAccess.state(context.name, namespace: place, access)
            if state == .unknown { model.writeAccess.check(context, namespace: place, access) }
            if let why = state.unavailable(access, namespace: place, review: true) { return why }
        }
        return nil
    }

    static func noEarlierRevision(_ release: KubeHelmRelease) -> String {
        "Helm release \(release.namespace)/\(release.name) has no earlier revision kept to roll back to."
    }

    /// The release a key or the palette acts on: the row highlighted —
    /// ↑ ↓ move it off the one opened —, else the one opened.
    var helmPicked: KubeHelmRelease? { helm.selectedRelease ?? helm.opened?.release }

    /// ⌫ in the Helm section: the release highlighted, uninstalled — asked, its name typed.
    func helmDeleteKey() -> Bool {
        guard let release = helmPicked else { return false }
        runHelmWrite(.helmUninstall, on: release)
        return true
    }

    /// `verb` on the release, by the one path every tab write takes; a
    /// rollback goes to `revision` when given (its History row), else
    /// to one picked from the history.
    func runHelmWrite(_ verb: KubeProcessVerb, on release: KubeHelmRelease, revision: Int? = nil) {
        guard writeChecking == nil else { return }
        writeStatus = nil
        guard Self.helmWriteVerbs.contains(verb) else {
            writeStatus = .failed("\(verb.title) isn't a Helm write Overterm runs in a tab.")
            return
        }
        guard let context = helmContext else {
            writeStatus = .failed("No context for the Helm section.")
            return
        }
        if let refused = KubeProcessCheck.rule(verb, for: context).refused
            ?? KubeHelmWrite.refusal(name: release.name, storage: release.storage)
        {
            writeStatus = .failed(refused)
            return
        }
        let choices = KubeHelmWrite.choices(release)
        if verb == .helmRollback {
            if choices.isEmpty {
                writeStatus = .failed(Self.noEarlierRevision(release))
                return
            }
            // A History row's revision: any kept one but the latest, past the sheet's limit too.
            if let revision, !KubeHelmWrite.canRollBack(release, to: revision) {
                writeStatus = .failed(
                    "Revision \(revision) isn't one helm release \(release.namespace)/\(release.name) can roll back to: it is at \(release.revision).")
                return
            }
        }
        // The kinds its manifest names, when it was read: reviewed too.
        let manifest = helm.opened.flatMap { $0.release.id == release.id && $0.context == context.name ? $0.detail?.manifest : nil } ?? ""
        let accesses =
            KubeHelmWrite.accesses(verb, storage: release.storage, namespace: release.namespace)
            + KubeHelmWrite.resourceAccesses(verb, manifest: manifest, discovery: model.knownDiscovery(of: context.name), namespace: release.namespace)
        let object = "Helm release \(release.namespace)/\(release.name)"
        writeChecks += 1
        let token = writeChecks
        writeChecking = token
        writeStatus = .working("Checking… \(object)")
        Task { [weak self] in
            defer { self?.endChecking(token) }
            // The access review first: nothing is asked before it says yes.
            for (access, place) in accesses {
                let answer = await self?.model.writeAccess.answer(context, namespace: place ?? "", access) ?? .failed("")
                guard let self else { return }
                if let why = KubeAccessState.answered(answer).unavailable(access, namespace: place ?? "", review: true) {
                    self.writeStatus = .failed(why)
                    return
                }
            }
            guard let self else { return }
            self.endChecking(token)
            self.writeStatus = nil
            switch verb {
            case .helmUninstall:
                self.confirmTabCommand(
                    KubeHelmWrite.uninstall(release: release.name, namespace: release.namespace, storage: release.storage, revisions: release.history.count),
                    reviewed: context, pin: release.namespace)
            default:
                let rollBack: @MainActor (Int) -> Void = { [weak self] chosen in
                    self?.confirmTabCommand(
                        KubeHelmWrite.rollback(
                            release: release.name, namespace: release.namespace, storage: release.storage, revision: chosen, from: release.revision),
                        reviewed: context, pin: release.namespace)
                }
                if let revision { return rollBack(revision) }
                let now = self.clock()
                self.actions?.choose(
                    "Roll back to which revision?",
                    "Helm release \(release.namespace)/\(release.name) in \(context.displayName), at revision \(release.revision) now. "
                        + "Each kept revision, newest first.",
                    choices.map { KubeHelmWrite.label($0, summary: self.helm.summaries[$0.id], now: now) }
                ) { index in
                    guard choices.indices.contains(index) else { return }
                    rollBack(choices[index].revision)
                }
            }
        }
    }
}
