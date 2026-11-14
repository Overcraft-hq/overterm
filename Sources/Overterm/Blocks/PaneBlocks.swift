import AppKit
import Combine

/// One pane's command ledger, kept up to date from what libghostty pushes.
///
/// Also decides when the scroll map is on screen. macOS hides scrollbars
/// until you scroll unless you have asked for them always, and a map that
/// is always there would cost every pane 16 pt of width for something you
/// look at while scrolling — so it follows the same rule as the system's
/// own.
@MainActor
final class PaneBlocks: ObservableObject {
    @Published private(set) var ledger = CommandLedger()
    /// The link under the pointer, if any. libghostty pushes the URL and
    /// nothing else — no rectangle — so this is all anyone can know about
    /// where it is, and the header is where it can be said.
    @Published private(set) var hoveredLink: String?
    /// Whether the map is drawn right now.
    @Published private(set) var showMap = NSScroller.preferredScrollerStyle == .legacy
    private var hiding: Task<Void, Never>?
    /// Told when a command finishes, so the palette's history gets it.
    var onCommandFinished: ((CommandBlock) -> Void)?

    /// How long the map stays after the last scroll, matching the feel of
    /// an overlay scrollbar.
    static let linger: Duration = .milliseconds(1200)

    /// Bumped whenever the pane says something happened on screen — a
    /// scroll (new lines), a title, a bell, a notification, a command's end —
    /// not an agent's progress, which ticks while it works: the Terraform
    /// pane monitor reads a screen again only when it moved (3.2's budget).
    private(set) var outputMark: UInt64 = 0

    func handle(_ event: TerminalEvent) {
        switch event {
        case .linkHover, .progress: break
        default: outputMark &+= 1
        }
        switch event {
        case .scrolled(let total, let offset, let rows):
            ledger.scrolled(total: total, offset: offset, rows: rows)
            flashMap()
        case .commandFinished(let exitCode, let seconds):
            ledger.finished(exitCode: exitCode, seconds: seconds)
            ledger.lastFinished.map { onCommandFinished?($0) }
        case .linkHover(let url):
            if hoveredLink != url { hoveredLink = url }
        case .bell, .notification, .progress:
            break
        }
    }

    /// The shell set its title. With shell integration that is the command
    /// about to run — the only name a command ever gets — except when it
    /// is the directory, which means the prompt came back.
    /// `kubeconfig`: the pane's own `KUBECONFIG` (a pinned pane's).
    func titleChanged(_ title: String, cwd: String?, kubeconfig: String? = nil) {
        outputMark &+= 1
        if CommandLedger.isPrompt(title, cwd: cwd) {
            ledger.prompted()
        } else {
            commandFolder = cwd
            ledger.began(command: title)
            // Terraform printing secrets in clear: the pane keeps no scrollback (5.6 rule 6).
            if TerraformCommandLine.all(in: title).contains(where: \.printsSecrets) { printedTerraformSecrets = true }
            // A kubectl-family command: the files its context comes from are
            // read the first time (KubeAmbientContexts), never per command.
            KubeAmbientContexts.shared.noticed(title, cwd: cwd, kubeconfig: kubeconfig)
        }
    }

    /// A command run here printed what Terraform keeps secret
    /// (`TerraformCommandLine.printsSecrets`): the pane's
    /// `terraformSensitive` reads it.
    private(set) var printedTerraformSecrets = false

    /// The folder the latest command began in: what a relative
    /// `--kubeconfig ./prod.yaml` in it is relative to.
    private(set) var commandFolder: String?

    /// The command running, else the last one run: what the header's
    /// Kubernetes warning is about (3.11): a quick `kubectl delete` ends
    /// before anyone reads a header, so what it reached stays said until
    /// the next command.
    var latestCommand: String? { ledger.blocks.last?.command }

    /// Shown while the pointer is over the right edge, as a scrollbar is.
    func hoverMap(_ inside: Bool) {
        hiding?.cancel()
        showMap = inside || NSScroller.preferredScrollerStyle == .legacy
    }

    private func flashMap() {
        guard NSScroller.preferredScrollerStyle != .legacy else { return }
        hiding?.cancel()
        showMap = true
        hiding = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            self?.showMap = false
        }
    }
}
