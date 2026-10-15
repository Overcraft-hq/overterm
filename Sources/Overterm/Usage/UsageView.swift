import SwiftUI

/// The usage pane: what each agent has left of its quota, and what the
/// logs on this Mac say the day cost.
struct UsageView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var theme: ChromeTheme
    @ObservedObject var settings: Settings
    let onClose: () -> Void

    private var showsCost: Bool { settings.usageCost }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.providers.isEmpty {
                placeholder
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if showsCost { scope }
                        ForEach(model.providers) { provider in
                            card(provider)
                        }
                        if showsCost, model.providers.count > 1 { total }
                        footnote
                    }
                    .padding(12)
                }
            }
        }
        .background(theme.strip)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Usage").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
            if model.isRefreshing { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12) }
            Spacer(minLength: 0)
            Button(action: { model.refresh(force: true) }) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Ask the agents again")
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.needle").font(.system(size: 20)).foregroundStyle(theme.text3)
            Text("Nothing to track yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text2)
            Text("Claude Code and Codex are read from their own logs on this Mac. Run one and its limits show up here.")
                .font(.system(size: 11))
                .foregroundStyle(theme.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Spacer()
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }

    private var scope: some View {
        Picker("", selection: $model.scope) {
            ForEach(UsageScope.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func card(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: snapshot.provider.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(snapshot.provider.tint)
                    .frame(width: 16)
                Text(verbatim: snapshot.provider.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                if let plan = snapshot.plan {
                    Text(verbatim: plan.capitalized)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.text2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.iconBg))
                }
                Spacer(minLength: 0)
                if let asOf = snapshot.metersAsOf {
                    Text(verbatim: UsageFormat.age(asOf))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.text3)
                        .help("What the provider last wrote down. It only refreshes while the agent runs.")
                }
            }
            ForEach(snapshot.meters) { meter in
                bar(meter)
            }
            if snapshot.isStale(), let asOf = snapshot.metersAsOf {
                Text(
                    verbatim: snapshot.provider == .claude
                        ? "Every window above ended after Claude wrote these down \(UsageFormat.age(asOf)). It only writes them when it asks — /usage in Claude Code refreshes them."
                        : "Written \(UsageFormat.age(asOf)); every window above has started again since."
                )
                .font(.system(size: 10))
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let note = snapshot.note {
                Text(verbatim: note).font(.system(size: 10)).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            if showsCost { spend(snapshot.spend) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.border))
    }

    private func bar(_ meter: UsageMeter) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: meter.name).font(.system(size: 11)).foregroundStyle(theme.text2)
                Spacer(minLength: 0)
                if let used = meter.usedDollars, let limit = meter.limitDollars {
                    Text(verbatim: "\(UsageFormat.money(used)) of \(UsageFormat.money(limit))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.text3)
                }
                Text(verbatim: meter.reading())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(colour(meter))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.segIdle.opacity(0.35))
                    Capsule().fill(colour(meter)).frame(width: max(0, geometry.size.width * meter.fraction()))
                }
            }
            .frame(height: 5)
            Text(verbatim: meter.resets()).font(.system(size: 10)).foregroundStyle(theme.text3)
        }
    }

    private func colour(_ meter: UsageMeter) -> Color {
        switch meter.level() {
        case .easy: theme.accentText
        case .close: theme.orangeText
        case .spent: TabStatusStyle.failed
        }
    }

    @ViewBuilder private func spend(_ spend: UsageSpend) -> some View {
        if spend.tokens.total > 0 {
            HStack(spacing: 6) {
                if let dollars = spend.dollars {
                    Text(verbatim: UsageFormat.money(dollars))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.text)
                }
                Text(verbatim: "\(TabInfoView.tokens(spend.tokens.total)) tokens")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.text2)
                Text(verbatim: "· everything on this Mac")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.text3)
                Spacer(minLength: 0)
                if !spend.models.isEmpty {
                    Text(verbatim: spend.models.map(ModelPricing.shortName).joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.text3)
                        .lineLimit(1)
                }
            }
            if spend.unpriced > 0 {
                Text(verbatim: "\(TabInfoView.tokens(spend.unpriced)) tokens of a model with no price here")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.text3)
            }
        }
    }

    @ViewBuilder private var total: some View {
        let spend = model.providers.map(\.spend).reduce(UsageSpend(), +)
        if let dollars = spend.dollars {
            HStack {
                Text(verbatim: "\(model.scope.title), both").font(.system(size: 11)).foregroundStyle(theme.text2)
                Spacer(minLength: 0)
                Text(verbatim: UsageFormat.money(dollars))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text)
            }
            .padding(.horizontal, 10)
        }
    }

    private var footnote: some View {
        Text(
            verbatim: showsCost
                ? "The percentages are the providers' own. The money is this Mac's logs at list API prices — an estimate, not your bill."
                : "The percentages are the providers' own, read from their logs on this Mac."
        )
        .font(.system(size: 10))
        .foregroundStyle(theme.text3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }
}
