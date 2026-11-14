import XCTest

@testable import Overterm

/// Stage 2c (analysis 2.4, 5.6, 5.10): a state's JSON through the
/// allow-list, masked at decode — a sensitive output never valued, its value
/// masked wherever it was copied; outputs into Overterm; the two reads
/// Overterm builds; the agents' tools.
final class TerraformStateTests: XCTestCase {
    static let sentinels = ["acme-hunter2-SECRET", "tok-acme-123", "globex-BKPW", "4242"]

    /// The shape Terraform 1.17.1 wrote in a sandbox (`terraform show
    /// -json` of a local state, `terraform_data` only), the sentinels
    /// planted in every place a state holds a value in clear.
    static let state = """
        {
          "format_version": "1.0",
          "terraform_version": "1.17.1",
          "planted_top": "acme-hunter2-SECRET",
          "values": {
            "outputs": {
              "api_url": {"sensitive": false, "value": "https://acme-api.example.test:8443/v1", "type": "string"},
              "db_host": {"sensitive": false, "value": "acme-db.cluster-abc.eu-west-1.rds.amazonaws.com", "type": "string"},
              "db_password": {"sensitive": true, "value": "acme-hunter2-SECRET", "type": "string"},
              "pin": {"sensitive": true, "value": 4242, "type": "number"},
              "leak": {"sensitive": false, "value": {"name": "acme-api", "password": "acme-hunter2-SECRET", "port": 8443, "note": "uses acme-hunter2-SECRET today"}, "type": ["object", {"name": "string", "note": "string", "password": "string", "port": "number"}]},
              "pin_copy": {"sensitive": false, "value": 4242, "type": "number"},
              "names": {"sensitive": false, "value": ["acme-0", "acme-1"], "type": ["list", "string"]},
              "cluster": {"sensitive": false, "value": {"name": "acme-prod", "endpoint": "https://ABC123.gr7.eu-west-1.eks.amazonaws.com", "arn": "arn:aws:eks:eu-west-1:123456789012:cluster/acme-prod"}, "type": ["object", {"arn": "string", "endpoint": "string", "name": "string"}]}
            },
            "root_module": {
              "resources": [
                {
                  "address": "terraform_data.acme_api", "mode": "managed", "type": "terraform_data", "name": "acme_api",
                  "provider_name": "terraform.io/builtin/terraform", "schema_version": 0,
                  "values": {
                    "id": "415149ff-acme",
                    "input": {"name": "acme-api", "password": "acme-hunter2-SECRET", "port": 8443},
                    "output": {"name": "acme-api", "password": "acme-hunter2-SECRET", "port": 8443},
                    "store": null, "triggers_replace": null
                  },
                  "sensitive_values": {"input": {"password": true}, "output": {}},
                  "planted": "globex-BKPW"
                },
                {
                  "address": "terraform_data.globex", "mode": "managed", "type": "terraform_data", "name": "globex",
                  "provider_name": "terraform.io/builtin/terraform", "tainted": true,
                  "values": {"id": "globex-1", "input": {"token": "tok-acme-123", "key_name": "globex-key", "kms_key_id": "alias/globex"}, "output": null},
                  "sensitive_values": {},
                  "depends_on": ["terraform_data.acme_api"]
                },
                {
                  "address": "terraform_data.acme_list[0]", "mode": "managed", "type": "terraform_data", "name": "acme_list", "index": 0,
                  "provider_name": "terraform.io/builtin/terraform", "values": {"id": "acme-0", "input": "acme-0"}, "sensitive_values": {}
                },
                {
                  "address": "data.terraform_remote_state.globex", "mode": "data", "type": "terraform_remote_state", "name": "globex",
                  "provider_name": "terraform.io/builtin/terraform", "values": {"backend": "local", "outputs": {"secret_word": "globex-BKPW"}},
                  "sensitive_values": {"outputs": true}
                }
              ],
              "child_modules": [
                {
                  "address": "module.acme_net",
                  "resources": [
                    {
                      "address": "module.acme_net.terraform_data.inner", "mode": "managed", "type": "terraform_data", "name": "inner",
                      "provider_name": "terraform.io/builtin/terraform", "values": {"id": "inner-1", "input": "globex"}, "sensitive_values": {}
                    }
                  ]
                }
              ]
            }
          }
        }
        """

