import AppKit
import Combine
import SwiftUI

/// A Terraform file in the editor (analysis 4.14, stage 1a): its module
/// folder's bar under the text — Validate, Format, what the last validate
/// said — `terraform fmt` on save where the checkout already passes
/// `fmt -check`, validate's diagnostics on the lines they name, and F12
/// and ⇧⌘O by the module's own index (`TerraformConfigIndex`) where
/// terraform-ls isn't running. Format is an edit (`replaceText`), undoable;
/// nothing is written behind the buffer, and nothing ever runs `init`.
extension EditorViewController {
    func attachTerraform(_ buffer: EditorBuffer) {
        guard let url = buffer.url, buffer.document.unavailable == nil, buffer.sqlConsole == nil, TerraformEditorModel.isTerraform(url) else { return }
        let folder = TerraformEditorModel.shared.folder(for: url)
        buffer.terraform = folder
        folder.attach(buffer)
        TerraformEditorModel.shared.checkFormat(for: folder)
        // terraform-ls is told the terraform Overterm runs: the login shell's PATH, asked off the main thread.
        if Settings.shared.editorLanguageServers, LanguageServers.spec(for: url)?.id == "terraform" { TerraformCLI.warm() }
    }

    /// The bar under a Terraform file's text.
    func showTerraformBar(_ folder: TerraformFolder) {
        consoleHost.rootView = AnyView(
            TerraformEditorBar(
                folder: folder, model: TerraformEditorModel.shared, theme: chrome, title: terraformTitle(folder),
                validate: { [weak self] in self?.validateTerraform(manual: true) },
                format: { [weak self] in
                    guard let self, let buffer = self.active else { return }
                    _ = self.formatTerraform(buffer, manual: true, then: {})
                },
                askWhy: terraformHost == nil
                    ? nil
                    : { [weak self, weak folder] in
                        guard let folder else { return }
                        self?.terraformHost?.askWhy(validateOf: folder)
                    }))
        consoleHeight.constant = TerraformEditorBar.height
    }

    /// The folder as the checkout names it: `envs/dev`.
    private func terraformTitle(_ folder: TerraformFolder) -> String {
        let checkout = folder.checkout.standardizedFileURL.path
        let path = folder.url.standardizedFileURL.path
        if path == checkout { return folder.url.lastPathComponent }
        return path.hasPrefix(checkout + "/") ? String(path.dropFirst(checkout.count + 1)) : path
    }

    // MARK: Validate

    /// Validates the showing file's folder (the bar's button, the palette).
    func validateTerraform(manual: Bool) {
        guard let buffer = active, let folder = buffer.terraform else { return NSSound.beep() }
        // A manual run asks fmt -check again: the checkout may have been formatted since.
        if manual { TerraformEditorModel.shared.checkFormat(for: folder, again: true) }
        // Validate reads the files: what's on screen is saved first, as a
        // person would — and validated once it is written, which format on
        // save may make later than this returns (`terraformSaved`).
        if manual, buffer.document.isDirty {
            buffer.terraformValidatesOnSave = true
            return save(buffer, overwriting: false)
        }
        folder.validate(manual: manual)
    }

    /// After a save: validate where terraform-ls isn't running (it has its
    /// own), and always when the save was Validate's.
    func terraformSaved(_ buffer: EditorBuffer) {
        guard let folder = buffer.terraform, let url = buffer.url else { return }
        if buffer.terraformValidatesOnSave {
            buffer.terraformValidatesOnSave = false
            return folder.validate(manual: true)
        }
        guard LanguageServers.shared.existingServer(for: url) == nil else { return }
        folder.validate(manual: false)
    }

    func observeTerraformDiagnostics() {
        NotificationCenter.default.addObserver(forName: .terraformDiagnostics, object: nil, queue: .main) { [weak self] note in
            guard let folder = note.object as? TerraformFolder else { return }
            MainActor.assumeIsolated { self?.receiveTerraform(folder) }
        }
    }

    private func receiveTerraform(_ folder: TerraformFolder) {
        // Only over the text validate read: a buffer edited since it started
        // keeps no marks (its edit dropped them); its next save validates again.
        for buffer in buffers where buffer.terraform === folder && folder.describes(buffer) {
            guard let url = buffer.url else { continue }
            let text = buffer.storage.string as NSString
            buffer.terraformDiagnostics = folder.diagnostics(for: url).compactMap { diagnostic in
                guard let start = diagnostic.start else { return nil }
                return EditorDiagnostic(
                    range: TerraformValidation.range(from: start, to: diagnostic.end, in: text), severity: diagnostic.severity == .error ? .error : .warning,
                    message: diagnostic.message, source: "terraform validate")
            }
            if buffer === active {
                textView.diagnostics = buffer.diagnostics
                updateProblemLines()
                updateStatus()
            }
        }
    }

    func dropTerraformDiagnostics(_ buffer: EditorBuffer) {
        buffer.terraformDiagnostics = []
        guard buffer === active else { return }
        textView.diagnostics = buffer.diagnostics
        updateProblemLines()
    }

    // MARK: Format

