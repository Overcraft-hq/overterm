import AppKit
import SwiftUI

/// What the state view's buttons do, the window's way.
struct TerraformStateActions {
    /// Read the state again.
    var refresh: (TerraformStateRead) -> Void
    /// An output's offer: the browser column, the Database client's form,
    /// the API environment, the Kubernetes page (2.4).
    var offer: (TerraformOutputLinks.Offer, TerraformState.Output, TerraformStateRead) -> Void
    /// A file of the checkout at a line ("Open block").
    var open: (URL, Int?) -> Void
    var close: () -> Void
}

/// A root's state in the right slot (analysis 2.4, stage 2c): its outputs —
/// a sensitive one says "sensitive", with no Show (5.6 rule 9) — with what
/// each opens in Overterm, then its resources grouped by module, each
/// opening into its attributes as the masked model has them: a value
/// marked sensitive is ••••••, never a value. `state list`'s addresses
/// show at once; the values once `show -json` is read.
struct TerraformStateView: View {
    @ObservedObject var read: TerraformStateRead
    @ObservedObject var theme: ChromeTheme
    let actions: TerraformStateActions
    @State private var filter = ""

    private var red: Color { TerraformPanelView.production }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            switch read.phase {
            case .refused(let why):
                message(why, color: red).accessibilityIdentifier("terraform.state.refused")
            case .failed(let why):
                message(why, color: red).accessibilityIdentifier("terraform.state.failed")
            case .preparing:
                progress("Checking the workspace…")
            default:
                content
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terraform.state")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if read.card.isProduction {
                    Text("PRODUCTION").font(.system(size: ChromeMetrics.text(9.5), weight: .bold)).foregroundStyle(Color.white)
                        .padding(.horizontal, 5).frame(height: 16).background(RoundedRectangle(cornerRadius: 4).fill(red))
                }
                Text(verbatim: "State · " + read.card.name).font(.system(size: ChromeMetrics.text(12.5), weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                Text(verbatim: "· workspace \(read.workspace) · \(read.card.backendSummary) · \(read.isGoing ? "reading" : read.age())")
                    .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(verbatim: countsText).font(.system(size: ChromeMetrics.text(11), weight: .semibold, design: .monospaced)).foregroundStyle(theme.text)
                    .accessibilityIdentifier("terraform.state.counts")
                Button(action: actions.close) { Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(10))) }
                    .buttonStyle(.plain).foregroundStyle(theme.text3).help("Close the pane")
            }
            HStack(spacing: 6) {
                if !read.isGoing {
                    button("Read Again", "arrow.clockwise") { actions.refresh(read) }.accessibilityIdentifier("terraform.state.again")
                }
                TextField("Filter by address", text: $filter).textFieldStyle(.roundedBorder).font(.system(size: ChromeMetrics.text(11)))
                    .frame(maxWidth: 220).accessibilityIdentifier("terraform.state.filter")
                Spacer(minLength: 0)
            }
            if let elsewhere = read.card.stateElsewhere, read.isEmpty {
                Text(verbatim: "No state in this worktree: the state is in \(elsewhere).").font(.system(size: ChromeMetrics.text(11), weight: .semibold))
                    .foregroundStyle(red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var countsText: String {
        let resources = read.addresses.count
        var text = "\(resources) resource\(resources == 1 ? "" : "s")" + (read.capped ? "+" : "")
        if let outputs = read.state?.outputs.count { text += " · \(outputs) output\(outputs == 1 ? "" : "s")" }
        return text
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            list
            Text("Masked by Terraform's sensitive marks and Overterm's rules: a value marked sensitive is never shown.")
                .font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3).padding(.horizontal, 12).padding(.vertical, 5)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if read.phase == .listing {
                    progress("Listing the state…")
                } else if read.phase == .reading {
                    progress("Reading its values…")
                }
                if read.isEmpty {
                    message("No state in workspace \(read.workspace) yet.", color: theme.text2).accessibilityIdentifier("terraform.state.empty")
                }
                outputs
                ForEach(TerraformStateRows.filtered(read.groups, filter: filter)) { group in
                    groupHeader(group)
                    if !read.folded.contains(group.id) {
                        ForEach(group.addresses, id: \.self) { address in
                            resourceRow(address)
                        }
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder private var outputs: some View {
        if let state = read.state, !state.outputs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("OUTPUTS").font(.system(size: ChromeMetrics.text(10), weight: .semibold)).foregroundStyle(theme.text3)
                ForEach(state.outputs) { output in
                    outputRow(output)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terraform.state.outputs")
            Divider().opacity(0.4)
        }
    }

    private func outputRow(_ output: TerraformState.Output) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: output.name).font(.system(size: ChromeMetrics.text(11.5), weight: .semibold, design: .monospaced)).foregroundStyle(theme.text)
                Text(verbatim: output.type).font(.system(size: ChromeMetrics.text(10), design: .monospaced)).foregroundStyle(theme.text3).lineLimit(1)
                if output.sensitive {
                    Text("sensitive").font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).foregroundStyle(theme.orangeText)
                        .help("A sensitive output's value is never shown, and no tool reads one.")
                } else {
                    Text(verbatim: Self.drawn((output.value ?? .null).said(cut: 200))).font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                        .foregroundStyle(theme.text2).lineLimit(2).truncationMode(.tail).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            let offers = TerraformOutputLinks.offers(for: output)
            if !offers.isEmpty {
                HStack(spacing: 6) {
                    ForEach(offers, id: \.self) { offer in
                        button(offer.title, offer.symbol) { actions.offer(offer, output, read) }
                            .accessibilityIdentifier("terraform.state.offer.\(output.name).\(offer.key)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terraform.state.output.\(output.name)")
    }

    private func groupHeader(_ group: TerraformStateRows.Group) -> some View {
        Button {
            if read.folded.contains(group.id) { read.folded.remove(group.id) } else { read.folded.insert(group.id) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: read.folded.contains(group.id) ? "chevron.right" : "chevron.down").font(.system(size: ChromeMetrics.text(9)))
                Text(verbatim: group.title).font(.system(size: ChromeMetrics.text(10.5), weight: .semibold, design: .monospaced))
                Text(verbatim: "\(group.addresses.count)").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(theme.text2)
    }

    @ViewBuilder private func resourceRow(_ address: String) -> some View {
        let resource = read.resource(address)
        let open = read.expanded.contains(address)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if open { read.expanded.remove(address) } else { read.expanded.insert(address) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: ChromeMetrics.text(8.5))).foregroundStyle(theme.text3)
                    Text(verbatim: address).font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    if resource?.isData == true {
                        Text("data").font(.system(size: ChromeMetrics.text(9.5))).foregroundStyle(theme.text3)
                    }
                    if resource?.tainted == true {
                        Text("tainted").font(.system(size: ChromeMetrics.text(9.5), weight: .semibold)).foregroundStyle(theme.orangeText)
                            .help("The next apply replaces it.")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).frame(minHeight: ChromeMetrics.row(20)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { detail(address, resource) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terraform.state.resource.\(address)")
    }

    @ViewBuilder private func detail(_ address: String, _ resource: TerraformState.Resource?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let resource {
                Text(verbatim: "\(resource.type) · \(resource.provider)" + (resource.deposed.map { " · deposed \($0)" } ?? ""))
                    .font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
                ForEach(TerraformStateRows.attributes(resource), id: \.name) { attribute in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: attribute.name).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text2)
                            .frame(minWidth: 110, alignment: .leading)
                        Text(verbatim: attribute.value == "(sensitive)" ? TerraformPlan.redaction + "  sensitive" : Self.drawn(attribute.value))
                            .font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                            .foregroundStyle(attribute.value == "(sensitive)" ? theme.orangeText : theme.text).lineLimit(3).truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                }
                if !resource.dependsOn.isEmpty {
                    Text(verbatim: "depends on " + resource.dependsOn.prefix(8).joined(separator: ", ")).font(.system(size: ChromeMetrics.text(10)))
                        .foregroundStyle(theme.text3).lineLimit(2)
                }
            } else {
                Text(read.isGoing ? "Reading its values…" : "Not in the state's values.").font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
            }
            if let location = read.block(of: address) {
                Button {
                    actions.open(read.checkout.appendingPathComponent(location.file), location.line)
                } label: {
                    Text(verbatim: "Open block · \(location.said)").font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                }
                .buttonStyle(.link)
            }
        }
        .padding(.leading, 30).padding(.trailing, 12).padding(.bottom, 6)
    }

    // MARK: Pieces

    /// A value as drawn: a sensitive one inside it is ••••••, as the plan's are.
    static func drawn(_ said: String) -> String { said.replacingOccurrences(of: "(sensitive)", with: TerraformPlan.redaction) }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(verbatim: text).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityIdentifier("terraform.state.progress")
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
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