    static func decoded(agents: Bool = false) throws -> TerraformState {
        try TerraformState.decode(Data(Self.state.utf8), secretName: agents ? TerraformSecretNames.forAgents : TerraformSecretNames.isSecret)
    }

    func testTheAllowListAndTheMasks() throws {
        let state = try Self.decoded()
        XCTAssertEqual(state.terraformVersion, "1.17.1")
        XCTAssertEqual(
            state.resources.map(\.address),
            ["terraform_data.acme_api", "terraform_data.globex", "terraform_data.acme_list[0]", "data.terraform_remote_state.globex", "module.acme_net.terraform_data.inner"])
        XCTAssertEqual(state.resources.last?.module, "module.acme_net")
        XCTAssertEqual(state.modules, [nil, "module.acme_net"])
        let api = try XCTUnwrap(state.resource("terraform_data.acme_api"))
        guard case .object(let fields)? = api.values, case .object(let input)? = fields["input"], case .object(let output)? = fields["output"] else {
            return XCTFail("values")
        }
        XCTAssertEqual(input["password"], .sensitive, "marked by sensitive_values")
        XCTAssertEqual(output["password"], .sensitive, "the same value where nothing marks it")
        XCTAssertEqual(input["name"], .string("acme-api"))
        XCTAssertEqual(input["port"], .number("8443"))
        let globex = try XCTUnwrap(state.resource("terraform_data.globex"))
        XCTAssertTrue(globex.tainted)
        XCTAssertEqual(globex.dependsOn, ["terraform_data.acme_api"])
        guard case .object(let globexFields)? = globex.values, case .object(let globexInput)? = globexFields["input"] else { return XCTFail("globex") }
        XCTAssertEqual(globexInput["token"], .sensitive, "a token by its name, though unmarked")
        XCTAssertEqual(globexInput["key_name"], .string("globex-key"), "a key's name is what a reviewer reads")
        XCTAssertEqual(globexInput["kms_key_id"], .string("alias/globex"))
        XCTAssertTrue(state.resource("data.terraform_remote_state.globex")?.isData == true)

        let outputs = Dictionary(uniqueKeysWithValues: state.outputs.map { ($0.name, $0) })
        XCTAssertEqual(outputs["db_password"]?.sensitive, true)
        XCTAssertNil(outputs["db_password"]?.value, "a sensitive output is never valued")
        XCTAssertNil(outputs["pin"]?.value)
        XCTAssertEqual(outputs["pin_copy"]?.value, .sensitive, "a sensitive number copied into an unmarked output")
        guard case .object(let leak)? = outputs["leak"]?.value else { return XCTFail("leak") }
        XCTAssertEqual(leak["password"], .sensitive)
        XCTAssertEqual(leak["note"], .sensitive, "a string holding a sensitive value is masked whole")
        XCTAssertEqual(outputs["api_url"]?.value, .string("https://acme-api.example.test:8443/v1"))
        XCTAssertEqual(outputs["names"]?.type, "list(string)")
        XCTAssertEqual(outputs["leak"]?.type, "object({name=string, note=string, password=string, port=number})")
    }

    /// 5.6 rule 12: no sentinel survives anywhere a state's decode reaches.
    func testNoSentinelSurvives() throws {
        for agents in [false, true] {
            let state = try Self.decoded(agents: agents)
            var texts = [String(reflecting: state), TerraformStateText.outputs(state.outputs, root: "envs/dev")]
            texts.append(TerraformStateText.list(state.resources.map(\.address), capped: false, root: "envs/dev"))
            for resource in state.resources { texts.append(TerraformStateText.resource(resource, root: "envs/dev")) }
            texts += state.outputs.flatMap(TerraformOutputLinks.offers(for:)).map { "\($0)" }
            for sentinel in Self.sentinels {
                for text in texts { XCTAssertFalse(text.contains(sentinel), "\(sentinel) in \(text.prefix(200))") }
            }
            XCTAssertFalse(String(reflecting: state).contains("planted"), "a key outside the allow-list is dropped")
            XCTAssertFalse(String(reflecting: state).contains("schema_version"))
        }
    }

