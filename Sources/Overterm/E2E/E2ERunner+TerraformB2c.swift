import AppKit

/// Terraform stage 2c (docs/design/terraform/analysis.md 2.4, 5.6, 9):
/// state and outputs, masked. A root's state in the right slot — `state
/// list`'s addresses grouped by module, then `show -json`'s values — its
/// outputs with what they open in Overterm; a sensitive output says
/// "sensitive" and is never valued: not in the model, the view's
/// accessibility text, or what `tf_outputs`, `tf_state_show` and
/// `tf_state_list` give an agent — nor its value copied into an output or
/// an attribute nothing marks. Overterm runs only `state list` and
/// `show -json` there, in the workspace it checked.
///
/// The real terraform behind the recording wrapper, in the guarded
/// environment, over a checkout this scenario writes, `terraform_data`
/// only, its state made by the CLI first. Called from the `terraform`
/// scenario, which skips without one.
extension E2ERunner {
    func terraformStateB2c(binary: String) async {
        guard let recorder = try? TerraformRecorder.make(in: out("terraform-state-recorder"), target: binary) else {
            return check("state: the recording wrapper is made", false)
        }
        let wrapper = TerraformCLI.scenarioWrapper
        TerraformCLI.scenarioWrapper = recorder.wrapper
        defer { TerraformCLI.scenarioWrapper = wrapper }

        let sentinel = "acme-hunter2-SECRET"
        let checkout = out("acme-state")
        let dev = checkout.appendingPathComponent("envs/dev", isDirectory: true)
        let files: [String: String] = [
            ".gitignore": ".terraform/\n*.tfstate\n*.tfstate.*\n",
            // Committed, as a reviewed lock file is: an agent's own read of the
            // values may then start the root's providers (none here).
            "envs/dev/.terraform.lock.hcl": "# acme: no providers to lock\n",
            "envs/dev/main.tf": """
            variable "acme_db_password" {
              type      = string
              sensitive = true
              default   = "\(sentinel)"
            }

            resource "terraform_data" "acme_api" {
              input = {
                name     = "acme-api"
                port     = 8443
                password = var.acme_db_password
              }
            }

            resource "terraform_data" "acme_list" {
              count = 2
              input = "acme-${count.index}"
            }

            module "acme_net" {
              source = "../../modules/acme-net"
            }

            output "api_url" {
              value = "https://acme-api.example.test:8443/v1"
            }

            output "db_host" {
              value = "acme-db.cluster-abc.eu-west-1.rds.amazonaws.com"
            }

            output "db_password" {
              value     = var.acme_db_password
              sensitive = true
            }

            output "acme_api" {
              value = terraform_data.acme_api.output
            }

            output "cluster" {
              value = {
                name     = "acme-dev"
                endpoint = "https://ABC123.gr7.eu-west-1.eks.amazonaws.com"
                arn      = "arn:aws:eks:eu-west-1:123456789012:cluster/acme-dev"
              }
            }

            """,
            "modules/acme-net/main.tf": "resource \"terraform_data\" \"inner\" {\n  input = \"globex\"\n}\n",
        ]
        let git = URL(fileURLWithPath: "/usr/bin/git")
        do {
            for (path, text) in files {
                let url = checkout.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            _ = try Git.runBlocking(git, ["init", "-q", "-b", "main"], in: checkout, success: [0], timeout: 10)
            _ = try Git.runBlocking(git, ["add", "-A"], in: checkout, success: [0], timeout: 10)
            _ = try Git.runBlocking(
                git, ["-c", "user.name=Acme", "-c", "user.email=acme@example.test", "commit", "-q", "-m", "acme"], in: checkout, success: [0], timeout: 10)
        } catch {
            return check("state: the checkout is written", false, "\(error)")
        }
        // The state, made by the CLI in the guarded environment: Overterm never applies here.
        guard let cli = try? TerraformGuards.prepareScratch(at: out("terraform-state-cli")) else { return check("state: the CLI's scratch", false) }
        let environment = cli.environment
        let log = out("terraform-state-cli.log")
        let applied = await TerraformPanelModel.blocking { () -> Int32 in
            let initialised = Self.terraformCLI(binary, ["init", "-input=false"], in: dev, environment: environment, log: log)
            guard initialised == 0 else { return initialised }
            return Self.terraformCLI(binary, ["apply", "-auto-approve", "-input=false"], in: dev, environment: environment, log: log)
        }
        check("state: envs/dev has its state, from the CLI", applied == 0, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
        let before = recorder.calls().count

        let offers = OfferLog()
        TerraformStateReads.shared.offerRecorder = { offers.all.append($0) }
        defer { TerraformStateReads.shared.offerRecorder = nil }

        let panel = app.terraformPanel
        app.newTab(in: checkout)
        app.showTerraformPanel(nil)
        // Another scenario's checkout has an envs/dev too: this one's, once the panel follows the new tab.
        check(
            "state: the root is listed",
            await eventually(15) {
                panel.checkout.map { self.realPath($0) } == self.realPath(checkout) && panel.state == .read
                    && panel.roots.contains { $0.path == "envs/dev" }
            }, "\(panel.checkout?.path ?? "-"): \(panel.roots.map(\.path))")
        guard let card = panel.roots.first(where: { $0.path == "envs/dev" }) else { return check("state: envs/dev", false) }
        check("state: nothing read before the click", !recorder.calls().dropFirst(before).contains { $0.subcommand == "state" || $0.subcommand == "show" })

        // The person's read, in the slot: the card's State button, pressed
        // twice at once — one read, never two.
        Self.accessibilityTree(true)
        defer { Self.accessibilityTree(false) }
        guard let root = app.window?.contentView else { return check("state: the window", false) }
        panel.selectedPath = card.path
        check("state: the card's State button", await eventually(5) { Self.accessibilityPress("terraform.panel.state", in: root, press: false) })
        // Both presses before the read's first step: the second finds it going.
        let pressed = Self.accessibilityPress("terraform.panel.state", in: root) && Self.accessibilityPress("terraform.panel.state", in: root)
        check("state: pressed twice", pressed)
        guard await eventually(5, { self.app.terraformPlanPane.state != nil }), let read = app.terraformPlanPane.state else {
            return check("state: the State button starts the read", false)
        }
        check("state: the person's read, in the right slot", read.reader == .person && app.rightPane.mode == .terraformPlan)
        check("state: read", await eventually(40) { read.phase == .read }, "\(read.phase)")
        let addresses = ["module.acme_net.terraform_data.inner", "terraform_data.acme_api", "terraform_data.acme_list[0]", "terraform_data.acme_list[1]"]
        check("state: every object listed", read.addresses.sorted() == addresses, "\(read.addresses)")
        check(
            "state: grouped by module, the root's first",
            TerraformStateRows.groups(read.addresses).map(\.title) == ["root module", "module.acme_net"],
            "\(TerraformStateRows.groups(read.addresses).map(\.title))")
        guard let state = read.state else { return check("state: its values", false) }
        let outputs = Dictionary(uniqueKeysWithValues: state.outputs.map { ($0.name, $0) })
        check("state: the sensitive output is said to be, with no value", outputs["db_password"]?.sensitive == true && outputs["db_password"]?.value == nil)
        if case .object(let fields)? = outputs["acme_api"]?.value {
            check("state: its value copied into an unmarked output is masked there too", fields["password"] == .sensitive, "\(fields)")
        } else {
            check("state: the unmarked output's value", false)
        }
        if case .object(let fields)? = state.resource("terraform_data.acme_api")?.values, case .object(let output)? = fields["output"] {
            check("state: and in the attribute nothing marks", output["password"] == .sensitive, "\(output)")
        } else {
            check("state: the resource's values", false)
        }
        check(
            "state: a URL opens in the browser, a database host in the form, a cluster in Kubernetes",
            outputs["api_url"].map(TerraformOutputLinks.offers(for:))?.contains { $0.key == "browser" } == true
                && outputs["db_host"].map(TerraformOutputLinks.offers(for:))?.contains { $0.key == "database" } == true
                && outputs["cluster"].map(TerraformOutputLinks.offers(for:))?.contains { $0.key == "kubernetes" } == true
                && outputs["db_password"].map(TerraformOutputLinks.offers(for:))?.isEmpty == true)

        // What is drawn: every object open on its attributes.
        read.expanded = Set(read.addresses)
        var drawn = ""
        // The slot's element: SwiftUI folds the state view's own container
        // into the pane's ("terraform.plan"), which then is the state.
        check(
            "state: drawn, masked",
            await eventually(5) {
                drawn = Self.accessibilityElement("terraform.plan", in: root)?.text ?? ""
                return drawn.contains("State · envs/dev") && drawn.contains("db_password") && drawn.contains("sensitive") && drawn.contains("acme-api")
                    && drawn.contains(TerraformPlan.redaction)
            }, drawn)
        check("state: Open in Browser is offered", Self.accessibilityPress("terraform.state.offer.api_url.browser", in: root))
        check(
            "state: it opens the URL",
            await eventually(3) { offers.all.contains(.browser(URL(string: "https://acme-api.example.test:8443/v1")!)) }, "\(offers.all)")

        // What Overterm ran: state list and show -json, at the root, in the checked workspace.
        let calls = recorder.calls().dropFirst(before)
        let list = calls.first { $0.arguments == TerraformCommands.stateList }
        let show = calls.first { $0.arguments == TerraformCommands.showState }
        check("state: state list ran at the root", list?.cwd == realPath(dev), "\(calls.map(\.arguments))")
        check("state: once, for both presses", calls.filter { $0.arguments == TerraformCommands.stateList }.count == 1, "\(calls.map(\.arguments))")
        check("state: then show -json of the state", show?.cwd == realPath(dev) && show?.values["TF_WORKSPACE"] == "default", "\(show?.values ?? [:])")
        check(
            "state: nothing else — no output, no state pull, no write",
            calls.allSatisfy { TerraformCommands.isBuilt($0.arguments) && $0.subcommand != "output" && $0.subcommand != "apply" },
            "\(calls.map(\.arguments))")

        // An agent's tools: masked, a sensitive output never valued.
        guard let tag = app.store.selected?.terminal.processTag else { return check("state: the checkout's pane", false) }
        let listed = await stateTool("tf_state_list", ["root": "envs/dev"], pane: tag)
        check("state: tf_state_list gives the addresses by module", listed.contains("module.acme_net.terraform_data.inner") && listed.contains("root module:"), listed)
        let said = await stateTool("tf_outputs", ["root": "envs/dev"], pane: tag)
        check("state: tf_outputs says the sensitive one is, never its value", said.contains("db_password (string): sensitive") && said.contains("api_url"), said)
        let shown = await stateTool("tf_state_show", ["root": "envs/dev", "address": "terraform_data.acme_api"], pane: tag)
        check(
            "state: tf_state_show masks the password", (shown.contains("password = ••••••") || shown.contains("password = (sensitive)")) && shown.contains("acme-api"), shown)

        // The agent's own read (5.10, 5.13 rule 3): no fresh read of the
        // person's, so the tools read — state list and show -json only, in
        // the stripped environment, in the workspace checked.
        TerraformStateReads.shared.forget(checkout: checkout, root: card.path, reader: .person)
        let mark = recorder.calls().count
        let ownList = await stateTool("tf_state_list", ["root": "envs/dev"], pane: tag)
        check("state: the agent's own tf_state_list", ownList.contains("by the agent's own read") && ownList.contains("terraform_data.acme_api"), ownList)
        let ownOutputs = await stateTool("tf_outputs", ["root": "envs/dev"], pane: tag)
        check(
            "state: the agent's own tf_outputs, the sensitive one never valued",
            ownOutputs.contains("by the agent's own read") && ownOutputs.contains("db_password (string): sensitive") && ownOutputs.contains("api_url"), ownOutputs)
        let own = Array(recorder.calls().dropFirst(mark))
        check(
            "state: its runs are state list, then state list and show -json",
            own.map(\.arguments) == [TerraformCommands.stateList, TerraformCommands.stateList, TerraformCommands.showState], "\(own.map(\.arguments))")
        let home = (try? TerraformGuards.prepareScratch(at: AppEnvironment.terraformScratchDirectory))?.home.path
        check(
            "state: stripped — no credential's name, HOME the scratch one, TF_WORKSPACE the checked one, at the root",
            !own.isEmpty
                && own.allSatisfy {
                    !$0.names.contains(where: TerraformGuards.isCredential) && $0.values["HOME"] == home && $0.values["TF_WORKSPACE"] == "default"
                        && $0.cwd == realPath(dev)
                }, "\(own.map { ($0.names, $0.values) })")
        for (where_, text) in [
            ("the model", String(reflecting: state)), ("the view", drawn), ("tf_state_list", listed), ("tf_outputs", said), ("tf_state_show", shown),
            ("the agent's own tf_outputs", ownOutputs),
        ] {
            check("state: no sentinel in \(where_)", !text.contains(sentinel))
        }
    }

    /// A tool's text answer, as an agent reads it.
    private func stateTool(_ name: String, _ arguments: [String: Any], pane: String) async -> String {
        guard let result = try? await TerraformMCP.call(name, arguments, pane: pane) else { return "(threw)" }
        let content = result["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    @MainActor private final class OfferLog {
        var all: [TerraformOutputLinks.Offer] = []
    }
}
