import AppKit

/// Terraform stage 1a (docs/design/terraform/analysis.md 4.14, 9): a `.tf`
/// file coloured, `terraform validate`'s diagnostic at its line, Format
/// undoable, format on save only where the checkout already passes
/// `fmt -check`, F12 and ⇧⌘O without terraform-ls — and the checkout byte
/// for byte the same after validate (no lock file, no `.terraform`).
///
/// The real terraform (`OVERTERM_TERRAFORM`, which the test names) runs
/// behind the recording wrapper, in the guarded environment — a scratch
/// HOME and CLI config that fetches nothing, proxies at a dead port — over
/// checkouts this scenario writes, `terraform_data` only. Without one the
/// scenario says SKIP, loudly.
extension E2ERunner {
    func terraformScenario() async {
        guard case .variable(let binary) = AppEnvironment.terraformBinary else {
            print("E2E SKIP terraform: no OVERTERM_TERRAFORM — the test names the installed terraform")
            return
        }
        guard let recorder = try? TerraformRecorder.make(in: out("terraform-recorder"), target: binary) else {
            return check("the recording wrapper is made", false)
        }
        TerraformCLI.scenarioWrapper = recorder.wrapper
        defer { TerraformCLI.scenarioWrapper = nil }

        // A checkout whose files pass `terraform fmt -check`, with one error.
        let checkout = out("acme-infra")
        let dev = checkout.appendingPathComponent("envs/dev", isDirectory: true)
        let main = dev.appendingPathComponent("main.tf")
        let variables = dev.appendingPathComponent("variables.tf")
        let mainText = """
            # The acme dev environment.
            locals {
              acme_tags = { team = "acme" }
            }

            resource "terraform_data" "acme" {
              input = var.acme_nme
            }

            output "acme_input" {
              value = terraform_data.acme.output
            }

            """
        do {
            try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
            try mainText.write(to: main, atomically: true, encoding: .utf8)
            try "variable \"acme_name\" {\n  type    = string\n  default = \"acme-dev\"\n}\n".write(to: variables, atomically: true, encoding: .utf8)
            try "acme_name = \"acme-dev\"\n".write(to: dev.appendingPathComponent("dev.tfvars"), atomically: true, encoding: .utf8)
            _ = try Git.runBlocking(URL(fileURLWithPath: "/usr/bin/git"), ["init", "-q"], in: checkout, success: [0], timeout: 10)
        } catch {
            return check("the checkout is written", false, "\(error)")
        }

        app.openInEditor(main)
        guard let editor = app.editor else { return check("editor exists", false) }
        check("main.tf opens", await eventually(3) { editor.active?.url?.lastPathComponent == "main.tf" })
        guard let buffer = editor.active, let textView = Self.find(NSTextView.self, in: editor.view, where: { _ in true }) else {
            return check("its text view", false)
        }
        check("it is HCL", buffer.language?.id == "hcl", buffer.language?.id ?? "none")

        // Colours come from tree-sitter's HCL grammar, off the main thread.
        let text = mainText as NSString
        let colored = await eventually(4) {
            guard let storage = textView.textStorage, storage.length == text.length else { return false }
            let string = storage.attribute(.foregroundColor, at: text.range(of: "terraform_data").location, effectiveRange: nil) as? NSColor
            let comment = storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
            let equals = storage.attribute(.foregroundColor, at: text.range(of: " = var").location + 1, effectiveRange: nil) as? NSColor
            return string != nil && comment != nil && string != equals && comment != equals && string != comment
        }
        check("a .tf file is coloured: strings, comments, plain text apart", colored)

        check("the Terraform bar is under it", buffer.terraform != nil && editor.consoleHeight.constant == TerraformEditorBar.height)
        Self.accessibilityTree(true)
        defer { Self.accessibilityTree(false) }
        check("with Validate", await eventually(2) { Self.accessibilityPress("terraform.editor.validate", in: editor.view, press: false) })

        // Opening it asked fmt -check of the checkout, once: it passes.
        check("the checkout passes fmt -check", await eventually(15) { TerraformEditorModel.shared.checkoutPassesFormat(main) == true })
        let realCheckout = realPath(checkout)
        let checks = recorder.calls().filter { $0.arguments == TerraformCommands.formatCheck }
        check("fmt -check ran once, at the checkout's top", checks.count == 1 && checks.first?.cwd == realCheckout, "\(checks)")

        // Validate: the diagnostic at its line, the checkout untouched.
        let before = snapshot(checkout)
        editor.perform("terraform.validate")
        let folder = buffer.terraform
        check(
            "validate finds the misspelt variable", await eventually(30) { folder?.state == .problems(errors: 1, warnings: 0) },
            "\(String(describing: folder?.state))")
        let marked = buffer.terraformDiagnostics.map { text.substring(with: $0.range) }
        check("its diagnostic is on line 7, under var.acme_nme", marked == ["var.acme_nme"], "\(marked)")
        check(
            "the text view shows it", textView is CodeTextView && (textView as? CodeTextView)?.diagnostics.contains { $0.source == "terraform validate" } == true)
        check(
            "saying what terraform said",
            buffer.terraformDiagnostics.first?.message.hasPrefix("Reference to undeclared input variable") == true,
            buffer.terraformDiagnostics.first?.message ?? "")
        let after = snapshot(checkout)
        check("the checkout is byte for byte the same after validate", before == after, "\(Set(after.keys).symmetricDifference(before.keys))")
        check(
            "no lock file, no .terraform",
            !FileManager.default.fileExists(atPath: dev.appendingPathComponent(".terraform.lock.hcl").path)
                && !FileManager.default.fileExists(atPath: dev.appendingPathComponent(".terraform").path))
        let validates = recorder.calls().filter { $0.subcommand == "validate" }
        let call = validates.last
        check("validate ran in the module's folder", validates.count == 1 && call?.cwd == realPath(dev), "\(validates.map(\.cwd))")
        check("as `validate -json -no-color`", call?.arguments == TerraformCommands.validate, "\(call?.arguments ?? [])")
        check(
            "with no credential, a scratch HOME and CLI config, no call home",
            call.map { TerraformGuards.credentials(in: Dictionary(uniqueKeysWithValues: $0.names.map { ($0, "") })).isEmpty } == true
                && call?.values["HOME"] == AppEnvironment.terraformScratchDirectory.appendingPathComponent("home").path
                && call?.values["CHECKPOINT_DISABLE"] == "1" && call?.values["TF_DATA_DIR"] == dev.appendingPathComponent(".terraform").path
                && call?.values["TF_WORKSPACE"] == nil,
            "\(call?.names ?? []) \(call?.values ?? [:])")

        // F12 on var.acme_nme's neighbour, fixed: to its variable block in the other file.
        editor.replaceText(of: buffer, with: mainText.replacingOccurrences(of: "acme_nme", with: "acme_name"))
        check("an edit drops validate's marks, which no longer describe it", buffer.terraformDiagnostics.isEmpty)
        let fixed = buffer.storage.string as NSString
        textView.setSelectedRange(NSRange(location: fixed.range(of: "var.acme_name").location + 6, length: 0))
        editor.perform("editor.goToDefinition")
        check(
            "F12 on var.acme_name opens its variable block, without terraform-ls",
            await eventually(3) {
                editor.active?.url?.lastPathComponent == "variables.tf"
                    && (textView.string as NSString).substring(with: textView.selectedRange()) == "acme_name"
            }, "\(editor.active?.url?.lastPathComponent ?? "") \(textView.selectedRange())")
        app.openInEditor(main)
        check("back to main.tf", await eventually(2) { editor.active === buffer })
        var symbols: [EditorSymbol]?
        editor.loadSymbols(buffer) { symbols = $0 }
        check(
            "⇧⌘O lists its blocks and locals", await eventually(2) { symbols?.map(\.name) == ["local.acme_tags", "terraform_data.acme", "output.acme_input"] },
            "\(symbols?.map(\.name) ?? [])")

        // Format: one edit, undone by one undo.
        let messy = (buffer.storage.string).replacingOccurrences(of: "  input = var.acme_name", with: "  input     =    var.acme_name")
        editor.replaceText(of: buffer, with: messy)
        await pause(0.2)
        editor.perform("editor.format")
        check(
            "Format runs terraform fmt over the buffer", await eventually(10) { buffer.storage.string.contains("\n  input = var.acme_name\n") },
            buffer.storage.string)
        check("Format wrote nothing", (try? String(contentsOf: main, encoding: .utf8)) == mainText)
        await pause(0.2)
        buffer.undo.undo()
        check("one undo takes it back", buffer.storage.string == messy, buffer.storage.string)

        // A syntax error: not formatted, and said.
        editor.replaceText(of: buffer, with: messy + "locals {\n  broken = \n")
        await pause(0.2)
        editor.perform("editor.format")
        check(
            "a file that doesn't parse isn't formatted, and the bar says why",
            await eventually(10) { folder?.formatNote?.hasPrefix("Not formatted: line ") == true }, folder?.formatNote ?? "")
        check("its text left as it was", buffer.storage.string.hasSuffix("broken = \n"))

        // Save: formatted (the checkout passes), then validated (no terraform-ls here).
        editor.replaceText(of: buffer, with: messy)
        editor.saveDocument(nil)
        check(
            "saving formats it first, where the checkout passes fmt -check",
            await eventually(10) { (try? String(contentsOf: main, encoding: .utf8))?.contains("\n  input = var.acme_name\n") == true })
        check("and validates its folder: valid now", await eventually(30) { folder?.state == .valid(warnings: 0) }, "\(String(describing: folder?.state))")
        check("its marks gone", buffer.terraformDiagnostics.isEmpty)

        // A line typed while validate runs: its answer describes the file
        // as saved, so it isn't laid over the text on screen.
        let broken = buffer.storage.string.replacingOccurrences(of: "input = var.acme_name", with: "input = var.acme_nme")
        editor.replaceText(of: buffer, with: broken)
        editor.saveDocument(nil)
        check("the misspelling is saved", await eventually(10) { (try? String(contentsOf: main, encoding: .utf8)) == broken })
        let running = folder?.state == .running
        let typed = "# acme: a line typed while validate ran\n" + broken
        editor.replaceText(of: buffer, with: typed)
        check("validate was running when the line was typed", running, "\(String(describing: folder?.state))")
        check("it finishes", await eventually(30) { folder?.state == .problems(errors: 1, warnings: 0) }, "\(String(describing: folder?.state))")
        check("its marks aren't laid over text edited while it ran", buffer.terraformDiagnostics.isEmpty, "\(buffer.terraformDiagnostics)")

        // Validate with edits: saved first, validated once written — the mark where the text on screen has it.
        editor.perform("terraform.validate")
        let typedText = typed as NSString
        check(
            "Validate saves the edits, then validates what was written",
            await eventually(30) { buffer.terraformDiagnostics.map { typedText.substring(with: $0.range) } == ["var.acme_nme"] && buffer.storage.string == typed },
            "\(buffer.terraformDiagnostics.map(\.range))")
        check("the file has the typed line", (try? String(contentsOf: main, encoding: .utf8)) == typed)

        // A checkout that doesn't pass fmt -check is never reformatted on save.
        let loose = out("globex-loose")
        let looseFile = loose.appendingPathComponent("main.tf")
        try? FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        let looseText = "resource \"terraform_data\" \"globex\" {\n  input     =    \"globex\"\n}\n"
        try? looseText.write(to: looseFile, atomically: true, encoding: .utf8)
        _ = try? Git.runBlocking(URL(fileURLWithPath: "/usr/bin/git"), ["init", "-q"], in: loose, success: [0], timeout: 10)
        app.openInEditor(looseFile)
        check("its fmt -check fails", await eventually(15) { TerraformEditorModel.shared.checkoutPassesFormat(looseFile) == false })
        if let looseBuffer = editor.active, looseBuffer.url?.lastPathComponent == "main.tf", looseBuffer !== buffer {
            editor.replaceText(of: looseBuffer, with: looseText + "# globex\n")
            editor.saveDocument(nil)
            await pause(1)
            check(
                "saved as typed, not reformatted", (try? String(contentsOf: looseFile, encoding: .utf8)) == looseText + "# globex\n",
                (try? String(contentsOf: looseFile, encoding: .utf8)) ?? "")
        } else {
            check("the second checkout's file shows", false)
        }

        // Every terraform the editor started: one of its lines, in a scenario folder, no credential.
        let calls = recorder.calls()
        check(
            "every call is a line the editor builds, inside this run's folders",
            !calls.isEmpty && calls.allSatisfy { TerraformCommands.all.contains($0.arguments) && $0.cwd.hasPrefix(realPath(scratch)) },
            "\(calls.map { "\($0.arguments) @ \($0.cwd)" })")
        check("none ran init", !calls.contains { $0.subcommand == "init" })
    }

    /// Every file under `folder` but `.git`'s, by path, with its bytes.
    private func snapshot(_ folder: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return found }
        for case let url as URL in walker {
            let relative = String(url.path.dropFirst(folder.path.count))
            if relative.hasPrefix("/.git") { continue }
            found[relative] = (try? Data(contentsOf: url)) ?? Data()
        }
        return found
    }

    func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
