import AppKit
import SwiftUI

/// What the plan view's buttons do, the window's way.
struct TerraformPlanActions {
    var planAgain: (TerraformPlanRun, TerraformCommands.LockWait) -> Void
    var discard: (TerraformPlanRun) -> Void
    var copySummary: (TerraformPlanRun) -> Void
    var askWhy: (TerraformPlanRun) -> Void
    /// Ask Why on a failed apply: the apply's diagnostics and log (6.4).
    var askWhyApply: (TerraformApplyRun) -> Void = { _ in }
    /// Plan Again after an apply, a reattached one's too.
    var planAfterApply: (TerraformApplyRun) -> Void = { _ in }
    /// An apply shown in the slot: its progress and Stop (4.7).
    var showApply: (TerraformApplyRun) -> Void = { _ in }
    /// The root's var files chosen for its plans (Missing variables, 2.2).
    var chooseVarFiles: (TerraformPlanRun, [String]) -> Void
    /// A file of the checkout at a line.
    var open: (URL, Int?) -> Void
    var close: () -> Void
    /// Apply… (6.4): the checks, the sheet, the detached apply.
    var apply: (TerraformPlanRun) -> Void = { _ in }
    /// Stop (`.`): asked the second time.
    var stopApply: (TerraformApplyRun) -> Void = { _ in }
    /// Plan again with a mode (2a): only this address, replacing it.
    var planMode: (TerraformPlanRun, TerraformPlanMode) -> Void = { _, _ in }
}

/// The plan in the right slot (analysis 6.3): the header — root, branch @
/// commit, age, the profile its environment used — and the counts bar;
/// what is stale, what its code runs, which inputs changed it; then the
/// rows: drift first, replace, delete, forget and actions red with their
/// cause chains, the same change ×N folded, moves and imports, data
/// sources folded. While it runs, its progress and log. Values only as
/// the masked model has them: a sensitive one is ••••••, never a value.
struct TerraformPlanPaneView: View {
    @ObservedObject var pane: TerraformPlanPaneModel
    @ObservedObject var theme: ChromeTheme
    let actions: TerraformPlanActions

