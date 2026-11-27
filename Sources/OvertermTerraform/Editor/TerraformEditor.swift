import AppKit

extension EditorBuffer {
    /// A Terraform file: its module folder — validate, Format — and the bar under it.
    package var terraform: TerraformFolder? {
        get { terraformPart as? TerraformFolder }
        set { terraformPart = newValue }
    }
}

extension EditorViewController {
    /// The window: Ask Why on a Terraform folder's failed validate.
    package var terraformHost: TerraformEditorHost? {
        get { terraformHostStorage as? TerraformEditorHost }
        set { terraformHostStorage = newValue }
    }
}

/// Terraform's part in the editor, set once (`OvertermFeatures`).
package enum TerraformEditor {
    package static func install() {
        LanguageServers.terraformEnvironmentStorage = (
            TerraformEnvironment.languageServerAdded(scratch: TerraformGuards.Scratch(folder: AppEnvironment.terraformScratchDirectory)),
            TerraformEnvironment.languageServerRemoved
        )
        LanguageServers.terraformKnownPathStorage = { TerraformCLI.knownBinary()?.path }
        EditorViewController.hooksStorage.didLoad.append { editor in
            editor.observeTerraformDiagnostics()
            editor.observeTerraformTestDiagnostics()
        }
        EditorViewController.hooksStorage.attach.append { editor, buffer in editor.attachTerraform(buffer) }
        EditorViewController.hooksStorage.panel.append { editor, buffer in
            guard let folder = buffer.terraform else { return false }
            editor.showTerraformBar(folder)
            return true
        }
        EditorViewController.hooksStorage.command.append { editor, id, buffer in
            guard id == "terraform.validate" else { return nil }
            guard buffer.terraform != nil else { return false }
            editor.validateTerraform(manual: true)
            return true
        }
        EditorViewController.hooksStorage.format.append { editor, buffer in editor.formatTerraform(buffer, manual: true, then: {}) }
        EditorViewController.hooksStorage.didChange.append { editor, buffer in
            if !buffer.terraformDiagnostics.isEmpty { editor.dropTerraformDiagnostics(buffer) }
        }
        EditorViewController.hooksStorage.didSave.append { editor, buffer in editor.terraformSaved(buffer) }
        // A Terraform file: terraform fmt, only where the checkout already passes fmt -check — never the server's formatter.
        EditorViewController.hooksStorage.saveFormat.append { editor, buffer, save in
            guard let url = buffer.url, TerraformEditorModel.isFormattable(url) else { return nil }
            guard TerraformEditorModel.shared.formatsOnSave(url) else { return .asIs }
            _ = editor.formatTerraform(buffer, then: save)
            return .formatting
        }
        EditorViewController.hooksStorage.symbols.append { editor, buffer in buffer.terraform != nil ? editor.terraformSymbols(buffer) : nil }
        // Terraform without terraform-ls: the module's own index.
        EditorViewController.hooksStorage.definition.append { editor, buffer, index in
            guard buffer.terraform != nil else { return false }
            editor.terraformDefinition(at: index)
            return true
        }
    }
}

/// The editor's way to the window's Ask Agent sheet.
@MainActor
package protocol TerraformEditorHost: AnyObject {
    func askWhy(validateOf folder: TerraformFolder)
    /// Plan, from the editor's bar (TF-U5): asked as the panel's Plan is.
    func planFromEditor(_ card: TerraformRootCard, checkout: URL)
}
