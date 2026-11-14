import SwiftUI

/// What the panel's verbs do, the window's way.
struct TerraformPanelActions {
    /// A shell tab with its folder at the root (4.9): no `TF_WORKSPACE`.
    var openTerminal: (TerraformRootCard) -> Void
    /// The root's first `.tf` file in the editor.
    var openFile: (URL) -> Void
    /// `terraform validate` of the root (stage 1a's, credentials stripped).
    var validate: (TerraformRootCard) -> Void
    /// Overterm's plan, in the right slot (stage 1d).
    var plan: (TerraformRootCard) -> Void
    /// Init, the fetch list shown first (4.13).
    var initialize: (TerraformRootCard) -> Void
    /// The workspace chip's menu (4.9).
    var chooseWorkspace: (TerraformRootCard) -> Void
    /// The root's last plan, shown in the slot.
    var showPlan: (TerraformPlanRun) -> Void
    /// A destroy plan, asked first (2a).
    var planDestroy: (TerraformRootCard) -> Void = { _ in }
    /// An apply going in this root, shown in the slot with its Stop (4.7).
    var showApply: (TerraformApplyRun) -> Void = { _ in }
    /// The root's state and outputs, masked, in the slot (2.4, stage 2c).
    var showState: (TerraformRootCard) -> Void = { _ in }
    /// Check Drift: a refresh-only plan (2.6, stage 2d).
    var checkDrift: (TerraformRootCard) -> Void = { _ in }
    /// `terraform test` of the root, in the slot (2.9, stage 2d).
    var test: (TerraformRootCard) -> Void = { _ in }
    var showTest: (TerraformTestRun) -> Void = { _ in }
}

/// The rail's Terraform panel (analysis 6.1, 6.2): the selected tab's
/// checkout's roots, grouped by top folder, each a chip — its class band,
/// workspace, backend, version — and what the other worktrees say of it;
/// its modules and who calls them; examples and Terragrunt folded.
struct TerraformPanelView: View {
    @ObservedObject var panel: TerraformPanelModel
    @ObservedObject var settings: Settings
    @ObservedObject var theme: ChromeTheme
    let group: TabGroup?
    let actions: TerraformPanelActions
    @State private var showModules = true
    @State private var showExamples = false

    static let production = KubernetesPageView.production
    static let remote = Color(red: 0.85, green: 0.55, blue: 0.1)

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Terraform", group: group, theme: theme, help: panel.checkout?.path) {
                PanelHeaderButton(symbol: "arrow.clockwise", help: "Read the roots again", action: { panel.refresh() }, theme: theme)
            }
            if !settings.bool("terraform.enabled") {
                note("Terraform is off in Settings.")
            } else if panel.checkout == nil {
                note("No checkout here: a tab in a repository shows its Terraform roots.")
            } else {
                switch panel.state {
                case .notGit:
                    note("Not a repository's top folder: Overterm looks for roots only in one — never in your home folder or /.")
                case .idle, .reading:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 12)
                case .read:
                    content
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityIdentifier("terraform.panel")
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(panel.inherited.notes, id: \.self) { line in
                    Text(verbatim: line).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.orangeText)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 3)
                        .accessibilityIdentifier("terraform.panel.inherited")
                }
                if panel.roots.isEmpty && panel.modules.isEmpty && panel.terragrunt.isEmpty {
                    quiet("No Terraform roots in this checkout.")
                }
                ForEach(groups, id: \.name) { group in
                    section(group.name)
                    ForEach(group.roots) { card in RootRow(card: card, panel: panel, theme: theme, actions: actions) }
                }
                if !panel.modules.isEmpty {
                    fold("Modules", count: panel.modules.count, open: $showModules)
                    if showModules {
                        ForEach(panel.modules) { module in moduleRow(module) }
                    }
                }
                if !panel.terragrunt.isEmpty {
                    section("Terragrunt")
                    ForEach(panel.terragrunt) { folder in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: folder.path.isEmpty ? "." : folder.path).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                                .foregroundStyle(theme.text)
                            Text(folder.kind == .terragruntUnit ? "Terragrunt unit: run it with terragrunt in a terminal" : "Terragrunt's configuration")
                                .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 3)
                    }
                }
                if !panel.examples.isEmpty {
                    fold("Examples and tests", count: panel.examples.count, open: $showExamples)
                    if showExamples {
                        ForEach(panel.examples) { folder in
                            Text(verbatim: folder.path).font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text2)
                                .padding(.horizontal, 12).padding(.vertical, 2)
                        }
                    }
                }
                if panel.capped {
                    quiet("More files than Overterm lists (20,000): some roots may be missing.")
                }
                Text("Overterm checks what it runs. What you or an agent type in a terminal is your own terraform, with your credentials.")
                    .font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.top, 12)
            }
            .padding(.bottom, 8)
        }
    }

    /// Roots by their top folder: `envs/dev` and `envs/prod` under `envs`.
    private var groups: [(name: String, roots: [TerraformRootCard])] {
        var order: [String] = []
        var byName: [String: [TerraformRootCard]] = [:]
        for card in panel.roots {
            let top = card.path.split(separator: "/").first.map(String.init) ?? "."
            let name = card.path.contains("/") ? top : "."
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(card)
        }
        return order.map { (name: $0 == "." ? "Roots" : $0, roots: byName[$0] ?? []) }
    }

    private func moduleRow(_ module: TerraformModuleRow) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: module.path).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text)
                .lineLimit(1).truncationMode(.middle)
            if module.touched { changedDot }
            Spacer(minLength: 4)
            Text(verbatim: module.callers.count == 1 ? "1 root" : "\(module.callers.count) roots")
                .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .help(module.callers.isEmpty ? "No root here calls it" : "Called by " + module.callers.joined(separator: ", "))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terraform.panel.module.\(module.path)")
    }

    private var changedDot: some View {
        Circle().fill(theme.accentText).frame(width: 6, height: 6).help("Changed in this checkout")
    }

    private func section(_ title: String) -> some View {
        Text(verbatim: title).font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
    }

    private func fold(_ title: String, count: Int, open: Binding<Bool>) -> some View {
        Button {
            open.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: ChromeMetrics.text(9)))
                Text(verbatim: "\(title) (\(count))").font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).textCase(.uppercase)
            }
            .foregroundStyle(theme.text3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.top, 8)
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 4)
    }

    static func color(_ rootClass: TerraformClass, theme: ChromeTheme) -> Color {
        switch rootClass {
        case .production: production
        case .remote: remote
        case .local: theme.text3
        }
    }
}

