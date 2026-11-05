import Foundation

/// The Helm section (`8`; stage 2c): the releases of the context and
/// namespace shown, from Helm's records' metadata, read while the section
/// shows on a page on screen; a release opened is its one record read
/// (`KubeHelmSession`). Reads only: Helm's writes are stage 2f's.
extension KubernetesPageModel {
    /// Whether the Helm section is on screen.
    var helmShows: Bool { section == .helm && visible && windowVisible }

    /// The section shown: its list read again. Hidden — another section,
    /// the page or its window off screen — what a release's record said
    /// goes: another section closes it, the page hiding keeps it open
    /// saying so.
    func updateHelmReading() {
        if helmShows {
            // One detail at a time: the kind's under the section goes.
            if detail != nil { closeDetail() }
            loadHelm()
        } else if section != .helm {
            helm.close()
        } else {
            helm.pageHidden()
        }
    }

    /// Refresh, and the section shown: the releases listed again.
    func loadHelm() {
        guard let context = model.selectedName else { return }
        helm.load(context: context, scope: model.scope, client: model.client(for: context))
    }

    /// Another context or namespace: its releases, if the section shows;
    /// else what the last one read goes now.
    func helmScopeChanged() {
        if helmShows {
            loadHelm()
        } else if helm.context != model.selectedName || helm.scope != model.scope {
            helm.close()
        }
    }

    /// A release opened (a click, ↩): its latest revision, or one of its history.
    func openHelm(_ release: KubeHelmRelease, revision: KubeHelmRecord? = nil) {
        let production = model.contexts.context(named: helm.context ?? "")?.isProduction ?? true
        if revision == nil { helm.tab = .overview }
        helm.open(release, revision: revision, isProduction: production)
    }

    /// A key while the Helm section shows: ↑ ↓ along the releases, ↩
    /// opens one, Esc closes it, `k` copies its helm command — and the
    /// page's own keys (sections, `n`, `c`, `:`, `0`, `?`, `/`) as ever.
    /// The list's verbs would act on the kind under the section: refused.
    /// Nil: not Helm's, the page's to decide — every key while `?` shows.
    func helmPress(_ characters: String) -> Bool? {
        // The cheat sheet showing: every key is its to close first.
        if cheatSheet { return nil }
        switch characters {
        case "\u{F700}":
            helm.move(-1)
            return true
        case "\u{F701}":
            helm.move(1)
            return true
        case "\r":
            guard let release = helm.selectedRelease else { return false }
            openHelm(release)
            return true
        case "\u{1B}":
            guard helm.opened != nil else { return false }
            helm.close()
            return true
        case "k":
            actions?.copy(helmCommand)
            return true
        default:
            guard case .key(let key) = KubernetesKey.press(characters, sheetShowing: cheatSheet) else { return nil }
            return [.command, .namespace, .context, .allNamespaces].contains(key) ? nil : false
        }
    }

    /// The release picked's `helm status`, else the list's `helm list`.
    var helmCommand: String {
        let context = helm.context ?? model.selectedName ?? ""
        if let release = helm.opened?.release ?? helm.selectedRelease {
            return KubeHelmLine.status(context: context, namespace: release.namespace, release: release.name)
        }
        return KubeHelmLine.list(context: context, scope: helm.scope ?? model.scope)
    }

    /// Where the refusal sends you: a terminal pinned to the context, in
    /// the namespace shown (on production asked first).
    func openHelmTerminal() {
        guard let context = model.selected else { return }
        actions?.openTerminal(context, model.scope.namespace(for: .pods))
    }
}
