import SwiftUI

/// The Kubernetes page (⌥⌘J): over the body like Docker's, in its turn.
/// The contexts, the namespace and the sections down the left, the Pods
/// list in the middle as the server formats it, how the context's proxy
/// stands along the bottom. On a production context a red band runs across
/// the top of everything on the page. Single letters act while the list has
/// the keyboard (`KubernetesKey`; `?` lists them). It reads only: no verb
/// here changes a cluster.
struct KubernetesPageView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var model: KubernetesModel
    @ObservedObject var theme: ChromeTheme

    enum Focus: Hashable { case list, filter, namespace }
    @FocusState private var focus: Focus?
    @State private var typedNamespace = ""

    /// Production's colour: the band, the context's dot, its card's edge.
    static let production = Color(red: 0.86, green: 0.17, blue: 0.17)

    var body: some View {
        VStack(spacing: 0) {
            if let band = page.band, model.enabled {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                    Text(verbatim: band).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(Self.production)
                .accessibilityIdentifier("kubernetes.productionBand")
            }
            HStack(spacing: 0) {
                sidebar.frame(width: 230).background(theme.strip)
                Rectangle().fill(theme.border).frame(width: 1)
                main
            }
        }
        .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .overlay { if page.cheatSheet { ResourceKeySheet<KubernetesKey>(theme: theme, identifier: "kubernetes.keys") { page.cheatSheet = false } } }
        .onChange(of: page.focusList) { _ in focus = .list }
        .onChange(of: page.focusFilter) { _ in focus = .filter }
        .onAppear { focus = .list }
    }

    // MARK: The left

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.enabled, !model.contexts.contexts.isEmpty {
                caption("Contexts")
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(model.contexts.contexts) { context in contextRow(context) }
                    }
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                caption("Namespace").padding(.top, 10)
                namespacePicker
                caption("Workloads").padding(.top, 10)
                ForEach(KubernetesPageModel.Section.allCases) { section in
                    Button {
                        page.section = section
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: section.symbol).frame(width: 18)
                            Text(section.title)
                            Spacer()
                            if model.podState == .live {
                                Text(verbatim: "\(model.pods.count)").foregroundStyle(theme.text3).font(.system(size: 11, design: .monospaced))
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
            }
            Spacer(minLength: 8)
            if model.enabled, let context = model.selected { contextCard(context) }
        }
        .padding(12)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3).padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    private func classColor(_ context: KubeContext) -> Color {
        switch context.contextClass {
        case .production: Self.production
        case .remote: TabStatusStyle.waiting
        case .local: TabStatusStyle.done
        }
    }

    private func contextRow(_ context: KubeContext) -> some View {
        let picked = model.selectedName == context.name
        return Button {
            model.select(context.name)
            page.giveListTheKeyboard()
        } label: {
            HStack(spacing: 8) {
                DockerStatusDot(color: classColor(context))
                Text(verbatim: context.displayName).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if context.name == model.contexts.current {
                    Text("current").font(.system(size: 10)).foregroundStyle(theme.text3)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(picked ? theme.text : theme.text2)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(picked ? theme.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(context.name) — \(context.contextClass.title)\(context.isWritable ? "" : ", read-only")")
        .accessibilityIdentifier("kubernetes.context.\(context.name)")
    }

    @ViewBuilder private var namespacePicker: some View {
        Menu {
            Button("All Namespaces (0)") { model.setScope(.all) }
            if !model.namespaces.isEmpty { Divider() }
            let favourites = model.selected?.settings.favouriteNamespaces ?? []
            ForEach(favourites + model.namespaces.filter { !favourites.contains($0) }, id: \.self) { name in
                Button(name) { model.setScope(.namespace(name)) }
            }
            Divider()
            Button("Other Namespace…") {
                typedNamespace = ""
                page.typingNamespace = true
                focus = .namespace
            }
        } label: {
            Text(verbatim: page.scopeLabel).font(.system(size: 12)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .accessibilityIdentifier("kubernetes.namespace")
        if page.typingNamespace {
            TextField("a namespace", text: $typedNamespace)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($focus, equals: .namespace)
                .onSubmit {
                    let name = typedNamespace.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { model.setScope(.namespace(name)) }
                    page.typingNamespace = false
                    focus = .list
                }
                .onExitCommand {
                    page.typingNamespace = false
                    focus = .list
                }
                .padding(.horizontal, 8)
        }
        if let refused = model.namespacesRefused {
            Text(verbatim: refused).font(.system(size: 10.5)).foregroundStyle(theme.text3).padding(.horizontal, 10)
        }
    }

    /// The context: its class, how it signs in, its server, whether it can be written to.
    private func contextCard(_ context: KubeContext) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                DockerStatusDot(color: classColor(context))
                Text(verbatim: page.classLabel ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text)
            }
            Text(verbatim: context.name).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.text2).lineLimit(2)
                .truncationMode(.middle).textSelection(.enabled)
            Text(verbatim: [context.auth.map { "\($0)" }, context.server].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(2).truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.rowHover.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(context.isProduction ? Self.production : .clear, lineWidth: 1.5))
        .accessibilityIdentifier("kubernetes.contextCard")
    }

    // MARK: The middle

    private var main: some View {
        VStack(spacing: 0) {
            if !model.enabled {
                empty(
                    "Kubernetes is off", "Settings ▸ Kubernetes turns it on. Nothing reads a kubeconfig or reaches a cluster while it is off.",
                    button: "Kubernetes Settings…", id: "kubernetes.off"
                ) { page.actions?.settings() }
            } else if !model.contextsRead {
                VStack { ProgressView().controlSize(.small) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.contexts.contexts.isEmpty {
                empty("No kubeconfig", noKubeconfigDetail, button: "Kubernetes Settings…", id: "kubernetes.noKubeconfig") { page.actions?.settings() }
            } else {
                header
                Rectangle().fill(theme.border).frame(height: 1)
                content
                Rectangle().fill(theme.border).frame(height: 1)
                contextBar
            }
        }
    }

    private var noKubeconfigDetail: String {
        var lines =
            AppEnvironment.guardsKubeconfig
            ? ["This run reads no kubeconfig of yours: only OVERTERM_KUBECONFIG's, and it names none."]
            : ["No context in KUBECONFIG's files (else ~/.kube/config), or in Settings ▸ Kubernetes ▸ More kubeconfig files."]
        lines += model.contexts.problems
        return lines.joined(separator: "\n")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(page.section.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(theme.text)
            if model.podState == .live || model.pods.count > 0 {
                let failing = page.failing.count
                Text(verbatim: "\(model.pods.count) · \(page.scopeLabel)" + (failing > 0 ? " · \(failing) failing" : ""))
                    .font(.system(size: 12)).foregroundStyle(failing > 0 ? TabStatusStyle.failed : theme.text3)
                    .accessibilityIdentifier("kubernetes.counts")
            }
            Spacer(minLength: 12)
            Toggle("Wide", isOn: $page.wide).toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(theme.text2)
                .help("What kubectl get -o wide adds (\(KubernetesKey.wide.key))")
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
                    .accessibilityIdentifier("kubernetes.filter")
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

    @ViewBuilder private var content: some View {
        if case .failed(let reason, let problem) = model.podState, model.pods.count == 0 {
            failed(reason, problem)
        } else if model.pods.columns.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if let reason = model.proxyStatus.reason {
                    Text(verbatim: reason).font(.system(size: 12)).foregroundStyle(theme.text2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if case .failed(let reason, _) = model.podState { banner(reason) }
                if case .retrying(let reason) = model.podState { banner("Trying again: \(reason)") }
                let rows = page.rows
                if rows.isEmpty {
                    Text(verbatim: page.filter.isEmpty ? "No pods in \(page.scopeLabel)." : "Nothing matches “\(page.filter)”.")
                        .font(.system(size: 12)).foregroundStyle(theme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                    Spacer(minLength: 0)
                } else {
                    ResourceTable(
                        rows: rows, selection: $page.selection, columns: page.columns, sort: $page.sort, cell: { row, column in cell(row, column) },
                        verbs: { page.verbs(for: $0) },
                        copy: {
                            let names = page.selectedNames
                            if !names.isEmpty { page.actions?.copy(names.joined(separator: "\n")) }
                        }, accessibilityIdentifier: "kubernetes.list")
                }
            }
        }
    }

    /// A cell as the server wrote it — a failing pod's Status in red with
    /// its reason, an age kept moving.
    private func cell(_ row: KubePodListRow, _ column: ResourceColumn?) -> AnyView {
        let view: AnyView
        if column?.id == KubernetesPageModel.namespaceColumn {
            view = AnyView(Text(verbatim: row.row.id.namespace ?? "").foregroundStyle(theme.text2))
        } else if let column, let (index, server) = page.column(column.id) {
            let text = index < row.row.cells.count ? row.row.cells[index].text : ""
            switch server.name.lowercased() {
            case "age":
                let anchor = model.anchors[row.row.id]
                view = AnyView(
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(verbatim: anchor?.age(at: context.date).map(KubeAge.format) ?? text).foregroundStyle(theme.text2)
                    })
            case "status" where row.summary?.isFailing == true:
                view = AnyView(
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                        Text(verbatim: row.summary?.exitReason ?? text)
                    }
                    .foregroundStyle(TabStatusStyle.failed)
                    .help("\(row.row.id.name): \(row.summary?.exitReason ?? text)"))
            case "status":
                let done = row.summary?.isReady == true || row.summary?.isCompleted == true
                view = AnyView(Text(verbatim: text).foregroundStyle(done ? theme.text : TabStatusStyle.waiting))
            case "name":
                view = AnyView(Text(verbatim: text).foregroundStyle(theme.text))
            default:
                view = AnyView(Text(verbatim: text).foregroundStyle(theme.text2))
            }
        } else {
            view = AnyView(EmptyView())
        }
        return AnyView(
            view
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .environment(\.colorScheme, theme.isDark ? .dark : .light))
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TabStatusStyle.failed)
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(3).textSelection(.enabled)
            Spacer()
            Button("Try Again") { model.retry() }.buttonStyle(.plain).foregroundStyle(theme.accentText).font(.system(size: 12))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(TabStatusStyle.failed.opacity(0.1))
        .accessibilityIdentifier("kubernetes.error")
    }

    private func failed(_ reason: String, _ problem: KubeProxyProblem?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30, weight: .light)).foregroundStyle(theme.text3)
            Text("The pods couldn't be read").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
            Text(verbatim: reason).font(.system(size: 12)).foregroundStyle(theme.text2).multilineTextAlignment(.center).frame(maxWidth: 440)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                if let command = problem?.command {
                    Button("Run \(command)") { page.actions?.run(command) }
                        .help("In a terminal tab; then Try Again")
                }
                Button("Try Again") { model.retry() }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("kubernetes.failed")
    }

    // MARK: The bottom

    private var proxyColor: Color {
        switch model.proxyStatus {
        case .open: TabStatusStyle.done
        case .signingIn, .waitingForSignIn: TabStatusStyle.waiting
        case .stopped: TabStatusStyle.failed
        case .closed: theme.text3
        }
    }

    private var proxyText: String {
        switch model.proxyStatus {
        case .open:
            return ["Connected through kubectl proxy", model.version.map { "Kubernetes \($0.gitVersion)" }].compactMap { $0 }.joined(separator: " · ")
        case .closed:
            return model.podState == .loading ? "Connecting…" : "Not connected"
        default:
            return model.proxyStatus.reason ?? ""
        }
    }

    private var contextBar: some View {
        HStack(spacing: 8) {
            DockerStatusDot(color: proxyColor)
            Text(verbatim: proxyText).font(.system(size: 11)).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if case .stopped(let problem) = model.proxyStatus {
                if let command = problem.command {
                    Button("Run \(command)") { page.actions?.run(command) }.font(.system(size: 11))
                }
                Button("Try Again") { model.retry() }.font(.system(size: 11))
            }
            if let label = page.classLabel {
                Text(verbatim: label).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.selected?.isProduction == true ? Self.production : theme.text3)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .accessibilityIdentifier("kubernetes.contextBar")
    }

    private func empty(_ title: String, _ detail: String, button: String, id: String, _ action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "steeringwheel").font(.system(size: 34, weight: .light)).foregroundStyle(theme.text3)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
            Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(theme.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button(button, action: action)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(id)
    }
}
