import SwiftUI

/// What the review's Terraform section asks the window to do.
struct TerraformReviewActions {
    /// Plan a touched root in the checkout with the head: always asked (5.5).
    var plan: (ReviewModel, TerraformReview.Root) -> Void = { _, _ in }
    var initialize: (ReviewModel, TerraformReview.Root) -> Void = { _, _ in }
    /// The plan in the right slot, the review page put aside.
    var show: (TerraformPlanRun) -> Void = { _ in }
    /// "Post to Pull Request…": the comment shown first.
    var post: (ReviewModel) -> Void = { _ in }
    /// The head in a new worktree, when no checkout has it.
    var checkOut: (ReviewModel) -> Void = { _ in }
    /// Whether the review has a pull request to post to.
    var pullRequest: (ReviewModel) -> Int? = { _ in nil }
}

/// The review's Terraform section (stage 2f): "what will this change do in
/// the cloud", above its diff — the roots it touches, their class, why,
/// and each one's latest plan in the checkout with the head.
struct TerraformReviewSectionView: View {
    @ObservedObject var review: ReviewModel
    @ObservedObject var model: TerraformReviewModel
    @ObservedObject var registry = TerraformRunRegistry.shared
    @ObservedObject var theme: ChromeTheme
    let actions: TerraformReviewActions

    var body: some View {
        if !model.roots.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                if model.expanded {
                    if let note = model.head?.note {
                        line(note, color: TerraformPanelView.remote).padding(.horizontal, 16).padding(.bottom, 4)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.roots) { root in
                                TerraformReviewRow(
                                    review: review, root: root, run: run(root), model: model, theme: theme, actions: actions)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Rectangle().fill(theme.border).frame(height: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review.terraform")
        }
    }

    private func run(_ root: TerraformReview.Root) -> TerraformPlanRun? {
        guard let head = model.head else { return nil }
        return registry.latest(checkout: head.checkout.url, root: root.path)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                model.expanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.expanded ? "chevron.down" : "chevron.right").font(.system(size: ChromeMetrics.text(9)))
                    Image(systemName: "square.stack.3d.up").font(.system(size: ChromeMetrics.text(11)))
                    Text(verbatim: "Terraform · \(model.roots.count) root\(model.roots.count == 1 ? "" : "s") touched")
                        .font(.system(size: ChromeMetrics.text(11.5), weight: .semibold))
                    let production = model.roots.filter(\.isProduction).count
                    if production > 0 {
                        Text(verbatim: "\(production) PRODUCTION").font(.system(size: ChromeMetrics.text(9.5), weight: .bold)).foregroundStyle(Color.white)
                            .padding(.horizontal, 5).frame(height: 16)
                            .background(RoundedRectangle(cornerRadius: 4).fill(TerraformPanelView.production))
                    }
                }
                .foregroundStyle(theme.text2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("review.terraform.fold")
            Text(verbatim: where_).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if model.head == nil {
                Button(model.checkingOut ? "Checking Out…" : "Check Out in a New Worktree…") { actions.checkOut(review) }
                    .controlSize(.small)
                    .disabled(model.checkingOut)
                    .help("Its head isn't checked out anywhere: a plan needs its files. Nothing is planned until you press Plan, which asks first")
                    .accessibilityIdentifier("review.terraform.checkout")
            }
            if let number = actions.pullRequest(review), model.head != nil {
                Button("Post to Pull Request…") { actions.post(review) }
                    .controlSize(.small)
                    .disabled(!model.canPost(registry))
                    .help("A comment on #\(number) with each root's latest plan at its head, masked — shown before it is posted")
                    .accessibilityIdentifier("review.terraform.post")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: ChromeMetrics.row(32))
    }

    private var where_: String {
        if let head = model.head { return "plans run in \(head.checkout.name) (\(head.checkout.url.path))" }
        return "its head isn't checked out: roots as in this checkout"
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}

/// One touched root: its class band, name, why, and its latest plan there.
private struct TerraformReviewRow: View {
    @ObservedObject var review: ReviewModel
    let root: TerraformReview.Root
    let run: TerraformPlanRun?
    @ObservedObject var model: TerraformReviewModel
    @ObservedObject var theme: ChromeTheme
    let actions: TerraformReviewActions

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Rectangle().fill(TerraformPanelView.color(root.rootClass, theme: theme)).frame(width: 3, height: 26)
            Text(verbatim: root.name).font(.system(size: ChromeMetrics.text(12), weight: .semibold, design: .monospaced)).foregroundStyle(theme.text)
                .lineLimit(1)
            Text(verbatim: root.rootClass.title.uppercased()).font(.system(size: ChromeMetrics.text(9.5), weight: .bold))
                .foregroundStyle(root.rootClass == .local ? theme.text2 : Color.white)
                .padding(.horizontal, 5).frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(root.rootClass == .local ? theme.rowSel : TerraformPanelView.color(root.rootClass, theme: theme)))
            Text(verbatim: root.why).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text3)
                .lineLimit(1).truncationMode(.middle)
            if !root.present {
                Text(verbatim: "new in this review").font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
            }
            Spacer(minLength: 8)
            if let run { TerraformReviewPlanCell(run: run, theme: theme, show: { actions.show(run) }) }
            if model.head != nil {
                if model.cards[root.path]?.facts.needsInit == true {
                    Button("Init…") { actions.initialize(review, root) }.controlSize(.small)
                        .accessibilityIdentifier("review.terraform.init.\(root.path)")
                }
                Button(run == nil ? "Plan…" : "Plan Again…") { actions.plan(review, root) }
                    .controlSize(.small)
                    .disabled(run?.isGoing == true || model.cards[root.path] == nil || model.head?.isReviewed == false)
                    .help(
                        model.head?.note
                            ?? "Plans the reviewed code: asked first, with what it runs or reaches — a plan runs it with your credentials"
                    )
                    .accessibilityIdentifier("review.terraform.plan.\(root.path)")
            } else {
                Text(verbatim: "not checked out").font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(root.name), \(root.rootClass.title), \(root.why)"))
        .accessibilityIdentifier("review.terraform.root.\(root.path)")
    }
}

/// A root's latest plan in the head's checkout: its counts, age and
/// staleness, or where it stands while it runs; pressed, the plan.
private struct TerraformReviewPlanCell: View {
    @ObservedObject var run: TerraformPlanRun
    @ObservedObject var theme: ChromeTheme
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            HStack(spacing: 5) {
                Text(verbatim: said).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                if let stale = run.staleReason(.shared) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(TerraformPanelView.remote).help("Stale: " + stale)
                }
            }
            .foregroundStyle(theme.text2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(run.plan?.counts.sentence ?? "Show the plan")
    }

    private var said: String {
        switch run.phase {
        case .preparing, .running: return "planning…"
        case .waiting: return "waiting for the state"
        case .planned, .noChanges:
            guard let plan = run.plan else { return "planned" }
            return plan.counts.bar + " · " + run.age()
        case .failed: return "plan failed"
        case .refused: return "refused"
        case .stopped: return "stopped"
        case .tooLarge: return "too large to show"
        }
    }
}