    var body: some View {
        VStack(spacing: 0) {
            TerraformGoingApplies(registry: .shared, pane: pane, theme: theme, show: actions.showApply)
            if let apply = pane.apply {
                TerraformApplyView(apply: apply, pane: pane, theme: theme, actions: actions)
            } else if let run = pane.run {
                TerraformRunView(run: run, pane: pane, registry: .shared, theme: theme, actions: actions)
            } else {
                Text("No plan yet: Plan a root from the Terraform panel (⌥⌘E).")
                    .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terraform.plan")
    }
}

/// The applies going that the slot doesn't show (4.7): each a button
/// to its progress and Stop — another plan shown over one, a second apply
/// found at launch. Nothing when none is.
private struct TerraformGoingApplies: View {
    @ObservedObject var registry: TerraformRunRegistry
    @ObservedObject var pane: TerraformPlanPaneModel
    @ObservedObject var theme: ChromeTheme
    let show: (TerraformApplyRun) -> Void

    var body: some View {
        let others = registry.applies.filter { $0 !== pane.apply && $0.isGoing }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(others) { apply in
                    TerraformGoingApplyButton(apply: apply, theme: theme, words: "Apply · \(apply.marker.name) · \(apply.worktree)", show: show)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terraform.plan.goingApplies")
        }
    }
}

private struct TerraformRunView: View {
    @ObservedObject var run: TerraformPlanRun
    @ObservedObject var pane: TerraformPlanPaneModel
    @ObservedObject var registry: TerraformRunRegistry
    @ObservedObject var theme: ChromeTheme
    let actions: TerraformPlanActions
    @FocusState private var filterFocused: Bool

    private var red: Color { TerraformPanelView.production }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            switch run.phase {
            case .preparing, .waiting, .running:
                progress
            case .refused(let why):
                message(why, color: red).accessibilityIdentifier("terraform.plan.refused")
                log
            case .failed(let why):
                failure(why)
            case .stopped:
                message("Stopped.", color: theme.orangeText)
                log
            case .tooLarge(let why):
                message(why, color: theme.orangeText).accessibilityIdentifier("terraform.plan.tooLarge")
                log
            case .planned, .noChanges:
                if run.kind == .initialize {
                    message("Init done.", color: theme.text2).accessibilityIdentifier("terraform.plan.initDone")
                    log
                } else {
                    planned
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if run.card.isProduction {
                    Text("PRODUCTION").font(.system(size: ChromeMetrics.text(9.5), weight: .bold)).foregroundStyle(Color.white)
                        .padding(.horizontal, 5).frame(height: 16).background(RoundedRectangle(cornerRadius: 4).fill(red))
                }
                Text(verbatim: (run.kind == .plan ? (run.mode.isDestroy ? "Destroy plan · " : "Plan · ") : "Init · ") + run.card.name)
                    .font(.system(size: ChromeMetrics.text(12.5), weight: .semibold, design: .monospaced)).foregroundStyle(theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: headerDetail).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let plan = run.plan {
                    Text(verbatim: plan.counts.bar).font(.system(size: ChromeMetrics.text(11.5), weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.text).help(plan.counts.sentence)
                        .accessibilityIdentifier("terraform.plan.bar")
                }
                Button(action: actions.close) { Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(10))) }
                    .buttonStyle(.plain).foregroundStyle(theme.text3).help("Close the pane")
            }
            HStack(spacing: 6) {
                if run.kind == .plan, !run.isGoing, run.record != nil {
                    let greyed = run.applyGreyed(registry, writable: Settings.shared.terraformRoots[run.card.path]?.writable ?? false)
                    Button {
                        actions.apply(run)
                    } label: {
                        Label(run.mode.isDestroy ? "Destroy…" : "Apply…", systemImage: "play.fill").font(.system(size: ChromeMetrics.text(11), weight: .semibold))
                            .padding(.horizontal, 7).frame(height: ChromeMetrics.row(22))
                            .background(RoundedRectangle(cornerRadius: 5).fill(greyed == nil ? (run.card.isProduction ? red.opacity(0.85) : theme.accentText.opacity(0.85)) : theme.iconBg))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(greyed == nil ? Color.white : theme.text3)
                    .disabled(greyed != nil)
                    .help(greyed ?? "Apply this plan, and nothing else (⇧A): asked first")
                    .accessibilityIdentifier("terraform.plan.apply")
                    .accessibilityValue(Text(verbatim: greyed ?? "ready"))
                }
                if run.isGoing {
                    button("Stop", "stop.circle") { run.stop() }.accessibilityIdentifier("terraform.plan.stop")
                } else {
                    button(run.kind == .plan ? "Plan Again" : "Init Again", "arrow.clockwise") { actions.planAgain(run, .person) }
                        .accessibilityIdentifier("terraform.plan.again")
                }
                if run.plan != nil {
                    button("Copy Summary", "doc.on.doc") { actions.copySummary(run) }.accessibilityIdentifier("terraform.plan.copy")
                }
                if case .failed = run.phase { button("Ask Why", "questionmark.bubble") { actions.askWhy(run) } }
                if !run.isGoing { button("Discard", "trash") { actions.discard(run) }.accessibilityIdentifier("terraform.plan.discard") }
                Spacer(minLength: 0)
            }
            if let label = run.mode.label {
                Text(verbatim: "A \(label) plan" + (run.mode.isDestroy ? ": its apply destroys everything listed." : "."))
                    .font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(run.mode.isDestroy ? red : theme.orangeText)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("terraform.plan.mode")
            }
            if let plan = run.plan, !plan.complete, !run.mode.isDestroy {
                Text(verbatim: run.card.isProduction ? "Partial: not applied on production — plan the whole root." : "Partial: only some of the root's changes.")
                    .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.orangeText)
            }
            if let stale = run.staleReason(registry) {
                Text(verbatim: stale).font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(red)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("terraform.plan.stale")
            }
            if let plan = run.plan, !plan.hasPriorState {
                Text(verbatim: "Creates everything: no state found" + (run.workspace == "default" ? "." : " in workspace \(run.workspace)."))
                    .font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(run.workspace == "default" ? theme.orangeText : red)
                    .accessibilityIdentifier("terraform.plan.noState")
            }
            if let plan = run.plan, plan.partlyUnderstood {
                Text(verbatim: "Partly understood: Overterm doesn't read \(plan.unknownKeys.joined(separator: ", ")) — apply it in a terminal.")
                    .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.orangeText).fixedSize(horizontal: false, vertical: true)
            }
            if !run.risks.isEmpty {
                Text(verbatim: "Its code: " + run.risks.prefix(6).map(\.said).joined(separator: "; "))
                    .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.orangeText).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("terraform.plan.risks")
            }
            if let inputs = inputsLine {
                Text(verbatim: inputs).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text3)
                    .lineLimit(2).truncationMode(.tail).accessibilityIdentifier("terraform.plan.inputs")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var headerDetail: String {
        var parts: [String] = ["workspace \(run.workspace)"]
        if let branch = run.branch { parts.append(branch) }
        parts.append(run.isGoing ? "running" : run.age())
        if let profile = run.profile { parts.append("AWS_PROFILE \(profile)") }
        if let region = run.region { parts.append(region) }
        if let agent = run.agent { parts.append("asked by \(agent)") }
        return "· " + parts.joined(separator: " · ")
    }

