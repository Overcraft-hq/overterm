import SwiftUI

/// The Docker page (⌥⌘P): over the body like Settings, in its turn. The
/// sections and the engine down the left, the list in the middle, the
/// selected container at the right. Single letters act while the list has
/// the keyboard (DockerKey; `?` lists them).
struct DockerPageView: View {
    @ObservedObject var page: DockerPageModel
    @ObservedObject var docker: DockerModel
    /// The window's checkout's compose project before it runs (the page's
    /// `planned`), observed so the list follows it.
    @ObservedObject var checkoutCompose: ComposeFileModel
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
        // Hidden, its views live on: what they read waits for this.
        .environment(\.dockerShown, page.visible)
        .overlay { if page.cheatSheet { cheatSheet } }
        .sheet(isPresented: $page.cleaning) { DockerCleanUpSheet(page: page, docker: docker, theme: theme) }
        .sheet(isPresented: Binding(get: { page.runSpec != nil }, set: { if !$0 { page.runSpec = nil } })) {
            if let spec = page.runSpec { DockerRunSheet(spec: spec, page: page, docker: docker, actions: actions) }
        }
        .sheet(isPresented: Binding(get: { page.profileChoice != nil }, set: { if !$0 { page.profileChoice = nil } })) {
            ComposeProfilesSheet(page: page, endpoint: docker.endpoint)
        }
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
            if let clients = page.mcpClients, !clients.isEmpty { mcpToolkit(clients).padding(.bottom, 10) }
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
        case .builds: page.builds.isEmpty ? nil : page.builds.count
        case .models: page.models.map(\.models.count)
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

    /// Overterm's agents and Docker's MCP Toolkit: which reach its servers.
    private func mcpToolkit(_ clients: [MCPToolkitClient]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MCP Toolkit").font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            ForEach(clients) { client in
                HStack(spacing: 6) {
                    DockerStatusDot(color: client.connected ? TabStatusStyle.done : theme.text3)
                    Text(verbatim: client.name).font(.system(size: 11.5)).foregroundStyle(client.installed ? theme.text2 : theme.text3).lineLimit(1)
                    Spacer(minLength: 4)
                    Button(client.connected ? "Disconnect" : "Connect") { page.toggleMCP(client) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                        .help(DockerMCPToolkit.command(client, connect: !client.connected) + " — in a terminal tab; it changes \(client.name)'s config")
                }
            }
        }
        .padding(.horizontal, 10)
        .accessibilityIdentifier("docker.mcpToolkit")
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
                    let extras = docker.runtime.extras(context: docker.endpoint?.context)
                    if !extras.isEmpty {
                        Divider()
                        ForEach(extras, id: \.title) { extra in Button(extra.title) { actions.run(extra.command, nil) } }
                    }
                    Divider()
                    if case .ssh(let target) = docker.endpoint?.address {
                        ForEach(target.commands, id: \.title) { command in Button(command.title) { actions.run(command.command, nil) } }
                    } else {
                        Button("Edit Engine Settings…") { page.editEngineConfig() }
                            .help("\(docker.runtime.configFile(context: docker.endpoint?.context)?.path ?? "") — applied when it restarts")
                    }
                    Divider()
                    contexts
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

    /// The CLI's contexts: one picked is Overterm's alone (`docker.context`).
    @ViewBuilder private var contexts: some View {
        let chosen = Settings.shared.dockerContext
        Button {
            Settings.shared.set("docker.context", nil)
        } label: {
            Text(chosen.isEmpty ? "✓ The CLI's Current Context" : "The CLI's Current Context")
        }
        ForEach(DockerEndpoint.contexts().map(\.name), id: \.self) { name in
            Button {
                Settings.shared.set("docker.context", .string(name))
            } label: {
                Text(chosen == name ? "✓ \(name)" : name)
            }
        }
    }

