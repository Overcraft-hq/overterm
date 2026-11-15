import AppKit
import SwiftUI

/// Suspend Tab: every process of a tab's panes stopped (SIGSTOP) — no
/// CPU, nothing lost — until Resume Tab continues them (SIGCONT) where they
/// were.
///
/// What a pane stops is its set (docs/design/activity/analysis.md, 6.5,
/// `ActivityPaneSet`): its `login`'s descendants and what left its terminal
/// carrying its tag — never a tmux server and its sessions' shells, an
/// ssh-agent, a colima daemon, an app started with `code .`, a nohup'd job,
/// anything on another terminal, which a tag reaches too (2.4, item 14).
/// Of the set, only what runs as the user alone, and no zombie.
///
/// The shell is stopped with what it runs, and first: a shell that saw its
/// job stop would take the terminal back for its prompt, and the job,
/// continued, would be in the background. Continued in the opposite order,
/// children before their shell, the shell never sees a thing.
///
/// Every send goes through `ProcessSignals` (6.10, the one signal path): by
/// the identity each process was listed with, so a Resume hours later
/// continues only what is still that process — never a pid someone else
/// holds now, perhaps a job they stopped with ⌃Z elsewhere.
enum TabSuspension {
    /// What a press stops in one pane, read at the press, as the scan this
    /// lookup replaced read it (7.8): a lookup in the app's census that
    /// always ticks. The window's readers' lookups answer from a snapshot up
    /// to a tick old, and a tab suspended from one would keep running what
    /// started since — the command just typed, an agent's new shell, a
    /// server's new worker — while its shell sat stopped under the cover.
    /// Blocking: off the main thread.
    static func targets(login: pid_t?, tag: String, checkouts: [String], census: ActivitySampler = .app) -> [ActivitySignalTarget] {
        guard let (slice, snapshot) = ProcessInspector(census: census, freshness: 0).slice(root: login, tag: tag) else { return [] }
        let terminal = census.appContext.panes.first { $0.tag == tag }?.terminal
        return targets(of: slice, in: snapshot, terminal: terminal, checkouts: checkouts)
    }

    /// The pane's set itself, read now as `targets` reads it: what it
    /// leaves out and why (`ActivityPaneSet.leftOut`). Blocking.
    static func paneSet(login: pid_t?, tag: String, checkouts: [String], census: ActivitySampler = .app) -> ActivityPaneSet? {
        guard let (slice, snapshot) = ProcessInspector(census: census, freshness: 0).slice(root: login, tag: tag) else { return nil }
        let terminal = census.appContext.panes.first { $0.tag == tag }?.terminal
        return ActivityPaneSet(slice, in: snapshot, terminal: terminal, checkouts: checkouts)
    }

    /// Of `slice`'s set (`ActivityPaneSet`), what runs as the user alone
    /// and hasn't ended, parents first — the order to stop in — each with
    /// the executable the census read. Pure.
    static func targets(of slice: ActivityPaneSlice, in snapshot: ActivitySnapshot, terminal: dev_t? = nil, checkouts: [String] = [])
        -> [ActivitySignalTarget]
    {
        let set = ActivityPaneSet(slice, in: snapshot, terminal: terminal, checkouts: checkouts)
        return ProcessInspector.running(set.members, in: snapshot).map { ActivitySignalTarget($0, path: snapshot.facts[$0]?.path) }
    }

    /// Stops `targets` in order; the ones that stopped.
    static func stop(_ targets: [ActivitySignalTarget], signals: ProcessSignals = ProcessSignals()) -> [ActivitySignalTarget] {
        targets.filter { target in
            if case .sent = signals.send(.stop, to: target, alone: false) { return true }
            return false
        }
    }

    /// Continues what `stop` stopped, children first: each only while it
    /// is still the process it stopped.
    static func resume(_ targets: [ActivitySignalTarget], signals: ProcessSignals = ProcessSignals()) {
        for target in targets.reversed() { _ = signals.send(.cont, to: target, alone: false) }
    }
}

extension Tab {
    /// Any of its panes suspended — a pane moved out takes its state along.
    var isSuspended: Bool { terminals.contains { $0.isSuspended } }
}

extension TerminalView {
    var isSuspended: Bool { suspended != nil }

    /// Stops `targets` (this pane's set, parents first) and covers the pane.
    func suspend(_ targets: [ActivitySignalTarget]) {
        guard !isSuspended, surface != nil else { return }
        suspended = TabSuspension.stop(targets)
        let cover = SuspendedCover(frame: bounds)
        cover.autoresizingMask = [.width, .height]
        addSubview(cover)
    }

