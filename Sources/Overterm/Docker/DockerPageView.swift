import SwiftUI

/// The Docker page (⌥⌘P): over the body like Settings, in its turn. The
/// sections and the engine down the left, the list in the middle, the
/// selected container at the right. Single letters act while the list has
/// the keyboard (DockerKey; `?` lists them).
struct DockerPageView: View {
    @ObservedObject var page: DockerPageModel
    @ObservedObject var docker: DockerModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions

    enum Focus: Hashable { case list, filter }
    @FocusState private var focus: Focus?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210).background(theme.strip)
            Rectangle().fill(theme.border).frame(width: 1)
            main
        }
        .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .overlay { if page.cheatSheet { cheatSheet } }
        .sheet(isPresented: $page.cleaning) { DockerCleanUpSheet(page: page, docker: docker, theme: theme) }
        .onChange(of: page.focusList) { _ in focus = .list }
        .onChange(of: page.focusFilter) { _ in focus = .filter }
        .onAppear { focus = .list }
    }

    // MARK: The left

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(DockerPageModel.Section.allCases) { section in
                Button {
                    page.section = section
                } label: {
                    HStack(spacing: 8) {
                        // A column of their own: the glyphs differ in width.
                        Image(systemName: section.symbol).frame(width: 18)
                        Text(section.title)
                        Spacer()
                        if let count = count(section) {
                            Text(verbatim: "\(count)").foregroundStyle(theme.text3).font(.system(size: 11, design: .monospaced))
                        }
                    }
                    .foregroundStyle(page.section == section ? theme.text : theme.text2)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(page.section == section ? theme.selected : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            DockerDiskSummary(docker: docker, theme: theme).padding(.bottom, 8)
            Button {
                page.cleaning = true
            } label: {
                Label("Clean Up…", systemImage: "sparkles").font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text2)
            .disabled(!docker.connection.isRunning)
            .help("What nothing uses, listed before it goes (c)")
            .accessibilityIdentifier("docker.cleanUp")
            engine
        }
        .padding(12)
    }

    /// A section's count, once it has been read.
    private func count(_ section: DockerPageModel.Section) -> Int? {
        switch section {
        case .containers: docker.containers.count
        case .images: docker.images.isEmpty ? nil : docker.images.count
        case .volumes: docker.volumes.isEmpty ? nil : docker.volumes.count
        case .networks: docker.networks.isEmpty ? nil : docker.networks.count
        }
    }

    private var engineColor: Color {
        switch docker.connection {
        case .running: TabStatusStyle.done
        case .connecting: TabStatusStyle.waiting
        case .down: TabStatusStyle.failed
        case .off: theme.text3
        }
    }

    /// Which engine, whether it answers, and what can be done to it.
    private var engine: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                DockerStatusDot(color: engineColor)
                Text(verbatim: docker.runtime.name).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    ForEach([DockerRuntime.Action.start, .stop, .restart], id: \.self) { action in
                        if let command = docker.runtime.command(action, context: docker.endpoint?.context) {
                            Button("\(action.rawValue.capitalized) \(docker.runtime.name)") { actions.run(command, nil) }
                        }
                    }
                    Divider()
                    Button("Connect Again") { docker.reconnect() }
                    Button("Docker Settings…") { actions.settings() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 20, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityIdentifier("docker.engineMenu")
            }
            Text(verbatim: engineDetail).font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.rowHover.opacity(0.6)))
    }

    private var engineDetail: String {
        switch docker.connection {
        case .running(let api):
            return [docker.info?.ServerVersion.map { "Engine \($0)" }, "API \(api)", docker.endpoint?.context].compactMap { $0 }.joined(separator: " · ")
        case .connecting: return "Connecting…"
        case .down: return docker.runtimeStatus == .starting ? "Starting…" : "Not answering"
        case .off: return "Off"
        }
    }

    // MARK: The middle

    private var main: some View {
        VStack(spacing: 0) {
            header
            if let error = page.error { banner(error) }
            if let cleaned = page.cleaned { note(cleaned) }
            Rectangle().fill(theme.border).frame(height: 1)
            switch docker.connection {
            case .running where page.section == .images: DockerImagesView(page: page, docker: docker, theme: theme, actions: actions)
            case .running where page.section == .volumes: DockerVolumesView(page: page, docker: docker, theme: theme, actions: actions)
            case .running where page.section == .networks: DockerNetworksView(page: page, docker: docker, theme: theme, actions: actions)
            case .running:
                if docker.containers.isEmpty {
                    empty("No containers", "Run one — `docker run`, or `docker compose up` in a checkout — and it shows here.")
                } else {
                    // The list keeps its place whether or not the detail is
                    // beside it: moved into another container, SwiftUI made
                    // it again, and its table took the keyboard and the
                    // scroll position with it on the first click.
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            list
                            if page.showDetail, let container = page.detailed {
                                Rectangle().fill(theme.border).frame(width: 1)
                                ContainerDetailView(
                                    container: container, session: page.session(for: container.Id), tab: $page.detailTab,
                                    theme: theme, actions: actions,
                                    act: { page.act($0, on: [container]) }, remove: { page.confirmRemove([container]) }
                                )
                                .id(container.Id)
                                .frame(width: min(480, max(320, geometry.size.width * 0.42)))
                            }
                        }
                    }
                }
            case .connecting:
                VStack { ProgressView().controlSize(.small) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .down(let reason):
                down(reason)
            case .off:
                empty(
                    "Docker isn't connected", AppEnvironment.isIsolated ? "This run reaches no Docker." : "Settings ▸ Docker has it off, or no engine set.")
            }
        }
    }

    private var running: Int { docker.containers.filter { $0.state == .running }.count }

    private var header: some View {
        HStack(spacing: 10) {
            Text(page.section.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(theme.text)
            if docker.connection.isRunning, page.section == .containers {
                Text(verbatim: "\(running) running · \(docker.containers.count)").font(.system(size: 12)).foregroundStyle(theme.text3)
            }
            Spacer(minLength: 12)
            if page.section == .containers {
                Toggle("Running only", isOn: $page.runningOnly).toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(theme.text2)
            }
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(theme.text3)
                TextField("Filter  /", text: $page.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focus, equals: .filter)
                    .onSubmit { focus = .list }
                    .onExitCommand {
                        page.filter = ""
                        focus = .list
                    }
                    .accessibilityIdentifier("docker.filter")
            }
            .padding(.horizontal, 8)
            .frame(width: 240, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover.opacity(0.7)))
            Button {
                page.cheatSheet.toggle()
            } label: {
                Image(systemName: "keyboard").font(.system(size: 12)).foregroundStyle(theme.text2)
            }
            .buttonStyle(.plain)
            .help("Keys (?)")
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    /// What went well, said once.
    private func note(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(TabStatusStyle.done)
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(theme.text)
            Spacer()
            Button("Dismiss") { page.cleaned = nil }.buttonStyle(.plain).foregroundStyle(theme.accentText).font(.system(size: 12))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(TabStatusStyle.done.opacity(0.1))
        .accessibilityIdentifier("docker.cleaned")
    }

    private func banner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TabStatusStyle.failed)
            Text(verbatim: error).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(3).textSelection(.enabled)
            Spacer()
            Button("Dismiss") { page.error = nil }.buttonStyle(.plain).foregroundStyle(theme.accentText).font(.system(size: 12))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(TabStatusStyle.failed.opacity(0.1))
        .accessibilityIdentifier("docker.error")
    }

    private var list: some View {
        let groups = page.groups
        return List(selection: $page.selection) {
            ForEach(groups) { group in
                DockerProjectRow(
                    group: group, folded: page.collapsed.contains(group.id), busy: false, theme: theme,
                    fold: { page.toggleFold(group.id) }, act: { verb in if let project = group.project { page.compose(verb, project) } }
                )
                .tag(group.id)
                .listRowSeparator(.hidden)
                .contextMenu { projectMenu(group) }
                if !page.collapsed.contains(group.id) {
                    ForEach(group.containers) { container in
                        DockerContainerRow(
                            container: container, inProject: group.project != nil, busy: page.busy.contains(container.Id), theme: theme,
                            open: actions.open
                        )
                        .tag(container.Id)
                        .listRowSeparator(.hidden)
                        .contextMenu { containerMenu(container) }
                    }
                }
            }
            if groups.isEmpty {
                Text("Nothing matches “\(page.filter)”.").font(.system(size: 12)).foregroundStyle(theme.text3).padding(.vertical, 8)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .focused($focus, equals: .list)
        .onCopyCommand { page.selectedContainers.map { NSItemProvider(object: $0.name as NSString) } }
        .accessibilityIdentifier("docker.list")
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox").font(.system(size: 34, weight: .light)).foregroundStyle(theme.text3)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
            Text(.init(detail)).font(.system(size: 12)).foregroundStyle(theme.text2).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func down(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.system(size: 34, weight: .light)).foregroundStyle(theme.text3)
            Text(docker.runtimeStatus == .starting ? "\(docker.runtime.name) is starting…" : "\(docker.runtime.name) isn't running")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
            Text(verbatim: reason).font(.system(size: 12)).foregroundStyle(theme.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack(spacing: 10) {
                if let start = docker.runtime.command(.start, context: docker.endpoint?.context) {
                    Button("Start \(docker.runtime.name)") {
                        actions.run(start, nil)
                        docker.reconnect()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button("Try Again") { docker.reconnect() }
            }
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("docker.down")
    }

    // MARK: Menus

    @ViewBuilder private func containerMenu(_ container: ContainerSummary) -> some View {
        let targets = page.selection.contains(container.Id) ? page.selectedContainers : [container]
        Button(container.state.isUp ? "Stop" : "Start") { page.act(container.state.isUp ? .stop : .start, on: targets) }
        Button("Restart") { page.act(.restart, on: targets) }
        if container.state == .running || container.state == .paused {
            Button(container.state == .paused ? "Unpause" : "Pause") { page.act(container.state == .paused ? .unpause : .pause, on: targets) }
        }
        Divider()
        Button("Open a Shell in a Tab") { actions.run(DockerCommands.shell(in: container, endpoint: docker.endpoint), nil) }
            .disabled(container.state != .running)
        Button("Follow Logs in a Tab") { actions.run(DockerCommands.followLogs(of: container, endpoint: docker.endpoint), nil) }
        if let port = PublishedPort.of(container.Ports ?? []).first, let url = port.url {
            Button("Open \(url.absoluteString)") { actions.open(url) }
        }
        if DockerDatabaseGuess.kind(of: container.Image) != nil {
            Button("Open in Database…") { page.openInDatabase(container) }
        }
        Divider()
        Button("Copy Name") { actions.copy(container.name) }
        Button("Copy ID") { actions.copy(container.Id) }
        Divider()
        Button(targets.count > 1 ? "Remove \(targets.count) Containers…" : "Remove…") { page.confirmRemove(targets) }
    }

    @ViewBuilder private func projectMenu(_ group: DockerListGroup) -> some View {
        if let project = group.project {
            Button("Up (in a Tab)") { page.compose("up", project) }
            Button("Start") { page.compose("start", project) }
            Button("Stop") { page.compose("stop", project) }
            Button("Restart") { page.compose("restart", project) }
            Divider()
            Button("Follow Logs in a Tab") { page.compose("logs", project) }
            Button("Pull Images in a Tab") { page.compose("pull", project) }
            if let dir = project.workingDir { Button("Copy Folder") { actions.copy(dir) } }
            Divider()
            Button("Down…") { page.compose("down", project) }
        }
    }

    private var cheatSheet: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keys in the list").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text).padding(.bottom, 4)
            ForEach(DockerKey.allCases, id: \.self) { key in
                HStack(spacing: 12) {
                    Text(verbatim: key.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text)
                        .frame(width: 48, alignment: .leading)
                    Text(key.title).font(.system(size: 12)).foregroundStyle(theme.text2)
                }
            }
            Text("↑↓ to move, ⇧ and ⌘ to pick several, ⌘C copies their names.").font(.system(size: 11)).foregroundStyle(theme.text3)
                .padding(.top, 6)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.menu).shadow(radius: 20))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.menuEdge))
        .onTapGesture { page.cheatSheet = false }
        .accessibilityIdentifier("docker.keys")
    }
}
