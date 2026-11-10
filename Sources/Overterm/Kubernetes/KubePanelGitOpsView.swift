import SwiftUI

/// The rail's "GitOps" part (gitops.md 4.5): after the deployed commit,
/// before the workloads, only when there is a match, an owner, a problem
/// or the production button. A row: the state's dot, the object, its
/// state and why, its revision and age, and in grey why it matched —
/// "deploy/fake-dev", "owns Deployment/shop-api" — with what it tracks.
/// Its buttons go through the window (`KubeGitOpsPanelHost`), so through
/// the page's guard path; what they did is said here.
struct KubePanelGitOpsView: View {
    @ObservedObject var gitOps: KubePanelGitOps
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if gitOps.shows {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("GitOps").font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
                    Spacer(minLength: 0)
                    // Read, failed, or neither tool served: always a way to read again.
                    if gitOps.canRefresh {
                        Button {
                            gitOps.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10))
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
                    Text(verbatim: status.text).font(.system(size: 10.5)).foregroundStyle(status.isFailure ? TabStatusStyle.failed : theme.text2)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 2)
                        .accessibilityIdentifier("kubernetes.panel.gitops.status")
                }
                if case .waiting(let reads) = gitOps.state {
                    VStack(alignment: .leading, spacing: 3) {
                        Button("Find What Deploys This") { gitOps.find() }
                            .buttonStyle(.link).font(.system(size: 11))
                            .help("On production nothing is listed across the cluster until asked")
                            .accessibilityIdentifier("kubernetes.panel.gitops.find")
                        if !reads.isEmpty {
                            Text(verbatim: reads).font(.system(size: 10.5)).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 2)
                }
                if case .failed(let reason) = gitOps.state { line(reason, failed: true) }
                ForEach(gitOps.problems, id: \.self) { line($0, failed: true) }
                ForEach(gitOps.matches) { match in row(match) }
                ForEach(gitOps.searched, id: \.self) { line($0, failed: false) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kubernetes.panel.gitops")
        }
    }

    private func line(_ text: String, failed: Bool) -> some View {
        Text(verbatim: text).font(.system(size: 10.5)).foregroundStyle(failed ? TabStatusStyle.failed : theme.text3).lineLimit(3)
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

    private func row(_ match: KubePanelGitOps.Match) -> some View {
        let now = Date()
        let object = match.object
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(color(object?.state)).frame(width: 7, height: 7)
                Text(verbatim: match.said).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if let object {
                let revision = KubeGitOpsRevision.column(object)
                let age = object.stateSince.map { " · \(KubeAge.format(now.timeIntervalSince($0)))" } ?? ""
                Text(verbatim: "\(object.state.word): \(object.why)" + (revision.isEmpty ? "" : " · \(revision)") + age)
                    .font(.system(size: 10.5)).foregroundStyle(object.state.mark == .bad ? TabStatusStyle.failed : theme.text2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: ([match.why] + [match.tracks].compactMap { $0 }).joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(theme.text3)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if object != nil {
                HStack(spacing: 10) {
                    Button("Open on Page") { gitOps.openOnPage(match) }
                    Button(match.key.kind == "Application" ? "Refresh" : "Reconcile") { gitOps.reconcile(match) }
                        .help("Asked in the window first, through the page's checks")
                        .accessibilityIdentifier("kubernetes.panel.gitops.reconcile")
                    if match.key.kind == "Application" || match.key.kind == "Kustomization" || match.key.kind == "HelmRelease" {
                        Button(match.key.kind == "Application" ? "Sync in a Tab…" : "With Source in a Tab…") { gitOps.syncInTab(match) }
                    }
                    if match.isProblem { Button("Ask Why") { gitOps.askWhy(match) } }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
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
