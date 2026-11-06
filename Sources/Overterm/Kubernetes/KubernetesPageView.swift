import SwiftUI

/// The Kubernetes page (⌥⌘J): over the body like Docker's, in its turn.
/// The contexts, the namespace and the sections down the left — the one
/// showing open on its kinds — the kind's list in the middle as the server
/// formats it, how the context's proxy stands along the bottom. On a
/// production context a red band runs across the top of everything on the
/// page. Single letters act while the list has the keyboard
/// (`KubernetesKey`; `?` lists them); `n` and `c` pick a namespace or a
/// context over the page (`KubePicker`), `:` names a kind (`KubeCommandBar`).
/// Its writes (stage 2a) are verbs like any other — only on a writable
/// context, each through the page's guard path; production's are off until
/// its card turns them on for the session.
struct KubernetesPageView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var model: KubernetesModel
    @ObservedObject var theme: ChromeTheme

    /// The filter field's focus. The list's is the window's to give
    /// (`giveListTheKeyboard`, `focusPageList`): a `FocusState` no view is
    /// bound to takes the keyboard from the table and leaves it with the window.
    enum Focus: Hashable { case filter }
    @FocusState private var focus: Focus?

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
        .overlay(alignment: .top) {
            if page.picker != nil { KubePickerView(page: page, theme: theme).padding(.top, 70) }
        }
        .overlay(alignment: .top) {
            if page.command != nil { KubeCommandBarView(page: page, theme: theme).padding(.top, 70) }
        }
        .overlay(alignment: .top) {
            if page.forwardDraft != nil { KubeForwardSheetView(page: page, theme: theme).padding(.top, 70) }
        }
        .overlay(alignment: .top) {
            if page.scaleDraft != nil { KubeScaleSheetView(page: page, theme: theme).padding(.top, 70) }
        }
        .overlay(alignment: .top) {
            if page.resizeDraft != nil { KubeResizeSheetView(page: page, theme: theme).padding(.top, 70) }
        }
        .overlay(alignment: .top) {
            if page.namespaceDraft != nil { KubeNamespaceSheetView(page: page, theme: theme).padding(.top, 70) }
        }
        .onChange(of: page.focusFilter) { _ in focus = .filter }
        // A table with no columns refuses the keyboard: given it while the
        // pods are asked for (the page opened, a namespace or a context
        // picked), the window keeps it. Once the server's columns come the
        // list takes it — if nothing else has it.
        .onChange(of: model.rows.columns.isEmpty) { empty in
            guard !empty, focus != .filter, page.picker == nil, page.command == nil, page.scaleDraft == nil, page.namespaceDraft == nil,
                page.forwardDraft == nil, page.resizeDraft == nil
            else { return }
            DispatchQueue.main.async { page.offerListTheKeyboard() }
        }
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
                caption("Resources").padding(.top, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(KubeSection.allCases) { section in sectionRow(section) }
                    }
                }
            }
            Spacer(minLength: 8)
            if model.enabled, let context = model.selected { contextCard(context) }
        }
        .padding(12)
    }

    private func sectionRow(_ section: KubeSection) -> some View {
        let open = page.section == section
        let kinds = model.catalog.kinds(in: section)
        return VStack(alignment: .leading, spacing: 1) {
            Button {
                page.showSection(section)
                page.giveListTheKeyboard()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: section.symbol).frame(width: 18)
                    Text(section.title)
                    Spacer()
                    if section == .helm {
                        KubeHelmCount(helm: page.helm, theme: theme)
                    } else if section == .overview {
                        KubeOverviewCount(session: page.clusterOverview)
                    } else if !section.listsKinds {
                        KubeForwardsCount(forwards: page.forwards, theme: theme)
                    } else if !model.catalog.isEmpty {
                        Text(verbatim: "\(kinds.count)").foregroundStyle(theme.text3).font(.system(size: 10.5, design: .monospaced))
                    }
                    Text(verbatim: section.key).foregroundStyle(theme.text3).font(.system(size: 10.5, design: .monospaced))
                }
                .font(.system(size: 12.5))
                .foregroundStyle(open ? theme.text : theme.text2)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("kubernetes.section.\(section.rawValue)")
            if open, section.listsKinds {
                ForEach(Array(kinds.enumerated()), id: \.element.fullName) { offset, kind in
                    // Custom resources by API group, each named once.
                    if section == .custom, offset == 0 || kinds[offset - 1].group != kind.group {
                        Text(verbatim: kind.group).font(.system(size: 10)).foregroundStyle(theme.text3).padding(.leading, 36).padding(.top, 4)
                    }
                    kindRow(kind)
                }
                if kinds.isEmpty {
                    Text(verbatim: model.catalog.isEmpty ? (model.discoveryProblem ?? "Reading what the cluster serves…") : "None here.")
                        .font(.system(size: 11)).foregroundStyle(theme.text3).padding(.leading, 36).padding(.vertical, 4)
                }
            }
        }
    }

    private func kindRow(_ kind: KubeResourceKind) -> some View {
        let shown = model.kind.fullName == kind.fullName && page.showsSection
        return Button {
            page.showKind(kind)
            page.giveListTheKeyboard()
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: KubeKindCatalog.title(of: kind)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if shown, model.listState == .live {
                    Text(verbatim: "\(model.rows.count)").foregroundStyle(theme.text3).font(.system(size: 10.5, design: .monospaced))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(shown ? theme.text : theme.text2)
            .padding(.leading, 36)
            .padding(.trailing, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(shown ? theme.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(kind.fullName) · \(kind.groupVersion)\(kind.shortNames.isEmpty ? "" : " · :" + kind.shortNames.joined(separator: ", :"))")
        .accessibilityIdentifier("kubernetes.kind.\(kind.fullName)")
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
        .contextMenu {
            Button("Terminal in This Context") { page.openTerminal(in: context) }
        }
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
            Button("Other Namespace…  n") { page.openPicker(.namespace) }
        } label: {
            Text(verbatim: page.scopeLabel).font(.system(size: 12)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .accessibilityIdentifier("kubernetes.namespace")
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
            // The user's own kubectl, pinned to this context: not read-only.
            Button {
                page.openTerminal()
            } label: {
                Label("Terminal in This Context", systemImage: "helm").font(.system(size: 11))
            }
            .buttonStyle(.link)
            .foregroundStyle(context.isProduction ? Self.production : theme.accentText)
            .padding(.top, 4)
            .help("A tab whose plain kubectl, helm or k9s goes to \(context.name) — with your own rights. Your current context is unchanged.")
            .accessibilityIdentifier("kubernetes.terminal")
            // Production's writes, for this session only (rule 2).
            if context.isProduction {
                Button {
                    if context.sessionWrites { page.endProductionWrites() } else { page.allowProductionWrites() }
                } label: {
                    Label(
                        context.sessionWrites ? "Writes On Until Quit — Turn Off" : "Allow Writes Until Quit…",
                        systemImage: context.sessionWrites ? "lock.open.fill" : "lock.fill"
                    ).font(.system(size: 11))
                }
                .buttonStyle(.link)
                .foregroundStyle(Self.production)
                .help(
                    context.sessionWrites
                        ? "Writes are on for \(context.name) until Overterm quits: each one is asked, a destructive one by its name."
                        : "Production is read-only. Writes can be turned on for this session only — never by a setting."
                )
                .accessibilityIdentifier("kubernetes.productionWrites")
            }
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
            Text(verbatim: page.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(theme.text)
                .accessibilityIdentifier("kubernetes.title")
            if page.showsSection, model.listState == .live || model.rows.count > 0 {
                let failing = page.failing.count
                Text(verbatim: "\(model.rows.count) · \(model.kind.namespaced ? page.scopeLabel : "cluster-wide")" + (failing > 0 ? " · \(failing) failing" : ""))
                    .font(.system(size: 12)).foregroundStyle(failing > 0 ? TabStatusStyle.failed : theme.text3)
                    .accessibilityIdentifier("kubernetes.counts")
            }
            if let note = page.metricsNote {
                Text(verbatim: note).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.tail).help(note)
                    .accessibilityIdentifier("kubernetes.metricsNote")
            }
            if page.detail == nil, let problem = page.commandProblem {
                Text(verbatim: problem).font(.system(size: 11.5)).foregroundStyle(TabStatusStyle.failed).lineLimit(1).truncationMode(.tail)
                    .help(problem).accessibilityIdentifier("kubernetes.commandProblem")
            } else if page.detail == nil, let status = page.writeStatus {
                Text(verbatim: status.text).font(.system(size: 11.5)).foregroundStyle(status.isFailure ? TabStatusStyle.failed : theme.text2)
                    .lineLimit(1).truncationMode(.tail).help(status.text).accessibilityIdentifier("kubernetes.writeStatus")
            } else if page.detail == nil, let status = page.compareStatus {
                // Compare with… from a row's menu, no detail open: said here.
                Text(verbatim: status.text).font(.system(size: 11.5)).foregroundStyle(theme.text2)
                    .lineLimit(1).truncationMode(.tail).help(status.text).accessibilityIdentifier("kubernetes.compareStatus")
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
                    .onSubmit {
                        page.applySelector()
                        page.giveListTheKeyboard()
                    }
                    .onExitCommand {
                        page.filter = ""
                        page.giveListTheKeyboard()
                    }
                    .accessibilityIdentifier("kubernetes.filter")
            }
            .padding(.horizontal, 8)
            .frame(width: 240, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover.opacity(0.7)))
            KubeSavedFilterMenu(page: page, theme: theme)
            Button {
                page.copyKubectl()
            } label: {
                Image(systemName: "terminal").font(.system(size: 12)).foregroundStyle(theme.text2)
            }
            .buttonStyle(.plain)
            .help("Copy as kubectl (\(KubernetesKey.copyKubectl.key)) — \(page.listKubectl ?? "")")
            .accessibilityIdentifier("kubernetes.copyKubectl")
            Button {
                page.exportCSV()
            } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 12)).foregroundStyle(theme.text2)
            }
            .buttonStyle(.plain)
            .disabled(!page.canExport)
            .help("Export the list as CSV — its columns and the rows the filter shows")
            .accessibilityIdentifier("kubernetes.exportCSV")
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

    /// The list keeps its place in the view tree whatever it shows — loading,
    /// empty, failed — so the keyboard given to it (`n`, `c`, a context
    /// picked) finds it, and its selection and scroll survive a new list:
    /// the Docker page's lesson. What it says instead lies over it.
    private var content: some View {
        let rows = page.rows
        let failedOutright: (String, KubeProxyProblem?)? =
            if case .failed(let reason, let problem) = model.listState, model.rows.count == 0 { (reason, problem) } else { nil }
        return VStack(spacing: 0) {
            if failedOutright == nil {
                if case .failed(let reason, _) = model.listState { banner(reason) }
                if case .retrying(let reason) = model.listState { banner("Trying again: \(reason)") }
            }
            selectorLine
            // The list keeps its place whether or not the detail is beside
            // it (the Docker page's lesson): first in the stack, always.
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    list(rows, failedOutright: failedOutright)
                    if let detail = page.detail {
                        Rectangle().fill(theme.border).frame(width: 1)
                        KubeDetailView(page: page, session: detail, theme: theme)
                            .id(detail.id)
                            .frame(width: min(560, max(340, geometry.size.width * 0.45)))
                    }
                }
            }
        }
    }

    private func list(_ rows: [KubeListRow], failedOutright: (String, KubeProxyProblem?)?) -> some View {
        ZStack(alignment: .topLeading) {
            ResourceTable(
                rows: rows, selection: $page.selection, columns: page.columns, sort: $page.sort, cell: { row, column in cell(row, column) },
                verbs: { page.verbs(for: $0) },
                copy: {
                    let names = page.selectedNames
                    if !names.isEmpty { page.actions?.copy(names.joined(separator: "\n")) }
                }, accessibilityIdentifier: "kubernetes.list", pressed: { page.pressed($0) })
            if page.section == .overview {
                KubeClusterOverviewView(page: page, session: page.clusterOverview, model: model, theme: theme)
            } else if page.section == .helm {
                KubeHelmSection(page: page, helm: page.helm, theme: theme)
            } else if !page.section.listsKinds {
                KubeForwardsSection(page: page, forwards: page.forwards, theme: theme)
            } else if !page.showsSection {
                Text(verbatim: sectionNote).font(.system(size: 12)).foregroundStyle(theme.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
                    .accessibilityIdentifier("kubernetes.sectionNote")
            } else if let (reason, problem) = failedOutright {
                failed(reason, problem).background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
            } else if model.rows.columns.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if let reason = model.proxyStatus.reason {
                        Text(verbatim: reason).font(.system(size: 12)).foregroundStyle(theme.text2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            } else if rows.isEmpty {
                Text(verbatim: page.filter.isEmpty ? emptyNote : "Nothing matches “\(page.filter)”.")
                    .font(.system(size: 12)).foregroundStyle(theme.text3)
                    .padding(.horizontal, 20).padding(.top, 34)
                    .allowsHitTesting(false)
            }
        }
    }

    private var emptyNote: String {
        let title = KubeKindCatalog.title(of: model.kind).lowercased()
        return model.kind.namespaced ? "No \(title) in \(page.scopeLabel)." : "No \(title)."
    }

    /// Why a section shows no list.
    private var sectionNote: String {
        if model.catalog.isEmpty { return model.discoveryProblem.map { "What the cluster serves couldn't be read: \($0)" } ?? "Reading what the cluster serves…" }
        return page.section == .custom ? "No custom resources: this cluster serves no CRD that can be listed." : "This cluster serves none of \(page.section.title)' kinds."
    }

    /// What `label:` and `field:` ask the server for, or why a word of them
    /// can't be — or that the list is another window's, asked with its own
    /// filter.
    @ViewBuilder private var selectorLine: some View {
        let reading = page.selectorReading
        let ours = page.listIsOurs
        if !reading.selectors.isEmpty || !reading.refused.isEmpty || !ours {
            HStack(spacing: 6) {
                Image(systemName: reading.refused.isEmpty && ours ? "server.rack" : "exclamationmark.triangle").font(.system(size: 10))
                if !ours {
                    Text(verbatim: "Another window's list (\(model.selectors.said ?? "every row")) — ↩ in the filter asks for this one's")
                        .foregroundStyle(TabStatusStyle.failed)
                } else if let said = model.selectors.said {
                    Text(verbatim: "Asked of the server: \(said)")
                }
                if !reading.refused.isEmpty {
                    Text(verbatim: "Not a selector: \(reading.refused.joined(separator: " "))").foregroundStyle(TabStatusStyle.failed)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.text3)
            .padding(.horizontal, 20)
            .frame(height: 22)
            .accessibilityIdentifier("kubernetes.selector")
        }
    }

    /// A cell as the server wrote it — a failing pod's Status in red with
    /// its reason, an age kept moving.
    private func cell(_ row: KubeListRow, _ column: ResourceColumn?) -> AnyView {
        let view: AnyView
        if column?.id == KubernetesPageModel.namespaceColumn {
            view = AnyView(Text(verbatim: row.row.id.namespace ?? "").foregroundStyle(theme.text2))
        } else if let column, let measure = KubernetesPageModel.measure(of: column.id) {
            let usage = page.usage(measure, of: row)
            view = AnyView(
                Text(verbatim: usage.text).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(usage.sort == nil ? theme.text3 : theme.text2)
                    .help(usage.help ?? ""))
        } else if column?.id == KubernetesPageModel.volumeColumn {
            let usage = page.volumeUsage(of: row)
            view = AnyView(
                Text(verbatim: usage.text).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(usage.sort == nil ? theme.text3 : theme.text2)
                    .help(usage.help ?? ""))
        } else if column?.id == KubeDeploymentHint.column {
            let hint = row.hint
            view = AnyView(
                Text(verbatim: hint?.text ?? "")
                    .foregroundStyle(hint?.isBad == true ? TabStatusStyle.failed : hint?.isDone == true ? theme.text : TabStatusStyle.waiting))
        } else if let column, let (index, server) = page.column(column.id) {
            let text = index < row.row.cells.count ? row.row.cells[index].text : ""
            switch server.name.lowercased() {
            case "age", "created at":
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
                            .help("\(row.row.id.name): \(row.summary?.exitReason ?? text)")
                        Spacer(minLength: 4)
                        askWhyButton(row)
                    }
                    .foregroundStyle(TabStatusStyle.failed))
            case "status" where row.summary != nil:
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

    /// A failing pod's Ask Why, in its row — Docker's Ask Why button, as
    /// the detail's and the menu's verb (`askWhyVerb`) is.
    private func askWhyButton(_ row: KubeListRow) -> some View {
        Button {
            page.askWhy(row: row.id)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "sparkles").font(.system(size: 9))
                Text("Why").font(.system(size: 11))
            }
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(Capsule().fill(TabColor.purple.color.opacity(0.18)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TabColor.purple.color)
        .help("Ask an Agent Why… (\(KubernetesKey.askWhy.key)) — the brief shown, scrubbed, before it is sent")
        .accessibilityIdentifier("kubernetes.askWhy")
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
            Text(verbatim: "\(KubeKindCatalog.title(of: model.kind)) couldn't be read").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
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
            return model.listState == .loading ? "Connecting…" : "Not connected"
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


/// How many things the Overview says fail, beside its section's name.
struct KubeOverviewCount: View {
    @ObservedObject var session: KubeClusterOverviewSession

    var body: some View {
        if session.state != .idle, session.overview.problems > 0 {
            Text(verbatim: "\(session.overview.problems)").foregroundStyle(TabStatusStyle.failed).font(.system(size: 10.5, design: .monospaced))
        }
    }
}

/// The filter's saved ones, for the context shown (`KubeSavedFilters`):
/// Save This Filter, each saved filter shown again, each removed.
struct KubeSavedFilterMenu: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var theme: ChromeTheme
    @ObservedObject var store: KubeSavedFilters = .shared

    var body: some View {
        let saved = page.model.selectedName.map { store.filters(on: $0) } ?? []
        Menu {
            Button("Save This Filter") { page.saveFilter() }
                .disabled(page.filter.trimmingCharacters(in: .whitespaces).isEmpty)
            if !saved.isEmpty {
                Divider()
                ForEach(saved) { filter in
                    Button(filter.name + " — " + filter.said) { page.applySavedFilter(filter) }
                }
                Divider()
                Menu("Remove") {
                    ForEach(saved) { filter in Button(filter.name) { store.remove(filter.id) } }
                }
            }
        } label: {
            Image(systemName: saved.isEmpty ? "bookmark" : "bookmark.fill").font(.system(size: 12)).foregroundStyle(theme.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Saved filters for this context — also in the palette (⌘K)")
        .accessibilityIdentifier("kubernetes.savedFilters")
    }
}