    /// The inputs that change a plan (2.2): the var files, auto-loaded or
    /// chosen, and the `TF_VAR_` names in its environment — never values.
    private var inputsLine: String? {
        var parts: [String] = []
        let files = run.autoVarFiles + run.varFiles
        if !files.isEmpty { parts.append("var files: " + files.joined(separator: ", ")) }
        if !run.variableNames.isEmpty { parts.append("TF_VAR_: " + run.variableNames.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Running

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: progressText).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2)
                    .accessibilityIdentifier("terraform.plan.progress")
            }
            .padding(.horizontal, 12).padding(.top, 8)
            log
        }
    }

    private var progressText: String {
        if case .waiting(let why) = run.phase { return why }
        if run.phase == .preparing { return "Checking the workspace…" }
        if run.kind == .initialize { return "Initialising… \(Int(Date().timeIntervalSince(run.started))) s" }
        return "Refreshed \(run.refreshed) · planned \(run.plannedChanges) · \(Int(Date().timeIntervalSince(run.started))) s"
    }

    private var log: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(run.log.suffix(400).enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text2)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .accessibilityIdentifier("terraform.plan.log")
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Failed

    @ViewBuilder private func failure(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lock = run.lock {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: lock.said()).font(.system(size: ChromeMetrics.text(12), weight: .semibold)).foregroundStyle(red)
                        .accessibilityIdentifier("terraform.plan.lock")
                    if let note = run.lockNote {
                        Text(verbatim: note).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text2)
                    }
                    Text(verbatim: "Lock ID \(lock.id)" + (lock.http ? " · an http backend" : "")).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                        .foregroundStyle(theme.text3).textSelection(.enabled)
                    HStack(spacing: 6) {
                        button("Wait for It", "hourglass") { actions.planAgain(run, .wait) }.accessibilityIdentifier("terraform.plan.wait")
                        button("Ask Why", "questionmark.bubble") { actions.askWhy(run) }
                    }
                }
            } else {
                Text(verbatim: why).font(.system(size: ChromeMetrics.text(12), weight: .semibold)).foregroundStyle(red)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("terraform.plan.failed")
            }
            if !run.missingVariables.isEmpty { missingVariables(run.offeredVarFiles) }
            ForEach(Array(run.diagnostics.prefix(20).enumerated()), id: \.offset) { _, diagnostic in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(diagnostic.severity == .error ? "Error" : "Warning"): \(diagnostic.summary)")
                        .font(.system(size: ChromeMetrics.text(11.5), weight: .semibold))
                        .foregroundStyle(diagnostic.severity == .error ? red : theme.orangeText)
                    if !diagnostic.detail.isEmpty {
                        Text(verbatim: diagnostic.detail).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let file = diagnostic.file {
                        Button {
                            actions.open(run.card.folder.appendingPathComponent(file), diagnostic.start?.line)
                        } label: {
                            Text(verbatim: "Open at \(file)" + (diagnostic.start.map { ":\($0.line)" } ?? ""))
                                .font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        Divider().opacity(0.4)
        log
    }

    /// The root's var files, offered when a variable has no value (2.2):
    /// read with the run, off the main thread — never in a body.
    private func missingVariables(_ files: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "No value for " + run.missingVariables.joined(separator: ", ") + (files.isEmpty ? ": give one in a .tfvars file of the root." : ". Plan with:"))
                .font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text)
            HStack(spacing: 6) {
                ForEach(files, id: \.self) { file in
                    button(file, "doc.text") { actions.chooseVarFiles(run, [file]) }.accessibilityIdentifier("terraform.plan.varFile.\(file)")
                }
            }
        }
    }

    // MARK: Planned

    private var planned: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterBar
            Divider().opacity(0.4)
            if run.phase == .noChanges {
                message("No changes: the infrastructure matches the configuration.", color: theme.text2)
                    .accessibilityIdentifier("terraform.plan.noChanges")
            }
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(pane.rows) { row in
                            TerraformPlanRowView(
                                row: row, causes: pane.causes(row), expanded: pane.expanded.contains(row.id), selected: pane.selected == row.id,
                                block: pane.block(of: row.address), checkout: run.checkout, theme: theme, actions: actions,
                                plan: { mode in actions.planMode(run, mode) },
                                press: {
                                    pane.toggle(row)
                                    pane.takeKeyboard()
                                }
                            )
                            .equatable()
                            .id(row.id)
                        }
                        outputs
                    }
                    .padding(.bottom, 10)
                }
                .background(
                    TerraformPlanKeyCatcher(
                        request: pane.keyboard,
                        press: { code, characters in
                            guard let key = TerraformPlanPaneModel.key(keyCode: code, characters: characters) else { return false }
                            return pane.press(key, actions: actions)
                        },
                        copy: { pane.copyAddress() })
                )
                .onChange(of: pane.selected) { id in
                    if let id { scroller.scrollTo(id) }
                }
            }
            Text("Masked by Terraform's sensitive marks and Overterm's rules: a value marked sensitive is never shown.")
                .font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3).padding(.horizontal, 12).padding(.vertical, 5)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            TextField("Filter by address", text: $pane.filter).textFieldStyle(.roundedBorder).font(.system(size: ChromeMetrics.text(11)))
                .frame(maxWidth: 220).accessibilityIdentifier("terraform.plan.filter")
                .focused($filterFocused)
                .onChange(of: pane.filterFocus) { _ in filterFocused = true }
            ForEach(TerraformPlanRows.Chip.allCases, id: \.self) { chip in
                Button {
                    pane.toggle(chip)
                } label: {
                    Text(verbatim: chip.rawValue).font(.system(size: ChromeMetrics.text(10.5)))
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(pane.chips.contains(chip) ? theme.selected : theme.iconBg))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(theme.text)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    @ViewBuilder private var outputs: some View {
        if let plan = run.plan, !plan.outputs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("OUTPUTS").font(.system(size: ChromeMetrics.text(10), weight: .semibold)).foregroundStyle(theme.text3)
                ForEach(plan.outputs, id: \.name) { output in
                    Text(verbatim: "\(output.name)  " + (output.sensitive ? "sensitive" : output.after.map { $0.said(cut: 120) } ?? "known after apply"))
                        .font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10)
            .accessibilityIdentifier("terraform.plan.outputs")
        }
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
}

