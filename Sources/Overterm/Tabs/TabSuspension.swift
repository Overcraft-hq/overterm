import AppKit
import SwiftUI

/// Suspend Tab: every process in a tab's panes stopped (SIGSTOP) — no CPU,
/// nothing lost — until Resume Tab continues them (SIGCONT) where they were.
///
/// The shell is stopped with what it runs, and first: a shell that saw its
/// job stop would take the terminal back for its prompt, and the job,
/// continued, would be in the background. Continued in the opposite order,
/// children before their shell, the shell never sees a thing.
enum TabSuspension {
    /// Parents before their children — the order to stop in.
    static func order(_ roots: [ProcessNode]) -> [pid_t] { roots.flatMap(\.flattened).map(\.pid) }

    /// Stops `pids` in order; the ones that stopped.
    static func stop(_ pids: [pid_t]) -> [pid_t] { pids.filter { kill($0, SIGSTOP) == 0 } }

    /// Continues what `stop` stopped, children first.
    static func resume(_ pids: [pid_t]) {
        for pid in pids.reversed() { kill(pid, SIGCONT) }
    }
}

extension Tab {
    /// Any of its panes suspended — a pane moved out takes its state along.
    var isSuspended: Bool { terminals.contains { $0.isSuspended } }
}

extension TerminalView {
    var isSuspended: Bool { suspendedPIDs != nil }

    /// Stops `pids` (this pane's, parents first) and covers the pane.
    func suspend(_ pids: [pid_t]) {
        guard !isSuspended, surface != nil else { return }
        suspendedPIDs = TabSuspension.stop(pids)
        let cover = SuspendedCover(frame: bounds)
        cover.autoresizingMask = [.width, .height]
        addSubview(cover)
    }

    func resume() {
        guard let pids = suspendedPIDs else { return }
        suspendedPIDs = nil
        TabSuspension.resume(pids)
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
    /// Stops every process in the tab's panes. The process scan runs off
    /// the main thread; a Resume in between wins.
    func suspendTab(_ tab: Tab) {
        let panes = tab.terminals.filter { !$0.isSuspended }
        guard !panes.isEmpty else { return }
        let roots = panes.map { (SurfaceProcesses.shared.loginPID(of: $0), $0.processTag) }
        let inspector = processInspector
        DispatchQueue.global(qos: .userInitiated).async {
            let orders = roots.map { TabSuspension.order(inspector.tree(root: $0.0, tag: $0.1)) }
            Task { @MainActor in
                tab.objectWillChange.send()
                self.store.objectWillChange.send()
                for (pane, pids) in zip(panes, orders) { pane.suspend(pids) }
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
                    Image(systemName: "pause.circle.fill").font(.system(size: 11))
                    Text(verbatim: "\(tabs.count) suspended").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(theme.text2)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(theme.selected))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Suspended tabs — their processes stopped until resumed")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Suspended").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text2)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                    ForEach(tabs) { tab in
                        HStack(spacing: 8) {
                            Button {
                                showing = false
                                select(tab)
                            } label: {
                                Text(tab.title).font(.system(size: 13)).foregroundStyle(theme.text).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button("Resume") { resume(tab) }.controlSize(.small)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
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
