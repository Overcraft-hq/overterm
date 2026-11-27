import SwiftUI

/// The changes pane's Terraform line (TF-G1): the roots the changed files
/// touch, by name — directly or through a module they call — each with
/// Plan, production in its red. Read only while the pane shows changes
/// with a Terraform file among them (`TerraformReviewModel`, the review
/// tab's own read); nothing while there is none.
package struct TerraformChangesLine: View {
    @ObservedObject package var model: TerraformReviewModel
    @ObservedObject package var theme: ChromeTheme
    package let plan: (TerraformReview.Root) -> Void

    package init(model: TerraformReviewModel, theme: ChromeTheme, plan: @escaping (TerraformReview.Root) -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self._theme = ObservedObject(wrappedValue: theme)
        self.plan = plan
    }

    package var body: some View {
        if !model.roots.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Terraform: " + TerraformChangesLine.summary(model.roots))
                    .font(.system(size: ChromeMetrics.text(11), weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .lineLimit(2)
                    .accessibilityIdentifier("diff.terraform.summary")
                ForEach(model.roots) { root in
                    HStack(spacing: 6) {
                        Text(verbatim: root.name)
                            .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                            .foregroundStyle(root.isProduction ? TerraformPanelView.production : theme.text)
                        if root.isProduction {
                            Text(verbatim: "PRODUCTION").font(.system(size: ChromeMetrics.text(9), weight: .bold)).foregroundStyle(TerraformPanelView.production)
                        }
                        Text(verbatim: root.why).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Plan") { plan(root) }
                            .controlSize(.small)
                            .help("Plan \(root.name) — asked first where its class or its code asks")
                            .accessibilityIdentifier("diff.terraform.plan.\(root.path)")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    /// "envs/dev, envs/prod (via modules/network)": each root by name, a
    /// module it is reached through said once. Pure.
    package nonisolated static func summary(_ roots: [TerraformReview.Root]) -> String {
        roots.map { root in
            guard let range = root.why.range(of: "through ") else { return root.name }
            return "\(root.name) (via \(root.why[range.upperBound...]))"
        }.joined(separator: ", ")
    }
}