    func resume() {
        guard let targets = suspended else { return }
        suspended = nil
        TabSuspension.resume(targets)
        subviews.filter { $0 is SuspendedCover }.forEach { $0.removeFromSuperview() }
    }
}

/// Over a suspended pane: what it is, and the way back. Clicks stop here —
/// the terminal under it isn't listening.
final class SuspendedCover: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = GhosttyRuntime.shared.backgroundColor.withAlphaComponent(0.78).cgColor
        let label = NSTextField(labelWithString: "Suspended")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = GhosttyRuntime.shared.foregroundColor
        let detail = NSTextField(labelWithString: "Its processes are stopped where they were.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = GhosttyRuntime.shared.foregroundColor.withAlphaComponent(0.6)
        let button = NSButton(title: "Resume", target: nil, action: #selector(TerminalWindowController.resumeTabOfPane(_:)))
        // No Return for it: key equivalents go to the whole window, and the
        // editor's Return would resume the tab.
        button.bezelStyle = .rounded
        let stack = NSStackView(views: [label, detail, button])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

extension TerminalWindowController {
    /// Stops each of the tab's panes' sets, read at the press
    /// (`TabSuspension.targets`). A pane not paired yet is paired first,
    /// from a list of the app's children read off the main thread
    /// (`pairWaiting`); the lookup runs off it too; a Resume in between
    /// wins.
    func suspendTab(_ tab: Tab) {
        let panes = tab.terminals.filter { !$0.isSuspended }
        guard !panes.isEmpty else { return }
        // A `.app` inside one of these stays the pane's: a dev build.
        let checkouts = Array(Set(store.tabs.compactMap { $0.checkoutSource?.root.path }))
        Task { @MainActor in
            await SurfaceProcesses.shared.pairWaiting()
            let roots = panes.map { (SurfaceProcesses.shared.pairedLoginPID(of: $0), $0.processTag) }
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                let sets = roots.map { TabSuspension.targets(login: $0.0, tag: $0.1, checkouts: checkouts) }
                Task { @MainActor in
                    tab.objectWillChange.send()
                    self.store.objectWillChange.send()
                    for (pane, targets) in zip(panes, sets) { pane.suspend(targets) }
                }
            }
        }
    }

    func resumeTab(_ tab: Tab) {
        tab.objectWillChange.send()
        store.objectWillChange.send()
        tab.terminals.forEach { $0.resume() }
        if store.selected === tab { tab.terminal.window?.makeFirstResponder(tab.terminal) }
    }

    /// The cover's Resume: the tab of the pane it covers.
    @objc func resumeTabOfPane(_ sender: NSView) {
        var view: NSView? = sender
        while let current = view, !(current is TerminalView) { view = current.superview }
        guard let tab = tab(containing: view as? TerminalView) else { return }
        resumeTab(tab)
    }
}

/// "2 suspended" in the strip, beside "need you": a stopped tab is easy to
/// forget, and one scrolled out of the strip or in a collapsed island
/// says nothing at all. The list behind it resumes one, or all.
struct SuspendedChip: View {
    @ObservedObject var store: TabStore
    @ObservedObject var theme: ChromeTheme
    let select: (Tab) -> Void
    let resume: (Tab) -> Void
    let resumeAll: () -> Void
    @State private var showing = false

    private var suspended: [Tab] { store.tabs.filter(\.isSuspended) }

    var body: some View {
        let tabs = suspended
        if !tabs.isEmpty {
            Button {
                showing.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "pause.circle.fill").font(.system(size: ChromeMetrics.text(11)))
                    Text(verbatim: "\(tabs.count) suspended").font(.system(size: ChromeMetrics.text(12), weight: .semibold))
                }
                .foregroundStyle(theme.text2)
                .padding(.horizontal, 10)
                .frame(height: ChromeMetrics.row(28))
                .background(Capsule().fill(theme.selected))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Suspended tabs — their processes stopped until resumed")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Suspended").font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(theme.text2)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                    ForEach(tabs) { tab in
                        HStack(spacing: 8) {
                            Button {
                                showing = false
                                select(tab)
                            } label: {
                                Text(tab.title).font(.system(size: ChromeMetrics.text(13))).foregroundStyle(theme.text).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button("Resume") { resume(tab) }.controlSize(.small)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: ChromeMetrics.row(32))
                    }
                    Divider().padding(.horizontal, 10).padding(.vertical, 5)
                    HStack {
                        Spacer()
                        Button("Resume All") {
                            showing = false
                            resumeAll()
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 10).padding(.bottom, 6)
                }
                .padding(5)
                .frame(width: 300)
                .environment(\.colorScheme, theme.isDark ? .dark : .light)
            }
        }
    }
}
