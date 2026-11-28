import SwiftUI

/// The rail's "GitOps" part (gitops.md 4.5): after the deployed commit,
/// before the workloads, only when there is a match, an owner, a problem
/// or the production button. A row: the state's dot, the object, its
/// state and why, its revision and age, and in grey why it matched —
/// "deploy/fake-dev", "owns Deployment/shop-api" — with what it tracks.
/// Its buttons go through the window (`KubeGitOpsPanelHost`), so through
/// the page's guard path; what they did is said here. An Argo CD app read
/// from marks (14.2.5): its state by Argo CD's built-in rules and why,
/// whose health that is, where its Application stands, why it matched —
/// Open shows its detail on the page, and no GitOps verb is offered; those
/// matched only by name or image apart, muted, as "probably" — the bound
/// namespace's, those elsewhere counted —; nothing matched said by what
/// was compared.
package struct KubePanelGitOpsView: View {
    @ObservedObject package var gitOps: KubePanelGitOps
    @ObservedObject package var theme: ChromeTheme
    /// The keys it names, as bound now.
    @ObservedObject var keys = Keybindings.shared

    package var body: some View {
        if gitOps.shows {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("GitOps").font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
                    Spacer(minLength: 0)
                    // Read, failed, or neither tool served: always a way to read again.
                    if gitOps.canRefresh {
                        Button {
                            gitOps.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: ChromeMetrics.text(10)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.text3)
                        .help("Read what deploys this checkout again")
                        .accessibilityIdentifier("kubernetes.panel.gitops.refresh")
                    }
                }
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                // What a verb asked from here did, above the rows it may be about.
                if let status = gitOps.status {
                    Text(verbatim: status.text).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(status.isFailure ? TabStatusStyle.failed : theme.text2)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 2)
                        .accessibilityIdentifier("kubernetes.panel.gitops.status")
                }
                if case .waiting(let reads) = gitOps.state {
                    VStack(alignment: .leading, spacing: 3) {
                        Button("Find What Deploys This") { gitOps.find() }
                            .buttonStyle(.link).font(.system(size: ChromeMetrics.text(11)))
                            .help("On production nothing is listed across the cluster until asked")
                            .accessibilityIdentifier("kubernetes.panel.gitops.find")
                        if !reads.isEmpty {
                            Text(verbatim: reads).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 2)
                }
                if case .failed(let reason) = gitOps.state { line(reason, failed: true) }
                if let marks = gitOps.marksLine {
                    line(marks, failed: false).accessibilityIdentifier("kubernetes.panel.gitops.marks")
                }
                ForEach(gitOps.problems, id: \.self) { line($0, failed: true) }
                ForEach(gitOps.matches.filter { $0.marked?.probable != true }) { match in
                    if let marked = match.marked { markedRow(match, marked) } else { row(match) }
                }
                probablyPart
                if let nothing = gitOps.marksSaid.nothing {
                    // What was compared, whole: it is all a nothing found may say.
                    // Its notes carry the API server's own words: the hover capped, as every hover here.
                    Text(verbatim: nothing).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 2).help(KubeMarkedSection.capped(nothing))
                        .accessibilityIdentifier("kubernetes.panel.gitops.nothing")
                }
                ForEach(gitOps.marksSaid.caveats, id: \.self) { line($0, failed: false) }
                ForEach(gitOps.searched, id: \.self) { line($0, failed: false) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kubernetes.panel.gitops")
        }
    }

    /// The apps matched by name, image or a manifest with no namespace:
    /// apart, muted, never as found — or, past three, how many; the bound
    /// namespace's, and beneath them those elsewhere counted.
    @ViewBuilder private var probablyPart: some View {
        let probable = gitOps.matches.filter { $0.marked?.probable == true }
        if !probable.isEmpty || gitOps.marksSaid.tooMany != nil {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "May deploy this checkout (by name)").font(.system(size: ChromeMetrics.text(10.5), weight: .medium)).foregroundStyle(theme.text3)
                    .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
                if let tooMany = gitOps.marksSaid.tooMany { line(tooMany, failed: false) }
                ForEach(probable) { match in
                    if let marked = match.marked { markedRow(match, marked) }
                }
                if let elsewhere = gitOps.marksSaid.elsewhere {
                    line(elsewhere, failed: false).accessibilityIdentifier("kubernetes.panel.gitops.probably.elsewhere")
                }
            }
            .opacity(0.85)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kubernetes.panel.gitops.probably")
        }
    }

    /// An app read from marks: its state and why, whose health, where its
    /// Application stands, why it matched; Open — never a GitOps verb.
    private func markedRow(_ match: KubePanelGitOps.Match, _ marked: KubePanelGitOps.Marked) -> some View {
        let now = Date()
        let health = marked.health
        let age = health.since.map { " · \(KubeAge.format(max(0, now.timeIntervalSince($0))))" } ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            // Its name whole, over two lines if it must: the part's line says it is Argo CD's.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(color(health.state)).frame(width: 7, height: 7)
                Text(verbatim: marked.app.said + (marked.app.installation.map { " · installation \($0)" } ?? ""))
                    .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).lineLimit(2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(match.said)
                Spacer(minLength: 0)
            }
            Text(verbatim: "\(health.word): \(health.why)" + age)
                .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(health.state.mark == .bad ? TabStatusStyle.failed : theme.text2).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("kubernetes.panel.gitops.marked.health")
            small(marked.scope.said(now: now), failed: false, id: "kubernetes.panel.gitops.marked.scope")
            small(marked.place.said(context: gitOps.contextName ?? ""), failed: false, id: "kubernetes.panel.gitops.marked.place")
            Text(verbatim: match.why).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Open") { gitOps.openMarked(match) }
                    .help("Its detail on the page: its objects as Argo CD would draw them, each with its health")
                    .accessibilityIdentifier("kubernetes.panel.gitops.marked.open")
                if match.asksWhy {
                    Button("Ask Why") { gitOps.askWhy(match) }
                        .help("Ask an agent why: its objects' states, conditions and pods, scrubbed — shown whole before it is sent")
                        .accessibilityIdentifier("kubernetes.panel.gitops.marked.askWhy")
                }
            }
            .buttonStyle(.link)
            .font(.system(size: ChromeMetrics.text(11)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .help(KubeMarkedSection.capped(([health.word == health.state.word ? nil : "Argo CD's word: \(health.word)"].compactMap { $0 } + health.notes).joined(separator: "\n")))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kubernetes.panel.gitops.marked.\(marked.app.id)")
    }

    private func line(_ text: String, failed: Bool) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(failed ? TabStatusStyle.failed : theme.text3).lineLimit(3)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 2)
    }

    private func color(_ state: KubeGitOpsState?) -> Color {
        guard let state else { return theme.text3 }
        switch state.mark {
        case .bad: return TabStatusStyle.failed
        case .waiting: return TabStatusStyle.waiting
        case .good: return TabStatusStyle.done
        default: return theme.text3
        }
    }

    /// Has this branch reached the cluster (4.3): the manifests line beside
    /// the image's, attempted ≠ applied, fetched not applied, no change
    /// under the path, the files this branch changes — as of the last fetch.
    @ViewBuilder private func reachLines(_ match: KubePanelGitOps.Match, _ reach: KubeGitOpsReach.Answer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: reach.deployed.text).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("kubernetes.panel.gitops.deployed")
            Text(verbatim: reach.source).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.middle)
            if let attempted = reach.attempted { small(attempted, failed: true, id: "kubernetes.panel.gitops.attempted") }
            if let fetched = reach.fetched { small(fetched, failed: false, id: "kubernetes.panel.gitops.fetched") }
            if let unchanged = reach.unchanged { small(unchanged, failed: false, id: "kubernetes.panel.gitops.unchanged") }
            if let changed = reach.changed {
                if changed.review != nil {
                    Button(changed.text) { gitOps.reviewChanged(match) }
                        .buttonStyle(.link).font(.system(size: ChromeMetrics.text(10.5)))
                        .help(KeyHints.help("A review tab", command: "review.branch", keys: keys) + " of these files, from where this branch left \(changed.against)")
                        .accessibilityIdentifier("kubernetes.panel.gitops.changed")
                } else {
                    small(changed.text, failed: false, id: "kubernetes.panel.gitops.changed")
                }
            }
            ForEach(reach.checked, id: \.self) { small($0, failed: false, id: nil) }
            if let found = reach.found, !found.isHead || found.elsewhere > 0 {
                Button("Diff Deployed…Current") { gitOps.reviewDeployed(match) }
                    .buttonStyle(.link).font(.system(size: ChromeMetrics.text(11)))
                    .help(KeyHints.help("A review tab", command: "review.branch", keys: keys) + ": what the checkout has that isn't in the manifests' commit")
                    .accessibilityIdentifier("kubernetes.panel.gitops.diffDeployed")
            }
            if !reach.pathspecs.isEmpty || reach.found != nil {
                Text(verbatim: "as of the last fetch").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func small(_ text: String, failed: Bool, id: String?) -> some View {
        let view = Text(verbatim: text).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(failed ? TabStatusStyle.failed : theme.text2).lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        if let id { view.accessibilityIdentifier(id) } else { view }
    }

    /// A matched object's verbs, laid out by `row`.
    @ViewBuilder private func verbs(_ match: KubePanelGitOps.Match) -> some View {
        Button("Open on Page") { gitOps.openOnPage(match) }
        Button(match.key.kind == "Application" ? "Refresh" : "Reconcile") { gitOps.reconcile(match) }
            .help("Asked in the window first, through the page's checks")
            .accessibilityIdentifier("kubernetes.panel.gitops.reconcile")
        if match.key.kind == "Application" || match.key.kind == "Kustomization" || match.key.kind == "HelmRelease" {
            Button(match.key.kind == "Application" ? "Sync in a Tab…" : "With Source in a Tab…") { gitOps.syncInTab(match) }
        }
        if match.isProblem { Button("Ask Why") { gitOps.askWhy(match) } }
    }

    private func row(_ match: KubePanelGitOps.Match) -> some View {
        let now = Date()
        let object = match.object
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(color(object?.state)).frame(width: 7, height: 7)
                Text(verbatim: match.said).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if let object {
                let revision = KubeGitOpsRevision.column(object)
                let age = object.stateSince.map { " · \(KubeAge.format(now.timeIntervalSince($0)))" } ?? ""
                Text(verbatim: "\(object.state.word): \(object.why)" + (revision.isEmpty ? "" : " · \(revision)") + age)
                    .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(object.state.mark == .bad ? TabStatusStyle.failed : theme.text2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: ([match.why] + [match.tracks].compactMap { $0 }).joined(separator: " · ")).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let reach = match.reach { reachLines(match, reach) }
            if object != nil {
                // In a row while they fit, else one under another: squeezed
                // into the rail's width, a row of four broke each title a
                // letter or two to a line.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { verbs(match) }
                    VStack(alignment: .leading, spacing: 3) { verbs(match) }
                }
                .buttonStyle(.link)
                .font(.system(size: ChromeMetrics.text(11)))
                .disabled(gitOps.status?.isWorking == true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .help(object?.lastError ?? "")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kubernetes.panel.gitops.\(match.key.namespace ?? "").\(match.key.name)")
    }
}