    /// `terraform fmt` over `buffer`'s text, applied as one edit; false
    /// when it isn't a Terraform file (the caller formats some other way).
    /// `done` runs whatever came of it.
    @discardableResult
    func formatTerraform(_ buffer: EditorBuffer, manual: Bool = false, then done: @escaping () -> Void) -> Bool {
        guard let url = buffer.url, TerraformEditorModel.isFormattable(url) else { return false }
        // A manual Format asks fmt -check again, as Validate does.
        if manual, let folder = buffer.terraform { TerraformEditorModel.shared.checkFormat(for: folder, again: true) }
        let version = buffer.version
        let text = buffer.storage.string
        Task { [weak self, weak buffer] in
            let result = await TerraformEditorModel.shared.format(text, file: url)
            defer { done() }
            guard let self, let buffer else { return }
            switch result {
            case .formatted(let formatted):
                buffer.terraform?.formatNote = nil
                // Typed over meanwhile: the newer text wins, unformatted.
                guard buffer.version == version, formatted != text else { return }
                self.replaceText(of: buffer, with: formatted)
            case .failed(let why):
                buffer.terraform?.formatNote = "Not formatted: \(why)"
            case .noTerraform:
                buffer.terraform?.formatNote = "Not formatted: no terraform found"
            }
        }
        return true
    }

    // MARK: Definitions and symbols, without terraform-ls

    /// F12 on `var.x`, `local.x`, `module.y`, `data.t.n`, `t.n`: the
    /// module's index is read and parsed off the main thread
    /// (`TerraformConfigIndex.load`), then the jump is made if the caret
    /// hasn't moved meanwhile.
    func terraformDefinition(at index: Int) {
        guard let buffer = active, let url = buffer.url else { return NSSound.beep() }
        let tfvars = url.pathExtension.lowercased() == "tfvars"
        guard let address = TerraformConfigIndex.reference(at: index, in: buffer.storage.string, tfvars: tfvars) else { return NSSound.beep() }
        let folder = url.standardizedFileURL.deletingLastPathComponent()
        let open = Dictionary(
            buffers.compactMap { buffer in buffer.url.map { ($0.standardizedFileURL.path, buffer.storage.string) } }, uniquingKeysWith: { first, _ in first })
        let version = buffer.version
        Task { [weak self, weak buffer] in
            let definition = await TerraformConfigIndex.loadDefinition(of: address, in: folder, open: open)
            guard let self, let buffer, self.active === buffer, buffer.version == version else { return }
            guard let definition else { return NSSound.beep() }
            let range = definition.nameRange
            self.show(definition.file, selecting: { range })
        }
    }

    /// ⇧⌘O's list and the breadcrumb: the file's blocks, its locals each.
    func terraformSymbols(_ buffer: EditorBuffer) -> [EditorSymbol] {
        guard let url = buffer.url else { return [] }
        return TerraformConfigIndex.definitions(in: buffer.storage.string, file: url).map { definition in
            let name = definition.address.hasPrefix("tfvars.") ? String(definition.address.dropFirst("tfvars.".count)) : definition.address
            return EditorSymbol(name: name, kind: definition.kind, range: definition.range, selection: definition.nameRange, depth: 0)
        }
    }
}

/// The bar under a Terraform file: its folder, Validate, Format, and what
/// the last of them said.
struct TerraformEditorBar: View {
    @ObservedObject var folder: TerraformFolder
    @ObservedObject var model: TerraformEditorModel
    @ObservedObject var theme: ChromeTheme
    let title: String
    let validate: () -> Void
    let format: () -> Void
    /// Ask Why on a failed validate: its diagnostics to the checkout's agent.
    var askWhy: (() -> Void)? = nil

    static let height: CGFloat = 33

    private var failed: Bool {
        if case .problems(let errors, _) = folder.state, errors > 0 { return true }
        return false
    }

    private var formatNote: String? {
        if let note = folder.formatNote { return note }
        guard Settings.shared.terraformFormatOnSave else { return nil }
        switch model.checkoutPassesFormat(folder) {
        case true?: return "Formatted on save"
        case false?: return "Not formatted on save: the checkout doesn't pass terraform fmt -check"
        case nil: return nil
        }
    }

    private var stateColor: Color {
        switch folder.state {
        case .problems(let errors, _) where errors > 0: Color(nsColor: .systemRed)
        case .needsInit, .noTerraform, .failed, .problems: Color(nsColor: .systemOrange)
        case .valid: Color(nsColor: .systemGreen)
        default: theme.dimText
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "Terraform").font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(theme.dimText)
            Text(verbatim: title).font(.system(size: ChromeMetrics.text(12), weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                .truncationMode(.middle)
            Button("Validate") { validate() }
                .disabled(folder.isRunning)
                .help("terraform validate in this folder, with no credential in its environment — it starts the providers, never init")
                .fixedSize()
                .accessibilityIdentifier("terraform.editor.validate")
            Button("Format") { format() }
                .help("terraform fmt over this file, as one edit you can undo  ⇧⌥F")
                .fixedSize()
                .accessibilityIdentifier("terraform.editor.format")
            if !folder.state.text.isEmpty {
                Text(verbatim: folder.state.text).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(stateColor).lineLimit(1)
                    .truncationMode(.tail).help(folder.state.text)
                    .accessibilityIdentifier("terraform.editor.state")
            }
            if failed, let askWhy {
                Button("Ask Why") { askWhy() }
                    .help("Hands validate's errors to the checkout's agent: what's wrong, and what would fix it — never init, plan or apply")
                    .fixedSize()
                    .accessibilityIdentifier("terraform.editor.askWhy")
            }
            Spacer(minLength: 0)
            if let note = formatNote {
                Text(verbatim: note).font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.dimText).lineLimit(1).truncationMode(.tail)
                    .help(note)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.strip)
    }
}