    func testAgentsMaskTheBroaderNames() throws {
        let json = """
            {"format_version": "1.0", "values": {"outputs": {"session_key": {"sensitive": false, "value": "acme-session", "type": "string"}},
              "root_module": {"resources": [{"address": "a.b", "mode": "managed", "type": "a", "name": "b", "provider_name": "p",
                "values": {"private_key_id": "acme-kid", "region": "eu-west-1"}, "sensitive_values": {}}]}}}
            """
        let person = try TerraformState.decode(Data(json.utf8))
        XCTAssertEqual(person.outputs.first?.value, .string("acme-session"))
        let agents = person.forAgents()
        XCTAssertTrue(agents.outputs.first?.sensitive == true && agents.outputs.first?.value == nil)
        guard case .object(let fields)? = agents.resources.first?.values else { return XCTFail("values") }
        XCTAssertEqual(fields["private_key_id"], .sensitive)
        XCTAssertEqual(fields["region"], .string("eu-west-1"), "still readable to an agent")
    }

    func testFormatsAndEmptyStates() throws {
        XCTAssertThrowsError(try TerraformState.decode(Data(#"{"format_version": "2.0"}"#.utf8)))
        XCTAssertThrowsError(try TerraformState.decode(Data("not json".utf8)))
        let empty = try TerraformState.decode(Data(#"{"format_version": "1.0"}"#.utf8))
        XCTAssertTrue(empty.resources.isEmpty && empty.outputs.isEmpty, "an empty workspace's state has no values")
        let missing = try TerraformState.decode(Data(#"{"format_version": "1.0", "values": {"outputs": {"x": {"value": "acme-hunter2-SECRET"}}}}"#.utf8))
        XCTAssertEqual(missing.outputs.first?.sensitive, true, "an output that doesn't say is taken as sensitive")
        XCTAssertNil(missing.outputs.first?.value)
    }

    func testStateList() {
        let parsed = TerraformStateList.parse(
            "terraform_data.acme_api\nterraform_data.acme_list[0]\n\nmodule.acme_net.terraform_data.inner\nmodule.a[\"x.y\"].module.b.aws_x.y[0]\n-flag\n")
        XCTAssertEqual(parsed.addresses.count, 4)
        XCTAssertFalse(parsed.capped)
        XCTAssertEqual(TerraformStateList.module(of: "module.a[\"x.y\"].module.b.aws_x.y[0]"), "module.a[\"x.y\"].module.b")
        XCTAssertEqual(TerraformStateList.module(of: "module.acme_net.terraform_data.inner"), "module.acme_net")
        XCTAssertNil(TerraformStateList.module(of: "terraform_data.acme_list[0]"))
        let groups = TerraformStateRows.groups(parsed.addresses)
        XCTAssertEqual(groups.map(\.title), ["root module", "module.a[\"x.y\"].module.b", "module.acme_net"])
        XCTAssertEqual(TerraformStateRows.groups(parsed.addresses, filter: "INNER").map(\.title), ["module.acme_net"])
        XCTAssertEqual(TerraformStateList.parse("a.b\u{202E}c\n").addresses, ["a.b\\u{202E}c"], "a bidi character escaped")
    }

    /// The view's groups and objects, made once when the addresses come:
    /// the filter only narrows them, a current object found before a deposed one.
    func testTheReadArrangesOnce() throws {
        var state = try Self.decoded()
        var deposed = try XCTUnwrap(state.resources.first { $0.address == "terraform_data.globex" })
        deposed.deposed = "acme0001"
        deposed.tainted = false
        state.resources.insert(deposed, at: 0)
        let arranged = TerraformStateRead.arrange(state, listed: [], listedCapped: false)
        XCTAssertEqual(arranged.addresses.filter { $0 == "terraform_data.globex" }.count, 1, "a deposed object listed once")
        XCTAssertNil(arranged.resources["terraform_data.globex"]?.deposed, "the current object, not the deposed one")
        XCTAssertEqual(arranged.groups, TerraformStateRows.groups(arranged.addresses))
        XCTAssertEqual(TerraformStateRows.filtered(arranged.groups, filter: "INNER").map(\.title), ["module.acme_net"])
        XCTAssertEqual(TerraformStateRows.filtered(arranged.groups, filter: " "), arranged.groups)
        XCTAssertEqual(
            TerraformStateRows.filtered(arranged.groups, filter: "acme").flatMap(\.addresses),
            TerraformStateRows.groups(arranged.addresses, filter: "acme").flatMap(\.addresses))
        let capped = TerraformStateRead.arrange(state, listed: ["terraform_data.acme_api"], listedCapped: true)
        XCTAssertEqual(capped.addresses, ["terraform_data.acme_api"], "a list cut short keeps state list's addresses")
    }

    /// The two reads stage 2c builds, and nothing near them.
    func testTheStateReadsAreTheOnlyStateLines() {
        XCTAssertNil(TerraformCommands.refusal(TerraformCommands.stateList))
        XCTAssertNil(TerraformCommands.refusal(TerraformCommands.showState))
        XCTAssertEqual(TerraformCommands.stateList, ["state", "list", "-no-color"])
        XCTAssertEqual(TerraformCommands.showState, ["show", "-json", "-no-color"])
        let refused: [[String]] = [
            ["state", "list"], ["state", "list", "-no-color", "-state=other.tfstate"], ["state", "pull"], ["state", "show", "a.b"], ["state", "rm", "a.b"],
            ["state", "push", "x"], ["show", "-json"], ["show", "-json", "-no-color", "terraform.tfstate"], ["show", "-no-color"], ["output", "-json"],
            ["output", "db_password"], ["-chdir=envs/dev", "state", "list", "-no-color"],
        ]
        for arguments in refused { XCTAssertNotNil(TerraformCommands.refusal(arguments), "\(arguments)") }
        XCTAssertNil(TerraformProcessCheck.refused(.stateList, rootClass: .production), "a read starts on every class")
        XCTAssertNil(TerraformProcessCheck.refused(.show, rootClass: .production))
    }

    // MARK: Outputs into Overterm

    func testOffers() throws {
        let state = try Self.decoded()
        let outputs = Dictionary(uniqueKeysWithValues: state.outputs.map { ($0.name, $0) })
        let url = URL(string: "https://acme-api.example.test:8443/v1")!
        XCTAssertEqual(TerraformOutputLinks.offers(for: outputs["api_url"]!), [.browser(url), .apiVariable(name: "api_url", value: url.absoluteString)])
        XCTAssertEqual(
            TerraformOutputLinks.offers(for: outputs["db_host"]!),
            [.database(kind: .postgres, host: "acme-db.cluster-abc.eu-west-1.rds.amazonaws.com", port: nil, database: nil)])
        XCTAssertEqual(
            TerraformOutputLinks.offers(for: outputs["cluster"]!),
            [.kubernetes(.init(service: .eks, name: "acme-prod", server: "abc123.gr7.eu-west-1.eks.amazonaws.com"))],
            "the cluster's API server isn't offered as a page")
        XCTAssertTrue(TerraformOutputLinks.offers(for: outputs["db_password"]!).isEmpty, "a sensitive output offers nothing")
        XCTAssertTrue(TerraformOutputLinks.offers(for: outputs["leak"]!).allSatisfy { $0.key != "database" })
        func output(_ name: String, _ value: TerraformValue) -> TerraformState.Output { .init(name: name, type: "string", sensitive: false, value: value) }
        XCTAssertEqual(
            TerraformOutputLinks.offers(for: output("dsn", .string("postgres://acme:hunter@acme-db.internal:6543/acme_app"))),
            [.database(kind: .postgres, host: "acme-db.internal", port: 6543, database: "acme_app")], "a URL's host, port, database — never its password")
        XCTAssertEqual(
            TerraformOutputLinks.offers(for: output("db", .object(["endpoint": .string("acme.mysql.example.test"), "port": .number("3306")]))),
            [.database(kind: .mysql, host: "acme.mysql.example.test", port: 3306, database: nil)])
        XCTAssertTrue(TerraformOutputLinks.offers(for: output("site", .string("https://acme:pw@acme.example.test/"))).isEmpty, "no URL with a password in it")
        XCTAssertTrue(TerraformOutputLinks.offers(for: output("site", .sensitive)).isEmpty)
        XCTAssertTrue(TerraformOutputLinks.offers(for: output("bucket", .string("acme-logs"))).isEmpty)
        XCTAssertTrue(TerraformOutputLinks.offers(for: output("instance_host", .string("acme-web.example.test"))).isEmpty, "a host that says nothing of a database")
        XCTAssertEqual(
            TerraformOutputLinks.offers(for: output("gke", .string("projects/acme-prj/locations/europe-west1/clusters/acme-gke"))),
            [.kubernetes(.init(service: .gke, name: "acme-gke", server: nil))])
        XCTAssertEqual(TerraformOutputLinks.variableName("service.endpoint[0]"), "service_endpoint_0")
    }

    func testTheClustersContext() {
        let contexts: [(name: String, cluster: String, server: String?)] = [
            ("globex", "globex", "https://globex.example.test"),
            ("acme-admin", "arn:aws:eks:eu-west-1:123456789012:cluster/acme-prod", "https://ABC123.gr7.eu-west-1.eks.amazonaws.com"),
            ("gke_acme-prj_europe-west1_acme-gke", "gke_acme-prj_europe-west1_acme-gke", "https://10.0.0.1"),
        ]
        XCTAssertEqual(TerraformOutputLinks.context(for: .init(service: .eks, name: nil, server: "abc123.gr7.eu-west-1.eks.amazonaws.com"), in: contexts), "acme-admin")
        XCTAssertEqual(TerraformOutputLinks.context(for: .init(service: .eks, name: "acme-prod", server: nil), in: contexts), "acme-admin")
        XCTAssertEqual(TerraformOutputLinks.context(for: .init(service: .gke, name: "acme-gke", server: nil), in: contexts), "gke_acme-prj_europe-west1_acme-gke")
        XCTAssertNil(TerraformOutputLinks.context(for: .init(service: .aks, name: "acme", server: nil), in: contexts), "acme-prod isn't acme")
        XCTAssertEqual(TerraformOutputLinks.kubeconfigHint(for: .init(service: .eks, name: "acme-prod", server: nil)), "aws eks update-kubeconfig --name acme-prod")
    }

    /// Add to API environment: the variable set, every other byte kept.
    func testTheEnvironmentKeepsItsFile() throws {
        let text = "vars {\n  base_url: http://localhost:3000\n}\n\nvars:secret [\n  api_token\n]\n"
        let added = try XCTUnwrap(TerraformOutputLinks.environment(text, setting: "api_url", to: "https://acme-api.example.test"))
        XCTAssertTrue(added.contains("api_url: https://acme-api.example.test"), added)
        XCTAssertTrue(added.hasSuffix("vars:secret [\n  api_token\n]\n"), "the secrets' block as it was")
        XCTAssertTrue(added.contains("base_url: http://localhost:3000"))
        let changed = try XCTUnwrap(TerraformOutputLinks.environment(added, setting: "api_url", to: "https://globex.example.test"))
        XCTAssertEqual(changed.components(separatedBy: "api_url:").count, 2, "changed in place, not added twice")
        XCTAssertNil(TerraformOutputLinks.environment(text, setting: "api_token", to: "x"), "never over a secret")
    }
}

/// The agents' state tools (5.10): production's objects not shown, a
/// read without credentials refused where the providers can't start, the
/// person's read answering, masked again.
@MainActor
final class TerraformStateMCPTests: XCTestCase {
    private var checkout: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-state-\(UUID().uuidString)", isDirectory: true)
        checkout = base.appendingPathComponent("acme-live", isDirectory: true)
        for folder in ["envs/dev", "envs/prod"] {
            try FileManager.default.createDirectory(at: checkout.appendingPathComponent(folder), withIntermediateDirectories: true)
            try "resource \"terraform_data\" \"acme\" {\n  input = \"acme\"\n}\n".write(
                to: checkout.appendingPathComponent(folder + "/main.tf"), atomically: true, encoding: .utf8)
        }
        let git = URL(fileURLWithPath: "/usr/bin/git")
        _ = try Git.runBlocking(git, ["init", "-q", "-b", "main"], in: checkout, success: [0], timeout: 10)
        _ = try Git.runBlocking(git, ["add", "-A"], in: checkout, success: [0], timeout: 10)
        _ = try Git.runBlocking(
            git, ["-c", "user.name=Acme", "-c", "user.email=acme@example.test", "commit", "-q", "-m", "acme"], in: checkout, success: [0], timeout: 10)
        let top = checkout!
        TerraformMCP.paneCheckout = { $0 == "acme-state-pane" ? top : nil }
    }

    override func tearDown() async throws {
        TerraformMCP.paneCheckout = nil
        try? FileManager.default.removeItem(at: checkout.deletingLastPathComponent())
    }

    private func text(_ name: String, _ arguments: [String: Any]) async throws -> String {
        let result = try await TerraformMCP.call(name, arguments, pane: "acme-state-pane")
        return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    func testProductionsObjectsAreNotShown() async throws {
        let said = try await text("tf_state_show", ["root": "envs/prod", "address": "terraform_data.acme"])
        XCTAssertTrue(said.contains("is production: tf_state_show is off there"), said)
    }

    func testValuesNeedProvidersThatMayStart() async throws {
        let said = try await text("tf_outputs", ["root": "envs/dev"])
        XCTAssertTrue(said.contains("starts its providers") && said.contains("no .terraform.lock.hcl"), said)
    }

    // MARK: The read itself, behind the recording wrapper

    /// A stand-in terraform that answers as the read needs: `workspace
    /// list`, `state list`, `show -json` of the planted state — or sleeps.
    private func recorder(workspaces: String = "* default\n", sleep: Bool = false) throws -> TerraformRecorder {
        let folder = checkout.deletingLastPathComponent().appendingPathComponent("tf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let standIn = folder.appendingPathComponent("stand-in/terraform")
        try FileManager.default.createDirectory(at: standIn.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = folder.appendingPathComponent("stand-in/state.json")
        try Data(TerraformStateTests.state.utf8).write(to: json)
        let script = """
            #!/bin/bash -p
            \(sleep ? "exec /bin/sleep 30" : "")
            case "$1 $2" in
              "workspace list") printf '%s' \(TerraformRecorder.quoted(workspaces)) ;;
              "state list") printf 'terraform_data.acme_api\\nmodule.acme_net.terraform_data.inner\\n' ;;
              "show -json") /bin/cat \(TerraformRecorder.quoted(json.path)) ;;
              *) exit 9 ;;
            esac

            """
        try Data(script.utf8).write(to: standIn)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: standIn.path)
        return try TerraformRecorder.make(in: folder.appendingPathComponent("recorder"), target: standIn.path)
    }

    private func card(_ path: String) async throws -> TerraformRootCard {
        let listed = await TerraformMCP.read(checkout)
        return try XCTUnwrap(listed?.roots.first { $0.path == path }, "\(listed?.roots.map(\.path) ?? [])")
    }

    private func select(_ workspace: String, in root: String) throws {
        let data = checkout.appendingPathComponent(root + "/.terraform", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data((workspace + "\n").utf8).write(to: data.appendingPathComponent("environment"))
    }

    private func httpRoot() throws {
        let folder = checkout.appendingPathComponent("envs/qa", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        terraform {
          backend "http" {
            address = "http://127.0.0.1:9/acme-qa"
          }
        }

        resource "terraform_data" "acme" {
          input = "acme"
        }

        """.write(to: folder.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
    }

    /// 4.9, 5.13 rule 4: a workspace that doesn't exist refuses the read
    /// before `state list` or `show` — a local backend's by its folders.
    func testAMissingLocalWorkspaceIsRefusedBeforeAnyRead() async throws {
        try select("acme-gone", in: "envs/dev")
        let card = try await card("envs/dev")
        XCTAssertEqual(card.workspace, "acme-gone")
        let recorder = try recorder()
        let read = TerraformStateRead(checkout: checkout, card: card)
        await read.start(registry: TerraformRunRegistry(), settingPath: "", binary: recorder.wrapper)
        guard case .refused(let why) = read.phase else { return XCTFail("\(read.phase)") }
        XCTAssertTrue(why.contains("acme-gone") && why.contains("no longer exists"), why)
        XCTAssertTrue(recorder.calls().isEmpty, "\(recorder.calls().map(\.arguments))")
    }

    /// The same of a remote backend: `workspace list` asked (no
    /// `TF_WORKSPACE`), and nothing after it.
    func testAMissingRemoteWorkspaceIsRefusedAfterTheListAlone() async throws {
        try httpRoot()
        try select("acme-gone", in: "envs/qa")
        let card = try await card("envs/qa")
        let recorder = try recorder(workspaces: "* default\n  acme-stage\n")
        let read = TerraformStateRead(checkout: checkout, card: card)
        await read.start(registry: TerraformRunRegistry(), settingPath: "", binary: recorder.wrapper)
        guard case .refused(let why) = read.phase else { return XCTFail("\(read.phase)") }
        XCTAssertTrue(why.contains("acme-gone"), why)
        let calls = recorder.calls()
        XCTAssertEqual(calls.map(\.arguments), [TerraformCommands.workspaceList])
        XCTAssertNil(calls.first?.values["TF_WORKSPACE"], "workspace list refuses a pinned shell")
    }

    /// An agent's own read (5.10, 5.13 rule 3): `state list` and `show
    /// -json` only, in the stripped environment — its HOME the scratch one,
    /// `TF_WORKSPACE` the checked workspace, no credential's name — the
    /// values masked for agents.
    func testAnAgentsOwnReadIsStrippedAndRecorded() async throws {
        let card = try await card("envs/dev")
        let recorder = try recorder()
        let read = TerraformStateRead(checkout: checkout, card: card, reader: .agent)
        await read.start(registry: TerraformRunRegistry(), settingPath: "", binary: recorder.wrapper)
        XCTAssertEqual(read.phase, .read)
        let calls = recorder.calls()
        XCTAssertEqual(calls.map(\.arguments), [TerraformCommands.stateList, TerraformCommands.showState])
        let scratch = try TerraformGuards.prepareScratch(at: AppEnvironment.terraformScratchDirectory)
        for call in calls {
            XCTAssertEqual(call.values["TF_WORKSPACE"], "default")
            XCTAssertEqual(call.values["HOME"], scratch.home.path)
            XCTAssertEqual(call.values["TF_CLI_CONFIG_FILE"], scratch.cliConfig.path)
            XCTAssertEqual(
                call.cwd,
                realpath(card.folder.path, nil).map { pointer in
                    defer { free(pointer) }
                    return String(cString: pointer)
                })
            XCTAssertFalse(call.names.contains(where: TerraformGuards.isCredential), "\(call.names)")
        }
        XCTAssertEqual(read.resource("terraform_data.acme_api")?.address, "terraform_data.acme_api")
        let said = String(reflecting: read.state)
        for sentinel in TerraformStateTests.sentinels { XCTAssertFalse(said.contains(sentinel), sentinel) }
    }

    /// An agent never reads a remote backend's state itself: initialising
    /// it would use what its init record holds — credentials too (spike 4).
    func testAnAgentNeverReadsARemoteState() async throws {
        try httpRoot()
        let said = try await text("tf_state_list", ["root": "envs/qa"])
        XCTAssertTrue(said.contains("never reaches") && said.contains("open State"), said)
        let card = try await card("envs/qa")
        let recorder = try recorder()
        let read = TerraformStateRead(checkout: checkout, card: card, reader: .agent, values: false)
        await read.start(registry: TerraformRunRegistry(), settingPath: "", binary: recorder.wrapper)
        guard case .refused = read.phase else { return XCTFail("\(read.phase)") }
        XCTAssertTrue(recorder.calls().isEmpty, "\(recorder.calls().map(\.arguments))")
    }

    /// An agent's own read stays inside the pane's checkout (5.10): a local
    /// backend whose `path` or `workspace_dir` leaves it — written there,
    /// or reached through a link — is refused; inside, it is read.
    func testAnAgentNeverReadsALocalStateOutsideTheCheckout() throws {
        let root = checkout.appendingPathComponent("envs/dev", isDirectory: true)
        let outside = checkout.deletingLastPathComponent().appendingPathComponent("globex-live", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        func refusal(_ settings: [String: String], workspace: String = "default") -> String? {
            TerraformStateRead.agentLocalRefusal(
                backend: .init(type: "local", settings: settings), workspace: workspace, root: root, checkout: checkout)
        }
        XCTAssertNil(refusal([:]), "terraform.tfstate in the root")
        XCTAssertNil(refusal(["path": "state/acme.tfstate", "workspace_dir": "../dev-states"]))
        XCTAssertNil(refusal([:], workspace: "acme-qa"))
        XCTAssertNil(TerraformStateRead.agentLocalRefusal(backend: .init(type: "s3"), workspace: "default", root: root, checkout: checkout))
        for settings in [
            ["path": outside.appendingPathComponent("terraform.tfstate").path], ["path": "../../../globex-live/terraform.tfstate"],
            ["workspace_dir": outside.path], ["workspace_dir": "../../../globex-live"], ["path": "~/acme.tfstate"],
        ] {
            let said = refusal(settings) ?? ""
            XCTAssertTrue(said.contains("outside the checkout"), "\(settings): \(said)")
        }
        // Through a link: the default file, or a folder on the way, pointing out.
        let state = root.appendingPathComponent("terraform.tfstate")
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: outside.appendingPathComponent("terraform.tfstate"))
        XCTAssertNotNil(refusal([:]), "terraform.tfstate a link out, its target not even there")
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("acme-link"), withDestinationURL: outside)
        XCTAssertNotNil(refusal(["path": "acme-link/terraform.tfstate"]))
        XCTAssertNotNil(refusal(["workspace_dir": "acme-link"], workspace: "acme-qa"))
        XCTAssertNotNil(refusal(["path": "acme-link/../dev.tfstate"]), "`..` taken after the link, as the system does: lexically the root, physically beside the checkout")
    }

    /// The read itself refuses before running anything, and so does tf_state_list.
    func testAnAgentsReadOfALocalStateOutsideIsRefusedBeforeAnyRun() async throws {
        let folder = checkout.appendingPathComponent("envs/far", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let away = checkout.deletingLastPathComponent().appendingPathComponent("globex-live/terraform.tfstate").path
        try "terraform {\n  backend \"local\" {\n    path = \"\(away)\"\n  }\n}\n\nresource \"terraform_data\" \"acme\" {}\n".write(
            to: folder.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        let said = try await text("tf_state_list", ["root": "envs/far"])
        XCTAssertTrue(said.contains("outside the checkout"), said)
        let card = try await card("envs/far")
        let recorder = try recorder()
        let read = TerraformStateRead(checkout: checkout, card: card, reader: .agent, values: false)
        await read.start(registry: TerraformRunRegistry(), settingPath: "", binary: recorder.wrapper)
        guard case .refused(let why) = read.phase else { return XCTFail("\(read.phase)") }
        XCTAssertTrue(why.contains("outside the checkout"), why)
        XCTAssertTrue(recorder.calls().isEmpty, "\(recorder.calls().map(\.arguments))")
    }

    /// A read stopped while terraform runs: the run interrupted, nothing
    /// lands after.
    func testAStoppedReadEndsItsRun() async throws {
        let card = try await card("envs/dev")
        let recorder = try recorder(sleep: true)
        let read = TerraformStateRead(checkout: checkout, card: card)
        let started = Date()
        read.begin(settingPath: "", registry: TerraformRunRegistry(), binary: recorder.wrapper)
        let task = try XCTUnwrap(read.task)
        for _ in 0..<100 where recorder.calls().isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(recorder.calls().map(\.arguments), [TerraformCommands.stateList])
        XCTAssertTrue(read.isGoing)
        read.stop()
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "the sleeping stand-in was interrupted")
        guard case .failed(let why) = read.phase else { return XCTFail("\(read.phase)") }
        XCTAssertTrue(why.hasPrefix("Stopped"), why)
        XCTAssertTrue(read.addresses.isEmpty && read.state == nil, "nothing landed after")
    }

    func testThePersonsReadAnswersMaskedAgain() async throws {
        let listed = await TerraformMCP.read(checkout)
        let card = try XCTUnwrap(listed?.roots.first { $0.path == "envs/dev" })
        let person = TerraformStateRead(checkout: checkout, card: card)
        person.landed(try TerraformStateTests.decoded())
        TerraformStateReads.shared.add(person)
        let outputs = try await text("tf_outputs", ["root": "envs/dev"])
        XCTAssertTrue(outputs.contains("From the state the person read"), outputs)
        XCTAssertTrue(outputs.contains("db_password (string): sensitive — never shown"), outputs)
        XCTAssertTrue(outputs.contains("api_url (string) = \"https://acme-api.example.test:8443/v1\""), outputs)
        let shown = try await text("tf_state_show", ["root": "envs/dev", "address": "terraform_data.acme_api"])
        XCTAssertTrue(shown.contains("password = ••••••") && shown.contains("name = \"acme-api\""), shown)
        let addresses = try await text("tf_state_list", ["root": "envs/dev"])
        XCTAssertTrue(addresses.contains("module.acme_net:") && addresses.contains("  terraform_data.acme_list[0]"), addresses)
        let missing = try await text("tf_state_show", ["root": "envs/dev", "address": "terraform_data.acme"])
        XCTAssertTrue(missing.contains("isn't in the state"), missing)
        for text in [outputs, shown, addresses] {
            for sentinel in TerraformStateTests.sentinels { XCTAssertFalse(text.contains(sentinel), sentinel) }
        }
    }
}