/// One row: its symbol, address and what happens; a replace or delete's
/// cause chain under it; ↩ (or a click) its attributes, before → after.
/// Its values only — it observes no model — so a keystroke in the filter
/// or a row opened redraws the rows that changed, not every row.
private struct TerraformPlanRowView: View, Equatable {
    let row: TerraformPlanRow
    let causes: [TerraformCauseChain.Link]
    let expanded: Bool
    let selected: Bool
    let block: TerraformCauseChain.Location?
    let checkout: URL
    @ObservedObject var theme: ChromeTheme
    let actions: TerraformPlanActions
    /// Plan again with a mode: only this address, or replacing it (2a).
    let plan: (TerraformPlanMode) -> Void
    let press: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.causes == b.causes && a.expanded == b.expanded && a.selected == b.selected && a.block == b.block && a.checkout == b.checkout
    }

    private var color: Color {
        switch row.section {
        case .risky, .actions: TerraformPanelView.production
        case .drift: theme.orangeText
        default: theme.text
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: row.symbol).font(.system(size: ChromeMetrics.text(12), weight: .bold, design: .monospaced)).foregroundStyle(color)
                    .frame(width: 14)
                Text(verbatim: TerraformPlanText.escaped(row.address)).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                    .foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                if row.count > 1 {
                    Text(verbatim: "×\(row.count)").font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).foregroundStyle(theme.text2)
                }
                Text(verbatim: row.what).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(row.section == .risky ? color : theme.text3)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            if !causes.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(causes.enumerated()), id: \.offset) { _, link in
                        if let location = link.location {
                            Button {
                                actions.open(checkout.appendingPathComponent(location.file), location.line)
                            } label: {
                                Text(verbatim: "← " + link.text).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                            }
                            .buttonStyle(.link)
                            if link.changed {
                                Text("changed in this branch").font(.system(size: ChromeMetrics.text(10), weight: .semibold)).foregroundStyle(theme.accentText)
                            }
                        } else {
                            Text(verbatim: "← " + link.text).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text2)
                        }
                    }
                }
                .padding(.leading, 20)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: TerraformCauseChain.said(causes)))
                .accessibilityIdentifier("terraform.plan.cause.\(row.address)")
            }
            if expanded { detail }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(expanded || selected ? theme.rowSel : Color.clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(theme.accentText).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: press)
        .contextMenu {
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.address, forType: .string)
            }
            if let block {
                Button("Open Block") { actions.open(checkout.appendingPathComponent(block.file), block.line) }
            }
            if row.section != .drift, TerraformCommands.isAddress(row.address) {
                Divider()
                Button("Plan Only This (Partial)") { plan(.targets(row.count > 1 ? row.members.map(\.address) : [row.address])) }
                if row.first?.action != .delete, row.first?.mode == "managed" {
                    Button("Plan Replacing This") { plan(.replace(row.count > 1 ? row.members.map(\.address) : [row.address])) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terraform.plan.row.\(row.address)")
    }

    @ViewBuilder private var detail: some View {
        if let change = row.first {
            let diff = TerraformAttributeDiff.lines(change)
            VStack(alignment: .leading, spacing: 1) {
                if row.count > 1 {
                    Text(verbatim: row.members.map(\.address).prefix(50).joined(separator: ", ")).font(.system(size: ChromeMetrics.text(10), design: .monospaced))
                        .foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(diff.lines) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: line.path).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text)
                                .frame(minWidth: 90, alignment: .leading)
                            if line.text == nil {
                                Text(verbatim: (line.before ?? "(none)") + "  →  " + (line.after ?? "(none)"))
                                    .font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text2).lineLimit(3)
                            }
                            if line.forces {
                                Text("forces replacement").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(TerraformPanelView.production)
                            }
                        }
                        if let text = line.text {
                            // A long string, or JSON in a string, diffed by line.
                            ForEach(Array(text.enumerated()), id: \.offset) { _, textLine in
                                Text(verbatim: textLine.said)
                                    .font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                                    .foregroundStyle(textLine.kind == .removed ? TerraformPanelView.production : textLine.kind == .added ? theme.accentText : theme.text3)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                            .padding(.leading, 12)
                        }
                    }
                }
                if diff.unchanged > 0 {
                    Text(verbatim: "\(diff.unchanged) unchanged attribute\(diff.unchanged == 1 ? "" : "s")").font(.system(size: ChromeMetrics.text(10)))
                        .foregroundStyle(theme.text3)
                }
                if let block {
                    Button {
                        actions.open(checkout.appendingPathComponent(block.file), block.line)
                    } label: {
                        Text(verbatim: "\(block.said)  Open block").font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.leading, 20).padding(.top, 3)
            .accessibilityIdentifier("terraform.plan.detail.\(row.address)")
        }
    }
}

/// The plan list's keys (Section 7): an AppKit view behind the rows that
/// takes the keyboard when a row is pressed — SwiftUI's own key handling
/// is macOS 14. Letters reach it only while it is the first responder, so
/// the terminal and the filter field keep theirs. Clicks pass through.
struct TerraformPlanKeyCatcher: NSViewRepresentable {
    /// Bumped by a row's press: take the keyboard.
    let request: Int
    let press: (UInt16, String?) -> Bool
    let copy: () -> String?

    func makeNSView(context: Context) -> TerraformPlanKeyView { TerraformPlanKeyView() }

    func updateNSView(_ view: TerraformPlanKeyView, context: Context) {
        view.press = press
        view.copyText = copy
        guard request != view.request else { return }
        view.request = request
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }
}

final class TerraformPlanKeyView: NSView {
    var press: (UInt16, String?) -> Bool = { _, _ in false }
    var copyText: () -> String? = { nil }
    var request = 0

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty, press(event.keyCode, event.charactersIgnoringModifiers) else { return super.keyDown(with: event) }
    }

    @objc func copy(_ sender: Any?) {
        guard let text = copyText() else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
