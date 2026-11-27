import AppKit

/// Var Files… (TF-U4): the root's `.tfvars` ticked for its plans before any
/// plan has failed for want of one — several at once, None clearing them —
/// from its card, its menu, and the plan's inputs line.
extension TerminalWindowController {
    package func chooseTerraformVarFiles(_ card: TerraformRootCard, checkout: URL? = nil) {
        guard let checkout = checkout ?? terraformPanel.checkout else { return NSSound.beep() }
        let folder = card.folder
        Task { @MainActor [weak self] in
            let choosable = await Task.detached { TerraformRootStore.choosable(in: folder) }.value
            guard let self else { return }
            let current = TerraformRootStore.shared.varFiles(checkout: checkout, root: card.path)
            let chosen: [String]?
            if let recorder = self.terraformVarFilesRecorder {
                chosen = recorder(choosable, current)
            } else {
                chosen = await self.askVarFiles(card.name, choosable: choosable, current: current)
            }
            guard let chosen else { return }
            // Only the root's own files, as it lists them now.
            TerraformRootStore.shared.setVarFiles(chosen.filter(choosable.contains), checkout: checkout, root: card.path)
            self.terraformPanel.objectWillChange.send()
        }
    }

    /// The sheet: a box a file, ticked as chosen now; Use, None, Cancel.
    /// What was ticked, [] for None, nil for Cancel.
    private func askVarFiles(_ root: String, choosable: [String], current: [String]) async -> [String]? {
        let alert = NSAlert()
        alert.messageText = "Var files for \(root)'s plans"
        alert.informativeText =
            choosable.isEmpty
            ? "\(root) has no .tfvars of its own besides the ones every run loads (terraform.tfvars, *.auto.tfvars)."
            : "Ticked files are passed with -var-file, in this order, to every plan of this root here. terraform.tfvars and *.auto.tfvars load anyway."
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "None")
        let boxes = choosable.map { name -> NSButton in
            let box = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            box.state = current.contains(name) ? .on : .off
            return box
        }
        if !boxes.isEmpty {
            let stack = NSStackView(views: boxes)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            stack.frame = NSRect(origin: .zero, size: NSSize(width: 320, height: stack.fittingSize.height))
            alert.accessoryView = stack
        }
        guard let window else { return nil }
        let response = await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        switch response {
        case .alertFirstButtonReturn: return boxes.filter { $0.state == .on }.map(\.title)
        case .alertThirdButtonReturn: return []
        default: return nil
        }
    }
}