    private var engineDetail: String {
        switch docker.connection {
        case .running(let api):
            return [
                docker.info?.ServerVersion.map { "Engine \($0)" }, "API \(api)", docker.enginePlatform?.short, docker.endpoint?.context,
                docker.publishedHost.map { "on \($0)" },
            ]
            .compactMap { $0 }.joined(separator: " · ")
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
            if let transferring = page.transferring {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: transferring + "…").font(.system(size: 12)).foregroundStyle(theme.text2)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 6)
            }
            Rectangle().fill(theme.border).frame(height: 1)
            switch docker.connection {
            case .running where page.section == .images: DockerImagesView(page: page, docker: docker, theme: theme, actions: actions)
            case .running where page.section == .volumes: DockerVolumesView(page: page, docker: docker, theme: theme, actions: actions)
            case .running where page.section == .networks: DockerNetworksView(page: page, docker: docker, theme: theme, actions: actions)
            case .running where page.section == .builds: DockerBuildsView(page: page, theme: theme, actions: actions)
            case .running where page.section == .models: DockerModelsView(page: page, theme: theme, actions: actions)
            case .running:
                if page.isEmpty {
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
                                    docker: docker, theme: theme, actions: actions, verbs: { page.verbs(for: container) }
                                )
                                .id(container.Id)
                                .frame(width: min(480, max(320, geometry.size.width * 0.42)))
                            } else if page.showDetail, let project = page.detailedProject {
                                Rectangle().fill(theme.border).frame(width: 1)
                                ProjectDetailView(
                                    project: project, session: page.projectSession(for: project.name), page: page, ports: page.ports, theme: theme,
                                    actions: actions, planError: project.planned ? checkoutCompose.error : nil
                                )
                                .id(project.name)
                                .frame(width: min(520, max(340, geometry.size.width * 0.45)))
                            } else if page.showDetail, let session = page.detailedSession {
                                Rectangle().fill(theme.border).frame(width: 1)
                                TestcontainersSessionView(session: session, page: page, theme: theme, actions: actions)
                                    .id(DockerPageModel.sessionTag(session.id))
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
            // The columns' names in the list's own header: the rows' insets.
            Section {
                ForEach(groups) { group in
                    DockerProjectRow(
                        group: group, folded: page.collapsed.contains(group.id), busy: page.busy.contains(group.id), theme: theme,
                        fold: { page.toggleFold(group.id) }, act: { verb in if let project = group.project { page.compose(verb, project) } },
                        usage: page.usage(of: group), columns: true
                    )
                    .tag(group.id)
                    .listRowSeparator(.hidden)
                    .contextMenu { projectMenu(group) }
                    if !page.collapsed.contains(group.id) {
                        ForEach(group.containers) { container in
                            DockerContainerRow(
                                container: container, inProject: group.project != nil || group.session != nil, busy: page.busy.contains(container.Id),
                                docker: docker,
                                theme: theme, open: actions.open, remoteHost: docker.publishedHost, usage: page.usage(of: container), columns: true
                            )
                            .tag(container.Id)
                            .listRowSeparator(.hidden)
                            .contextMenu { containerMenu(container) }
                        }
                        // A project before it runs: its services, none created.
                        ForEach(group.services) { service in
                            DockerPlannedServiceRow(service: service, theme: theme, folder: group.project?.workingDir, columns: true)
                                .tag(DockerPageModel.serviceTag(service))
                                .listRowSeparator(.hidden)
                                .contextMenu { projectMenu(group) }
                        }
                    }
                }
                if groups.isEmpty {
                    Text("Nothing matches “\(page.filter)”.").font(.system(size: 12)).foregroundStyle(theme.text3).padding(.vertical, 8)
                }
            } header: {
                DockerListColumns(sort: $page.sort, theme: theme)
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
        DockerVerbMenu(verbs: page.verbs(for: container, targets: page.selection.contains(container.Id) ? page.selectedContainers : nil))
    }

    @ViewBuilder private func projectMenu(_ group: DockerListGroup) -> some View {
        if let project = group.project {
            DockerVerbMenu(verbs: page.verbs(for: project))
        } else if let session = group.session {
            DockerVerbMenu(verbs: page.verbs(for: session))
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