/// One root's chip (6.2): the class band, its name and class, the
/// workspace, the backend, the version — red on production.
private struct RootRow: View {
    let card: TerraformRootCard
    @ObservedObject var panel: TerraformPanelModel
    @ObservedObject var registry = TerraformRunRegistry.shared
    @ObservedObject var setup = TerraformWorktreeSetup.shared
    @ObservedObject var theme: ChromeTheme
    let actions: TerraformPanelActions

    private var selected: Bool { panel.selectedPath == card.path }
    private var color: Color { TerraformPanelView.color(card.rootClass, theme: theme) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: card.name).font(.system(size: ChromeMetrics.text(12), weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    // The checkout's branch @ commit (6.2): shown, never a signal (5.1).
                    if let branch = panel.branchLabel {
                        Text(verbatim: "· " + branch).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text3)
                            .lineLimit(1).truncationMode(.tail)
                            .help("The checkout's branch and commit: the branch names the work, not where it goes — never a production signal")
                            .accessibilityIdentifier("terraform.panel.branch.\(card.path)")
                    }
                    if card.touched { Circle().fill(theme.accentText).frame(width: 6, height: 6).help("Changed in this checkout") }
                    Spacer(minLength: 4)
                    classPill
                }
                HStack(spacing: 6) {
                    Button {
                        actions.chooseWorkspace(card)
                    } label: {
                        Text(verbatim: "workspace \(card.workspace) ▾").font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                            .padding(.horizontal, 5).frame(height: 17)
                            .background(RoundedRectangle(cornerRadius: 4).fill(theme.rowSel))
                            .foregroundStyle(theme.text2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Select a workspace: it writes \(card.name)/.terraform/environment, which every terminal there follows")
                    .accessibilityIdentifier("terraform.panel.workspace.\(card.path)")
                    Text(verbatim: card.backendSummary).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text2)
                        .lineLimit(1).truncationMode(.middle)
                }
                notes
                if selected { detail }
            }
            .padding(.leading, 9).padding(.trailing, 10).padding(.vertical, 6)
        }
        .background(selected ? theme.rowSel : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { panel.selectedPath = selected ? nil : card.path }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(card.name), \(card.rootClass.title)"))
        .accessibilityIdentifier("terraform.panel.root.\(card.path)")
    }

    private var classPill: some View {
        Text(verbatim: card.rootClass.title.uppercased())
            .font(.system(size: ChromeMetrics.text(9.5), weight: .bold))
            .foregroundStyle(card.rootClass == .local ? theme.text2 : Color.white)
            .padding(.horizontal, 5).frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(card.rootClass == .local ? theme.rowSel : color))
            .help(card.rootClass.title + ": " + card.verdict.reason)
            .accessibilityIdentifier("terraform.panel.class.\(card.path)")
    }

    @ViewBuilder private var notes: some View {
        if let elsewhere = card.stateElsewhere {
            line("No state in this worktree: the state is in \(elsewhere)'s checkout. A plan here would create everything again.", TerraformPanelView.production)
                .accessibilityIdentifier("terraform.panel.noState.\(card.path)")
        }
        if let drift = TerraformLockDrift.summary(card.lockDrift) {
            line("Lock file: " + drift, theme.orangeText).accessibilityIdentifier("terraform.panel.lockDrift.\(card.path)")
        }
        // What New Task did here (stage 2b).
        if let made = setup.root(panel.checkout, path: card.path) {
            ForEach(made.notes, id: \.self) { note in line(note, theme.orangeText) }
            line(made.preparation.words, made.preparation.isProblem ? theme.orangeText : theme.text3)
                .accessibilityIdentifier("terraform.panel.newWorktree.\(card.path)")
        }
        if !card.sharedWith.isEmpty {
            line("Shares its state with " + card.sharedWith.joined(separator: ", "), theme.text3)
                .accessibilityIdentifier("terraform.panel.shared.\(card.path)")
        }
        // An apply going here — this session's, or one followed again after
        // a quit — reachable whatever the slot shows: its progress and Stop.
        ForEach(registry.applies.filter { $0.isGoing && $0.marker.root == card.path && $0.marker.checkout == (panel.checkout ?? card.folder).standardizedFileURL.path }) {
            apply in
            TerraformGoingApplyButton(apply: apply, theme: theme, words: "applying", show: actions.showApply)
                .accessibilityIdentifier("terraform.panel.apply.\(card.path)")
        }
        if let run = TerraformRunRegistry.shared.latest(checkout: panel.checkout ?? card.folder, root: card.path), let plan = run.plan {
            Button {
                actions.showPlan(run)
            } label: {
                Text(verbatim: "last plan \(plan.counts.bar) · \(run.age())").font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                    .foregroundStyle(run.staleReason(.shared) == nil ? theme.text2 : theme.orangeText)
            }
            .buttonStyle(.plain)
            .help(run.staleReason(.shared) ?? plan.counts.sentence)
            .accessibilityIdentifier("terraform.panel.lastPlan.\(card.path)")
        }
        TerraformRootChecksView(
            card: card, checkout: panel.checkout ?? card.folder, registry: registry, tests: .shared, theme: theme, showPlan: actions.showPlan,
            showTest: actions.showTest)
        let varFiles = TerraformRootStore.shared.varFiles(checkout: panel.checkout ?? card.folder, root: card.path)
        if !varFiles.isEmpty {
            line("var files: " + varFiles.joined(separator: ", "), theme.text3).accessibilityIdentifier("terraform.panel.varFiles.\(card.path)")
        }
        if card.backendChanged { line("The backend changed since init: run init in a terminal.", theme.orangeText) }
        if card.facts.needsInit { line("Needs init: a provider it requires isn't in its lock file.", theme.orangeText) }
        HStack(spacing: 6) {
            if let version = card.version {
                Text(verbatim: card.versionMismatch ?? "tf \(version)").font(.system(size: ChromeMetrics.text(10), design: .monospaced))
                    .foregroundStyle(card.versionMismatch == nil ? theme.text3 : theme.orangeText)
                    .accessibilityIdentifier("terraform.panel.version.\(card.path)")
            }
            if card.workspaceClasses.count > 1 {
                Text(verbatim: "workspaces: " + card.workspaceClasses.keys.sorted().joined(separator: ", "))
                    .font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private func line(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(card.rootClass.title): \(card.verdict.reason)").font(.system(size: ChromeMetrics.text(10.5)))
                .foregroundStyle(card.isProduction ? TerraformPanelView.production : theme.text2).fixedSize(horizontal: false, vertical: true)
            ForEach(card.workspaceClasses.keys.sorted().filter { $0 != card.workspace }, id: \.self) { workspace in
                Text(verbatim: "workspace \(workspace): \(card.workspaceClasses[workspace]?.title ?? "")").font(.system(size: ChromeMetrics.text(10)))
                    .foregroundStyle(card.workspaceClasses[workspace] == .production ? TerraformPanelView.production : theme.text3)
            }
            if !card.modules.isEmpty {
                Text(verbatim: "calls " + card.modules.joined(separator: ", ")).font(.system(size: ChromeMetrics.text(10), design: .monospaced))
                    .foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                button("Plan", "play.circle") { actions.plan(card) }
                    .accessibilityIdentifier("terraform.panel.plan")
                button("Init…", "arrow.down.circle") { actions.initialize(card) }
                    .accessibilityIdentifier("terraform.panel.init")
                button("State", "list.bullet.rectangle") { actions.showState(card) }
                    .accessibilityIdentifier("terraform.panel.state")
            }
            // New Task's init writes this root's .terraform now.
            .disabled(setup.isInitializing(card.folder))
            HStack(spacing: 6) {
                button("Terminal in This Root", "terminal") { actions.openTerminal(card) }
                    .accessibilityIdentifier("terraform.panel.terminal")
                button("Validate", "checkmark.seal") { actions.validate(card) }
            }
            HStack(spacing: 6) {
                button("Check Drift", "arrow.triangle.2.circlepath") { actions.checkDrift(card) }
                    .accessibilityIdentifier("terraform.panel.drift")
                button("Test", "checkmark.circle") { actions.test(card) }
                    .accessibilityIdentifier("terraform.panel.test")
            }
            .disabled(setup.isInitializing(card.folder))
            if !(Settings.shared.terraformRoots[card.path]?.writable ?? true) {
                Text(verbatim: "Plan only: terraform.roots sets this root's writable to false.")
                    .font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("terraform.panel.planOnly")
            } else if card.isProduction {
                Text(verbatim: "Production: each apply asks for the root's name.")
                    .font(.system(size: ChromeMetrics.text(10))).foregroundStyle(TerraformPanelView.production)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("terraform.panel.productionAsks")
            }
        }
        .padding(.top, 3)
    }

    private func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: ChromeMetrics.text(11)))
                .padding(.horizontal, 7).frame(height: ChromeMetrics.row(22))
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.iconBg))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text)
    }

    @ViewBuilder private var menu: some View {
        // New Task's init writes this root's .terraform now: nothing runs in it meanwhile.
        let initializing = setup.isInitializing(card.folder)
        Group {
            Button("Plan") { actions.plan(card) }
            Button("Plan Destroy…") { actions.planDestroy(card) }
            Button("Init…") { actions.initialize(card) }
        }
        .disabled(initializing)
        Button("Select Workspace…") { actions.chooseWorkspace(card) }
        Group {
            Button("State and Outputs") { actions.showState(card) }
            Button("Check Drift") { actions.checkDrift(card) }
            Button("Test") { actions.test(card) }
        }
        .disabled(initializing)
        Divider()
        Button("Terminal in This Root") { actions.openTerminal(card) }
        Button("Validate") { actions.validate(card) }
        if let file = mainFile { Button("Open \(file.lastPathComponent)") { actions.openFile(file) } }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(card.folder.path, forType: .string)
        }
    }

    private var mainFile: URL? {
        let main = card.folder.appendingPathComponent("main.tf")
        if FileManager.default.fileExists(atPath: main.path) { return main }
        return nil
    }
}

/// An apply that is going, as a button that shows it in the slot (4.7):
/// the panel's card, and the slot's list when it shows something else.
/// It observes its apply, so it goes once the apply ends.
struct TerraformGoingApplyButton: View {
    @ObservedObject var apply: TerraformApplyRun
    @ObservedObject var theme: ChromeTheme
    /// "applying", or the root's name and worktree for the slot's list.
    let words: String
    let show: (TerraformApplyRun) -> Void

    var body: some View {
        if apply.isGoing {
            Button {
                show(apply)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.circle.fill").font(.system(size: ChromeMetrics.text(10)))
                    Text(verbatim: "\(words) · \(apply.progressText()) — Show")
                        .font(.system(size: ChromeMetrics.text(10.5), weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(apply.marker.rootClass == TerraformClass.production.rawValue ? TerraformPanelView.production : theme.orangeText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show this apply's progress, with Stop")
        }
    }
}
