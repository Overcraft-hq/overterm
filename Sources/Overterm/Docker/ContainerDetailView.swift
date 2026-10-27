import SwiftUI

/// A container, at the side of the list: what it is, how it ended, how to
/// reach it, what it was given — and its logs, its inspect data, its use.
/// The same on the page and in the right-hand pane.
struct ContainerDetailView: View {
    let container: ContainerSummary
    @ObservedObject var session: ContainerSession
    @Binding var tab: ContainerTab
    /// Whether it is on screen: a hidden page reads no logs and no stats.
    let visible: Bool
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions
    /// What the page does for the header's buttons.
    let act: (DockerEngine.ContainerAction) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs
            Rectangle().fill(theme.border).frame(height: 1)
            switch tab {
            case .overview:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let message = session.detail?.State.Error, !message.isEmpty { problem(message) }
                        if let error = session.error { problem(error) }
                        overview
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .logs: DockerLogsPane(container: container, session: session, theme: theme, actions: actions)
            case .inspect: DockerInspectPane(session: session, theme: theme, actions: actions)
            case .stats: DockerStatsPane(container: container, session: session, theme: theme)
            }
        }
        .accessibilityIdentifier("docker.detail")
        .onAppear { follow() }
        .onChange(of: tab) { _ in follow() }
        .onChange(of: visible) { _ in follow() }
        .onDisappear {
            session.hideLogs()
            session.hideStats()
        }
    }

    /// Logs and stats are read only while their tab shows.
    private func follow() {
        if visible && tab == .logs { session.showLogs() } else { session.hideLogs() }
        if visible && tab == .stats { session.showStats() } else { session.hideStats() }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(ContainerTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? theme.text : theme.text2)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(tab == item ? theme.selected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("docker.tab.\(item.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                DockerStatusDot(color: DockerStatusStyle.color(container, idle: theme.text3))
                Text(verbatim: container.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                headerButton(container.state.isUp ? "stop.fill" : "play.fill", container.state.isUp ? "Stop (s)" : "Start (s)") {
                    act(container.state.isUp ? .stop : .start)
                }
                headerButton("arrow.clockwise", "Restart (r)") { act(.restart) }
                headerButton("terminal", "A shell in it (e)") { actions.run(DockerCommands.shell(in: container, endpoint: DockerModel.shared.endpoint), nil) }
                    .disabled(container.state != .running)
                headerButton("trash", "Remove (⌫)", remove)
            }
            Text(verbatim: subtitle).font(.system(size: 11.5)).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let project = container.composeProject { parts.append([project, container.composeService].compactMap { $0 }.joined(separator: " · ")) }
        parts.append(container.Image)
        parts.append(container.Status)
        return parts.joined(separator: "  —  ")
    }

    private func headerButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text2)
        .help(help)
    }

    private func problem(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TabStatusStyle.failed)
            Text(verbatim: message).font(.system(size: 12)).foregroundStyle(theme.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(TabStatusStyle.failed.opacity(0.12)))
    }

    // MARK: Overview

    @ViewBuilder private var overview: some View {
        let ports = PublishedPort.of(container.Ports ?? [])
        if !ports.isEmpty {
            block("Ports") {
                ForEach(ports, id: \.self) { port in
                    HStack(spacing: 8) {
                        DockerPortPill(port: port, theme: theme, open: actions.open)
                        if let url = port.url { Text(verbatim: url.absoluteString).font(.system(size: 11.5)).foregroundStyle(theme.text3) }
                    }
                }
            }
        }
        if let detail = session.detail {
            block("Container") {
                row("ID", String(detail.Id.prefix(12)), copy: detail.Id)
                row("Command", ((detail.Config.Entrypoint ?? []) + (detail.Config.Cmd ?? [])).joined(separator: " "))
                if let dir = detail.Config.WorkingDir, !dir.isEmpty { row("Working dir", dir) }
                if let user = detail.Config.User, !user.isEmpty { row("User", user) }
                if let policy = detail.HostConfig?.RestartPolicy?.Name, !policy.isEmpty, policy != "no" { row("Restart", policy) }
                if let started = detail.State.StartedAt, container.state.isUp { row("Started", Self.date(started)) }
                if let finished = detail.State.FinishedAt, !container.state.isUp, !finished.hasPrefix("0001") {
                    row("Finished", Self.date(finished) + (detail.State.ExitCode.map { " — exit \($0)" } ?? ""))
                }
                if detail.State.OOMKilled == true { row("Memory", "killed: out of memory") }
            }
            if let probes = detail.State.Health?.Log, let last = probes.last {
                block("Health") {
                    row("Status", detail.State.Health?.Status ?? "")
                    if let output = last.Output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty { row("Last check", output) }
                }
            }
            if let mounts = detail.Mounts, !mounts.isEmpty {
                block("Mounts") {
                    ForEach(Array(mounts.enumerated()), id: \.offset) { _, mount in
                        row(mount.Destination, [mount.Name ?? mount.Source ?? "", mount.RW == false ? "read-only" : nil].compactMap { $0 }.joined(separator: " — "))
                    }
                }
            }
            if let networks = detail.NetworkSettings?.Networks, !networks.isEmpty {
                block("Networks") {
                    ForEach(networks.keys.sorted(), id: \.self) { name in row(name, networks[name]?.IPAddress ?? "") }
                }
            }
            let env = detail.env
            if !env.isEmpty {
                block("Environment") {
                    ForEach(Array(env.enumerated()), id: \.offset) { _, entry in
                        row(entry.key, DockerSecrets.masked(entry.key, entry.value), copy: DockerSecrets.isSecret(entry.key) ? nil : entry.value)
                    }
                }
            }
        } else if session.error == nil {
            ProgressView().controlSize(.small)
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            content()
        }
    }

    private func row(_ key: String, _ value: String, copy: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: key).font(.system(size: 11.5)).foregroundStyle(theme.text2).frame(width: 120, alignment: .leading).lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: value).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.text).textSelection(.enabled)
                .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextMenu {
            if let copy { Button("Copy") { actions.copy(copy) } }
        }
    }

    /// `2026-10-27T10:00:00.123456789Z` → a date as the Mac writes one.
    static func date(_ text: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let trimmed = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        guard let date = formatter.date(from: trimmed) ?? ISO8601DateFormatter().date(from: text) else { return text }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
