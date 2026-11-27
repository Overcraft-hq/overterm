import AppKit
import SwiftUI

/// A root's validate from its card (TF-U11): the folder the editor's bar
/// validates, made from any configuration file in it — `.tf`, `.tf.json`
/// or `.tofu`, as `TerraformRoots` counts them —, and its result as a line
/// on the card.
@MainActor
package enum TerraformRootValidation {
    /// The root's folder to validate, or nil when nothing in it is configuration.
    package static func folder(of card: TerraformRootCard) -> TerraformFolder? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: card.folder.path)) ?? []).sorted()
        guard let name = names.first(where: { $0 == "main.tf" }) ?? names.first(where: isConfiguration) else { return nil }
        return TerraformEditorModel.shared.folder(for: card.folder.appendingPathComponent(name))
    }

    package nonisolated static func isConfiguration(_ name: String) -> Bool {
        name.hasSuffix(".tf") || name.hasSuffix(".tf.json") || name.hasSuffix(".tofu") || name.hasSuffix(".tofu.json")
    }

    /// The first file the last validate found an error in, else a warning's.
    package static func firstProblem(_ folder: TerraformFolder) -> (URL, Int?)? {
        let all = folder.allDiagnostics
        guard let first = all.first(where: { $0.severity == .error }) ?? all.first, let file = first.file else { return nil }
        return (folder.url.appendingPathComponent(file), first.start?.line)
    }
}

/// "validate: 2 errors" on the card; a press opens the first failing file.
package struct TerraformValidateLineView: View {
    @ObservedObject package var folder: TerraformFolder
    @ObservedObject package var theme: ChromeTheme
    package let open: (URL, Int?) -> Void

    package init(folder: TerraformFolder, theme: ChromeTheme, open: @escaping (URL, Int?) -> Void) {
        self.folder = folder
        self.theme = theme
        self.open = open
    }

    private var color: Color {
        switch folder.state {
        case .problems(let errors, _) where errors > 0: TerraformPanelView.production
        case .problems, .needsInit, .failed, .noTerraform: theme.orangeText
        default: theme.text2
        }
    }

    package var body: some View {
        if folder.state != .idle {
            Button {
                if let (file, line) = TerraformRootValidation.firstProblem(folder) { open(file, line) }
            } label: {
                Text(verbatim: "validate: \(folder.state.text)").font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                    .foregroundStyle(color).lineLimit(2).truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .help(TerraformRootValidation.firstProblem(folder) == nil ? folder.state.text : "Open the first file it found a problem in")
        }
    }
}
